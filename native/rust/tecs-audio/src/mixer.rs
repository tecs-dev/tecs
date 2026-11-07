//! The console: Playbacks into Tracks, Tracks into Buses, Buses into Master.
//!
//! This is a focused mixer rather than an adapted one, and the reason is
//! narrow. Tecs needs a voice to change whether it loops part way through and
//! to play out to its natural end when looping is turned off; it needs a loop
//! return point; it needs a fade-out started at stop time and clocked by the
//! audio thread; and it needs an explicit pair of left and right speaker gains
//! that is not a single normalized pan. No established Rust mixer offers all of
//! those together, and each one that offers some of them also owns the device
//! and its own decode graph.
//!
//! The signal flow is a console's. A voice, which the design calls a
//! Playback, renders into its Track's buffer. A Track runs its insert chain,
//! applies its fader (gain, mute, solo) and its pan or position, adds itself
//! into the Bus it routes to, and copies itself post-fader into the return
//! Buses it sends to. Buses form a tree: each runs its inserts and fader and
//! adds into its parent, deepest first, down to Master, bus zero, whose fader
//! comes before its inserts so its limiter has the last word. Track zero is the
//! default Track, routed to Master, where a `PLAY` with no Track sounds.
//!
//! Everything here runs under one lock. The output callback takes it to fill a
//! buffer and Tecs takes it to apply a command batch or read a position. Nothing
//! on the render path allocates, opens a file, decodes or frees: a `PLAY`
//! arrives with its source built, an effect arrives built, every buffer and
//! list is sized on the submitting thread, and whatever ends is retired to a
//! list the submitting thread collects and frees.
//!
//! The mixer keeps the output clock, which is the frames it has rendered. A
//! command carrying an `at` on that clock waits in a schedule, ordered by its
//! frame and then by submission, and `render` splits its buffer at every
//! scheduled frame, so the command takes effect on exactly that output sample.
//! A command with no `at`, or one already rendered, applies at once, after
//! every scheduled command due by then. Structural commands, which create or
//! destroy a Track or a Bus, always apply at once.
//!
//! A voice exists from the frame its `PLAY` is due on, and Tecs may address it
//! before then. A `STOP` that reaches a handle whose `PLAY` is still waiting
//! cancels that start, and anything else is moved to the start's own frame,
//! after it. Every `PLAY` ends in exactly one `FINISHED`.
//!
//! Fader and send levels are targets that the mixer glides towards over a few
//! milliseconds, so a change never clicks and a late frame never jumps.

use std::collections::VecDeque;

use crate::command::{self, Command, Event};
use crate::effects::Effect;
use crate::source::{Source, MAX_CHANNELS};

/// Where a voice, or a Track, sits in the output.
#[derive(Clone, Copy, PartialEq)]
enum Placement {
    /// Maps source channels onto output channels unchanged.
    None,
    /// Folds the source to mono and places it against a listener at the origin.
    Spatial { x: f32, y: f32, z: f32 },
    /// Scales the left and right output channels by an explicit gain each.
    Stereo { left: f32, right: f32 },
}

/// How many source frames one voice pulls ahead of the resampler.
const STAGING_FRAMES: usize = 256;

/// The most frames a strip processes at once. Renders are cut into blocks of
/// this size, so every strip's buffer is this long.
pub const BLOCK_FRAMES: usize = 256;

/// The most return Buses one Track sends to.
pub const MAX_SENDS: usize = 8;

/// The most effects one strip's insert chain holds.
pub const MAX_INSERTS: usize = 16;

/// How long a fader or send glides to a new level.
const GLIDE_SECONDS: f32 = 0.005;

/// How many times a looping voice may restart inside one output frame before
/// the mixer gives up on it.
const MAX_LOOP_RESTARTS: u32 = 4;

/// Scheduled commands the mixer holds room for before a submit has to grow it.
const SCHEDULE_COMMANDS: usize = 1024;

/// A command waiting for its frame.
struct Scheduled {
    frame: u64,
    command: Command,
    /// The voice a `PLAY` starts, built when it was submitted.
    voice: Option<Voice>,
    /// The effect an `EFFECT_INSERT` adds, built when it was submitted.
    effect: Option<Box<dyn Effect>>,
}

/// One playback in progress.
struct Voice {
    handle: u32,
    /// The Track it renders into.
    track: u32,
    source: Box<dyn Source>,
    gain: f32,
    pitch: f32,
    placement: Placement,
    repeating: bool,
    loop_start: f64,
    paused: bool,
    envelope: f32,
    envelope_step: f32,
    stopping: bool,
    nearest: bool,
    holding_last: bool,
    fraction: f64,
    previous: [f32; MAX_CHANNELS],
    upcoming: [f32; MAX_CHANNELS],
    primed: bool,
    staging: Vec<f32>,
    staged: usize,
    consumed: usize,
    ended: bool,
    /// Reads its source a frame at a time, because the source takes events.
    sequenced: bool,
}

impl Voice {
    fn step(&self, output_rate: u32) -> f64 {
        if output_rate == 0 {
            return 0.0;
        }
        self.pitch as f64 * self.source.sample_rate() as f64 / output_rate as f64
    }

    fn pull(&mut self) -> bool {
        let channels = self.source.channels() as usize;
        if channels == 0 || channels > MAX_CHANNELS {
            self.ended = true;
            return false;
        }
        let mut restarts = 0;
        while self.consumed >= self.staged {
            // A sequenced source is read one frame at a time, so an event the
            // mixer delivers reaches it before the frame it is due on is read.
            let want = if self.sequenced {
                channels
            } else {
                self.staging.len() - self.staging.len() % channels
            };
            self.staged = self.source.read(&mut self.staging[..want]);
            self.consumed = 0;
            if self.staged > 0 {
                break;
            }
            if !self.source.exhausted() {
                return false;
            }
            if !self.repeating {
                self.ended = true;
                return false;
            }
            restarts += 1;
            if restarts > MAX_LOOP_RESTARTS || !self.source.seek(self.loop_start) {
                self.ended = true;
                return false;
            }
        }
        self.previous = self.upcoming;
        let from = self.consumed * channels;
        self.upcoming[..channels].copy_from_slice(&self.staging[from..from + channels]);
        self.consumed += 1;
        true
    }

    fn advance(&mut self) -> bool {
        if self.pull() {
            return true;
        }
        if !self.nearest || !self.ended || self.holding_last {
            return false;
        }
        self.ended = false;
        self.holding_last = true;
        self.previous = self.upcoming;
        true
    }

    fn fade_to(&mut self, target: f32, seconds: f32, output_rate: u32) {
        if seconds <= 0.0 || output_rate == 0 {
            self.envelope = target;
            self.envelope_step = 0.0;
            return;
        }
        let frames = (seconds * output_rate as f32).max(1.0);
        self.envelope_step = (target - self.envelope) / frames;
    }
}

/// Peak and power since the meter was last read, and the samples clipped.
#[derive(Clone, Copy, Debug, Default)]
pub struct Meter {
    pub peak: f32,
    pub squares: f64,
    pub samples: u64,
    pub clipped: u64,
}

impl Meter {
    fn measure(&mut self, buffer: &[f32]) {
        for sample in buffer {
            let value = sample.abs();
            if value > self.peak {
                self.peak = value;
            }
            self.squares += (*sample as f64) * (*sample as f64);
            if value >= 1.0 {
                self.clipped += 1;
            }
        }
        self.samples += buffer.len() as u64;
    }

    /// Reports the root mean square since the last read.
    pub fn rms(&self) -> f32 {
        if self.samples == 0 {
            0.0
        } else {
            (self.squares / self.samples as f64).sqrt() as f32
        }
    }
}

/// One insert in a chain, with the id Tecs gave it.
struct Insert {
    id: u64,
    effect: Box<dyn Effect>,
}

/// What a Track and a Bus share: a buffer, a fader, an insert chain, a meter.
struct Strip {
    buffer: Vec<f32>,
    /// The fader's target, and the level gliding towards it.
    gain: f32,
    level: f32,
    mute: bool,
    inserts: Vec<Insert>,
    meter: Meter,
    /// Frames the inserts still ring for after the strip's input stopped.
    tail: u64,
    /// Set when something was added into the buffer this block.
    fed: bool,
    /// Set while the strip has nothing to process, so a new level takes
    /// effect at once: a jump on silence cannot click.
    idle: bool,
}

impl Strip {
    fn new(channels: usize) -> Strip {
        Strip {
            buffer: vec![0.0; BLOCK_FRAMES * channels.max(1)],
            gain: 1.0,
            level: 1.0,
            mute: false,
            inserts: Vec::with_capacity(MAX_INSERTS),
            meter: Meter::default(),
            tail: 0,
            fed: false,
            idle: true,
        }
    }

    /// Sets the fader's target, snapping to it while the strip is idle.
    fn set_gain(&mut self, gain: f32) {
        self.gain = gain.max(0.0);
        if self.idle {
            self.level = self.gain;
        }
    }

    /// Reports whether the strip has anything to process this block.
    fn awake(&self) -> bool {
        self.fed || self.tail > 0
    }

    /// Runs the insert chain, keeping the tail up to date.
    fn run_inserts(&mut self, frames: usize, channels: usize) {
        let samples = frames * channels;
        if self.inserts.is_empty() {
            self.tail = 0;
            return;
        }
        for insert in &mut self.inserts {
            insert
                .effect
                .process(&mut self.buffer[..samples], frames, channels);
        }
        if self.fed {
            self.tail = self
                .inserts
                .iter()
                .map(|insert| insert.effect.tail_frames())
                .max()
                .unwrap_or(0);
        } else {
            self.tail = self.tail.saturating_sub(frames as u64);
        }
    }

    /// Applies the fader, gliding towards `target`.
    fn run_fader(&mut self, target: f32, frames: usize, channels: usize, glide: f32) {
        if self.level == target {
            if target != 1.0 {
                for sample in &mut self.buffer[..frames * channels] {
                    *sample *= target;
                }
            }
            return;
        }
        for frame in 0..frames {
            self.level += (target - self.level) * glide;
            if (self.level - target).abs() < 1e-5 {
                self.level = target;
            }
            for channel in 0..channels {
                self.buffer[frame * channels + channel] *= self.level;
            }
        }
    }
}

/// A channel strip with its routing.
struct Track {
    strip: Strip,
    bus: u32,
    solo: bool,
    placement: Placement,
    sends: Vec<SendLevel>,
}

/// One post-fader send, with its level gliding to its target.
struct SendLevel {
    bus: u32,
    target: f32,
    level: f32,
}

/// A subgroup, a return, or Master.
struct Bus {
    strip: Strip,
    parent: u32,
    paused: bool,
    /// Paused here or above, which holds every voice routed under it.
    held: bool,
    depth: u32,
}

/// Everything the mixer has finished with, for a thread that may free it.
///
/// Dropping this is what frees it, so the caller drops it outside the lock.
pub struct Retired {
    voices: Vec<Voice>,
    effects: Vec<Box<dyn Effect>>,
    strips: Vec<Strip>,
}

impl Retired {
    /// Reports how many voices it holds.
    pub fn len(&self) -> usize {
        self.voices.len()
    }

    /// Reports whether it holds nothing at all.
    pub fn is_empty(&self) -> bool {
        self.voices.is_empty() && self.effects.is_empty() && self.strips.is_empty()
    }
}

