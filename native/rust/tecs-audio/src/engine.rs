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

use crate::abi::{Decoder, DecoderVTable, EffectKind, EffectVTable};
use crate::command::{self, Command, Event};
use crate::conform::Format;
use crate::decode::{self, Streamer};
use crate::device::CpalHost;
use crate::effects::{self, Effect};
use crate::listen::{self, Summary, Tap};
use crate::mixer::{Fresh, Mixer, Prepared, Storage, StripMeter};
use crate::output::{self, Host, NoDevice, Output, Start, Timing};
use crate::queue::{self, Consumer, Producer};
use crate::render::{Message, Published, RenderSide, Report};
use crate::source::{ResidentSource, Source, MAX_CHANNELS};
use crate::stream::Feeder;

/// Measures a clip's duration against the streaming threshold.
pub const MODE_AUTO: u32 = 0;

/// Holds a clip's decoded samples in memory.
pub const MODE_RESIDENT: u32 = 1;

/// Reads a clip from its file for each voice.
pub const MODE_STREAM: u32 = 2;

/// The rate an engine asked for zero frames per second runs at.
const DEFAULT_RATE: u32 = 48_000;

/// The channels an engine asked for none runs with.
const DEFAULT_CHANNELS: u16 = 2;

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
    /// The render side: the mixer and its ends of the queues. Only a
    /// renderer takes this lock, and the control side only when nothing
    /// else renders.
    render: Arc<Mutex<RenderSide>>,
    /// The control side's ends of the queues.
    control: Mutex<ControlSide>,
    /// What the render side publishes for queries.
    published: Arc<Published>,
    clips: RwLock<HashMap<u32, Clip>>,
    /// Sources a Decoder opened and not yet started, by the voice handle
    /// whose `PLAY` will take them.
    synths: Mutex<HashMap<u32, Box<dyn Source>>>,
    /// Decoders by id, one-based: id one is the built-in PCM Decoder.
    decoders: RwLock<Vec<Decoder>>,
    /// Effect kinds a library registered, by id less `ABI_EFFECTS`.
    effect_kinds: RwLock<Vec<EffectKind>>,
    /// Effects built for an `EFFECT_INSERT`, by the id Tecs gave them.
    effects: Mutex<HashMap<u64, Box<dyn Effect>>>,
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
    /// Why the output last dropped, as a C string, on the same terms.
    dropped: Mutex<CString>,
    /// The last recording summary, as a C string, on the same terms.
    summary: Mutex<CString>,
    sample_rate: u32,
    channels: u16,
    available: bool,
    failed: Arc<AtomicBool>,
}

/// The first effect kind id a registered library gets; the ones below it
/// are built in.
pub const ABI_EFFECTS: u32 = 1000;

/// Messages the render side's inbox holds, and reports its outbox holds.
const QUEUE_MESSAGES: usize = 8192;

/// The control side's half of the engine.
struct ControlSide {
    inbox: Producer<Message>,
    outbox: Consumer<Report>,
    /// Messages that found the inbox full, sent first next time.
    backlog: std::collections::VecDeque<Message>,
    /// Observations taken off the outbox and not yet drained.
    events: Vec<Event>,
    /// Track and Bus ids the render side has room for.
    track_room: usize,
    bus_room: usize,
}

impl ControlSide {
    fn send(&mut self, message: Message) {
        if !self.backlog.is_empty() {
            self.backlog.push_back(message);
            self.flush();
            return;
        }
        if let Err(back) = self.inbox.push(message) {
            self.backlog.push_back(back);
        }
    }

    fn flush(&mut self) {
        while let Some(message) = self.backlog.pop_front() {
            if let Err(back) = self.inbox.push(message) {
                self.backlog.push_front(back);
                return;
            }
        }
    }

    /// Takes everything off the outbox, keeping the observations and freeing
    /// the rest here, on the control side.
    fn settle(&mut self) {
        while let Some(report) = self.outbox.pop() {
            match report {
                Report::Event(event) => self.events.push(event),
                // Dropped here: freed on this thread, not the renderer's.
                Report::Leftover(_) | Report::Storage(_) | Report::Message(_) => {}
            }
        }
        self.flush();
    }
}

