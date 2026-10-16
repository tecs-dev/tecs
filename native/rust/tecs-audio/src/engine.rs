//! One output, the clips loaded against it, and the seam Tecs drives it by.
//!
//! Everything a command needs from a file is prepared before the mixer lock is
//! taken. A `PLAY` on a resident clip becomes a reference count and a `PLAY` on
//! a streamed one becomes an open decoder, and only then does the batch reach
//! the mixer. The output callback therefore never waits on a file.

use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use crate::command::{self, Command, Event};
use crate::decode::{self, Streamer};
use crate::device::{self, Output};
use crate::fm::{self, FmPort, Kind};
use crate::mixer::Mixer;
use crate::source::{ResidentSource, Source, MAX_CHANNELS};
use crate::stream::Feeder;
use crate::synth::{self, Port, Settings};

/// Measures a clip's duration against the streaming threshold.
pub const MODE_AUTO: u32 = 0;

/// Holds a clip's decoded samples in memory.
pub const MODE_RESIDENT: u32 = 1;

/// Reads a clip from its file for each voice.
pub const MODE_STREAM: u32 = 2;

/// A loaded clip, in whichever of the two forms it settled on.
enum Clip {
    /// Decoded once and shared by every voice reading it.
    Resident {
        samples: Arc<[f32]>,
        channels: u16,
        sample_rate: u32,
        duration: f64,
    },
    /// Opened afresh by every voice, which is what makes a long piece of music
    /// cost one decoder rather than its whole length in memory.
    Streamed { path: String, duration: f64 },
}

/// Reports what a load settled on, for the caller to hand back to Tecs.
pub struct Loaded {
    /// The audio duration in seconds, and zero when the input cannot say.
    pub duration: f64,
    /// Whether decoded samples stay in memory.
    pub resident: bool,
}

/// One audio output and everything Tecs reaches it through.
pub struct Engine {
    mixer: Arc<Mutex<Mixer>>,
    clips: RwLock<HashMap<u32, Clip>>,
    /// SoundFonts by the id `load_sound_font` handed out, shared by every
    /// synthesizer opened on one.
    fonts: RwLock<HashMap<u32, Arc<rustysynth::SoundFont>>>,
    next_font: Mutex<u32>,
    /// Synthesizers opened and not yet started, General MIDI and FM alike, by
    /// the voice handle whose `PLAY` will take them.
    synths: Mutex<HashMap<u32, Box<dyn Source>>>,
    feeder: Feeder,
    output: Option<Output>,
    /// The reason the most recent failing call gave, kept so the binding can
    /// read it after the fact rather than carrying a string across the seam on
    /// every call.
    last_error: Mutex<String>,
    /// The same reason as a C string, so the binding can borrow it. Replaced
    /// rather than added to, which is why a caller has to read it before its
    /// next call on this device.
    reported: Mutex<CString>,
    sample_rate: u32,
    channels: u16,
    available: bool,
    failed: Arc<AtomicBool>,
}

impl Engine {
    /// Opens the default output and returns the engine driving it.
    ///
    /// A machine with no sound still gets an engine. It reports `available` as
    /// false, takes every command, and mixes nothing, because a game that has
    /// to branch on whether audio exists is a game that gets the branch wrong.
    pub fn open(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        match device::open(sample_rate, channels, max_voices) {
            Ok((output, mixer)) => {
                let rate = output.sample_rate;
                let opened = output.channels;
                Engine::assemble(mixer, Some(output), rate, opened, true, String::new())
            }
            Err(reason) => {
                let mixer = Arc::new(Mutex::new(Mixer::new(sample_rate, channels, max_voices)));
                Engine::assemble(mixer, None, sample_rate, channels, false, reason)
            }
        }
    }

    /// Creates an engine with no device, whose buffers the caller renders.
    ///
    /// This is the deterministic path: `render` produces exactly the frames it
    /// is asked for, on the calling thread, with no device, no output thread
    /// and no clock. Tests drive the mixer through it, and so can a headless
    /// host that wants audio it can capture.
    pub fn open_offline(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        let mixer = Arc::new(Mutex::new(Mixer::new(sample_rate, channels, max_voices)));
        Engine::assemble(mixer, None, sample_rate, channels, false, String::new())
    }