/// What a meter read reports for one strip.
#[derive(Clone, Copy, Debug)]
pub struct StripMeter {
    /// Zero for a Track, one for a Bus.
    pub bus: bool,
    pub id: u32,
    pub meter: Meter,
}

/// Mixes every voice through the console into one output buffer.
pub struct Mixer {
    voices: Vec<Voice>,
    events: Vec<Event>,
    master_gain: f32,
    output_rate: u32,
    output_channels: u16,
    max_voices: usize,
    rendered: u64,
    schedule: VecDeque<Scheduled>,
    retired: Vec<Voice>,
    retired_effects: Vec<Box<dyn Effect>>,
    retired_strips: Vec<Strip>,
    late: u64,
    tracks: Vec<Option<Track>>,
    buses: Vec<Option<Bus>>,
    /// Bus ids other than Master, deepest first, which is the order they sum.
    order: Vec<u32>,
    any_solo: bool,
    /// Effects in every chain, which is how many a timed removal can retire.
    insert_count: usize,
    /// The per-frame glide coefficient for faders and sends.
    glide: f32,
    /// Set when the mixer runs on the render side, where nothing may grow:
    /// a full schedule applies a command at once rather than growing.
    bounded: bool,
}

/// What the render side hands back to be freed, one thing at a time.
///
/// Carried by value rather than boxed, so handing one over allocates nothing.
pub enum Leftover {
    Voice(VoiceBox),
    Effect(Box<dyn Effect>),
    Strip(StripBox),
}

/// A finished voice, as a `Leftover` carries it.
pub struct VoiceBox(Voice);

/// A voice built on the control side for its `PLAY`, so starting it on the
/// render side allocates nothing. The Track it sounds on is settled there.
pub struct Prepared(Voice);

impl Prepared {
    /// Builds the voice a `PLAY` starts, or nothing for one that could
    /// never sound.
    pub fn new(
        command: &Command,
        source: Option<Box<dyn Source>>,
        output_rate: u32,
    ) -> Option<Prepared> {
        build_voice(command, source, output_rate).map(Prepared)
    }
}

/// A destroyed strip, as a `Leftover` carries it.
pub struct StripBox(Strip);

/// A strip built on the control side for a `TRACK_CREATE` or `BUS_CREATE`
/// to take, so creating one on the render side allocates nothing.
pub struct Fresh {
    strip: Strip,
    sends: Vec<SendLevel>,
}

impl Fresh {
    /// Builds a strip for a layout.
    pub fn new(channels: u16) -> Fresh {
        Fresh {
            strip: Strip::new(channels as usize),
            sends: Vec::with_capacity(MAX_SENDS),
        }
    }
}

/// Room for strips, built on the control side and adopted by the render
/// side, which moves what it holds into it and hands back the old storage.
pub struct Storage {
    tracks: Vec<Option<Track>>,
    buses: Vec<Option<Bus>>,
    order: Vec<u32>,
}

impl Storage {
    /// Builds room for this many Track and Bus ids.
    pub fn with_capacity(tracks: usize, buses: usize) -> Storage {
        Storage {
            tracks: Vec::with_capacity(tracks),
            buses: Vec::with_capacity(buses),
            order: Vec::with_capacity(buses),
        }
    }
}

impl Mixer {
    /// Creates a console for one output layout: Master, and the default Track
    /// routed to it.
    pub fn new(output_rate: u32, output_channels: u16, max_voices: usize) -> Mixer {
        let channels = output_channels as usize;
        let glide = if output_rate == 0 {
            1.0
        } else {
            1.0 - (-1.0 / (GLIDE_SECONDS * output_rate as f32)).exp()
        };
        let mut mixer = Mixer {
            voices: Vec::with_capacity(max_voices),
            events: Vec::with_capacity(max_voices),
            master_gain: 1.0,
            output_rate,
            output_channels,
            max_voices,
            rendered: 0,
            schedule: VecDeque::with_capacity(SCHEDULE_COMMANDS),
            retired: Vec::with_capacity(max_voices),
            retired_effects: Vec::new(),
            retired_strips: Vec::new(),
            late: 0,
            tracks: Vec::with_capacity(16),
            buses: Vec::with_capacity(8),
            order: Vec::with_capacity(8),
            any_solo: false,
            insert_count: 0,
            glide,
            bounded: false,
        };
        mixer.buses.push(Some(Bus {
            strip: Strip::new(channels),
            parent: 0,
            paused: false,
            held: false,
            depth: 0,
        }));
        mixer.tracks.push(Some(Track {
            strip: Strip::new(channels),
            bus: 0,
            solo: false,
            placement: Placement::None,
            sends: Vec::with_capacity(MAX_SENDS),
        }));
        mixer
    }

    // -- Recording and counters ------------------------------------------

    /// Reports how many timed commands arrived after their frame.
    pub fn late(&self) -> u64 {
        self.late
    }

    /// Reads and resets every strip's meter: Master first, then the other
    /// Buses, then the Tracks, into `out`, and reports how many it wrote.
    pub fn meters(&mut self, out: &mut Vec<StripMeter>) {
        out.clear();
        for (id, bus) in self.buses.iter_mut().enumerate() {
            if let Some(bus) = bus {
                out.push(StripMeter {
                    bus: true,
                    id: id as u32,
                    meter: std::mem::take(&mut bus.strip.meter),
                });
            }
        }
        for (id, track) in self.tracks.iter_mut().enumerate() {
            if let Some(track) = track {
                out.push(StripMeter {
                    bus: false,
                    id: id as u32,
                    meter: std::mem::take(&mut track.strip.meter),
                });
            }
        }
    }

    // -- The render side ------------------------------------------------------

    /// Runs bounded, as the render side does: no structure grows here.
    pub fn set_bounded(&mut self, bounded: bool) {
        self.bounded = bounded;
    }

    /// Reports how many Track and Bus ids the mixer has room for.
    pub fn strip_room(&self) -> (usize, usize) {
        (self.tracks.capacity(), self.buses.capacity())
    }

    /// Moves every strip into storage built with more room, and hands back
    /// the old storage, empty, for the control side to free.
    pub fn adopt(&mut self, mut storage: Storage) -> Storage {
        storage.tracks.append(&mut self.tracks);
        storage.buses.append(&mut self.buses);
        storage.order.append(&mut self.order);
        std::mem::swap(&mut self.tracks, &mut storage.tracks);
        std::mem::swap(&mut self.buses, &mut storage.buses);
        std::mem::swap(&mut self.order, &mut storage.order);
        storage
    }

    /// Makes room ahead, on whatever thread may allocate, for everything a
    /// bounded mixer will retire between two collections.
    pub fn reserve_bounded(
        &mut self,
        voices: usize,
        effects: usize,
        strips: usize,
        schedule: usize,
    ) {
        self.retired.reserve(voices);
        self.events.reserve(voices);
        self.retired_effects.reserve(effects);
        self.retired_strips.reserve(strips);
        self.schedule.reserve(schedule);
    }

    /// Hands over each finished voice, effect and strip in turn, without
    /// allocating, and keeps what `hand` will not take for next time.
    pub fn drain_leftovers(&mut self, mut hand: impl FnMut(Leftover) -> Result<(), Leftover>) {
        while let Some(voice) = self.retired.pop() {
            if let Err(Leftover::Voice(back)) = hand(Leftover::Voice(VoiceBox(voice))) {
                self.retired.push(back.0);
                return;
            }
        }
        while let Some(effect) = self.retired_effects.pop() {
            if let Err(Leftover::Effect(back)) = hand(Leftover::Effect(effect)) {
                self.retired_effects.push(back);
                return;
            }
        }
        while let Some(strip) = self.retired_strips.pop() {
            if let Err(Leftover::Strip(back)) = hand(Leftover::Strip(StripBox(strip))) {
                self.retired_strips.push(back.0);
                return;
            }
        }
    }

    /// Hands over each observation in turn, keeping what `hand` will not take.
    pub fn drain_events(&mut self, mut hand: impl FnMut(Event) -> bool) {
        let mut taken = 0;
        for event in &self.events {
            if !hand(*event) {
                break;
            }
            taken += 1;
        }
        self.events.drain(..taken);
    }

    /// Writes every voice's handle and position into `out`, within its room.
    pub fn positions_into(&self, out: &mut Vec<(u32, f64)>) {
        out.clear();
        for voice in &self.voices {
            if out.len() == out.capacity() {
                break;
            }
            out.push((voice.handle, voice.source.position()));
        }
    }

    /// Adds every strip's meter into `out`, by strip, and resets the strip's,
    /// adding a strip `out` lacks only while it has room.
    pub fn merge_meters(&mut self, out: &mut Vec<StripMeter>) {
        let mut merge = |bus: bool, id: u32, meter: &mut Meter| {
            let taken = std::mem::take(meter);
            if let Some(entry) = out
                .iter_mut()
                .find(|entry| entry.bus == bus && entry.id == id)
            {
                entry.meter.peak = entry.meter.peak.max(taken.peak);
                entry.meter.squares += taken.squares;
                entry.meter.samples += taken.samples;
                entry.meter.clipped += taken.clipped;
            } else if out.len() < out.capacity() {
                out.push(StripMeter {
                    bus,
                    id,
                    meter: taken,
                });
            }
        };
        for (id, bus) in self.buses.iter_mut().enumerate() {
            if let Some(bus) = bus {
                merge(true, id as u32, &mut bus.strip.meter);
            }
        }
        for (id, track) in self.tracks.iter_mut().enumerate() {
            if let Some(track) = track {
                merge(false, id as u32, &mut track.strip.meter);
            }
        }
    }

    // -- Retirement --------------------------------------------------------

    /// Hands over everything that has ended since the last call. Call it from
    /// a thread that may free memory, never from the output callback.
    pub fn collect(&mut self) -> Retired {
        let voices = self.retired.capacity();
        let effects = self.retired_effects.capacity();
        Retired {
            voices: std::mem::replace(&mut self.retired, Vec::with_capacity(voices)),
            effects: std::mem::replace(&mut self.retired_effects, Vec::with_capacity(effects)),
            strips: std::mem::take(&mut self.retired_strips),
        }
    }

    /// Makes room for everything that could end before the submitting thread
    /// looks again, so a push on the output callback never allocates.
    fn reserve_retired(&mut self) {
        let need = self.voices.len() + self.schedule.len() + 1;
        if self.retired.capacity() - self.retired.len() < need {
            self.retired.reserve(need);
        }
        if self.events.capacity() - self.events.len() < need {
            self.events.reserve(need);
        }
        let effects = self.insert_count + self.schedule.len() + 1;
        if self.retired_effects.capacity() - self.retired_effects.len() < effects {
            self.retired_effects.reserve(effects);
        }
    }

    fn retire(&mut self, voice: Voice) {
        self.events.push(Event {
            kind: command::EVENT_FINISHED,
            handle: voice.handle,
        });
        self.retired.push(voice);
    }

    fn finish_unstarted(&mut self, handle: u32) {
        if handle != 0 {
            self.events.push(Event {
                kind: command::EVENT_FINISHED,
                handle,
            });
        }
    }

    // -- The schedule --------------------------------------------------------

    pub fn rendered(&self) -> u64 {
        self.rendered
    }

