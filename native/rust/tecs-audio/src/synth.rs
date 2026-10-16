//! A General MIDI synthesizer that plays as one voice of the mixer.
//!
//! The synthesizer is `rustysynth`, rendering a SoundFont in-process. Tecs
//! starts it the way it starts any voice, so group gain, mute and pause, the
//! master gain and the voice ceiling reach it with no code of their own. What
//! is particular to it is how MIDI events cross from the game thread to the
//! output callback that renders them.
//!
//! The crossing is a bounded single-producer, single-consumer ring. The game
//! side pushes fixed-size events and never waits; the callback side pops them
//! while it holds the mixer lock it already holds to render, and never waits
//! either. Nothing on the render path allocates: the ring, the schedule the
//! callback sorts events into and the scratch buffers are all sized when the
//! synthesizer is made.
//!
//! Each event carries the frame of the synthesizer's own clock it is due at.
//! `rustysynth` applies a message at its next internal block boundary, never
//! part way through a block, so the render splits at those boundaries and
//! applies every due event at the first boundary at or after its frame. An
//! event is therefore never early and is at most `BLOCK_FRAMES - 1` frames
//! late, and where it lands depends only on its frame, which is what makes the
//! output a deterministic function of the schedule.
//!
//! The ring, the schedule and the source are not particular to General MIDI.
//! Anything that implements [`Target`] plays through them, and each target
//! names its own grid: eight frames for `rustysynth`, and one for the OPL
//! emulator in [`crate::fm`], whose register writes take effect on the very
//! sample they are due at.
//!
//! ```no_run
//! use tecsaudio::synth::{self, Settings};
//!
//! let font = synth::load_sound_font("FluidR3_GM.sf2").expect("a SoundFont");
//! let (mut port, mut source) = synth::open(&font, 48_000, &Settings::default()).expect("a synth");
//! port.send(0x90, 60, 100, 0.0);
//! let mut out = vec![0.0f32; 2 * 512];
//! use tecsaudio::source::Source;
//! source.read(&mut out);
//! ```

use std::cell::UnsafeCell;
use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use rustysynth::{SoundFont, Synthesizer, SynthesizerSettings};

use crate::source::Source;

/// Frames in one internal render block, and so the grid events land on.
///
/// `rustysynth` takes a block size from 8 to 1024 and applies MIDI only between
/// blocks. It also runs its envelopes and LFOs once per block, so a smaller
/// block is a finer grid at a higher cost per voice. Eight is the finest it
/// allows, and puts every event within 0.17 milliseconds of its time at 48 kHz.
/// Measured on FluidR3 GM with 48 notes held, polyphony 64 and the effects on,
/// eight costs 3.3 percent of one core against 1.9 percent at its default of
/// 64, which is a small price for a grid nobody can hear.
pub const BLOCK_FRAMES: usize = 8;

/// Events the ring between the game thread and the callback holds.
///
/// The callback moves events out of the ring into its schedule at every block,
/// so the ring only has to cover what a game sends between two blocks. The
/// schedule holds as many again, for events sent ahead of their time. Past
/// both, `send` refuses the event rather than growing anything the callback
/// touches.
pub const QUEUE_EVENTS: usize = 4096;

/// Applies a short MIDI message: `status`, `data1` and `data2`.
pub const KIND_MESSAGE: u8 = 0;

/// Releases every note, on `status` as a channel or on all sixteen when it is
/// `ALL_CHANNELS`. A nonzero `data1` cuts the notes without their release.
pub const KIND_NOTES_OFF: u8 = 1;

/// Returns every channel to its General MIDI defaults and silences every note.
pub const KIND_RESET: u8 = 2;

/// Replaces one memory image of an FM chip with the next one on its memory
/// channel: [`crate::fm`] only. Unlike every other event, a reset does not
/// discard it.
pub const KIND_MEMORY: u8 = 3;

/// Writes `data2` to the port whose offset is `status` and `data1`, low byte
/// first: [`crate::fm`] only.
pub const KIND_PORT: u8 = 4;

/// Names every channel in a `KIND_NOTES_OFF` event.
pub const ALL_CHANNELS: u8 = 0xFF;