    fn assemble(
        mixer: Arc<Mutex<Mixer>>,
        output: Option<Output>,
        sample_rate: u32,
        channels: u16,
        available: bool,
        reason: String,
    ) -> Engine {
        let failed = output
            .as_ref()
            .map(|output| Arc::clone(&output.failed))
            .unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
        Engine {
            failed,
            mixer,
            clips: RwLock::new(HashMap::new()),
            fonts: RwLock::new(HashMap::new()),
            next_font: Mutex::new(0),
            synths: Mutex::new(HashMap::new()),
            feeder: Feeder::start(),
            output,
            last_error: Mutex::new(reason),
            reported: Mutex::new(CString::default()),
            sample_rate,
            channels,
            available,
        }
    }

    /// Reports whether a real output opened.
    pub fn available(&self) -> bool {
        self.available && !self.failed()
    }

    /// Reports a terminal output-stream error, distinct from an offline engine.
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    /// Reports the frames per second the output runs at.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Reports the channels the output runs with.
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Returns the reason the most recent failing call gave.
    pub fn last_error(&self) -> String {
        match self.last_error.lock() {
            Err(_) => String::new(),
            Ok(value) => value.clone(),
        }
    }

    /// Returns the same reason as a borrowed C string.
    ///
    /// The pointer aliases storage this engine owns and the next call replaces
    /// it, so a caller reads the string before doing anything else here.
    pub fn last_error_cstr(&self) -> *const c_char {
        let text = CString::new(self.last_error()).unwrap_or_default();
        match self.reported.lock() {
            Err(_) => std::ptr::null(),
            Ok(mut slot) => {
                *slot = text;
                slot.as_ptr()
            }
        }
    }

    /// Records the reason a call is about to report.
    pub(crate) fn fail(&self, reason: String) -> String {
        if let Ok(mut slot) = self.last_error.lock() {
            *slot = reason.clone();
        }
        reason
    }

    /// Reads a file and holds it under `clip`.
    ///
    /// @return what the load settled on, or the reason nothing was loaded
    pub fn load_clip(
        &self,
        path: &str,
        clip: u32,
        mode: u32,
        stream_seconds: f32,
    ) -> Result<Loaded, String> {
        let duration = match mode {
            MODE_RESIDENT => None,
            _ => decode::probe_duration(path).map_err(|reason| self.fail(reason))?,
        };
        // A file that will not say how long it is stays resident, because the
        // question the threshold answers is whether the clip is large and an
        // unanswered one is more likely a sound effect than a soundtrack.
        let resident = match mode {
            MODE_RESIDENT => true,
            MODE_STREAM => false,
            _ => duration.is_none_or(|seconds| seconds <= stream_seconds as f64),
        };

        let entry = if resident {
            let decoded = decode::decode_all(path).map_err(|reason| self.fail(reason))?;
            self.resident(path, decoded)?
        } else {
            // Opened and dropped, so a path that cannot be read fails here
            // rather than silently producing a voice that never sounds.
            let streamer = Streamer::open(path).map_err(|reason| self.fail(reason))?;
            if streamer.channels() == 0 || streamer.channels() as usize > MAX_CHANNELS {
                return Err(self.fail(format!(
                    "'{path}' has {} channels, and the mixer carries at most {MAX_CHANNELS}",
                    streamer.channels()
                )));
            }
            Clip::Streamed {
                path: path.to_string(),
                duration: streamer.duration().or(duration).unwrap_or(0.0),
            }
        };

        self.hold(clip, entry)
    }

    /// Decodes the bytes of a whole encoded file held in memory and holds the
    /// result under `clip`.
    ///
    /// A clip from memory is always resident: there is no file for a voice to
    /// stream from, and the bytes are not kept. `name` stands where a path
    /// would, in every reason this reports and as the extension the probe is
    /// hinted with.
    ///
    /// @return what the load settled on, or the reason nothing was loaded
    pub fn load_clip_bytes(&self, name: &str, bytes: &[u8], clip: u32) -> Result<Loaded, String> {
        let decoded = decode::decode_bytes(name, bytes).map_err(|reason| self.fail(reason))?;
        let entry = self.resident(name, decoded)?;
        self.hold(clip, entry)
    }