    /// Reports the output clock: the frames rendered since the mixer was made.
    pub fn frames(&self) -> u64 {
        self.rendered
    }

    /// Reports how many commands are waiting for their frame.
    pub fn scheduled(&self) -> usize {
        self.schedule.len()
    }

    fn frame_at(&self, seconds: f64) -> u64 {
        if !seconds.is_finite() || seconds <= 0.0 {
            return 0;
        }
        (seconds * self.output_rate as f64).round() as u64
    }

    fn pending_start(&self, handle: u32) -> Option<u64> {
        self.schedule
            .iter()
            .find(|queued| queued.voice.is_some() && queued.command.handle == handle)
            .map(|queued| queued.frame)
    }

    fn cancel_pending(&mut self, handle: u32) -> bool {
        let mut cancelled = false;
        let mut index = 0;
        while index < self.schedule.len() {
            if self.schedule[index].command.handle != handle {
                index += 1;
                continue;
            }
            if let Some(queued) = self.schedule.remove(index) {
                if let Some(voice) = queued.voice {
                    cancelled = true;
                    self.retire(voice);
                }
            }
        }
        cancelled
    }

    fn defer_to_start(&mut self, command: &Command) -> bool {
        let Some(frame) = self.pending_start(command.handle) else {
            return false;
        };
        let at = self
            .schedule
            .partition_point(|queued| queued.frame <= frame);
        self.schedule.insert(
            at,
            Scheduled {
                frame,
                command: *command,
                voice: None,
                effect: None,
            },
        );
        true
    }

    /// Applies one command on the frame its `at` names, or at once.
    pub fn submit(&mut self, command: &Command, source: Option<Box<dyn Source>>) {
        self.submit_prepared(command, source, None);
    }

    /// Applies an `EFFECT_INSERT` with the effect it inserts.
    pub fn submit_effect(&mut self, command: &Command, effect: Box<dyn Effect>) {
        self.submit_prepared(command, None, Some(effect));
    }

    fn submit_prepared(
        &mut self,
        command: &Command,
        source: Option<Box<dyn Source>>,
        effect: Option<Box<dyn Effect>>,
    ) {
        self.reserve_retired();
        if structural(command.kind) {
            self.apply_due();
            self.apply_structure(command);
            return;
        }
        let frame = self.frame_at(command.at);
        if frame > 0 && frame < self.rendered {
            self.late += 1;
        }
        let full = self.bounded && self.schedule.len() == self.schedule.capacity();
        if full && frame > self.rendered {
            // Growing the schedule would allocate here; landing early is
            // the lesser harm, and it is counted.
            self.late += 1;
        }
        if frame <= self.rendered || full {
            self.apply_due();
            self.apply_with(command, source, effect);
            return;
        }
        let voice = if command.kind == command::PLAY {
            match self.build(command, source) {
                None => {
                    self.finish_unstarted(command.handle);
                    return;
                }
                Some(value) => Some(value),
            }
        } else {
            None
        };
        let at = self
            .schedule
            .partition_point(|queued| queued.frame <= frame);
        self.schedule.insert(
            at,
            Scheduled {
                frame,
                command: *command,
                voice,
                effect,
            },
        );
    }

    fn apply_due(&mut self) {
        while self
            .schedule
            .front()
            .is_some_and(|queued| queued.frame <= self.rendered)
        {
            let Some(queued) = self.schedule.pop_front() else {
                return;
            };
            match queued.voice {
                Some(voice) => self.admit(voice),
                None => self.apply_with(&queued.command, None, queued.effect),
            }
        }
    }

    // -- Voices --------------------------------------------------------------

    /// Reports how many voices are sounding, paused ones included.
    pub fn voice_count(&self) -> usize {
        self.voices.len()
    }

    fn index_of(&self, handle: u32) -> Option<usize> {
        self.voices.iter().position(|voice| voice.handle == handle)
    }

    /// Reports a voice's read position in seconds.
    pub fn position(&mut self, handle: u32) -> Option<f64> {
        self.apply_due();
        self.index_of(handle)
            .map(|index| self.voices[index].source.position())
    }

    /// Moves a voice's read position and reports whether the input accepted it.
    pub fn seek(&mut self, handle: u32, seconds: f64) -> bool {
        self.apply_due();
        match self.index_of(handle) {
            None => false,
            Some(index) => {
                let voice = &mut self.voices[index];
                if !voice.source.seek(seconds.max(0.0)) {
                    return false;
                }
                voice.staged = 0;
                voice.consumed = 0;
                voice.primed = false;
                voice.holding_last = false;
                voice.fraction = 0.0;
                voice.previous = [0.0; MAX_CHANNELS];
                voice.upcoming = [0.0; MAX_CHANNELS];
                true
            }
        }
    }

    /// Moves every observation since the last drain into `out`.
    pub fn drain(&mut self, out: &mut [Event]) -> usize {
        let count = self.events.len().min(out.len());
        out[..count].copy_from_slice(&self.events[..count]);
        self.events.drain(..count);
        count
    }

    /// Ends every voice without a fade, the waiting starts included, and
    /// drops every scheduled command.
    pub fn stop_all(&mut self) {
        self.reserve_retired();
        while let Some(queued) = self.schedule.pop_front() {
            if let Some(voice) = queued.voice {
                self.retire(voice);
            }
            if let Some(effect) = queued.effect {
                self.retired_effects.push(effect);
            }
        }
        while let Some(voice) = self.voices.pop() {
            self.retire(voice);
        }
    }

    /// Applies one command, taking the source a `PLAY` was prepared with.
    pub fn apply(&mut self, command: &Command, source: Option<Box<dyn Source>>) {
        if structural(command.kind) {
            self.apply_structure(command);
            return;
        }
        self.apply_with(command, source, None);
    }