/// One event on its way to the synthesizer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    /// The frame of the synthesizer clock the event is due at. Zero, and any
    /// frame already rendered, means the next block boundary.
    pub frame: u64,
    /// Selects the operation from this module's kind constants.
    pub kind: u8,
    /// Carries the status byte, or the channel for `KIND_NOTES_OFF`.
    pub status: u8,
    /// Carries the first data byte.
    pub data1: u8,
    /// Carries the second data byte.
    pub data2: u8,
}

/// Configures one synthesizer.
#[derive(Clone, Copy, Debug)]
pub struct Settings {
    /// The notes `rustysynth` sounds at once, from 8 to 256.
    pub polyphony: usize,
    /// Whether `rustysynth` runs its reverb and chorus.
    pub effects: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            polyphony: 64,
            effects: true,
        }
    }
}

/// What a synthesizer is driven through, so the scheduler can be tested
/// without a SoundFont and can drive more than one kind of synthesizer.
pub trait Target: Send {
    /// The frames between the points events can be applied at, which is the
    /// grid an event's frame is rounded up to.
    const BLOCK_FRAMES: usize;

    /// Applies one event at the current block boundary.
    fn apply(&mut self, event: &Event);

    /// Renders the next `left.len()` frames.
    fn render(&mut self, left: &mut [f32], right: &mut [f32]);
}

/// The `rustysynth` synthesizer as a target.
pub struct GeneralMidi {
    synthesizer: Synthesizer,
}

impl Target for GeneralMidi {
    const BLOCK_FRAMES: usize = BLOCK_FRAMES;

    fn apply(&mut self, event: &Event) {
        match event.kind {
            KIND_MESSAGE => {
                // System messages carry no channel and this synthesizer has no
                // use for any of them, so they are accepted and dropped here.
                // A hardware output would forward them.
                if event.status < 0xF0 {
                    self.synthesizer.process_midi_message(
                        i32::from(event.status & 0x0F),
                        i32::from(event.status & 0xF0),
                        i32::from(event.data1),
                        i32::from(event.data2),
                    );
                }
            }
            KIND_NOTES_OFF => {
                let immediate = event.data1 != 0;
                if event.status == ALL_CHANNELS {
                    self.synthesizer.note_off_all(immediate);
                } else {
                    self.synthesizer
                        .note_off_all_channel(i32::from(event.status), immediate);
                }
            }
            KIND_RESET => self.synthesizer.reset(),
            _ => {}
        }
    }

    fn render(&mut self, left: &mut [f32], right: &mut [f32]) {
        self.synthesizer.render(left, right);
    }
}

/// A bounded lock-free ring with one producer and one consumer.
///
/// `head` is the next slot to read and `tail` the next to write, both counted
/// without wrapping so that full and empty are told apart by their distance.
/// The producer alone moves `tail` and the consumer alone moves `head`, which
/// the `Producer` and `Consumer` halves enforce by taking `&mut self`.
struct Ring {
    slots: Box<[UnsafeCell<MaybeUninit<Event>>]>,
    head: AtomicUsize,
    tail: AtomicUsize,
}

// SAFETY: a slot is written only by the producer while it lies outside
// `head..tail`, and read only by the consumer while it lies inside, and the
// acquire and release pair on `tail` and `head` orders those accesses.
unsafe impl Sync for Ring {}

impl Ring {
    fn new(capacity: usize) -> Ring {
        let slots = (0..capacity)
            .map(|_| UnsafeCell::new(MaybeUninit::uninit()))
            .collect();
        Ring {
            slots,
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
        }
    }
}

/// The game-thread half of the ring.
struct Producer {
    ring: Arc<Ring>,
}

impl Producer {
    /// Appends an event and reports whether there was room for it.
    fn push(&mut self, event: Event) -> bool {
        let tail = self.ring.tail.load(Ordering::Relaxed);
        let head = self.ring.head.load(Ordering::Acquire);
        let capacity = self.ring.slots.len();
        if tail.wrapping_sub(head) >= capacity {
            return false;
        }
        // SAFETY: the slot lies outside `head..tail`, so the consumer is not
        // reading it, and only this producer writes.
        unsafe {
            (*self.ring.slots[tail % capacity].get()).write(event);
        }
        self.ring
            .tail
            .store(tail.wrapping_add(1), Ordering::Release);
        true
    }

