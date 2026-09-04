//! One output, the clips loaded against it, and the seam Tecs drives it by.
//!
//! Everything a command needs from a file is prepared before the mixer lock is
//! taken. A `PLAY` on a resident clip becomes a reference count and a `PLAY` on
//! a streamed one becomes an open decoder, and only then does the batch reach
//! the mixer. The output callback therefore never waits on a file.

use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::{Arc, Mutex, RwLock};

use crate::command::{self, Command, Event};
use crate::decode::{self, Streamer};
use crate::device::{self, Output};
use crate::mixer::Mixer;
use crate::source::{ResidentSource, Source, MAX_CHANNELS};
use crate::stream::Feeder;

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
        Engine {
            mixer,
            clips: RwLock::new(HashMap::new()),
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
        self.available
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
    fn fail(&self, reason: String) -> String {
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
            if decoded.channels == 0 || decoded.channels as usize > MAX_CHANNELS {
                return Err(self.fail(format!(
                    "'{path}' has {} channels, and the mixer carries at most {MAX_CHANNELS}",
                    decoded.channels
                )));
            }
            let frames = decoded.samples.len() / decoded.channels.max(1) as usize;
            let seconds = if decoded.sample_rate == 0 {
                0.0
            } else {
                frames as f64 / decoded.sample_rate as f64
            };
            Clip::Resident {
                samples: decoded.samples.into(),
                channels: decoded.channels,
                sample_rate: decoded.sample_rate,
                duration: seconds,
            }
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

    /// Builds the source a `PLAY` needs, outside the mixer lock.
    fn prepare(&self, command: &Command) -> Option<Box<dyn Source>> {
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
    }
}

#[cfg(test)]
mod tests {
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
    fn answers_a_position_query_for_a_handle_naming_nothing() {
        let engine = Engine::open_offline(48_000, 2, 8);
        assert_eq!(engine.position(7), -1.0);
        assert!(!engine.seek(7, 1.0));
    }
}