    fn apply_with(
        &mut self,
        command: &Command,
        source: Option<Box<dyn Source>>,
        effect: Option<Box<dyn Effect>>,
    ) {
        if targets_voice(command.kind) && self.index_of(command.handle).is_none() {
            if command.kind == command::STOP {
                self.cancel_pending(command.handle);
                return;
            }
            if self.defer_to_start(command) {
                return;
            }
        }
        match command.kind {
            command::PLAY => self.start(command, source),
            command::STOP => self.stop(command),
            command::PAUSE => self.set_paused(command.handle, true),
            command::RESUME => self.set_paused(command.handle, false),
            command::SET_GAIN => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].gain = command.gain;
                }
            }
            command::SET_PITCH => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].pitch = command.pitch;
                }
            }
            command::SET_LOOP => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].repeating = command.has(command::FLAG_LOOP);
                }
            }
            command::SET_POSITION => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::Spatial {
                        x: command.x,
                        y: command.y,
                        z: command.z,
                    };
                }
            }
            command::SET_STEREO => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::Stereo {
                        left: command.x,
                        right: command.y,
                    };
                }
            }
            command::CLEAR_PLACEMENT => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::None;
                }
            }
            command::SET_MASTER_GAIN => self.master_gain = command.gain,
            command::SET_RESAMPLE => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].nearest = command.has(command::FLAG_NEAREST);
                }
            }
            command::EVENT => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].source.event(command.data);
                }
            }
            command::SET_TRACK => {
                let track = self.track_or_default(command.target);
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].track = track;
                }
            }
            command::TRACK_SET => self.set_track(command),
            command::BUS_SET => self.set_bus(command),
            command::SEND => self.set_send(command),
            command::EFFECT_INSERT => {
                if let Some(effect) = effect {
                    self.insert_effect(command, effect);
                }
            }
            command::EFFECT_REMOVE => self.remove_effect(command.data),
            command::EFFECT_PARAM => {
                if let Some(insert) = self.find_effect(command.data) {
                    insert.effect.param(command.param, command.gain);
                }
            }
            _ => {}
        }
    }

    fn start(&mut self, command: &Command, source: Option<Box<dyn Source>>) {
        match self.build(command, source) {
            Some(voice) => self.admit(voice),
            None => self.finish_unstarted(command.handle),
        }
    }

    fn admit(&mut self, voice: Voice) {
        if self.voices.len() >= self.max_voices {
            self.retire(voice);
            return;
        }
        self.voices.push(voice);
    }

    fn build(&self, command: &Command, source: Option<Box<dyn Source>>) -> Option<Voice> {
        let mut voice = build_voice(command, source, self.output_rate)?;
        voice.track = self.track_or_default(voice.track);
        Some(voice)
    }

    /// Applies a `PLAY` whose voice the control side built.
    pub fn submit_voice(&mut self, command: &Command, prepared: Option<Prepared>) {
        self.reserve_retired();
        let Some(Prepared(mut voice)) = prepared else {
            self.finish_unstarted(command.handle);
            return;
        };
        voice.track = self.track_or_default(voice.track);
        let frame = self.frame_at(command.at);
        if frame > 0 && frame < self.rendered {
            self.late += 1;
        }
        let full = self.bounded && self.schedule.len() == self.schedule.capacity();
        if frame <= self.rendered || full {
            self.apply_due();
            self.admit(voice);
            return;
        }
        let at = self
            .schedule
            .partition_point(|queued| queued.frame <= frame);
        self.schedule.insert(
            at,
            Scheduled {
                frame,
                command: *command,
                voice: Some(voice),
                effect: None,
            },
        );
    }

    fn stop(&mut self, command: &Command) {
        let index = match self.index_of(command.handle) {
            None => return,
            Some(value) => value,
        };
        if command.fade > 0.0 {
            let rate = self.output_rate;
            let voice = &mut self.voices[index];
            voice.paused = false;
            voice.stopping = true;
            voice.fade_to(0.0, command.fade, rate);
            return;
        }
        let voice = self.voices.remove(index);
        self.retire(voice);
    }

    fn set_paused(&mut self, handle: u32, paused: bool) {
        if let Some(index) = self.index_of(handle) {
            let voice = &mut self.voices[index];
            if !voice.stopping {
                voice.paused = paused;
            }
        }
    }

    // -- Tracks and Buses ----------------------------------------------------

    /// Reports whether a Track exists.
    pub fn has_track(&self, id: u32) -> bool {
        self.tracks.get(id as usize).is_some_and(Option::is_some)
    }

    /// Reports whether a Bus exists.
    pub fn has_bus(&self, id: u32) -> bool {
        self.buses.get(id as usize).is_some_and(Option::is_some)
    }

    fn track_or_default(&self, id: u32) -> u32 {
        if self.has_track(id) {
            id
        } else {
            0
        }
    }

    fn bus_or_master(&self, id: u32) -> u32 {
        if self.has_bus(id) {
            id
        } else {
            0
        }
    }

    /// Applies a command that creates or destroys a strip, on the submitting
    /// thread, where allocating is allowed.
    fn apply_structure(&mut self, command: &Command) {
        self.apply_structure_with(command, None);
    }

    /// Applies a structural command with the strip the control side built
    /// for it, which a create takes instead of allocating one.
    pub fn apply_structure_with(&mut self, command: &Command, fresh: Option<Fresh>) {
        let channels = self.output_channels as usize;
        let (strip, sends) = match fresh {
            Some(made) => (Some(made.strip), Some(made.sends)),
            None => (None, None),
        };
        let id = command.target as usize;
        match command.kind {
            command::TRACK_CREATE => {
                if id == 0 {
                    return;
                }
                if self.tracks.len() <= id {
                    self.tracks.resize_with(id + 1, || None);
                }
                if self.tracks[id].is_none() {
                    let bus = self.bus_or_master(command.param);
                    self.tracks[id] = Some(Track {
                        strip: strip.unwrap_or_else(|| Strip::new(channels)),
                        bus,
                        solo: false,
                        placement: Placement::None,
                        sends: sends.unwrap_or_else(|| Vec::with_capacity(MAX_SENDS)),
                    });
                }
            }
            command::TRACK_DESTROY => {
                if id == 0 || id >= self.tracks.len() {
                    return;
                }
                if let Some(track) = self.tracks[id].take() {
                    for voice in &mut self.voices {
                        if voice.track == command.target {
                            voice.track = 0;
                        }
                    }
                    self.retire_strip(track.strip);
                    self.refresh_solo();
                }
            }
            command::BUS_CREATE => {
                if id == 0 {
                    return;
                }
                if self.buses.len() <= id {
                    self.buses.resize_with(id + 1, || None);
                }
                if self.buses[id].is_none() {
                    let parent = self.bus_or_master(command.param);
                    self.buses[id] = Some(Bus {
                        strip: strip.unwrap_or_else(|| Strip::new(channels)),
                        parent,
                        paused: false,
                        held: false,
                        depth: 0,
                    });
                    if self.order.capacity() < self.buses.len() {
                        self.order.reserve(self.buses.len());
                    }
                    self.reorder();
                }
            }
            command::BUS_DESTROY => {
                if id == 0 || id >= self.buses.len() {
                    return;
                }
                if let Some(bus) = self.buses[id].take() {
                    let parent = bus.parent;
                    for track in self.tracks.iter_mut().flatten() {
                        if track.bus == command.target {
                            track.bus = parent;
                        }
                        track.sends.retain(|send| send.bus != command.target);
                    }
                    for other in self.buses.iter_mut().flatten() {
                        if other.parent == command.target {
                            other.parent = parent;
                        }
                    }
                    self.retire_strip(bus.strip);
                    self.reorder();
                }
            }
            _ => {}
        }
    }

    fn retire_strip(&mut self, mut strip: Strip) {
        self.insert_count -= strip.inserts.len();
        for insert in strip.inserts.drain(..) {
            self.retired_effects.push(insert.effect);
        }
        self.retired_strips.push(strip);
    }

    /// Recomputes each Bus's depth, whether it is held, and the order Buses
    /// sum in. Allocates nothing: `order` has room for every Bus.
    fn reorder(&mut self) {
        let count = self.buses.len();
        for id in 0..count {
            // Walk up to Master, guarding against a cycle a bad parent made.
            let mut depth = 0u32;
            let mut held = false;
            let mut cursor = id;
            let mut steps = 0;
            while let Some(bus) = self.buses[cursor].as_ref() {
                held |= bus.paused;
                if cursor == 0 || steps > count {
                    break;
                }
                cursor = bus.parent as usize;
                depth += 1;
                steps += 1;
            }
            if let Some(bus) = self.buses[id].as_mut() {
                bus.depth = depth;
                bus.held = held;
            }
        }
        self.order.clear();
        for id in 1..count {
            if self.buses[id].is_some() {
                self.order.push(id as u32);
            }
        }
        let buses = &self.buses;
        self.order.sort_unstable_by_key(|id| {
            std::cmp::Reverse(buses[*id as usize].as_ref().map_or(0, |bus| bus.depth))
        });
    }

    fn refresh_solo(&mut self) {
        self.any_solo = self.tracks.iter().flatten().any(|track| track.solo);
    }

    fn set_track(&mut self, command: &Command) {
        let id = command.target as usize;
        let bus = self.bus_or_master(command.data as u32);
        let Some(Some(track)) = self.tracks.get_mut(id) else {
            return;
        };
        match command.param {
            command::TRACK_GAIN => track.strip.set_gain(command.gain),
            command::TRACK_MUTE => track.strip.mute = command.gain != 0.0,
            command::TRACK_SOLO => {
                track.solo = command.gain != 0.0;
                self.refresh_solo();
            }
            command::TRACK_BUS => track.bus = bus,
            command::TRACK_POSITION => {
                track.placement = Placement::Spatial {
                    x: command.x,
                    y: command.y,
                    z: command.z,
                }
            }
            command::TRACK_STEREO => {
                track.placement = Placement::Stereo {
                    left: command.x,
                    right: command.y,
                }
            }
            command::TRACK_UNPLACED => track.placement = Placement::None,
            _ => {}
        }
    }

    fn set_bus(&mut self, command: &Command) {
        let id = command.target as usize;
        let parent = self.bus_or_master(command.data as u32);
        let Some(Some(bus)) = self.buses.get_mut(id) else {
            return;
        };
        match command.param {
            command::BUS_GAIN => bus.strip.set_gain(command.gain),
            command::BUS_MUTE => bus.strip.mute = command.gain != 0.0,
            command::BUS_PAUSE => {
                bus.paused = command.gain != 0.0;
                self.reorder();
            }
            command::BUS_PARENT if id != 0 && parent as usize != id => {
                bus.parent = parent;
                self.reorder();
            }
            _ => {}
        }
    }

    fn set_send(&mut self, command: &Command) {
        let bus = command.param;
        if !self.has_bus(bus) || bus == 0 {
            return;
        }
        let Some(Some(track)) = self.tracks.get_mut(command.target as usize) else {
            return;
        };
        let level = command.gain.max(0.0);
        if let Some(send) = track.sends.iter_mut().find(|send| send.bus == bus) {
            send.target = level;
            return;
        }
        if level > 0.0 && track.sends.len() < MAX_SENDS {
            track.sends.push(SendLevel {
                bus,
                target: level,
                level: 0.0,
            });
        }
    }

    fn strip_mut(&mut self, bus: bool, id: u32) -> Option<&mut Strip> {
        if bus {
            self.buses
                .get_mut(id as usize)?
                .as_mut()
                .map(|bus| &mut bus.strip)
        } else {
            self.tracks
                .get_mut(id as usize)?
                .as_mut()
                .map(|track| &mut track.strip)
        }
    }

    fn insert_effect(&mut self, command: &Command, effect: Box<dyn Effect>) {
        let on_bus = command.has(command::FLAG_BUS);
        let position = command.param as usize;
        let id = command.data;
        let added = match self.strip_mut(on_bus, command.target) {
            Some(strip) if strip.inserts.len() < MAX_INSERTS => {
                let at = position.min(strip.inserts.len());
                strip.inserts.insert(at, Insert { id, effect });
                None
            }
            _ => Some(effect),
        };
        match added {
            None => self.insert_count += 1,
            Some(effect) => self.retired_effects.push(effect),
        }
    }

    fn find_effect(&mut self, id: u64) -> Option<&mut Insert> {
        for track in self.tracks.iter_mut().flatten() {
            if let Some(insert) = track
                .strip
                .inserts
                .iter_mut()
                .find(|insert| insert.id == id)
            {
                return Some(insert);
            }
        }
        for bus in self.buses.iter_mut().flatten() {
            if let Some(insert) = bus.strip.inserts.iter_mut().find(|insert| insert.id == id) {
                return Some(insert);
            }
        }
        None
    }

    fn remove_effect(&mut self, id: u64) {
        let mut removed: Option<Box<dyn Effect>> = None;
        for strip in self
            .tracks
            .iter_mut()
            .flatten()
            .map(|track| &mut track.strip)
            .chain(self.buses.iter_mut().flatten().map(|bus| &mut bus.strip))
        {
            if let Some(index) = strip.inserts.iter().position(|insert| insert.id == id) {
                removed = Some(strip.inserts.remove(index).effect);
                break;
            }
        }
        if let Some(effect) = removed {
            self.insert_count -= 1;
            self.retired_effects.push(effect);
        }
    }

    // -- Rendering -----------------------------------------------------------

    /// Fills `out` with the mix.
    ///
    /// `out` is interleaved at the mixer's own channel count, and whatever it
    /// held is overwritten. The buffer is rendered in spans split at every
    /// scheduled command's frame, each in blocks of at most `BLOCK_FRAMES`,
    /// and the output clock advances by the frames written.
    pub fn render(&mut self, out: &mut [f32]) {
        for sample in out.iter_mut() {
            *sample = 0.0;
        }
        let channels = self.output_channels as usize;
        if channels == 0 || self.output_rate == 0 {
            return;
        }
        let frames = out.len() / channels;
        let mut done = 0;
        while done < frames {
            self.apply_due();
            let left = (frames - done) as u64;
            let span = match self.schedule.front() {
                Some(queued) => (queued.frame - self.rendered).min(left),
                None => left,
            }
            .min(BLOCK_FRAMES as u64) as usize;
            self.render_block(&mut out[done * channels..(done + span) * channels], span);
            self.rendered += span as u64;
            done += span;
        }
    }

    /// Runs one block through the console into `out`.
    fn render_block(&mut self, out: &mut [f32], frames: usize) {
        let channels = self.output_channels as usize;
        let samples = frames * channels;
        let rate = self.output_rate;
        let glide = self.glide;

        for track in self.tracks.iter_mut().flatten() {
            track.strip.buffer[..samples].fill(0.0);
            track.strip.fed = false;
        }
        for bus in self.buses.iter_mut().flatten() {
            bus.strip.buffer[..samples].fill(0.0);
            bus.strip.fed = false;
        }

        // Playbacks into their Tracks.
        let mut index = 0;
        while index < self.voices.len() {
            let track_id = self.voices[index].track as usize;
            let (track_bus, ok) = match self.tracks.get(track_id) {
                Some(Some(track)) => (track.bus as usize, true),
                _ => (0, false),
            };
            if !ok {
                self.voices[index].track = 0;
            }
            let held = self
                .buses
                .get(track_bus)
                .and_then(Option::as_ref)
                .is_some_and(|bus| bus.held);
            if !held {
                let track_id = if ok { track_id } else { 0 };
                if let Some(Some(track)) = self.tracks.get_mut(track_id) {
                    let voice = &mut self.voices[index];
                    if !voice.paused && !voice.ended {
                        track.strip.fed = true;
                    }
                    render_voice(
                        voice,
                        &mut track.strip.buffer[..samples],
                        channels,
                        frames,
                        rate,
                    );
                }
            }
            if self.voices[index].ended {
                let voice = self.voices.remove(index);
                self.retire(voice);
            } else {
                index += 1;
            }
        }

        // Tracks into their Buses and sends.
        let any_solo = self.any_solo;
        for track_index in 0..self.tracks.len() {
            let Some(track) = self.tracks[track_index].as_mut() else {
                continue;
            };
            if !track.strip.awake() {
                track.strip.idle = true;
                continue;
            }
            track.strip.idle = false;
            track.strip.run_inserts(frames, channels);
            let silenced = track.strip.mute || (any_solo && !track.solo);
            let target = if silenced { 0.0 } else { track.strip.gain };
            track.strip.run_fader(target, frames, channels, glide);
            place(
                track.placement,
                &mut track.strip.buffer[..samples],
                channels,
            );
            track.strip.meter.measure(&track.strip.buffer[..samples]);
            let bus_id = track.bus as usize;
            // Split the borrow: the Track's buffer is read while Buses take it.
            let (tracks, buses) = (&mut self.tracks, &mut self.buses);
            let Some(track) = tracks[track_index].as_mut() else {
                continue;
            };
            if let Some(Some(bus)) = buses.get_mut(bus_id) {
                for (sample, value) in bus.strip.buffer[..samples]
                    .iter_mut()
                    .zip(&track.strip.buffer[..samples])
                {
                    *sample += *value;
                }
                bus.strip.fed = true;
            }
            for send in &mut track.sends {
                let Some(Some(bus)) = buses.get_mut(send.bus as usize) else {
                    continue;
                };
                for frame in 0..frames {
                    if send.level != send.target {
                        send.level += (send.target - send.level) * glide;
                        if (send.level - send.target).abs() < 1e-5 {
                            send.level = send.target;
                        }
                    }
                    for channel in 0..channels {
                        let slot = frame * channels + channel;
                        bus.strip.buffer[slot] += track.strip.buffer[slot] * send.level;
                    }
                }
                bus.strip.fed = true;
            }
        }

        // Buses into their parents, deepest first.
        for order_index in 0..self.order.len() {
            let id = self.order[order_index] as usize;
            let Some(bus) = self.buses[id].as_mut() else {
                continue;
            };
            if !bus.strip.awake() {
                bus.strip.idle = true;
                continue;
            }
            bus.strip.idle = false;
            bus.strip.run_inserts(frames, channels);
            let target = if bus.strip.mute { 0.0 } else { bus.strip.gain };
            bus.strip.run_fader(target, frames, channels, glide);
            bus.strip.meter.measure(&bus.strip.buffer[..samples]);
            let parent = bus.parent as usize;
            if parent == id {
                continue;
            }
            // Take the child out to add it into its parent.
            let Some(child) = self.buses[id].take() else {
                continue;
            };
            if let Some(Some(target)) = self.buses.get_mut(parent) {
                for (sample, value) in target.strip.buffer[..samples]
                    .iter_mut()
                    .zip(&child.strip.buffer[..samples])
                {
                    *sample += *value;
                }
                target.strip.fed = true;
            }
            self.buses[id] = Some(child);
        }

        // Master: fader first, then its inserts, so a limiter has the last word.
        if let Some(Some(master)) = self.buses.get_mut(0) {
            let strip = &mut master.strip;
            if self.master_gain != 1.0 {
                for sample in &mut strip.buffer[..samples] {
                    *sample *= self.master_gain;
                }
            }
            if strip.awake() {
                strip.run_inserts(frames, channels);
                let target = if strip.mute { 0.0 } else { strip.gain };
                strip.run_fader(target, frames, channels, glide);
            }
            strip.meter.measure(&strip.buffer[..samples]);
            out[..samples].copy_from_slice(&strip.buffer[..samples]);
        }
    }
}