    /// Turns decoded samples into a resident clip, refusing a channel count the
    /// mixer cannot carry.
    fn resident(&self, label: &str, decoded: decode::Decoded) -> Result<Clip, String> {
        if decoded.channels == 0 || decoded.channels as usize > MAX_CHANNELS {
            return Err(self.fail(format!(
                "'{label}' has {} channels, and the mixer carries at most {MAX_CHANNELS}",
                decoded.channels
            )));
        }
        let frames = decoded.samples.len() / decoded.channels.max(1) as usize;
        let seconds = if decoded.sample_rate == 0 {
            0.0
        } else {
            frames as f64 / decoded.sample_rate as f64
        };
        Ok(Clip::Resident {
            samples: decoded.samples.into(),
            channels: decoded.channels,
            sample_rate: decoded.sample_rate,
            duration: seconds,
        })
    }

    /// Puts a clip under its index, replacing whatever the index held, and
    /// reports what it settled on.
    fn hold(&self, clip: u32, entry: Clip) -> Result<Loaded, String> {
        let settled = match &entry {
            Clip::Resident { duration, .. } => Loaded {
                duration: *duration,
                resident: true,
            },
            Clip::Streamed { duration, .. } => Loaded {
                duration: *duration,
                resident: false,
            },
        };
        match self.clips.write() {
            Err(_) => return Err(self.fail("the clip table is poisoned".to_string())),
            Ok(mut clips) => {
                clips.insert(clip, entry);
            }
        }
        Ok(settled)
    }

    /// Drops whatever a clip index holds.
    ///
    /// Voices already reading it keep their own reference, so a sound playing
    /// across a release finishes on the samples it started with.
    pub fn release_clip(&self, clip: u32) {
        if let Ok(mut clips) = self.clips.write() {
            clips.remove(&clip);
        }
    }

    /// Reads a SoundFont and returns the id synthesizers name it by.
    ///
    /// @return the id, from one up, or the reason nothing was loaded
    pub fn load_sound_font(&self, path: &str) -> Result<u32, String> {
        let font = synth::load_sound_font(path).map_err(|reason| self.fail(reason))?;
        let id = match self.next_font.lock() {
            Err(_) => return Err(self.fail("the SoundFont counter is poisoned".to_string())),
            Ok(mut next) => {
                *next += 1;
                *next
            }
        };
        match self.fonts.write() {
            Err(_) => Err(self.fail("the SoundFont table is poisoned".to_string())),
            Ok(mut fonts) => {
                fonts.insert(id, font);
                Ok(id)
            }
        }
    }

    /// Drops a SoundFont. Synthesizers already opened on it keep their own
    /// reference and play on.
    pub fn release_sound_font(&self, font: u32) {
        if let Ok(mut fonts) = self.fonts.write() {
            fonts.remove(&font);
        }
    }

    /// Creates a synthesizer on a loaded SoundFont and parks its source for the
    /// `PLAY` carrying `handle` and `FLAG_SYNTH`.
    ///
    /// Everything that allocates happens here, on the caller's thread: the
    /// synthesizer, its voices, its queue and its scratch buffers. The output
    /// callback only ever renders it.
    ///
    /// @return the port events are sent through, or the reason nothing opened
    pub fn open_synth(&self, font: u32, handle: u32, settings: &Settings) -> Result<Port, String> {
        let shared = match self.fonts.read() {
            Err(_) => return Err(self.fail("the SoundFont table is poisoned".to_string())),
            Ok(fonts) => match fonts.get(&font) {
                None => return Err(self.fail(format!("no SoundFont is loaded under {font}"))),
                Some(value) => Arc::clone(value),
            },
        };
        let (port, source) =
            synth::open(&shared, self.sample_rate, settings).map_err(|reason| self.fail(reason))?;
        match self.synths.lock() {
            Err(_) => Err(self.fail("the synthesizer table is poisoned".to_string())),
            Ok(mut synths) => {
                synths.insert(handle, Box::new(source));
                Ok(port)
            }
        }
    }