    /// Appends `count` events, the one `event` makes for each index, or none
    /// of them when the ring cannot hold them all.
    ///
    /// The tail moves once, after the last is written, so the consumer sees
    /// either the whole batch or nothing of it.
    fn push_all(&mut self, count: usize, mut event: impl FnMut(usize) -> Event) -> bool {
        let tail = self.ring.tail.load(Ordering::Relaxed);
        let head = self.ring.head.load(Ordering::Acquire);
        let capacity = self.ring.slots.len();
        if count > capacity - tail.wrapping_sub(head) {
            return false;
        }
        for index in 0..count {
            let slot = tail.wrapping_add(index) % capacity;
            // SAFETY: every slot from `tail` for `count` lies outside
            // `head..tail`, since the check above left room for all of them,
            // so the consumer is not reading any of them.
            unsafe {
                (*self.ring.slots[slot].get()).write(event(index));
            }
        }
        self.ring
            .tail
            .store(tail.wrapping_add(count), Ordering::Release);
        true
    }
}

/// The callback half of the ring.
struct Consumer {
    ring: Arc<Ring>,
}

impl Consumer {
    /// Removes the oldest event, if there is one.
    fn pop(&mut self) -> Option<Event> {
        let head = self.ring.head.load(Ordering::Relaxed);
        let tail = self.ring.tail.load(Ordering::Acquire);
        if head == tail {
            return None;
        }
        let capacity = self.ring.slots.len();
        // SAFETY: the slot lies inside `head..tail`, so the producer finished
        // writing it before its release store on `tail`.
        let event = unsafe { (*self.ring.slots[head % capacity].get()).assume_init() };
        self.ring
            .head
            .store(head.wrapping_add(1), Ordering::Release);
        Some(event)
    }
}

/// What both halves of one synthesizer read.
struct Shared {
    /// Frames rendered since the synthesizer started, which is its clock.
    frames: AtomicU64,
}

/// The game side of one synthesizer: where events are sent and the clock read.
pub struct Port {
    producer: Producer,
    shared: Arc<Shared>,
    sample_rate: u32,
    dropped: u64,
}

impl Port {
    /// Converts a time on the synthesizer clock to the frame it is due at.
    ///
    /// Zero, a negative time and a time that is not a number all mean the next
    /// block boundary.
    fn frame_at(&self, seconds: f64) -> u64 {
        if seconds.is_nan() || seconds <= 0.0 {
            return 0;
        }
        (seconds * self.sample_rate as f64).round() as u64
    }

    /// Queues one event and reports whether the queue had room for it.
    pub(crate) fn push(&mut self, event: Event) -> bool {
        if self.producer.push(event) {
            return true;
        }
        self.dropped += 1;
        false
    }

    /// Queues `count` events, the one `event` makes for each index, all or
    /// none, and reports which. A refused batch counts as one drop.
    pub(crate) fn push_all(&mut self, count: usize, event: impl FnMut(usize) -> Event) -> bool {
        if self.producer.push_all(count, event) {
            return true;
        }
        self.dropped += 1;
        false
    }

    /// Reports whether the ring has room for one more event.
    ///
    /// The answer holds until this port pushes, since the callback only ever
    /// takes events out.
    pub(crate) fn has_room(&self) -> bool {
        let tail = self.producer.ring.tail.load(Ordering::Relaxed);
        let head = self.producer.ring.head.load(Ordering::Acquire);
        tail.wrapping_sub(head) < self.producer.ring.slots.len()
    }

    /// Counts a send refused before it reached the ring.
    pub(crate) fn refuse(&mut self) {
        self.dropped += 1;
    }