/// Builds the render side over a mixer and the control side that talks to it.
fn split(mixer: Mixer, max_voices: usize) -> (Arc<Mutex<RenderSide>>, ControlSide, Arc<Published>) {
    let (track_room, bus_room) = mixer.strip_room();
    let (to_render, inbox) = queue::queue(QUEUE_MESSAGES);
    let (outbox, from_render) = queue::queue(QUEUE_MESSAGES);
    let published = Arc::new(Published::new(max_voices));
    let render = Arc::new(Mutex::new(RenderSide::new(
        mixer,
        inbox,
        outbox,
        Arc::clone(&published),
        max_voices,
    )));
    let control = ControlSide {
        inbox: to_render,
        outbox: from_render,
        backlog: std::collections::VecDeque::new(),
        events: Vec::with_capacity(max_voices),
        track_room,
        bus_room,
    };
    (render, control, published)
}

impl Engine {
    /// Opens the default output and returns the engine driving it.
    ///
    /// A machine with no sound still gets an engine. It reports `available` as
    /// false, takes every command, and mixes nothing, because a game that has
    /// to branch on whether audio exists is a game that gets the branch wrong.
    ///
    /// The mix runs at `sample_rate` and `channels` for the life of the
    /// engine, whatever the device runs at, now or after it changes.
    pub fn open(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        Engine::open_with(
            CpalHost::new,
            Timing::default(),
            sample_rate,
            channels,
            max_voices,
        )
    }

    /// Opens the default output, or, when there is none, an output that keeps
    /// time without one and opens a device when one appears.
    ///
    /// Either way the engine is available: commands play into it and its
    /// clock runs at the wall clock's pace, so a timed command lands whether
    /// or not anything is heard.
    pub fn open_or_void(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        Engine::start_with(
            CpalHost::new,
            Timing::default(),
            Start::KeepTime,
            sample_rate,
            channels,
            max_voices,
        )
    }

    /// Opens a void output: no device, ever, and a clock that runs at the wall
    /// clock's pace, for a headless run that still keeps time.
    pub fn open_void(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        Engine::start_with(
            || Ok(NoDevice::new("a void output has no device")),
            Timing::default(),
            Start::KeepTime,
            sample_rate,
            channels,
            max_voices,
        )
    }

    /// Opens an output through any host, which is how a test stands a fake
    /// device in for the platform's.
    ///
    /// `make` runs on the output's own thread, which the host then lives on.
    pub fn open_with<H, F>(
        make: F,
        timing: Timing,
        sample_rate: u32,
        channels: u16,
        max_voices: usize,
    ) -> Engine
    where
        H: Host + 'static,
        F: FnOnce() -> Result<H, String> + Send + 'static,
    {
        Engine::start_with(
            make,
            timing,
            Start::RequireDevice,
            sample_rate,
            channels,
            max_voices,
        )
    }

    /// Opens an output through any host, choosing what happens when no device
    /// opens at start.
    pub fn start_with<H, F>(
        make: F,
        timing: Timing,
        start: Start,
        sample_rate: u32,
        channels: u16,
        max_voices: usize,
    ) -> Engine
    where
        H: Host + 'static,
        F: FnOnce() -> Result<H, String> + Send + 'static,
    {
        let format = Format {
            sample_rate: if sample_rate == 0 {
                DEFAULT_RATE
            } else {
                sample_rate
            },
            channels: if channels == 0 {
                DEFAULT_CHANNELS
            } else {
                channels
            },
        };
        let (render, control, published) = split(
            Mixer::new(format.sample_rate, format.channels, max_voices),
            max_voices,
        );
        match Output::start(make, Arc::clone(&render), format, timing, start) {
            Ok(output) => Engine::assemble(
                (render.clone(), control, published.clone()),
                Some(output),
                format.sample_rate,
                format.channels,
                true,
                String::new(),
            ),
            Err(reason) => Engine::assemble(
                split(
                    Mixer::new(format.sample_rate, format.channels, max_voices),
                    max_voices,
                ),
                None,
                format.sample_rate,
                format.channels,
                false,
                reason,
            ),
        }
    }