    /// Creates an emulated FM chip at `clock` hertz and parks its source for
    /// the `PLAY` carrying `handle` and `FLAG_SYNTH`, as `open_synth` does.
    ///
    /// The chip renders at its own rate, `kind.rate(clock)`, and the voice
    /// resamples it to the output.
    ///
    /// @return the port register writes are sent through, or the reason
    ///     nothing opened
    pub fn open_fm(&self, handle: u32, kind: Kind, clock: u32) -> Result<FmPort, String> {
        let (port, source) = fm::open(kind, clock);
        match self.synths.lock() {
            Err(_) => Err(self.fail("the synthesizer table is poisoned".to_string())),
            Ok(mut synths) => {
                synths.insert(handle, Box::new(source));
                Ok(port)
            }
        }
    }

    /// Builds the source a `PLAY` needs, outside the mixer lock.
    fn prepare(&self, command: &Command) -> Option<Box<dyn Source>> {
        if command.has(command::FLAG_SYNTH) {
            return self.synths.lock().ok()?.remove(&command.handle);
        }
        let clips = self.clips.read().ok()?;
        match clips.get(&command.clip)? {
            Clip::Resident {
                samples,
                channels,
                sample_rate,
                ..
            } => Some(Box::new(ResidentSource::new(
                Arc::clone(samples),
                *channels,
                *sample_rate,
            ))),
            Clip::Streamed { path, .. } => {
                let path = path.clone();
                // The read lock is released before the file is opened, so a
                // slow open never holds up a load on another thread.
                drop(clips);
                match Streamer::open(&path) {
                    Err(reason) => {
                        self.fail(reason);
                        None
                    }
                    Ok(streamer) => Some(Box::new(self.feeder.attach(streamer, 0.0))),
                }
            }
        }
    }

    /// Applies a batch of commands in order.
    pub fn submit(&self, commands: &[Command]) {
        let mut prepared: Vec<Option<Box<dyn Source>>> = Vec::with_capacity(commands.len());
        for entry in commands {
            prepared.push(if entry.kind == command::PLAY {
                self.prepare(entry)
            } else {
                None
            });
        }
        if let Ok(mut mixer) = self.mixer.lock() {
            for (entry, source) in commands.iter().zip(prepared) {
                mixer.apply(entry, source);
            }
        }
    }

    /// Moves every observation since the last drain into `out`.
    ///
    /// @return how many observations were written
    pub fn drain(&self, out: &mut [Event]) -> usize {
        match self.mixer.lock() {
            Err(_) => 0,
            Ok(mut mixer) => mixer.drain(out),
        }
    }

    /// Reports a voice's read position in seconds, and a negative number when
    /// the handle names nothing.
    pub fn position(&self, handle: u32) -> f64 {
        match self.mixer.lock() {
            Err(_) => -1.0,
            Ok(mixer) => mixer.position(handle).unwrap_or(-1.0),
        }
    }

    /// Moves a voice's read position and reports whether the input took it.
    pub fn seek(&self, handle: u32, seconds: f64) -> bool {
        match self.mixer.lock() {
            Err(_) => false,
            Ok(mut mixer) => mixer.seek(handle, seconds),
        }
    }

    /// Fills `out` with the mix, for an engine with no device.
    ///
    /// An engine holding an open output ignores this: its callback is already
    /// pulling the same mixer, and a second reader would take frames the device
    /// never hears.
    ///
    /// @return the frames written, and zero when the engine drives a device
    pub fn render(&self, out: &mut [f32]) -> usize {
        if self.output.is_some() || self.channels == 0 {
            return 0;
        }
        match self.mixer.lock() {
            Err(_) => 0,
            Ok(mut mixer) => {
                mixer.render(out);
                out.len() / self.channels as usize
            }
        }
    }

    /// Reports how many voices are sounding.
    pub fn voice_count(&self) -> usize {
        match self.mixer.lock() {
            Err(_) => 0,
            Ok(mixer) => mixer.voice_count(),
        }
    }