    /// Reports the rate the clock counts frames at.
    pub(crate) fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Queues a short MIDI message for `at` seconds on the synthesizer clock,
    /// and reports whether the queue had room for it.
    pub fn send(&mut self, status: u8, data1: u8, data2: u8, at: f64) -> bool {
        let frame = self.frame_at(at);
        self.push(Event {
            frame,
            kind: KIND_MESSAGE,
            status,
            data1: data1 & 0x7F,
            data2: data2 & 0x7F,
        })
    }

    /// Queues a release of every note on `channel`, or on every channel for
    /// `None`, for the next block boundary.
    pub fn notes_off(&mut self, channel: Option<u8>, immediate: bool) -> bool {
        self.push(Event {
            frame: 0,
            kind: KIND_NOTES_OFF,
            status: channel.map_or(ALL_CHANNELS, |value| value & 0x0F),
            data1: u8::from(immediate),
            data2: 0,
        })
    }

    /// Queues a reset for the next block boundary. Every event sent before it
    /// and not yet applied is discarded when the callback reaches it.
    ///
    /// The scheduler also takes a reset with a frame, which is how
    /// [`crate::fm::FmPort::reset`] schedules one: events sent before it and
    /// due before its frame still apply, and those due at or after it are
    /// discarded.
    pub fn reset(&mut self) -> bool {
        self.push(Event {
            frame: 0,
            kind: KIND_RESET,
            status: 0,
            data1: 0,
            data2: 0,
        })
    }

    /// Reports the synthesizer clock in seconds: the frames it has rendered
    /// over the output rate.
    pub fn now(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.shared.frames.load(Ordering::Acquire) as f64 / self.sample_rate as f64
    }

    /// Reports the frames the synthesizer has rendered.
    pub fn frames(&self) -> u64 {
        self.shared.frames.load(Ordering::Acquire)
    }

    /// Reports how many events `send`, `notes_off` and `reset` refused because
    /// the queue was full.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

/// The callback side of one synthesizer, read by the mixer as a voice's input.
pub struct SynthSource<T: Target> {
    target: T,
    consumer: Consumer,
    shared: Arc<Shared>,
    /// Events moved out of the ring, ordered by frame and then by sending.
    schedule: VecDeque<Event>,
    /// Frames rendered, mirrored from `shared` so the callback reads no atomic.
    frames: u64,
    /// Frames already rendered into the current internal block.
    phase: usize,
    sample_rate: u32,
    left: Vec<f32>,
    right: Vec<f32>,
}

impl<T: Target> SynthSource<T> {
    /// Moves every event the schedule has room for out of the ring.
    fn collect(&mut self) {
        // Bounded by the constant rather than by `capacity`, which may be
        // larger than was asked for and is not a promise to keep to.
        while self.schedule.len() < QUEUE_EVENTS {
            let Some(mut event) = self.consumer.pop() else {
                return;
            };
            // A time already rendered becomes the next boundary, and sending
            // order is kept among events that land on the same one.
            event.frame = event.frame.max(self.frames);
            if event.kind == KIND_RESET {
                // A reset discards everything sent before it that is due at
                // or after it, notes scheduled for later included: leaving
                // those would play them over the silence the reset was sent
                // to make. What is due before it still applies first, as it
                // would have without the reset.
                // A memory load is kept whatever its time: its image is
                // already on its way, and dropping the event would leave the
                // image for the next load to take.
                let at = event.frame;
                self.schedule
                    .retain(|queued| queued.frame < at || queued.kind == KIND_MEMORY);
            }
            let at = self
                .schedule
                .partition_point(|queued| queued.frame <= event.frame);
            self.schedule.insert(at, event);
        }
    }