    /// Creates an engine with no device, whose buffers the caller renders.
    ///
    /// This is the deterministic path: `render` produces exactly the frames it
    /// is asked for, on the calling thread, with no device, no output thread
    /// and no clock. Tests drive the mixer through it, and so can a headless
    /// host that wants audio it can capture.
    pub fn open_offline(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        let parts = split(Mixer::new(sample_rate, channels, max_voices), max_voices);
        Engine::assemble(parts, None, sample_rate, channels, false, String::new())
    }

    /// Creates a memory output: an offline engine that reports itself
    /// available, so Tecs plays into it, and whose clock moves only when the
    /// caller renders it. Deterministic, which is what tests and agents want.
    pub fn open_memory(sample_rate: u32, channels: u16, max_voices: usize) -> Engine {
        let parts = split(Mixer::new(sample_rate, channels, max_voices), max_voices);
        Engine::assemble(parts, None, sample_rate, channels, true, String::new())
    }

    /// Starts recording the next `frames` frames of the mix, allocating the
    /// recording here rather than on the render path.
    pub fn listen(&self, frames: usize) {
        let started = self.frames();
        let tap = Tap::new(frames, self.channels, started);
        let replaced = match self.published.tap.lock() {
            Err(_) => return,
            Ok(mut slot) => slot.replace(tap),
        };
        drop(replaced);
    }

    /// Runs `read` over the recording in progress, if there is one.
    pub fn with_recording<T>(&self, read: impl FnOnce(&Tap) -> T) -> Option<T> {
        let slot = self.published.tap.lock().ok()?;
        slot.as_ref().map(read)
    }

    /// Summarizes the recording in progress.
    pub fn recording_summary(&self) -> Option<Summary> {
        let rate = self.sample_rate;
        self.with_recording(|tap| listen::summarize(tap.samples(), tap.channels(), rate))
    }

    /// Encodes the recording in progress as a WAV file's bytes.
    pub fn recording_wav(&self) -> Option<Vec<u8>> {
        let rate = self.sample_rate;
        self.with_recording(|tap| listen::wav(tap.samples(), tap.channels(), rate))
    }

    /// Ends the recording, freeing it outside the lock.
    pub fn stop_listening(&self) {
        let taken = match self.published.tap.lock() {
            Err(_) => None,
            Ok(mut slot) => slot.take(),
        };
        drop(taken);
    }

    /// Holds a void output's clock for the caller to step with `render`, or
    /// lets it keep time again, and reports whether it is now steppable. A
    /// memory output always is; a device that is playing never is.
    pub fn hold_clock(&self, held: bool) -> bool {
        match &self.output {
            None => true,
            Some(output) => {
                output.hold(held);
                output.steppable()
            }
        }
    }

    /// Registers a Decoder a library handed over and returns its id.
    ///
    /// # Safety
    ///
    /// `vtable` must be null or point at a vtable that outlives the engine.
    pub unsafe fn register_decoder(&self, vtable: *const DecoderVTable) -> Result<u32, String> {
        let decoder = unsafe { Decoder::from_raw(vtable) }.map_err(|reason| self.fail(reason))?;
        let mut decoders = self
            .decoders
            .write()
            .map_err(|_| self.fail("the decoder registry is poisoned".to_string()))?;
        decoders.push(decoder);
        Ok(decoders.len() as u32)
    }

    /// Registers an Effect a library handed over and returns its kind id,
    /// which is past every built-in's.
    ///
    /// # Safety
    ///
    /// As for `register_decoder`.
    pub unsafe fn register_effect(&self, vtable: *const EffectVTable) -> Result<u32, String> {
        let kind = unsafe { EffectKind::from_raw(vtable) }.map_err(|reason| self.fail(reason))?;
        let mut kinds = self
            .effect_kinds
            .write()
            .map_err(|_| self.fail("the effect registry is poisoned".to_string()))?;
        kinds.push(kind);
        Ok(ABI_EFFECTS + kinds.len() as u32 - 1)
    }