    /// Stops every voice and closes the output.
    pub fn close(&mut self) {
        if let Ok(mut mixer) = self.mixer.lock() {
            mixer.stop_all();
        }
        // Dropping the stream stops the callback, so nothing reaches the mixer
        // after this point.
        self.output = None;
        self.available = false;
        if let Ok(mut clips) = self.clips.write() {
            clips.clear();
        }
        if let Ok(mut fonts) = self.fonts.write() {
            fonts.clear();
        }
        if let Ok(mut synths) = self.synths.lock() {
            synths.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn output_failure_is_distinct_from_offline_unavailability() {
        let mut engine = super::Engine::open_offline(48000, 2, 8);
        assert!(!engine.available());
        assert!(!engine.failed());
        engine.available = true;
        assert!(engine.available());
        engine
            .failed
            .store(true, std::sync::atomic::Ordering::Release);
        assert!(engine.failed());
        assert!(!engine.available());
    }

    use super::*;

    fn play(handle: u32, clip: u32) -> Command {
        Command {
            kind: command::PLAY,
            handle,
            clip,
            flags: 0,
            gain: 1.0,
            pitch: 1.0,
            start: 0.0,
            fade: 0.0,
            loop_start: 0.0,
            x: 0.0,
            y: 0.0,
            z: 0.0,
        }
    }

    #[test]
    fn renders_nothing_and_stays_usable_without_any_clip() {
        let engine = Engine::open_offline(48_000, 2, 8);
        engine.submit(&[play(1, 404)]);
        assert_eq!(engine.voice_count(), 0);
        let mut out = vec![1.0f32; 64];
        assert_eq!(engine.render(&mut out), 32);
        assert!(out.iter().all(|value| *value == 0.0));
    }

    #[test]
    fn reports_a_missing_file_rather_than_panicking() {
        let engine = Engine::open_offline(48_000, 2, 8);
        let failure = engine.load_clip("this/file/does/not/exist.ogg", 1, MODE_AUTO, 10.0);
        assert!(failure.is_err());
        assert!(!engine.last_error().is_empty());
    }

    #[test]
    fn plays_a_clip_decoded_from_memory_like_one_read_from_a_file() {
        // One second of mono 16-bit PCM at the engine's own rate, a constant
        // half-scale level, so the render needs no resampling to compare.
        let frames: u32 = 48_000;
        let level: i16 = 16_384;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + frames * 2).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&48_000u32.to_le_bytes());
        bytes.extend_from_slice(&96_000u32.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(frames * 2).to_le_bytes());
        for _ in 0..frames {
            bytes.extend_from_slice(&level.to_le_bytes());
        }

        let engine = Engine::open_offline(48_000, 2, 8);
        let loaded = engine
            .load_clip_bytes("level.wav", &bytes, 3)
            .expect("the bytes decode");
        assert!(loaded.resident);
        assert!((loaded.duration - 1.0).abs() < 1.0e-9);

        engine.submit(&[play(65_537, 3)]);
        assert_eq!(engine.voice_count(), 1);
        let mut out = vec![0.0f32; 2 * 256];
        assert_eq!(engine.render(&mut out), 256);
        assert!(
            out.iter().skip(64).any(|value| *value != 0.0),
            "a voice on a memory clip renders silence"
        );
    }