    /// Applies every scheduled event due at or before the current frame.
    fn apply_due(&mut self) {
        while let Some(event) = self.schedule.front() {
            if event.frame > self.frames {
                return;
            }
            let event = *event;
            self.schedule.pop_front();
            self.target.apply(&event);
        }
    }
}

impl<T: Target> Source for SynthSource<T> {
    fn channels(&self) -> u16 {
        2
    }

    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Renders up to the next boundary of the target's grid.
    ///
    /// One block per call rather than as much as `out` holds, so a voice reads
    /// at most one block ahead of the output and an event sent now reaches the
    /// next block rather than one a whole staging buffer later. On a grid of
    /// one frame that is a frame per call.
    fn read(&mut self, out: &mut [f32]) -> usize {
        let wanted = out.len() / 2;
        if wanted == 0 {
            return 0;
        }
        self.collect();
        if self.phase == 0 {
            self.apply_due();
        }
        let count = (T::BLOCK_FRAMES - self.phase).min(wanted);
        let (left, right) = (&mut self.left[..count], &mut self.right[..count]);
        self.target.render(left, right);
        for (index, (l, r)) in left.iter().zip(right.iter()).enumerate() {
            out[index * 2] = *l;
            out[index * 2 + 1] = *r;
        }
        self.phase = (self.phase + count) % T::BLOCK_FRAMES;
        self.frames += count as u64;
        self.shared.frames.store(self.frames, Ordering::Release);
        count
    }

    /// Refuses: a synthesizer has no position to move to.
    fn seek(&mut self, _seconds: f64) -> bool {
        false
    }

    fn position(&self) -> f64 {
        if self.sample_rate == 0 {
            0.0
        } else {
            self.frames as f64 / self.sample_rate as f64
        }
    }

    /// Never: a synthesizer sounds until its voice is stopped.
    fn exhausted(&self) -> bool {
        false
    }
}

/// Builds the two halves of one synthesizer around any target.
pub fn assemble<T: Target>(target: T, sample_rate: u32) -> (Port, SynthSource<T>) {
    let ring = Arc::new(Ring::new(QUEUE_EVENTS));
    let shared = Arc::new(Shared {
        frames: AtomicU64::new(0),
    });
    let port = Port {
        producer: Producer {
            ring: Arc::clone(&ring),
        },
        shared: Arc::clone(&shared),
        sample_rate,
        dropped: 0,
    };
    let source = SynthSource {
        target,
        consumer: Consumer { ring },
        shared,
        schedule: VecDeque::with_capacity(QUEUE_EVENTS),
        frames: 0,
        phase: 0,
        sample_rate,
        left: vec![0.0; T::BLOCK_FRAMES],
        right: vec![0.0; T::BLOCK_FRAMES],
    };
    (port, source)
}

/// Creates a General MIDI synthesizer on a loaded SoundFont.
///
/// @return the port the game sends through and the source the mixer reads, or
///     the reason `rustysynth` refused the settings
pub fn open(
    font: &Arc<SoundFont>,
    sample_rate: u32,
    settings: &Settings,
) -> Result<(Port, SynthSource<GeneralMidi>), String> {
    let rate = i32::try_from(sample_rate)
        .map_err(|_| format!("an output rate of {sample_rate} is out of range"))?;
    let mut options = SynthesizerSettings::new(rate);
    options.block_size = BLOCK_FRAMES;
    options.maximum_polyphony = settings.polyphony;
    options.enable_reverb_and_chorus = settings.effects;
    let synthesizer = Synthesizer::new(font, &options)
        .map_err(|error| format!("the synthesizer refused its settings: {error}"))?;
    Ok(assemble(GeneralMidi { synthesizer }, sample_rate))
}

/// Reads a SoundFont 2 file.
///
/// The RIFF header is checked first, so a file that is not a SoundFont is
/// refused with a reason that says so rather than with a parse error from
/// somewhere inside it.
///
/// @return the SoundFont, ready to share between synthesizers, or the reason
pub fn load_sound_font(path: &str) -> Result<Arc<SoundFont>, String> {
    let file = File::open(path).map_err(|error| format!("cannot open '{path}': {error}"))?;
    let mut reader = BufReader::new(file);
    let mut header = [0u8; 12];
    reader
        .read_exact(&mut header)
        .map_err(|_| format!("'{path}' is too short to be a SoundFont"))?;
    if &header[0..4] != b"RIFF" || &header[8..12] != b"sfbk" {
        return Err(format!("'{path}' is not a SoundFont 2 file"));
    }
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("cannot read '{path}': {error}"))?;
    let font = SoundFont::new(&mut reader)
        .map_err(|error| format!("'{path}' is not a readable SoundFont: {error}"))?;
    Ok(Arc::new(font))
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 48_000;