    /// Opens a Playback through Decoder `decoder` and holds it for the `PLAY`
    /// of `handle`, which carries `FLAG_SYNTH` to take it.
    pub fn open_decoded(
        &self,
        decoder: u32,
        handle: u32,
        params: &[u8],
        bytes: &[u8],
    ) -> Result<(), String> {
        let found = {
            let decoders = self
                .decoders
                .read()
                .map_err(|_| self.fail("the decoder registry is poisoned".to_string()))?;
            decoder
                .checked_sub(1)
                .and_then(|index| decoders.get(index as usize).copied())
        };
        let Some(found) = found else {
            return Err(self.fail(format!("no decoder has id {decoder}")));
        };
        let source = found
            .open(params, bytes, self.sample_rate)
            .map_err(|reason| self.fail(reason))?;
        match self.synths.lock() {
            Err(_) => Err(self.fail("the parked sources are poisoned".to_string())),
            Ok(mut parked) => {
                parked.insert(handle, Box::new(source));
                Ok(())
            }
        }
    }

    /// Builds an effect of kind `kind` for the `EFFECT_INSERT` that names
    /// `id`, at the mix's rate and layout.
    pub fn prepare_effect(&self, kind: u32, id: u64, params: &[u8]) -> Result<(), String> {
        let rate = self.sample_rate;
        let channels = self.channels as usize;
        let effect = if kind < ABI_EFFECTS {
            effects::builtin(kind, rate, channels)
                .ok_or_else(|| self.fail(format!("no built-in effect has id {kind}")))?
        } else {
            let found = self
                .effect_kinds
                .read()
                .ok()
                .and_then(|kinds| kinds.get((kind - ABI_EFFECTS) as usize).copied());
            let Some(found) = found else {
                return Err(self.fail(format!("no effect has id {kind}")));
            };
            found
                .open(params, rate, channels as u32)
                .map_err(|reason| self.fail(reason))?
        };
        match self.effects.lock() {
            Err(_) => Err(self.fail("the prepared effects are poisoned".to_string())),
            Ok(mut parked) => {
                parked.insert(id, effect);
                Ok(())
            }
        }
    }

    /// Reads and resets every strip's meter.
    pub fn meters(&self) -> Vec<StripMeter> {
        if self.inline() {
            if let Ok(mut render) = self.render.lock() {
                render.pump();
            }
        }
        match self.published.meters.lock() {
            Err(_) => Vec::new(),
            Ok(mut meters) => {
                let mut out = meters.clone();
                // Sorted as the mixer reports them: Master and the Buses,
                // then the Tracks, each by id.
                out.sort_by_key(|meter| (!meter.bus, meter.id));
                // Read resets: the next read starts from silence, keeping
                // every strip's slot so the render side never grows the list.
                for meter in meters.iter_mut() {
                    meter.meter = Default::default();
                }
                out
            }
        }
    }

    /// Reports how many timed commands arrived after their frame.
    pub fn late(&self) -> u64 {
        if self.inline() {
            if let Ok(mut render) = self.render.lock() {
                render.pump();
                return render.mixer().late();
            }
        }
        self.published.late.load(Ordering::Acquire)
    }