fn build_voice(
    command: &Command,
    source: Option<Box<dyn Source>>,
    output_rate: u32,
) -> Option<Voice> {
    let mut source = source?;
    if command.handle == 0 {
        return None;
    }
    if command.start > 0.0 {
        source.seek(command.start as f64);
    }
    let placement = if command.has(command::FLAG_SPATIAL) {
        Placement::Spatial {
            x: command.x,
            y: command.y,
            z: command.z,
        }
    } else if command.has(command::FLAG_STEREO) {
        Placement::Stereo {
            left: command.x,
            right: command.y,
        }
    } else {
        Placement::None
    };
    let sequenced = source.sequenced();
    let mut voice = Voice {
        handle: command.handle,
        track: command.target,
        source,
        gain: command.gain,
        pitch: command.pitch,
        placement,
        repeating: command.has(command::FLAG_LOOP),
        loop_start: command.loop_start.max(0.0) as f64,
        paused: false,
        envelope: 1.0,
        envelope_step: 0.0,
        stopping: false,
        nearest: command.has(command::FLAG_NEAREST),
        holding_last: false,
        fraction: 0.0,
        previous: [0.0; MAX_CHANNELS],
        upcoming: [0.0; MAX_CHANNELS],
        primed: false,
        staging: vec![0.0; STAGING_FRAMES * MAX_CHANNELS],
        staged: 0,
        consumed: 0,
        ended: false,
        sequenced,
    };
    if command.fade > 0.0 {
        voice.envelope = 0.0;
        voice.fade_to(1.0, command.fade, output_rate);
    }
    Some(voice)
}

/// Reports whether a command creates or destroys a strip, which always
/// applies at once, on the submitting thread.
fn structural(kind: u32) -> bool {
    matches!(
        kind,
        command::TRACK_CREATE | command::TRACK_DESTROY | command::BUS_CREATE | command::BUS_DESTROY
    )
}

/// Reports whether a command kind addresses one voice by its handle.
fn targets_voice(kind: u32) -> bool {
    matches!(
        kind,
        command::STOP
            | command::PAUSE
            | command::RESUME
            | command::SET_GAIN
            | command::SET_PITCH
            | command::SET_LOOP
            | command::SET_POSITION
            | command::SET_STEREO
            | command::CLEAR_PLACEMENT
            | command::SET_RESAMPLE
            | command::EVENT
            | command::SET_TRACK
    )
}

/// Applies a Track's placement to its summed buffer.
fn place(placement: Placement, buffer: &mut [f32], channels: usize) {
    if placement == Placement::None || channels == 0 {
        return;
    }
    let (left, right) = speaker_gains(placement);
    for frame in buffer.chunks_exact_mut(channels) {
        match placement {
            Placement::Spatial { .. } => {
                let mono = if channels > 1 {
                    (frame[0] + frame[1]) * 0.5
                } else {
                    frame[0]
                };
                frame[0] = mono * left;
                if channels > 1 {
                    frame[1] = mono * right;
                }
            }
            _ => {
                frame[0] *= left;
                if channels > 1 {
                    frame[1] *= right;
                }
            }
        }
    }
}

/// Adds one voice into a Track's buffer.
fn render_voice(voice: &mut Voice, out: &mut [f32], channels: usize, frames: usize, rate: u32) {
    if voice.paused || voice.ended {
        return;
    }
    let step = voice.step(rate);
    let source_channels = voice.source.channels() as usize;
    if source_channels == 0 || source_channels > MAX_CHANNELS {
        voice.ended = true;
        return;
    }
    if !voice.primed {
        if !voice.pull() {
            return;
        }
        voice.advance();
        voice.primed = true;
    }

    let mut frame = [0.0f32; MAX_CHANNELS];
    for position in 0..frames {
        while voice.fraction >= 1.0 {
            if !voice.advance() {
                return;
            }
            voice.fraction -= 1.0;
        }
        if voice.nearest {
            frame[..source_channels].copy_from_slice(&voice.previous[..source_channels]);
        } else {
            let blend = voice.fraction as f32;
            for (channel, value) in frame.iter_mut().enumerate().take(source_channels) {
                let previous = voice.previous[channel];
                *value = previous + (voice.upcoming[channel] - previous) * blend;
            }
        }

        if voice.envelope_step != 0.0 {
            voice.envelope += voice.envelope_step;
            if voice.envelope_step > 0.0 && voice.envelope >= 1.0 {
                voice.envelope = 1.0;
                voice.envelope_step = 0.0;
            } else if voice.envelope_step < 0.0 && voice.envelope <= 0.0 {
                voice.envelope = 0.0;
                voice.envelope_step = 0.0;
                if voice.stopping {
                    voice.ended = true;
                    return;
                }
            }
        }
        let level = voice.gain * voice.envelope;
        let (left, right) = speaker_gains(voice.placement);
        let base = position * channels;

        match voice.placement {
            Placement::Spatial { .. } => {
                let sum: f32 = frame.iter().take(source_channels).sum();
                let mono = sum / source_channels as f32 * level;
                out[base] += mono * left;
                if channels > 1 {
                    out[base + 1] += mono * right;
                }
            }
            _ => {
                for channel in 0..channels.min(2) {
                    let side = if channel == 0 { left } else { right };
                    let value = if source_channels == 1 {
                        frame[0]
                    } else {
                        frame[channel.min(source_channels - 1)]
                    };
                    out[base + channel] += value * level * side;
                }
            }
        }

        voice.fraction += step;
    }
}