    /// Builds a mono 8-bit unsigned WAV whose data chunk has an odd length and
    /// so carries the RIFF pad byte after it.
    fn odd_unsigned_wav(rate: u32, data: &[u8]) -> Vec<u8> {
        assert!(data.len() % 2 == 1, "the case under test is an odd chunk");
        let padded = data.len() as u32 + 1;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + padded).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&8u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        // The chunk size states the data alone; the pad byte is not counted.
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(data);
        bytes.push(0);
        bytes
    }

    #[test]
    fn resamples_an_odd_8_bit_clip_at_a_nonstandard_rate_from_memory() {
        // A ramp, because linear interpolation reproduces a ramp exactly, so
        // every resampled frame has a value to be checked against.
        let data: Vec<u8> = (0..201u32).map(|index| 28 + index as u8).collect();
        let source_value = |position: f64| (28.0 + position) / 128.0 - 1.0;

        for rate in [10_989u32, 18_868] {
            let bytes = odd_unsigned_wav(rate, &data);

            let decoded = decode::decode_bytes("SOUND.WAV", &bytes).expect("the WAV decodes");
            assert_eq!(decoded.sample_rate, rate);
            assert_eq!(decoded.channels, 1);
            // The pad byte is not a sample.
            assert_eq!(decoded.samples.len(), data.len());
            for (index, sample) in decoded.samples.iter().enumerate() {
                assert_eq!(*sample, data[index] as f32 / 128.0 - 1.0);
            }

            let engine = Engine::open_offline(48_000, 2, 8);
            let loaded = engine
                .load_clip_bytes("SOUND.WAV", &bytes, 1)
                .expect("the clip loads");
            assert!(loaded.resident);
            assert!((loaded.duration - data.len() as f64 / rate as f64).abs() < 1.0e-12);

            engine.submit(&[play(65_537, 1)]);
            let mut out = vec![0.0f32; 2 * 4096];
            engine.render(&mut out);
            assert_eq!(engine.voice_count(), 0, "the clip outlasted 4096 frames");

            // Output frame k reads source position k * rate / 48000, up to the
            // last pair of source frames the interpolator can blend.
            let step = rate as f64 / 48_000.0;
            let sounded = ((data.len() - 1) as f64 / step).ceil() as usize;
            for frame in 0..sounded {
                let want = source_value(frame as f64 * step) as f32;
                assert!(
                    (out[frame * 2] - want).abs() < 1.0e-4 && out[frame * 2 + 1] == out[frame * 2],
                    "frame {frame} at {rate} Hz rendered {}, expected {want}",
                    out[frame * 2]
                );
            }
            assert!(
                out[(sounded + 1) * 2..].iter().all(|value| *value == 0.0),
                "the voice at {rate} Hz sounded past its {sounded} resampled frames"
            );
        }
    }

    #[test]
    fn reports_bytes_that_are_not_audio_and_keeps_the_index_empty() {
        let engine = Engine::open_offline(48_000, 2, 8);
        let failure = engine.load_clip_bytes("junk.ogg", b"not audio", 4);
        assert!(failure.is_err());
        assert!(engine.last_error().contains("junk.ogg"));
        engine.submit(&[play(65_537, 4)]);
        assert_eq!(engine.voice_count(), 0);
    }

    #[test]
    fn an_fm_chip_started_by_its_play_renders_and_keeps_its_clock() {
        let engine = Engine::open_offline(48_000, 2, 8);
        let mut port = engine
            .open_fm(257, Kind::Ymf262, fm::OPL3_CLOCK)
            .expect("an OPL3 opens");
        assert!(port.reset(0.0));
        // A held note on channel 0, OPL3 mode and both outputs on.
        for (register, value) in [
            (0x105, 0x01),
            (0x20, 0x01),
            (0x23, 0x01),
            (0x40, 0x3f),
            (0x43, 0x00),
            (0x63, 0xf0),
            (0x83, 0x0f),
            (0xc0, 0x30),
            (0xa0, 0x41),
            (0xb0, 0x32),
        ] {
            assert!(port.write(register, value, 0.0));
        }
        let mut start = play(257, 0);
        start.flags = command::FLAG_SYNTH;
        engine.submit(&[start]);
        assert_eq!(engine.voice_count(), 1);
        let mut out = vec![0.0f32; 2 * 512];
        let mut heard = false;
        for block in 1..=200u64 {
            engine.render(&mut out);
            heard |= out.iter().any(|value| *value != 0.0);
            // The chip's clock follows the output's, block after block.
            let expected = block as f64 * 512.0 / 48_000.0;
            assert!(
                (port.now() - expected).abs() < 2.0 / 48_000.0,
                "block {block}: {}",
                port.now()
            );
        }
        assert!(heard, "the note is rendered");
        assert_eq!(engine.voice_count(), 1);
    }

    #[test]
    fn answers_a_position_query_for_a_handle_naming_nothing() {
        let engine = Engine::open_offline(48_000, 2, 8);
        assert_eq!(engine.position(7), -1.0);
        assert!(!engine.seek(7, 1.0));
    }
}