    fn assemble(
        parts: (Arc<Mutex<RenderSide>>, ControlSide, Arc<Published>),
        output: Option<Output>,
        sample_rate: u32,
        channels: u16,
        available: bool,
        reason: String,
    ) -> Engine {
        let failed = output
            .as_ref()
            .map(Output::failed)
            .unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
        let (render, control, published) = parts;
        Engine {
            failed,
            render,
            control: Mutex::new(control),
            published,
            clips: RwLock::new(HashMap::new()),
            synths: Mutex::new(HashMap::new()),
            decoders: RwLock::new(vec![
                // Valid by construction: it is this crate's own static.
                unsafe { Decoder::from_raw(&crate::pcm::VTABLE) }.expect("the PCM vtable"),
            ]),
            effect_kinds: RwLock::new(Vec::new()),
            effects: Mutex::new(HashMap::new()),
            feeder: Feeder::start(),
            output,
            last_error: Mutex::new(reason),
            reported: Mutex::new(CString::default()),
            dropped: Mutex::new(CString::default()),
            summary: Mutex::new(CString::default()),
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
    ///
    /// A device that drops is not one: the output reopens it, and only an
    /// output that can no longer do that reports failed.
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    /// Reports the frames per second the mix runs at, which is the rate it
    /// was opened for rather than the device's.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Reports the channels the mix runs with.
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Reports the mixer's clock: the seconds of mix rendered since the engine
    /// opened, at its own rate. It keeps moving while a device is gone.
    pub fn now(&self) -> f64 {
        match Ok::<u64, ()>(self.frames()) {
            Err(_) => 0.0,
            Ok(frames) if self.sample_rate > 0 => frames as f64 / self.sample_rate as f64,
            Ok(_) => 0.0,
        }
    }

    /// Reports the output's `output::STATE_` constant.
    pub fn output_state(&self) -> u32 {
        match &self.output {
            None => output::STATE_OFFLINE,
            Some(value) => value.state(),
        }
    }

    /// Reports how many times the output has dropped.
    pub fn output_drops(&self) -> u32 {
        self.output.as_ref().map_or(0, Output::drops)
    }

    /// Reports how many times the output has opened again after a drop.
    pub fn output_reopens(&self) -> u32 {
        self.output.as_ref().map_or(0, Output::reopens)
    }

    /// Returns why the output last dropped, and an empty string until it has.
    pub fn output_reason(&self) -> String {
        self.output.as_ref().map(Output::reason).unwrap_or_default()
    }

    /// Returns the same reason as a borrowed C string, on the terms of
    /// `last_error_cstr`.
    pub fn output_reason_cstr(&self) -> *const c_char {
        let text = CString::new(self.output_reason()).unwrap_or_default();
        match self.dropped.lock() {
            Err(_) => std::ptr::null(),
            Ok(mut slot) => {
                *slot = text;
                slot.as_ptr()
            }
        }
    }

    /// Reports the format the open stream runs at, and `None` while no stream
    /// is open.
    pub fn output_format(&self) -> Option<Format> {
        self.output.as_ref().and_then(Output::device_format)
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

    /// Summarizes the recording in progress as JSON in a C string that stays
    /// valid until the next call, or returns null with no recording.
    pub fn summary_cstr(&self) -> *const c_char {
        let Some(summary) = self.recording_summary() else {
            return std::ptr::null();
        };
        let text = CString::new(summary.to_json()).unwrap_or_default();
        match self.summary.lock() {
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

    /// Applies a batch of commands in order, each on the output frame its `at`
    /// names or at once.
    ///
    /// Everything a `PLAY` needs is built here, on the caller's thread, so a
    /// scheduled start reaches the output callback ready to sound.
    pub fn submit(&self, commands: &[Command]) {
        let mut prepared: Vec<Option<Box<dyn Source>>> = Vec::with_capacity(commands.len());
        let mut inserted: Vec<Option<Box<dyn Effect>>> = Vec::with_capacity(commands.len());
        for entry in commands {
            prepared.push(if entry.kind == command::PLAY {
                self.prepare(entry)
            } else {
                None
            });
            inserted.push(if entry.kind == command::EFFECT_INSERT {
                self.effects
                    .lock()
                    .ok()
                    .and_then(|mut parked| parked.remove(&entry.data))
            } else {
                None
            });
        }
        {
            let Ok(mut control) = self.control.lock() else {
                return;
            };
            for ((entry, source), effect) in commands.iter().zip(prepared).zip(inserted) {
                let fresh = match entry.kind {
                    command::TRACK_CREATE | command::BUS_CREATE => {
                        let id = entry.target as usize;
                        let grow_tracks =
                            entry.kind == command::TRACK_CREATE && id >= control.track_room;
                        let grow_buses =
                            entry.kind == command::BUS_CREATE && id >= control.bus_room;
                        if grow_tracks || grow_buses {
                            let tracks = if grow_tracks {
                                (id + 1).max(control.track_room * 2)
                            } else {
                                control.track_room
                            };
                            let buses = if grow_buses {
                                (id + 1).max(control.bus_room * 2)
                            } else {
                                control.bus_room
                            };
                            control.track_room = tracks;
                            control.bus_room = buses;
                            control.send(Message::Storage(Storage::with_capacity(tracks, buses)));
                            if let Ok(mut meters) = self.published.meters.lock() {
                                let want = tracks + buses;
                                let held = meters.len();
                                if meters.capacity() < want {
                                    meters.reserve(want - held);
                                }
                            }
                        }
                        Some(Fresh::new(self.channels))
                    }
                    _ => None,
                };
                // A start's voice is built here, where allocating is
                // allowed, rather than on the render side.
                let (source, voice) = if entry.kind == command::PLAY {
                    (None, Prepared::new(entry, source, self.sample_rate))
                } else {
                    (source, None)
                };
                control.send(Message::Command {
                    command: *entry,
                    source,
                    effect,
                    fresh,
                    voice,
                });
            }
            control.settle();
        }
        self.pump_inline();
    }

    /// Reports whether the control side is the only renderer: no output, or
    /// a held one, which is when it applies its own messages.
    fn inline(&self) -> bool {
        match &self.output {
            None => true,
            Some(output) => output.steppable(),
        }
    }

    /// In the inline mode, applies what waits and takes back what the render
    /// side handed over, so a query right after a submit sees it.
    fn pump_inline(&self) {
        if !self.inline() {
            return;
        }
        if let Ok(mut render) = self.render.lock() {
            render.pump();
        }
        if let Ok(mut control) = self.control.lock() {
            control.settle();
        }
    }

    /// Moves every observation since the last drain into `out`.
    ///
    /// @return how many observations were written
    pub fn drain(&self, out: &mut [Event]) -> usize {
        self.pump_inline();
        let Ok(mut control) = self.control.lock() else {
            return 0;
        };
        control.settle();
        let count = control.events.len().min(out.len());
        out[..count].copy_from_slice(&control.events[..count]);
        control.events.drain(..count);
        count
    }

    /// Reports a voice's read position in seconds, and a negative number when
    /// the handle names nothing.
    pub fn position(&self, handle: u32) -> f64 {
        if self.inline() {
            self.pump_inline();
            if let Ok(mut render) = self.render.lock() {
                return render.mixer().position(handle).unwrap_or(-1.0);
            }
        }
        match self.published.positions.lock() {
            Err(_) => -1.0,
            Ok(positions) => positions
                .iter()
                .find(|(each, _)| *each == handle)
                .map_or(-1.0, |(_, seconds)| *seconds),
        }
    }

    /// Reports the output clock in frames.
    pub fn frames(&self) -> u64 {
        if self.inline() {
            if let Ok(mut render) = self.render.lock() {
                return render.mixer().frames();
            }
        }
        self.published.frames.load(Ordering::Acquire)
    }

    /// Moves a voice's read position and reports whether the input took it.
    pub fn seek(&self, handle: u32, seconds: f64) -> bool {
        if self.inline() {
            self.pump_inline();
            if let Ok(mut render) = self.render.lock() {
                return render.mixer().seek(handle, seconds);
            }
        }
        // Applied on the render side before its next render. What can be
        // answered now is whether the voice was sounding when last published.
        let known = self.position(handle) >= 0.0;
        if let Ok(mut control) = self.control.lock() {
            control.send(Message::Seek { handle, seconds });
        }
        known
    }

    /// Fills `out` with the mix, for an engine with no device.
    ///
    /// An engine holding an open output ignores this: its callback is already
    /// pulling the same mixer, and a second reader would take frames the device
    /// never hears.
    ///
    /// @return the frames written, and zero when the engine drives a device
    pub fn render(&self, out: &mut [f32]) -> usize {
        let steppable = match &self.output {
            None => true,
            Some(output) => output.steppable(),
        };
        if !steppable || self.channels == 0 {
            return 0;
        }
        match self.render.lock() {
            Err(_) => return 0,
            Ok(mut render) => render.render(out),
        }
        if let Ok(mut control) = self.control.lock() {
            control.settle();
        }
        out.len() / self.channels as usize
    }

    /// Reports how many voices are sounding.
    pub fn voice_count(&self) -> usize {
        if self.inline() {
            self.pump_inline();
            if let Ok(mut render) = self.render.lock() {
                return render.mixer().voice_count();
            }
        }
        self.published.voices.load(Ordering::Acquire)
    }

    /// Stops every voice and closes the output.
    pub fn close(&mut self) {
        if let Ok(mut control) = self.control.lock() {
            control.send(Message::StopAll);
        }
        // Dropping the stream stops the callback, so nothing reaches the mixer
        // after this point; then the control side applies what is left.
        self.output = None;
        self.pump_inline();
        self.available = false;
        if let Ok(mut clips) = self.clips.write() {
            clips.clear();
        }
        if let Ok(mut synths) = self.synths.lock() {
            synths.clear();
        }
        if let Ok(mut effects) = self.effects.lock() {
            effects.clear();
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
            at: 0.0,
            ..Default::default()
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
    fn answers_a_position_query_for_a_handle_naming_nothing() {
        let engine = Engine::open_offline(48_000, 2, 8);
        assert_eq!(engine.position(7), -1.0);
        assert!(!engine.seek(7, 1.0));
    }

    #[test]
    fn runs_the_output_clock_by_rendered_frames_and_lands_a_command_on_it() {
        // One second of a constant level at the output rate, as 16-bit PCM.
        let frames: u32 = 48_000;
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
            bytes.extend_from_slice(&16_384i16.to_le_bytes());
        }
        let engine = Engine::open_offline(48_000, 2, 8);
        engine
            .load_clip_bytes("level.wav", &bytes, 3)
            .expect("the bytes decode");
        assert_eq!(engine.now(), 0.0);

        // Started 40 frames into the first render, then stopped 7 frames into
        // the second, both scheduled before either render.
        let mut start = play(65_537, 3);
        start.at = 40.0 / 48_000.0;
        let mut stop = play(65_537, 0);
        stop.kind = command::STOP;
        stop.at = (256.0 + 7.0) / 48_000.0;
        engine.submit(&[start, stop]);
        assert_eq!(engine.voice_count(), 0);

        let mut out = vec![0.0f32; 2 * 256];
        assert_eq!(engine.render(&mut out), 256);
        assert_eq!(engine.frames(), 256);
        assert!((engine.now() - 256.0 / 48_000.0).abs() < 1e-12);
        assert!(out[..80].iter().all(|value| *value == 0.0));
        assert!(out[80..].iter().all(|value| *value == 0.5));
        engine.render(&mut out);
        assert!(out[..14].iter().all(|value| *value == 0.5));
        assert!(out[14..].iter().all(|value| *value == 0.0));
        assert_eq!(engine.voice_count(), 0);
    }

    #[test]
    fn plays_a_sound_through_the_pcm_decoder_vtable_with_an_effect_and_meters() {
        let engine = Engine::open_memory(48_000, 2, 4);
        // 4801 frames of mono 8-bit PCM at three-quarters level.
        let wav = odd_unsigned_wav(48_000, &[224u8; 4801]);
        engine
            .open_decoded(1, 65_537, &[], &wav)
            .expect("the PCM decoder opens");
        assert!(
            engine.open_decoded(9, 65_538, &[], &wav).is_err(),
            "an unknown decoder"
        );
        engine
            .prepare_effect(crate::effects::FILTER, 77, &[])
            .expect("a built-in effect");
        let mut insert = Command {
            kind: command::EFFECT_INSERT,
            data: 77,
            ..Default::default()
        };
        insert.flags = command::FLAG_BUS;
        let mut start = play(65_537, 0);
        start.flags = command::FLAG_SYNTH;
        engine.submit(&[insert, start]);
        let mut out = vec![0.0f32; 2 * 2400];
        assert_eq!(engine.render(&mut out), 2400);
        assert!((out[2 * 2000] - 0.75).abs() < 0.02, "got {}", out[2 * 2000]);
        let meters = engine.meters();
        assert!(meters[0].bus && meters[0].id == 0, "Master first");
        // The filter rings on the clip's hard first step, so the peak is at least
        // the level and below full scale.
        let peak = meters[0].meter.peak;
        assert!((0.74..1.0).contains(&peak), "master peak {peak}");
        assert!((meters[0].meter.rms() - 0.75).abs() < 0.05);
        assert!(meters
            .iter()
            .any(|meter| !meter.bus && meter.id == 0 && meter.meter.peak > 0.5));
        assert_eq!(engine.meters()[0].meter.peak, 0.0, "reading resets");
    }
}