/// Returns the left and right gains a placement contributes.
fn speaker_gains(placement: Placement) -> (f32, f32) {
    match placement {
        Placement::None => (1.0, 1.0),
        Placement::Stereo { left, right } => (left.max(0.0), right.max(0.0)),
        Placement::Spatial { x, y, z } => {
            let distance = (x * x + y * y + z * z).sqrt();
            let attenuation = 1.0 / (1.0 + distance);
            let pan = if distance > 0.0 { x / distance } else { 0.0 };
            let left = ((1.0 - pan) * 0.5).max(0.0).sqrt();
            let right = ((1.0 + pan) * 0.5).max(0.0).sqrt();
            (attenuation * left, attenuation * right)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::ResidentSource;
    use std::sync::Arc;

    const RATE: u32 = 48_000;

    fn constant(frames: usize, value: f32) -> Box<dyn Source> {
        let samples: Arc<[f32]> = vec![value; frames * 2].into();
        Box::new(ResidentSource::new(samples, 2, RATE))
    }

    fn ramp(frames: usize) -> Box<dyn Source> {
        let mut samples = Vec::with_capacity(frames * 2);
        for index in 0..frames {
            samples.push(index as f32);
            samples.push(index as f32);
        }
        Box::new(ResidentSource::new(samples.into(), 2, RATE))
    }

    fn play(handle: u32) -> Command {
        Command {
            kind: command::PLAY,
            handle,
            clip: 1,
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

    fn plain(kind: u32, handle: u32) -> Command {
        let mut command = play(handle);
        command.kind = kind;
        command.clip = 0;
        command
    }

    fn finished(mixer: &mut Mixer) -> Vec<u32> {
        let mut out = [Event { kind: 0, handle: 0 }; 16];
        let count = mixer.drain(&mut out);
        out[..count].iter().map(|event| event.handle).collect()
    }

    #[test]
    fn mixes_a_resident_voice_at_its_own_gain() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.gain = 0.5;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 16];
        mixer.render(&mut out);
        assert!((out[0] - 0.5).abs() < 1e-5, "got {}", out[0]);
        assert!((out[1] - 0.5).abs() < 1e-5);
        assert_eq!(mixer.voice_count(), 1);
    }

    #[test]
    fn reports_a_voice_finished_when_its_input_runs_out() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(4, 1.0)));
        let mut out = vec![0.0f32; 64];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn keeps_a_repeating_voice_going_and_lets_it_finish_when_looping_stops() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        mixer.apply(&command, Some(constant(4, 1.0)));

        let mut out = vec![0.0f32; 200];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 1, "a looping voice does not run out");
        assert!(out[100] != 0.0, "it is still producing sound");

        // Clearing the flag lets the voice play out rather than cutting it.
        let mut off = plain(command::SET_LOOP, 7);
        off.flags = 0;
        mixer.apply(&off, None);
        assert_eq!(mixer.voice_count(), 1);
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn returns_a_repeat_to_its_loop_point() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        // Two frames in, out of four.
        command.loop_start = 2.0 / RATE as f32;
        mixer.apply(&command, Some(ramp(4)));

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        // The intro frames are heard once and the tail repeats, so the ramp
        // never falls back below the loop point after the first pass.
        let heard: Vec<f32> = out.iter().step_by(2).copied().collect();
        assert!(heard[0] < 1.0);
        assert!(
            heard[5..].iter().all(|value| *value >= 1.5),
            "after the first pass the voice stays past the loop point: {heard:?}"
        );
    }

    #[test]
    fn runs_a_fade_out_to_silence_before_ending_the_voice() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        mixer.apply(&command, Some(constant(1024, 1.0)));

        let mut stop = plain(command::STOP, 7);
        // Sixteen output frames of ramp.
        stop.fade = 16.0 / RATE as f32;
        mixer.apply(&stop, None);

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 1, "the fade is still running");
        assert!(out[0] > out[14], "the voice is on the way down");
        assert!(finished(&mut mixer).is_empty());

        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn runs_a_fade_in_from_silence() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.fade = 32.0 / RATE as f32;
        mixer.apply(&command, Some(constant(1024, 1.0)));

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        assert!(out[0] < 0.2, "it starts near silence: {}", out[0]);
        assert!(out[14] > out[0], "and rises");
    }

    #[test]
    fn ends_a_voice_at_once_when_a_stop_carries_no_fade() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(1024, 1.0)));
        mixer.apply(&plain(command::STOP, 7), None);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn holds_a_paused_voice_without_ending_it() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(8, 1.0)));
        mixer.apply(&plain(command::PAUSE, 7), None);

        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
        assert_eq!(mixer.voice_count(), 1);

        mixer.apply(&plain(command::RESUME, 7), None);
        mixer.render(&mut out);
        assert!(out[0] != 0.0);
    }

    #[test]
    fn resamples_a_pitched_voice_over_a_longer_stretch() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut half = play(7);
        half.pitch = 0.5;
        mixer.apply(&half, Some(constant(32, 1.0)));
        let mut out = vec![0.0f32; 2 * 40];
        mixer.render(&mut out);
        // Half rate reaches only half way through the input, so the voice
        // survives a buffer that would have exhausted it at rate one.
        assert_eq!(mixer.voice_count(), 1);

        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut double = play(9);
        double.pitch = 2.0;
        mixer.apply(&double, Some(constant(32, 1.0)));
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
    }

    #[test]
    fn scales_the_speakers_separately_for_an_explicit_pair() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_STEREO;
        command.x = 0.8;
        command.y = 0.2;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.8).abs() < 1e-5, "got {}", out[0]);
        assert!((out[1] - 0.2).abs() < 1e-5, "got {}", out[1]);
    }

    #[test]
    fn places_a_positioned_voice_and_attenuates_it_with_distance() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_SPATIAL;
        command.x = 1.0;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!(
            out[1] > out[0],
            "a sound on the right is louder on the right"
        );
        assert!(out[1] < 1.0, "and quieter than one at the listener");

        // The placement is exclusive: setting a pan replaces the position.
        let mut pan = plain(command::SET_STEREO, 7);
        pan.x = 1.0;
        pan.y = 1.0;
        mixer.apply(&pan, None);
        mixer.render(&mut out);
        assert!((out[0] - 1.0).abs() < 1e-5);
        assert!((out[1] - 1.0).abs() < 1e-5);

        mixer.apply(&plain(command::CLEAR_PLACEMENT, 7), None);
        mixer.render(&mut out);
        assert!((out[0] - 1.0).abs() < 1e-5);
    }

    #[test]
    fn scales_the_whole_mix_with_master_gain() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(64, 1.0)));
        let mut master = plain(command::SET_MASTER_GAIN, 0);
        master.gain = 0.25;
        mixer.apply(&master, None);
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.25).abs() < 1e-5, "got {}", out[0]);
    }

    #[test]
    fn sums_every_voice_into_one_buffer() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(64, 0.25)));
        mixer.apply(&play(8), Some(constant(64, 0.25)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.5).abs() < 1e-5, "got {}", out[0]);
    }

    #[test]
    fn refuses_a_voice_past_the_pool_ceiling() {
        let mut mixer = Mixer::new(RATE, 2, 2);
        mixer.apply(&play(7), Some(constant(64, 1.0)));
        mixer.apply(&play(8), Some(constant(64, 1.0)));
        mixer.apply(&play(9), Some(constant(64, 1.0)));
        assert_eq!(mixer.voice_count(), 2);
    }

    #[test]
    fn ignores_a_command_naming_no_voice() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&plain(command::STOP, 404), None);
        mixer.apply(&plain(command::PAUSE, 404), None);
        mixer.apply(&plain(command::SET_GAIN, 404), None);
        assert_eq!(mixer.voice_count(), 0);
        assert!(finished(&mut mixer).is_empty());
    }

    #[test]
    fn reads_and_moves_a_voice_position() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(RATE as usize, 1.0)));
        assert_eq!(mixer.position(7), Some(0.0));
        assert!(mixer.seek(7, 0.5));
        let position = mixer.position(7).expect("the voice is sounding");
        assert!((position - 0.5).abs() < 1e-3, "got {position}");
        assert_eq!(mixer.position(404), None);
        assert!(!mixer.seek(404, 0.5));
    }

    #[test]
    fn starts_a_voice_at_an_offset() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.start = 0.5;
        mixer.apply(&command, Some(constant(RATE as usize, 1.0)));
        let position = mixer.position(7).expect("the voice is sounding");
        assert!((position - 0.5).abs() < 1e-3, "got {position}");
    }

    #[test]
    fn drains_no_more_observations_than_the_caller_has_room_for() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(8, 1.0)));
        mixer.apply(&play(8), Some(constant(8, 1.0)));
        mixer.apply(&plain(command::STOP, 7), None);
        mixer.apply(&plain(command::STOP, 8), None);

        let mut out = [Event { kind: 0, handle: 0 }; 1];
        assert_eq!(mixer.drain(&mut out), 1);
        assert_eq!(out[0].handle, 7);
        assert_eq!(mixer.drain(&mut out), 1);
        assert_eq!(out[0].handle, 8);
        assert_eq!(mixer.drain(&mut out), 0);
    }

    /// Fills a source with a fixed pseudo-random signal, so a digest of the mix
    /// covers every interpolated value rather than a ramp's.
    fn noise(frames: usize, channels: u16, rate: u32, seed: u32) -> Box<dyn Source> {
        let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
        let mut samples = Vec::with_capacity(frames * channels as usize);
        for _ in 0..frames * channels as usize {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            samples.push((state >> 8) as f32 / (1u32 << 23) as f32 - 1.0);
        }
        Box::new(ResidentSource::new(samples.into(), channels, rate))
    }

    /// Renders a fixed mix of looping, panned, positioned, faded and repitched
    /// voices over uneven buffers, and folds every output sample's bits into
    /// one FNV-1a digest.
    ///
    /// With no `stamp`, each block's command is applied between renders, which
    /// is the only way the tree before scheduling could send it. With one,
    /// every command is submitted before the first render, stamped with its
    /// block's first frame plus `stamp`.
    fn mix_digest(stamp: Option<u64>) -> u64 {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut first = play(1);
        first.pitch = 0.731;
        first.gain = 0.8;
        first.flags = command::FLAG_LOOP;
        first.loop_start = 0.01;
        first.fade = 0.005;
        mixer.apply(&first, Some(noise(2000, 2, 44_100, 1)));
        let mut second = play(2);
        second.pitch = 1.37;
        second.flags = command::FLAG_STEREO;
        second.x = 0.3;
        second.y = 0.9;
        second.start = 0.002;
        mixer.apply(&second, Some(noise(5000, 1, 22_050, 2)));
        let mut third = play(3);
        third.flags = command::FLAG_SPATIAL;
        third.x = 1.5;
        third.y = -0.5;
        third.z = 2.0;
        mixer.apply(&third, Some(noise(3000, 2, 48_000, 3)));

        let blocks = [37usize, 512, 1000, 1, 255, 4096, 333, 2048];
        let mut commands: Vec<(usize, Command)> = Vec::new();
        for block in 0..blocks.len() {
            match block {
                2 => {
                    let mut command = plain(command::SET_PITCH, 1);
                    command.pitch = 1.9;
                    commands.push((block, command));
                }
                3 => {
                    let mut command = plain(command::SET_GAIN, 2);
                    command.gain = 0.4;
                    commands.push((block, command));
                }
                4 => {
                    let mut command = plain(command::STOP, 3);
                    command.fade = 0.01;
                    commands.push((block, command));
                }
                5 => {
                    let mut command = plain(command::SET_MASTER_GAIN, 0);
                    command.gain = 0.7;
                    commands.push((block, command));
                }
                6 => commands.push((block, plain(command::SET_LOOP, 1))),
                _ => {}
            }
        }
        if let Some(offset) = stamp {
            for (block, command) in commands.iter_mut() {
                let first: usize = blocks[..*block].iter().sum();
                command.at = (first as u64 + offset) as f64 / RATE as f64;
                mixer.submit(command, None);
            }
        }

        let mut digest: u64 = 0xcbf2_9ce4_8422_2325;
        for (block, frames) in blocks.iter().enumerate() {
            if stamp.is_none() {
                for (_, command) in commands.iter().filter(|(due, _)| *due == block) {
                    mixer.apply(command, None);
                }
            }
            let mut out = vec![0.0f32; frames * 2];
            mixer.render(&mut out);
            for value in out {
                for byte in value.to_bits().to_le_bytes() {
                    digest ^= byte as u64;
                    digest = digest.wrapping_mul(0x0100_0000_01b3);
                }
            }
        }
        digest
    }

    /// The digest the same mix produced before commands carried a time and
    /// voices a resampling mode, recorded from that tree with each command
    /// applied between renders.
    const LINEAR_MIX_BEFORE_SCHEDULING: u64 = 0xfafe_174b_b64f_1127;

    #[test]
    fn mixes_linear_voices_byte_for_byte_as_before_the_schedule() {
        assert_eq!(mix_digest(None), LINEAR_MIX_BEFORE_SCHEDULING);
        // Stamped on the frame a render would have started on, a command
        // lands where applying it between renders did.
        assert_eq!(mix_digest(Some(0)), LINEAR_MIX_BEFORE_SCHEDULING);
        // The control: one frame later is a different mix.
        assert_ne!(mix_digest(Some(1)), LINEAR_MIX_BEFORE_SCHEDULING);
    }

    /// Reads one channel of an interleaved stereo buffer.
    fn left(out: &[f32]) -> Vec<f32> {
        out.iter().step_by(2).copied().collect()
    }

    /// Returns the first frame two renders differ at.
    fn first_difference(one: &[f32], other: &[f32]) -> Option<usize> {
        one.iter().zip(other).position(|(a, b)| a != b)
    }

    /// Converts an output frame to the `at` naming it.
    fn at_frame(frame: u64) -> f64 {
        frame as f64 / RATE as f64
    }

    /// Plays a ramp at pitch one, renders `lead` frames, submits `command`,
    /// and returns the left channel of the next `frames`.
    fn ramp_after(lead: usize, frames: usize, command: Option<Command>) -> Vec<f32> {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(ramp(RATE as usize)));
        let mut out = vec![0.0f32; lead * 2];
        mixer.render(&mut out);
        if let Some(entry) = command {
            mixer.submit(&entry, None);
        }
        let mut out = vec![0.0f32; frames * 2];
        mixer.render(&mut out);
        left(&out)
    }

    #[test]
    fn lands_a_scheduled_pitch_on_its_frame_inside_the_next_render() {
        let lead = 256;
        let reference = ramp_after(lead, 512, None);
        for offset in [1usize, 2, 100, 255, 510] {
            let mut pitch = plain(command::SET_PITCH, 7);
            pitch.pitch = 2.0;
            pitch.at = at_frame((lead + offset) as u64);
            let changed = ramp_after(lead, 512, Some(pitch));
            // Output frame `offset` is the first one read at the new rate: it
            // still sits where the old rate brought it, and every frame after
            // it is two source frames further on rather than one.
            assert_eq!(changed[offset], reference[offset], "stamp {offset}");
            assert_eq!(
                first_difference(&changed, &reference),
                Some(offset + 1),
                "stamp {offset}"
            );
            for (frame, value) in changed.iter().enumerate().skip(offset) {
                let want = (lead + offset + 2 * (frame - offset)) as f32;
                assert_eq!(*value, want, "stamp {offset}, frame {frame}");
            }

            // The control: stamped one frame later, the change is seen one
            // frame later, so a stamp off by one is caught.
            let mut late = pitch;
            late.at = at_frame((lead + offset + 1) as u64);
            let later = ramp_after(lead, 512, Some(late));
            if offset + 2 < 512 {
                assert_eq!(first_difference(&later, &reference), Some(offset + 2));
                assert_ne!(later, changed, "stamp {offset}");
            }
        }
    }

    #[test]
    fn lands_a_scheduled_gain_start_and_stop_on_their_frames() {
        let mut gain = plain(command::SET_GAIN, 7);
        gain.gain = 0.5;
        gain.at = at_frame(300);
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(constant(RATE as usize, 1.0)));
        mixer.submit(&gain, None);
        let mut start = play(8);
        start.at = at_frame(400);
        mixer.submit(&start, Some(constant(RATE as usize, 0.25)));
        let mut stop = plain(command::STOP, 7);
        stop.at = at_frame(450);
        mixer.submit(&stop, None);
        assert_eq!(mixer.scheduled(), 3);
        assert_eq!(mixer.voice_count(), 1);

        let mut out = vec![0.0f32; 2 * 512];
        mixer.render(&mut out);
        let heard = left(&out);
        assert!(heard[..300].iter().all(|value| *value == 1.0));
        assert!(heard[300..400].iter().all(|value| *value == 0.5));
        assert!(heard[400..450].iter().all(|value| *value == 0.75));
        assert!(heard[450..].iter().all(|value| *value == 0.25));
        assert_eq!(mixer.frames(), 512);
        assert_eq!(mixer.scheduled(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn applies_commands_due_on_one_frame_in_the_order_they_were_sent() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(constant(RATE as usize, 1.0)));
        // Sent latest-first: the schedule orders by time, then by sending.
        for (gain, frame) in [(0.125, 200), (0.25, 100), (0.5, 100)] {
            let mut command = plain(command::SET_GAIN, 7);
            command.gain = gain;
            command.at = at_frame(frame);
            mixer.submit(&command, None);
        }
        let mut out = vec![0.0f32; 2 * 100];
        mixer.render(&mut out);
        // The clock now stands on frame 100 with both of its commands waiting,
        // and a command sent now with no time comes after them.
        let mut now = plain(command::SET_GAIN, 7);
        now.gain = 0.75;
        mixer.submit(&now, None);
        let mut out = vec![0.0f32; 2 * 200];
        mixer.render(&mut out);
        let heard = left(&out);
        assert!(heard[..100].iter().all(|value| *value == 0.75));
        assert!(heard[100..].iter().all(|value| *value == 0.125));
    }

    #[test]
    fn applies_a_command_whose_time_has_passed_at_the_next_frame() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(constant(RATE as usize, 1.0)));
        let mut out = vec![0.0f32; 2 * 1000];
        mixer.render(&mut out);
        let mut late = plain(command::SET_GAIN, 7);
        late.gain = 0.5;
        late.at = at_frame(100);
        mixer.submit(&late, None);
        assert_eq!(mixer.scheduled(), 0);
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert_eq!(left(&out), vec![0.5; 4]);
    }

    #[test]
    fn drops_every_scheduled_command_on_stop_all() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut start = play(7);
        start.at = at_frame(10);
        mixer.submit(&start, Some(constant(64, 1.0)));
        assert_eq!(mixer.scheduled(), 1);
        mixer.stop_all();
        assert_eq!(mixer.scheduled(), 0);
        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
    }

    /// Builds a source of distinct values, so a held frame and its neighbour
    /// can never be mistaken for each other.
    fn distinct(frames: usize, channels: u16, rate: u32) -> (Vec<f32>, Box<dyn Source>) {
        let mut samples = Vec::with_capacity(frames * channels as usize);
        for index in 0..frames * channels as usize {
            samples.push(((index * 7919) % 10_007) as f32 / 10_007.0 - 0.5);
        }
        let source: Box<dyn Source> =
            Box::new(ResidentSource::new(samples.clone().into(), channels, rate));
        (samples, source)
    }

    /// Returns the source frame a nearest-sample player reads at output frame
    /// `frame`: the integer part of the position, wrapped into the loop once
    /// it passes the end, or `None` once a one-shot has run out.
    fn nearest_frame(
        frame: usize,
        step: f64,
        frames: usize,
        loop_from: Option<usize>,
    ) -> Option<usize> {
        let index = (frame as f64 * step).floor() as usize;
        if index < frames {
            return Some(index);
        }
        let start = loop_from?;
        Some(start + (index - frames) % (frames - start))
    }

    #[test]
    fn holds_the_source_frame_a_nearest_reference_reads() {
        // Steps a binary fraction can hold exactly, so the reference's
        // positions and the voice's accumulated ones are the same numbers.
        let source_frames = 600;
        for (rate, step) in [
            (48_000u32, 1.0f64),
            (36_000, 0.75),
            (15_000, 0.3125),
            (72_000, 1.5),
            (96_000, 2.0),
        ] {
            for channels in [1u16, 2] {
                for loop_from in [None, Some(0), Some(437)] {
                    let (samples, source) = distinct(source_frames, channels, rate);
                    let mut start = play(7);
                    start.flags = command::FLAG_NEAREST;
                    if let Some(first) = loop_from {
                        start.flags |= command::FLAG_LOOP;
                        start.loop_start = (first as f64 / rate as f64) as f32;
                    }
                    let mut mixer = Mixer::new(RATE, 2, 8);
                    mixer.submit(&start, Some(source));
                    let frames = 4 * source_frames;
                    let mut out = vec![0.0f32; 2 * frames];
                    // Uneven buffers, so the hold survives every boundary.
                    let mut done = 0;
                    for block in [1usize, 37, 512, 1000].iter().cycle() {
                        let count = (*block).min(frames - done);
                        mixer.render(&mut out[done * 2..(done + count) * 2]);
                        done += count;
                        if done == frames {
                            break;
                        }
                    }
                    for frame in 0..frames {
                        let want = nearest_frame(frame, step, source_frames, loop_from);
                        for side in 0..2 {
                            let expected = match want {
                                None => 0.0,
                                Some(index) => {
                                    samples[index * channels as usize
                                        + side.min(channels as usize - 1)]
                                }
                            };
                            assert_eq!(
                                out[frame * 2 + side],
                                expected,
                                "{rate} Hz, {channels} channels, loop {loop_from:?}, frame {frame}"
                            );
                        }
                    }
                    assert_eq!(mixer.voice_count(), usize::from(loop_from.is_some()));
                }
            }
        }
    }

    #[test]
    fn interpolates_where_a_nearest_voice_holds() {
        let (_, linear_source) = distinct(600, 1, 36_000);
        let (_, nearest_source) = distinct(600, 1, 36_000);
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(linear_source));
        let mut linear = vec![0.0f32; 2 * 256];
        mixer.render(&mut linear);
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut start = play(7);
        start.flags = command::FLAG_NEAREST;
        mixer.submit(&start, Some(nearest_source));
        let mut nearest = vec![0.0f32; 2 * 256];
        mixer.render(&mut nearest);
        // The two agree where the position is whole and nowhere else.
        for frame in 0..256 {
            let whole = frame % 4 == 0;
            assert_eq!(
                linear[frame * 2] == nearest[frame * 2],
                whole,
                "frame {frame}"
            );
        }
    }

    #[test]
    fn switches_a_sounding_voice_to_nearest_on_a_scheduled_frame() {
        let (samples, source) = distinct(600, 1, 36_000);
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(source));
        let mut switch = plain(command::SET_RESAMPLE, 7);
        switch.flags = command::FLAG_NEAREST;
        switch.at = at_frame(101);
        mixer.submit(&switch, None);
        let mut out = vec![0.0f32; 2 * 256];
        mixer.render(&mut out);
        let heard = left(&out);
        // Frame 101 sits a quarter of the way between two source frames.
        let blended = samples[75] + (samples[76] - samples[75]) * 0.75;
        assert_ne!(heard[101], blended);
        assert_eq!(heard[100], samples[75]);
        for (frame, value) in heard.iter().enumerate().skip(101) {
            assert_eq!(*value, samples[frame * 3 / 4], "frame {frame}");
        }
        for frame in [1usize, 2, 3, 99] {
            assert_ne!(heard[frame], samples[frame * 3 / 4], "frame {frame} held");
        }

        // And back: clearing the flag interpolates again.
        let mut back = plain(command::SET_RESAMPLE, 7);
        back.at = at_frame(300);
        mixer.submit(&back, None);
        let mut out = vec![0.0f32; 2 * 256];
        mixer.render(&mut out);
        let heard = left(&out);
        assert_eq!(heard[300 - 256 - 1], samples[(299 * 3) / 4]);
        let frame = 301;
        let position = frame as f64 * 0.75;
        let below = position.floor() as usize;
        let blend = (position - below as f64) as f32;
        let want = samples[below] + (samples[below + 1] - samples[below]) * blend;
        assert!((heard[frame - 256] - want).abs() < 1e-6, "frame {frame}");
    }

    /// A constant source that records, when it is dropped, that it was.
    struct Tracked {
        inner: Box<dyn Source>,
        dropped: Arc<std::sync::atomic::AtomicBool>,
    }

    impl Source for Tracked {
        fn channels(&self) -> u16 {
            self.inner.channels()
        }
        fn sample_rate(&self) -> u32 {
            self.inner.sample_rate()
        }
        fn read(&mut self, out: &mut [f32]) -> usize {
            self.inner.read(out)
        }
        fn seek(&mut self, seconds: f64) -> bool {
            self.inner.seek(seconds)
        }
        fn position(&self) -> f64 {
            self.inner.position()
        }
        fn exhausted(&self) -> bool {
            self.inner.exhausted()
        }
    }

    impl Drop for Tracked {
        fn drop(&mut self) {
            self.dropped
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    fn tracked(frames: usize) -> (Box<dyn Source>, Arc<std::sync::atomic::AtomicBool>) {
        let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let source = Tracked {
            inner: constant(frames, 1.0),
            dropped: Arc::clone(&dropped),
        };
        (Box::new(source), dropped)
    }

    fn timed(mut command: Command, frame: u64) -> Command {
        command.at = at_frame(frame);
        command
    }

    #[test]
    fn an_untimed_stop_cancels_a_start_still_waiting_for_its_frame() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut start = timed(play(7), 32);
        start.flags = command::FLAG_LOOP;
        mixer.submit(&start, Some(constant(64, 1.0)));
        mixer.submit(&plain(command::STOP, 7), None);
        assert_eq!(mixer.scheduled(), 0);
        assert_eq!(
            finished(&mut mixer),
            vec![7],
            "the cancelled start reports its end"
        );
        let mut out = vec![0.0f32; 2 * 128];
        mixer.render(&mut out);
        assert!(
            out.iter().all(|value| *value == 0.0),
            "the looping voice never starts"
        );
        assert_eq!(mixer.voice_count(), 0);
    }

    #[test]
    fn a_timed_stop_before_a_later_start_cancels_it() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&timed(play(7), 64), Some(constant(256, 1.0)));
        mixer.submit(&timed(plain(command::STOP, 7), 16), None);
        let mut out = vec![0.0f32; 2 * 128];
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn a_setter_before_the_start_lands_on_the_start_frame() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&timed(play(7), 32), Some(constant(256, 1.0)));
        let mut gain = plain(command::SET_GAIN, 7);
        gain.gain = 0.25;
        mixer.submit(&gain, None);
        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        let heard = left(&out);
        assert!(heard[..32].iter().all(|value| *value == 0.0));
        assert!(
            heard[32..].iter().all(|value| (*value - 0.25).abs() < 1e-6),
            "the voice starts at the gain sent before it existed: {:?}",
            &heard[30..36]
        );
    }

    #[test]
    fn a_pause_before_the_start_holds_the_voice_from_its_first_frame() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&timed(play(7), 32), Some(constant(256, 1.0)));
        mixer.submit(&plain(command::PAUSE, 7), None);
        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
        assert_eq!(mixer.voice_count(), 1, "the voice started, held");
        mixer.submit(&plain(command::RESUME, 7), None);
        mixer.render(&mut out);
        assert!(left(&out).iter().all(|value| *value == 1.0));
    }

    #[test]
    fn a_start_dropped_for_a_full_pool_reports_its_end() {
        let mut mixer = Mixer::new(RATE, 2, 1);
        mixer.submit(&play(1), Some(constant(256, 1.0)));
        mixer.submit(&play(2), Some(constant(256, 1.0)));
        assert_eq!(finished(&mut mixer), vec![2], "an immediate start");
        mixer.submit(&timed(play(3), 16), Some(constant(256, 1.0)));
        let mut out = vec![0.0f32; 2 * 32];
        mixer.render(&mut out);
        assert_eq!(finished(&mut mixer), vec![3], "a scheduled start, at admit");
        assert_eq!(mixer.voice_count(), 1);
    }

    #[test]
    fn a_start_with_no_source_reports_its_end() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(4), None);
        mixer.submit(&timed(play(5), 16), None);
        assert_eq!(finished(&mut mixer), vec![4, 5]);
    }

    #[test]
    fn stop_all_reports_the_starts_still_waiting() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(1), Some(constant(256, 1.0)));
        mixer.submit(&timed(play(2), 64), Some(constant(256, 1.0)));
        mixer.stop_all();
        let mut ends = finished(&mut mixer);
        ends.sort();
        assert_eq!(ends, vec![1, 2]);
    }

    #[test]
    fn the_render_path_frees_no_voice_and_collect_hands_them_over() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let (ending, ending_dropped) = tracked(8);
        let (stopped, stopped_dropped) = tracked(256);
        let (full, full_dropped) = tracked(256);
        mixer.submit(&play(1), Some(ending));
        mixer.submit(&play(2), Some(stopped));
        mixer.submit(&timed(plain(command::STOP, 2), 16), None);
        let mut small = Mixer::new(RATE, 2, 1);
        small.submit(&play(9), Some(constant(256, 1.0)));
        small.submit(&timed(play(10), 8), Some(full));

        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        small.render(&mut out);
        assert_eq!(
            mixer.voice_count(),
            0,
            "one ran out, one was stopped on its frame"
        );
        let ordering = std::sync::atomic::Ordering::SeqCst;
        assert!(
            !ending_dropped.load(ordering),
            "an ending voice is not freed in render"
        );
        assert!(
            !stopped_dropped.load(ordering),
            "a timed stop does not free in render"
        );
        assert!(
            !full_dropped.load(ordering),
            "a start refused at admit is not freed in render"
        );

        let retired = mixer.collect();
        assert_eq!(retired.len(), 2);
        drop(retired);
        drop(small.collect());
        assert!(ending_dropped.load(ordering) && stopped_dropped.load(ordering));
        assert!(full_dropped.load(ordering));
    }

    #[test]
    fn a_time_that_is_not_finite_applies_at_once() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut start = play(7);
        start.at = f64::INFINITY;
        mixer.submit(&start, Some(constant(64, 1.0)));
        assert_eq!(mixer.scheduled(), 0);
        assert_eq!(mixer.voice_count(), 1);
    }

    fn strip(kind: u32, target: u32, param: u32) -> Command {
        let mut command = plain(kind, 0);
        command.target = target;
        command.param = param;
        command
    }

    #[test]
    fn a_track_on_a_bus_takes_both_faders_and_a_paused_bus_holds_it() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&strip(command::BUS_CREATE, 1, 0), None);
        let mut track = strip(command::TRACK_CREATE, 3, 0);
        track.param = 1;
        mixer.submit(&track, None);
        let mut gain = strip(command::TRACK_SET, 3, command::TRACK_GAIN);
        gain.gain = 0.5;
        mixer.submit(&gain, None);
        let mut bus_gain = strip(command::BUS_SET, 1, command::BUS_GAIN);
        bus_gain.gain = 0.5;
        mixer.submit(&bus_gain, None);
        let mut start = play(7);
        start.target = 3;
        mixer.submit(&start, Some(constant(48_000, 1.0)));
        let mut out = vec![0.0f32; 2 * 4800];
        mixer.render(&mut out);
        // Both faders glide to their targets within the first block or so.
        assert!((out[2 * 4799] - 0.25).abs() < 1e-3, "got {}", out[2 * 4799]);

        let mut pause = strip(command::BUS_SET, 1, command::BUS_PAUSE);
        pause.gain = 1.0;
        mixer.submit(&pause, None);
        let before = mixer.position(7).unwrap();
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
        assert_eq!(
            mixer.position(7).unwrap(),
            before,
            "a held voice does not advance"
        );
    }

    #[test]
    fn a_send_reaches_a_return_bus_post_fader() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&strip(command::BUS_CREATE, 2, 0), None);
        let mut mute_track = strip(command::TRACK_SET, 0, command::TRACK_MUTE);
        mute_track.gain = 0.0;
        mixer.submit(&mute_track, None);
        let mut send = strip(command::SEND, 0, 2);
        send.gain = 0.5;
        mixer.submit(&send, None);
        mixer.submit(&play(7), Some(constant(48_000, 1.0)));
        let mut out = vec![0.0f32; 2 * 4800];
        mixer.render(&mut out);
        // Dry 1.0 into Master, and 0.5 through the return bus.
        assert!((out[2 * 4799] - 1.5).abs() < 1e-3, "got {}", out[2 * 4799]);
    }

    #[test]
    fn solo_silences_every_other_track() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&strip(command::TRACK_CREATE, 1, 0), None);
        let mut solo = strip(command::TRACK_SET, 1, command::TRACK_SOLO);
        solo.gain = 1.0;
        mixer.submit(&solo, None);
        mixer.submit(&play(7), Some(constant(48_000, 1.0)));
        let mut soloed = play(8);
        soloed.target = 1;
        soloed.gain = 0.25;
        mixer.submit(&soloed, Some(constant(48_000, 1.0)));
        let mut out = vec![0.0f32; 2 * 4800];
        mixer.render(&mut out);
        assert!((out[2 * 4799] - 0.25).abs() < 1e-3, "got {}", out[2 * 4799]);
    }

    #[test]
    fn an_insert_processes_its_strip_and_its_parameter_lands_on_its_frame() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut insert = strip(command::EFFECT_INSERT, 0, 0);
        insert.data = 9;
        let effect = crate::effects::builtin(crate::effects::EQ, RATE, 2).unwrap();
        mixer.submit_effect(&insert, effect);
        mixer.submit(&play(7), Some(constant(48_000, 1.0)));
        let mut out = vec![0.0f32; 2 * 2400];
        mixer.render(&mut out);
        assert!(
            (out[2 * 2399] - 1.0).abs() < 1e-4,
            "a flat EQ passes the signal"
        );
        let mut cut = strip(command::EFFECT_PARAM, 0, crate::effects::EQ_LOW_GAIN);
        cut.data = 9;
        cut.gain = -24.0;
        mixer.submit(&cut, None);
        let mut longer = vec![0.0f32; 2 * 24_000];
        mixer.render(&mut longer);
        assert!(
            longer[2 * 23_999].abs() < 0.2,
            "a DC level through a -24 dB low shelf: {}",
            longer[2 * 23_999]
        );
        let mut remove = strip(command::EFFECT_REMOVE, 0, 0);
        remove.data = 9;
        mixer.submit(&remove, None);
        let retired = mixer.collect();
        assert!(
            !retired.is_empty(),
            "the removed effect is handed over to free"
        );
    }

    #[test]
    fn an_event_reaches_its_voice_on_its_frame() {
        struct Level {
            value: f32,
        }
        impl Source for Level {
            fn channels(&self) -> u16 {
                1
            }
            fn sample_rate(&self) -> u32 {
                RATE
            }
            fn read(&mut self, out: &mut [f32]) -> usize {
                out.fill(self.value);
                out.len()
            }
            fn seek(&mut self, _seconds: f64) -> bool {
                false
            }
            fn position(&self) -> f64 {
                0.0
            }
            fn exhausted(&self) -> bool {
                false
            }
            fn event(&mut self, data: u64) {
                self.value = data as f32 / 100.0;
            }
            fn sequenced(&self) -> bool {
                true
            }
        }
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&play(7), Some(Box::new(Level { value: 0.1 })));
        let mut event = timed(plain(command::EVENT, 7), 100);
        event.data = 50;
        mixer.submit(&event, None);
        let mut out = vec![0.0f32; 2 * 200];
        mixer.render(&mut out);
        let heard = left(&out);
        // Read a frame at a time, the change lands within two frames.
        assert!((heard[99] - 0.1).abs() < 1e-6, "before: {}", heard[99]);
        assert!(
            (heard[102] - 0.5).abs() < 1e-6,
            "after: {:?}",
            &heard[98..104]
        );
    }

    #[test]
    fn destroying_a_bus_reroutes_what_fed_it_and_a_track_moves_voices_home() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.submit(&strip(command::BUS_CREATE, 1, 0), None);
        let mut track = strip(command::TRACK_CREATE, 2, 0);
        track.param = 1;
        mixer.submit(&track, None);
        let mut start = play(7);
        start.target = 2;
        mixer.submit(&start, Some(constant(48_000, 1.0)));
        mixer.submit(&strip(command::BUS_DESTROY, 1, 0), None);
        mixer.submit(&strip(command::TRACK_DESTROY, 2, 0), None);
        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        assert!(
            (out[0] - 1.0).abs() < 1e-6,
            "the voice plays on the default track"
        );
        assert!(!mixer.collect().is_empty());
    }
}