    /// Records the frame each event was applied at and renders a constant, so
    /// a test can see both when an event landed and how far the clock ran.
    struct Recorder {
        frame: u64,
        applied: Arc<std::sync::Mutex<Vec<(u64, Event)>>>,
    }

    impl Target for Recorder {
        const BLOCK_FRAMES: usize = BLOCK_FRAMES;

        fn apply(&mut self, event: &Event) {
            self.applied
                .lock()
                .expect("the log is not poisoned")
                .push((self.frame, *event));
        }

        fn render(&mut self, left: &mut [f32], right: &mut [f32]) {
            left.fill(0.25);
            right.fill(0.5);
            self.frame += left.len() as u64;
        }
    }

    type Log = Arc<std::sync::Mutex<Vec<(u64, Event)>>>;

    fn recorder() -> (Port, SynthSource<Recorder>, Log) {
        let applied = Arc::new(std::sync::Mutex::new(Vec::new()));
        let (port, source) = assemble(
            Recorder {
                frame: 0,
                applied: Arc::clone(&applied),
            },
            RATE,
        );
        (port, source, applied)
    }

    /// Reads as the mixer does, a staging buffer at a time, for `frames`.
    fn pull(source: &mut impl Source, frames: usize) {
        let mut staging = vec![0.0f32; 256 * 2];
        let mut done = 0;
        while done < frames {
            let wanted = (frames - done).min(256);
            done += source.read(&mut staging[..wanted * 2]);
        }
    }

    fn frames_of(log: &Log) -> Vec<(u64, u8, u8)> {
        log.lock()
            .expect("the log is not poisoned")
            .iter()
            .map(|(frame, event)| (*frame, event.kind, event.data1))
            .collect()
    }

    #[test]
    fn lands_a_scheduled_event_on_the_first_block_boundary_at_or_after_it() {
        let (mut port, mut source, log) = recorder();
        let block = BLOCK_FRAMES as u64;
        // A boundary exactly, a frame past one, and a frame short of one.
        let frames = [8 * block, 8 * block + 1, 100 * block - 1];
        for (key, frame) in frames.iter().enumerate() {
            assert!(port.send(0x90, key as u8, 100, *frame as f64 / RATE as f64));
        }
        pull(&mut source, 2048);
        assert_eq!(
            frames_of(&log),
            vec![
                (8 * block, KIND_MESSAGE, 0),
                (9 * block, KIND_MESSAGE, 1),
                (100 * block, KIND_MESSAGE, 2)
            ]
        );
    }

    #[test]
    fn applies_an_unscheduled_or_past_event_at_the_next_boundary_in_sending_order() {
        let (mut port, mut source, log) = recorder();
        let block = BLOCK_FRAMES as u64;
        // Read part way into a block, as a staging buffer that does not
        // divide by the block leaves a voice.
        let mut partial = vec![0.0f32; 2 * (BLOCK_FRAMES / 2)];
        pull(&mut source, 40 * BLOCK_FRAMES);
        source.read(&mut partial);
        assert!(port.send(0x90, 1, 100, 0.0));
        assert!(port.send(0x90, 2, 100, 10.0 / RATE as f64));
        assert!(port.send(0x90, 3, 100, -1.0));
        pull(&mut source, 4 * BLOCK_FRAMES);
        let next = 41 * block;
        assert_eq!(
            frames_of(&log),
            vec![
                (next, KIND_MESSAGE, 1),
                (next, KIND_MESSAGE, 2),
                (next, KIND_MESSAGE, 3)
            ]
        );
    }

    #[test]
    fn orders_events_by_time_rather_than_by_sending() {
        let (mut port, mut source, log) = recorder();
        assert!(port.send(0x90, 2, 100, 512.0 / RATE as f64));
        assert!(port.send(0x90, 1, 100, 256.0 / RATE as f64));
        assert!(port.send(0x90, 3, 100, 512.0 / RATE as f64));
        pull(&mut source, 1024);
        assert_eq!(
            frames_of(&log),
            vec![
                (256, KIND_MESSAGE, 1),
                (512, KIND_MESSAGE, 2),
                (512, KIND_MESSAGE, 3)
            ]
        );
    }

    #[test]
    fn runs_the_clock_by_rendered_frames_only() {
        let (port, mut source, _log) = recorder();
        assert_eq!(port.now(), 0.0);
        pull(&mut source, 480);
        assert_eq!(port.frames(), 480);
        assert!((port.now() - 0.01).abs() < 1e-12);
    }

    #[test]
    fn interleaves_the_two_rendered_channels() {
        let (_port, mut source, _log) = recorder();
        let mut out = vec![0.0f32; 6];
        assert_eq!(source.read(&mut out), 3);
        assert_eq!(out, vec![0.25, 0.5, 0.25, 0.5, 0.25, 0.5]);
        assert!(!source.exhausted());
        assert!(!source.seek(1.0));
    }

    #[test]
    fn refuses_an_event_past_the_bound_and_counts_it() {
        let (mut port, mut source, log) = recorder();
        // Nothing renders, so nothing leaves the ring.
        for _ in 0..QUEUE_EVENTS {
            assert!(port.send(0x90, 1, 100, 1.0));
        }
        assert!(!port.send(0x90, 2, 100, 1.0));
        assert!(!port.reset());
        assert_eq!(port.dropped(), 2);

        // One block moves the ring into the schedule, which then has the
        // room again, and the refused events are gone rather than delayed.
        pull(&mut source, BLOCK_FRAMES);
        for _ in 0..QUEUE_EVENTS {
            assert!(port.send(0x90, 3, 100, 1.0));
        }
        // Ring and schedule are both full now.
        assert!(!port.send(0x90, 4, 100, 1.0));
        pull(&mut source, RATE as usize + 2 * BLOCK_FRAMES);
        let keys: Vec<u8> = frames_of(&log).iter().map(|entry| entry.2).collect();
        assert_eq!(keys.len(), 2 * QUEUE_EVENTS);
        assert!(!keys.contains(&2) && !keys.contains(&4));
    }

    #[test]
    fn discards_what_was_sent_before_a_reset_and_keeps_what_follows() {
        let (mut port, mut source, log) = recorder();
        assert!(port.send(0x90, 1, 100, 0.5));
        assert!(port.send(0x90, 2, 100, 0.0));
        assert!(port.reset());
        assert!(port.send(0x90, 3, 100, 0.0));
        pull(&mut source, RATE as usize);
        assert_eq!(
            frames_of(&log),
            vec![(0, KIND_RESET, 0), (0, KIND_MESSAGE, 3)]
        );
    }

    #[test]
    fn keeps_a_notes_off_in_order_with_the_events_around_it() {
        let (mut port, mut source, log) = recorder();
        assert!(port.send(0x90, 1, 100, 0.0));
        assert!(port.notes_off(Some(3), true));
        assert!(port.notes_off(None, false));
        assert!(port.send(0x90, 2, 100, 0.0));
        pull(&mut source, BLOCK_FRAMES);
        let applied: Vec<Event> = log
            .lock()
            .expect("the log is not poisoned")
            .iter()
            .map(|entry| entry.1)
            .collect();
        assert_eq!(applied.len(), 4);
        assert_eq!(applied[1].kind, KIND_NOTES_OFF);
        assert_eq!((applied[1].status, applied[1].data1), (3, 1));
        assert_eq!((applied[2].status, applied[2].data1), (ALL_CHANNELS, 0));
        assert_eq!(applied[3].data1, 2);
    }

    #[test]
    fn refuses_a_file_that_is_not_a_soundfont() {
        let directory = std::env::temp_dir().join(format!("tecs-synth-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("a scratch directory");
        let path = directory.join("not.sf2");
        std::fs::write(&path, b"RIFF\0\0\0\0WAVEfmt ").expect("a scratch file");
        let reason = load_sound_font(path.to_str().expect("a UTF-8 path"))
            .expect_err("a WAVE file is not a SoundFont");
        assert!(reason.contains("not a SoundFont 2"), "got {reason}");
        assert!(load_sound_font("no/such/font.sf2").is_err());
        std::fs::remove_dir_all(&directory).ok();
    }
}
