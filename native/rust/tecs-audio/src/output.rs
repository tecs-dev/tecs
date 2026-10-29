//! The output kept open across a device that changes under it.
//!
//! A stream is a promise about one device at one format, and the default
//! output breaks it: a Bluetooth headset turning its microphone on drops from
//! stereo at 44 100 or 48 000 Hz to mono at 16 000 or 24 000 Hz, a headset
//! leaves or comes back, a dock is unplugged. Some of those end the stream with
//! an error, some leave it paused with none, and some leave it running at a
//! format the device no longer has. So the stream is not the engine's: one
//! supervising thread owns it, notices it has gone (an error the callback
//! reported, a callback that stopped arriving, or a device whose format no
//! longer matches) and opens the default output again at whatever format it
//! has now.
//!
//! The mixer does not follow. It runs at the engine's own rate and layout
//! throughout, a [`Conformer`](crate::conform::Conformer) meets each stream's
//! format inside its callback, and while no stream is open the supervisor
//! renders the mix itself at the pace of the wall clock, so every position,
//! fade and scheduled event the mixer counts keeps moving and a voice that
//! would have finished during the gap still reports finished.
//!
//! Nothing here runs on the realtime thread except [`Feed::fill`], which locks
//! the mixer, checks that its stream is still the live one and renders. The
//! error callback stores a reason and wakes the supervisor; it never opens or
//! closes anything.

use std::any::Any;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::{self, JoinHandle, Thread};
use std::time::{Duration, Instant};

use crate::conform::{Conformer, Format};
use crate::mixer::Mixer;

/// No output was ever opened: an offline engine, or a machine with no sound.
pub const STATE_OFFLINE: u32 = 0;

/// A stream is open and pulling the mix.
pub const STATE_PLAYING: u32 = 1;

/// The stream dropped and the supervisor is opening another. The mix keeps
/// running and nothing is heard.
pub const STATE_REOPENING: u32 = 2;

/// The supervisor itself stopped, which only a panic does. Terminal.
pub const STATE_FAILED: u32 = 3;

/// Where streams come from: the platform's default output, or a test's fake.
///
/// A host lives on the supervising thread from creation to drop, so neither it
/// nor the streams it opens need to be `Send`.
pub trait Host {
    /// Reports the format the default output has now, or why there is none.
    fn current(&mut self) -> Result<Format, String>;

    /// Opens the default output at its current format and starts it.
    ///
    /// The host builds its callback's [`Feed`] from `tap` once it knows the
    /// format, and hands its error callback the tap's [`Alarm`].
    ///
    /// @return a value whose drop closes the stream, and the format it opened at
    fn open(&mut self, tap: Tap) -> Result<(Box<dyn Any>, Format), String>;

    /// Reports whether comparing `current` against an open stream's format is
    /// worth doing. A platform where the stream reports every change itself,
    /// or where asking is expensive, answers false.
    fn polls_format(&self) -> bool {
        true
    }
}

/// How quickly the supervisor reacts, and how hard it retries.
#[derive(Clone, Copy, Debug)]
pub struct Timing {
    /// How often it wakes while no stream is open, which is the step the
    /// mixer's clock moves in during the gap.
    pub tick: Duration,
    /// How often it compares the device's format against the stream's.
    pub poll: Duration,
    /// How long a stream may go without a callback before it counts as lost.
    pub stall: Duration,
    /// The wait before the first reopen attempt, doubled after each failure.
    pub first_retry: Duration,
    /// The longest wait between two attempts.
    pub last_retry: Duration,
    /// The attempts made before the supervisor stops trying and waits for the
    /// device to change.
    pub attempts: u32,
    /// How often it asks about the device once it has stopped trying.
    pub dormant_poll: Duration,
    /// How often it tries an unchanged device anyway once it has stopped.
    pub slow_retry: Duration,
}

impl Default for Timing {
    fn default() -> Timing {
        Timing {
            tick: Duration::from_millis(10),
            poll: Duration::from_millis(500),
            // Long enough for a Bluetooth link to come up before the first
            // callback of a new stream, which takes over a second.
            stall: Duration::from_secs(3),
            first_retry: Duration::from_millis(20),
            last_retry: Duration::from_secs(2),
            attempts: 10,
            dormant_poll: Duration::from_secs(1),
            slow_retry: Duration::from_secs(30),
        }
    }
}

/// The most mix the supervisor renders in one tick while the output is down,
/// so a wall clock that jumps (a debugger pause, a machine waking) costs a
/// skip in the clock rather than seconds of rendering.
const MAX_CATCH_UP_SECONDS: u64 = 1;

/// Frames the supervisor renders per call while the output is down.
const KEEP_BLOCK: usize = 512;

/// What the supervisor, the callbacks and the engine share.
struct Shared {
    mixer: Arc<Mutex<Mixer>>,
    engine: Format,
    /// The generation whose callback may render, and zero for none. Written
    /// only under the mixer lock and read only under it, so an old stream's
    /// last callback and the supervisor never both render the same frames.
    live: AtomicU64,
    /// Bumped by every callback that rendered.
    callbacks: AtomicU64,
    /// When the last of them rendered, in nanoseconds after `base`. A gap is
    /// counted from here rather than from when the supervisor noticed it, so
    /// the clock loses nothing to how long noticing took.
    last_callback: AtomicU64,
    base: Instant,
    /// The newest generation an error callback reported lost.
    lost: AtomicU64,
    /// The reason it gave, beside the generation it was for.
    lost_reason: Mutex<(u64, String)>,
    /// Set by a reroute the stream survived, asking for a format check now.
    recheck: AtomicBool,
    supervisor: OnceLock<Thread>,
    stop: AtomicBool,
    state: AtomicU32,
    failed: Arc<AtomicBool>,
    drops: AtomicU32,
    reopens: AtomicU32,
    /// Why the output last dropped, empty until it has.
    reason: Mutex<String>,
    device_rate: AtomicU32,
    device_channels: AtomicU32,
}

impl Shared {
    fn wake(&self) {
        if let Some(thread) = self.supervisor.get() {
            thread.unpark();
        }
    }
}

/// What a host needs to build one stream.
pub struct Tap {
    shared: Arc<Shared>,
    generation: u64,
}

impl Tap {
    /// Builds the data callback's state for a stream at `device`.
    ///
    /// Allocates the conversion, so call it before the stream starts.
    pub fn feed(&self, device: Format) -> Feed {
        Feed {
            shared: Arc::clone(&self.shared),
            generation: self.generation,
            conformer: Conformer::new(self.shared.engine, device),
        }
    }

    /// Returns what the stream's error callback reports through.
    pub fn alarm(&self) -> Alarm {
        Alarm {
            shared: Arc::clone(&self.shared),
            generation: self.generation,
        }
    }
}

/// The data callback's half of a stream.
pub struct Feed {
    shared: Arc<Shared>,
    generation: u64,
    conformer: Conformer,
}

impl Feed {
    /// Fills one device buffer, converting each float sample with `convert`.
    ///
    /// Called on the realtime thread. It locks the mixer as the callback always
    /// has, and allocates nothing.
    pub fn fill<T, C: Fn(f32) -> T>(&mut self, out: &mut [T], convert: C) {
        let mut mixer = match self.shared.mixer.lock() {
            Err(_) => {
                silence(out, &convert);
                return;
            }
            Ok(guard) => guard,
        };
        // A stream the supervisor has already let go of, or one it has not yet
        // caught the clock up for, plays silence and leaves the mix alone.
        if self.shared.live.load(Ordering::Acquire) != self.generation {
            drop(mixer);
            silence(out, &convert);
            return;
        }
        self.conformer
            .fill(out, |span| mixer.render(span), &convert);
        drop(mixer);
        // A monotonic clock read, which on every platform `cpal` serves is a
        // counter rather than a system call that can block.
        let at = self.shared.base.elapsed().as_nanos() as u64;
        self.shared.last_callback.store(at, Ordering::Relaxed);
        self.shared.callbacks.fetch_add(1, Ordering::Release);
    }
}

fn silence<T, C: Fn(f32) -> T>(out: &mut [T], convert: &C) {
    for target in out.iter_mut() {
        *target = convert(0.0);
    }
}

/// The error callback's half of a stream.
#[derive(Clone)]
pub struct Alarm {
    shared: Arc<Shared>,
    generation: u64,
}

impl Alarm {
    /// Reports the stream dead, for the supervisor to replace.
    ///
    /// Stores the reason without waiting on a lock, so it is safe from any
    /// thread, though it does allocate the reason. A report from a stream the
    /// supervisor has already replaced is ignored.
    pub fn lost(&self, reason: &str) {
        if let Ok(mut slot) = self.shared.lost_reason.try_lock() {
            if slot.0 <= self.generation {
                *slot = (self.generation, reason.to_string());
            }
        }
        self.shared
            .lost
            .fetch_max(self.generation, Ordering::AcqRel);
        self.shared.wake();
    }

    /// Asks for the device's format to be checked now, after a reroute the
    /// stream itself survived.
    pub fn recheck(&self) {
        self.shared.recheck.store(true, Ordering::Release);
        self.shared.wake();
    }
}

/// The supervised output an engine holds.
pub struct Output {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl Output {
    /// Starts the supervisor and waits for its first stream.
    ///
    /// The first open is not retried: a machine with no output at start is an
    /// engine without one, as it always was, and only a stream that opened is
    /// one the supervisor keeps open.
    ///
    /// @return the running output, or the reason the first stream did not open
    pub fn start<H, F>(
        make: F,
        mixer: Arc<Mutex<Mixer>>,
        engine: Format,
        timing: Timing,
    ) -> Result<Output, String>
    where
        H: Host + 'static,
        F: FnOnce() -> Result<H, String> + Send + 'static,
    {
        let shared = Arc::new(Shared {
            mixer,
            engine,
            live: AtomicU64::new(0),
            callbacks: AtomicU64::new(0),
            last_callback: AtomicU64::new(0),
            base: Instant::now(),
            lost: AtomicU64::new(0),
            lost_reason: Mutex::new((0, String::new())),
            recheck: AtomicBool::new(false),
            supervisor: OnceLock::new(),
            stop: AtomicBool::new(false),
            state: AtomicU32::new(STATE_OFFLINE),
            failed: Arc::new(AtomicBool::new(false)),
            drops: AtomicU32::new(0),
            reopens: AtomicU32::new(0),
            reason: Mutex::new(String::new()),
            device_rate: AtomicU32::new(0),
            device_channels: AtomicU32::new(0),
        });
        let (ready, opened) = mpsc::channel::<Result<(), String>>();
        let inner = Arc::clone(&shared);
        let thread = thread::Builder::new()
            .name("tecs-audio-output".to_string())
            .spawn(move || {
                let _ = inner.supervisor.set(thread::current());
                let host = match make() {
                    Err(reason) => {
                        let _ = ready.send(Err(reason));
                        return;
                    }
                    Ok(value) => value,
                };
                Supervisor::new(host, inner, timing).run(ready);
            })
            .map_err(|error| format!("the audio output thread did not start: {error}"))?;
        match opened.recv() {
            Ok(Ok(())) => Ok(Output {
                shared,
                thread: Some(thread),
            }),
            Ok(Err(reason)) => {
                let _ = thread.join();
                Err(reason)
            }
            Err(_) => {
                let _ = thread.join();
                Err("the audio output thread stopped before opening a stream".to_string())
            }
        }
    }

    /// Reports one of the `STATE_` constants.
    pub fn state(&self) -> u32 {
        self.shared.state.load(Ordering::Acquire)
    }

    /// Reports the sticky flag a dead supervisor leaves.
    pub fn failed(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.shared.failed)
    }

    /// Reports how many times the output has dropped.
    pub fn drops(&self) -> u32 {
        self.shared.drops.load(Ordering::Acquire)
    }

    /// Reports how many times it has opened again after a drop.
    pub fn reopens(&self) -> u32 {
        self.shared.reopens.load(Ordering::Acquire)
    }

    /// Returns why the output last dropped, and an empty string until it has.
    pub fn reason(&self) -> String {
        match self.shared.reason.lock() {
            Err(_) => String::new(),
            Ok(value) => value.clone(),
        }
    }

    /// Reports the format the open stream runs at, and `None` while none is.
    pub fn device_format(&self) -> Option<Format> {
        let rate = self.shared.device_rate.load(Ordering::Acquire);
        let channels = self.shared.device_channels.load(Ordering::Acquire);
        if rate == 0 || channels == 0 {
            return None;
        }
        Some(Format {
            sample_rate: rate,
            channels: channels as u16,
        })
    }
}

impl Drop for Output {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.wake();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Marks the output failed if the supervisor unwinds rather than returns.
struct Watch(Arc<Shared>);

impl Drop for Watch {
    fn drop(&mut self) {
        if thread::panicking() {
            self.0.failed.store(true, Ordering::Release);
            self.0.state.store(STATE_FAILED, Ordering::Release);
        }
    }
}

/// An open stream and what the supervisor watches it by.
struct Open {
    /// Dropped to close the stream.
    stream: Box<dyn Any>,
    format: Format,
    generation: u64,
    /// The callback count when it last moved, and when that was.
    callbacks: u64,
    progressed: Instant,
    /// Whether any callback has arrived, which is what makes a stall a lost
    /// stream rather than one that never worked.
    delivered: bool,
    next_poll: Instant,
}

/// The gap between a lost stream and the next, and the retry state.
struct Gap {
    /// When the gap began, and how many mixer frames it has rendered since.
    since: Instant,
    rendered: u64,
    attempts: u32,
    delay: Duration,
    next_attempt: Instant,
    /// Set once the attempts run out: the format the device last reported, or
    /// `None` for no device, which the supervisor waits to see change.
    dormant: Option<Option<Format>>,
    /// When a dormant supervisor next tries the unchanged device anyway.
    slow_retry: Instant,
}

enum Phase {
    Playing(Open),
    Down(Gap),
}

struct Supervisor<H: Host> {
    host: H,
    shared: Arc<Shared>,
    timing: Timing,
    generation: u64,
    /// Mixer frames the supervisor renders into while the output is down.
    scratch: Vec<f32>,
    /// Streams in a row that opened and never called back. Each counts as a
    /// failed attempt, so a device that opens and then never plays is not
    /// reopened forever at the fastest rate.
    silent_streams: u32,
}

impl<H: Host> Supervisor<H> {
    fn new(host: H, shared: Arc<Shared>, timing: Timing) -> Supervisor<H> {
        let width = (shared.engine.channels as usize).max(1);
        Supervisor {
            host,
            shared,
            timing,
            generation: 0,
            scratch: vec![0.0; KEEP_BLOCK * width],
            silent_streams: 0,
        }
    }

    fn run(mut self, ready: mpsc::Sender<Result<(), String>>) {
        let _watch = Watch(Arc::clone(&self.shared));
        let mut phase = match self.open() {
            Err(reason) => {
                let _ = ready.send(Err(reason));
                return;
            }
            Ok(open) => {
                self.go_live(&open, None);
                let _ = ready.send(Ok(()));
                Phase::Playing(open)
            }
        };
        drop(ready);

        while !self.shared.stop.load(Ordering::Acquire) {
            phase = match phase {
                Phase::Playing(open) => self.watch(open),
                Phase::Down(gap) => self.recover(gap),
            };
            let wait = match &phase {
                Phase::Playing(_) => self.timing.poll.min(self.timing.stall / 4),
                Phase::Down(_) => self.timing.tick,
            };
            thread::park_timeout(wait);
        }

        if let Phase::Playing(open) = phase {
            self.let_go();
            drop(open.stream);
        }
    }

    /// Opens a stream under a new generation. It plays silence until
    /// `go_live` hands it the mix.
    fn open(&mut self) -> Result<Open, String> {
        self.generation += 1;
        let tap = Tap {
            shared: Arc::clone(&self.shared),
            generation: self.generation,
        };
        let (stream, format) = self.host.open(tap)?;
        let now = Instant::now();
        Ok(Open {
            stream,
            format,
            generation: self.generation,
            callbacks: self.shared.callbacks.load(Ordering::Acquire),
            progressed: now,
            delivered: false,
            next_poll: now + self.timing.poll,
        })
    }

    /// Hands the mix to a stream, first rendering whatever the gap still owes
    /// the clock, under the one lock the callback also takes.
    fn go_live(&mut self, open: &Open, gap: Option<&mut Gap>) {
        let mut mixer = match self.shared.mixer.lock() {
            Err(_) => return,
            Ok(guard) => guard,
        };
        if let Some(gap) = gap {
            Self::keep_time(&mut mixer, &mut self.scratch, self.shared.engine, gap);
        }
        self.shared.live.store(open.generation, Ordering::Release);
        drop(mixer);
        self.shared
            .device_rate
            .store(open.format.sample_rate, Ordering::Release);
        self.shared
            .device_channels
            .store(u32::from(open.format.channels), Ordering::Release);
        self.shared.state.store(STATE_PLAYING, Ordering::Release);
    }

    /// Takes the mix back from a stream, so none of its callbacks renders again.
    fn let_go(&self) {
        // Poisoned or not, the lock is held across the store.
        let guard = self.shared.mixer.lock();
        self.shared.live.store(0, Ordering::Release);
        drop(guard);
        self.shared.device_rate.store(0, Ordering::Release);
        self.shared.device_channels.store(0, Ordering::Release);
    }

    /// Checks an open stream, and answers with the gap if it has gone.
    fn watch(&mut self, mut open: Open) -> Phase {
        let now = Instant::now();
        if self.shared.lost.load(Ordering::Acquire) >= open.generation {
            let reason = match self.shared.lost_reason.lock() {
                Ok(slot) if slot.0 == open.generation && !slot.1.is_empty() => slot.1.clone(),
                _ => "the output stream ended".to_string(),
            };
            return self.drop_stream(open, reason, now);
        }

        let count = self.shared.callbacks.load(Ordering::Acquire);
        if count != open.callbacks {
            open.callbacks = count;
            open.progressed = now;
            open.delivered = true;
        } else if now.duration_since(open.progressed) >= self.timing.stall {
            let reason = format!(
                "the output stopped asking for audio for {} ms",
                self.timing.stall.as_millis()
            );
            return self.drop_stream(open, reason, now);
        }

        let asked = self.shared.recheck.swap(false, Ordering::AcqRel);
        if asked || (self.host.polls_format() && now >= open.next_poll) {
            open.next_poll = now + self.timing.poll;
            // A device that cannot say what it is now is left to its stream:
            // an error or a stall will report it if it has really gone.
            if let Ok(format) = self.host.current() {
                if format != open.format {
                    let reason = format!(
                        "the output's format changed from {} to {}",
                        open.format.describe(),
                        format.describe()
                    );
                    return self.drop_stream(open, reason, now);
                }
            }
        }
        Phase::Playing(open)
    }

    /// Closes a lost stream and starts the gap.
    fn drop_stream(&mut self, open: Open, reason: String, now: Instant) -> Phase {
        self.let_go();
        let delivered =
            open.delivered || self.shared.callbacks.load(Ordering::Acquire) != open.callbacks;
        // The gap began at the stream's last callback, if it had one.
        let since = if delivered {
            let at = self.shared.last_callback.load(Ordering::Acquire);
            (self.shared.base + Duration::from_nanos(at)).min(now)
        } else {
            now
        };
        self.silent_streams = if delivered {
            0
        } else {
            self.silent_streams + 1
        };
        drop(open.stream);
        if let Ok(mut slot) = self.shared.reason.lock() {
            *slot = reason;
        }
        self.shared.drops.fetch_add(1, Ordering::AcqRel);
        self.shared.state.store(STATE_REOPENING, Ordering::Release);
        let mut gap = Gap {
            since,
            rendered: 0,
            attempts: self.silent_streams,
            delay: self.timing.first_retry,
            next_attempt: now + self.timing.first_retry,
            dormant: None,
            slow_retry: now,
        };
        if gap.attempts >= self.timing.attempts {
            gap.dormant = Some(self.host.current().ok());
            gap.slow_retry = now + self.timing.slow_retry;
            gap.next_attempt = now + self.timing.dormant_poll;
        }
        Phase::Down(gap)
    }

    /// Keeps the clock moving through the gap and tries for a new stream.
    fn recover(&mut self, mut gap: Gap) -> Phase {
        if let Ok(mut mixer) = self.shared.mixer.lock() {
            Self::keep_time(&mut mixer, &mut self.scratch, self.shared.engine, &mut gap);
        }

        let now = Instant::now();
        if now < gap.next_attempt {
            return Phase::Down(gap);
        }
        if let Some(seen) = gap.dormant {
            gap.next_attempt = now + self.timing.dormant_poll;
            let present = match self.host.current() {
                Err(_) => {
                    // Gone altogether, so its return counts as a device
                    // appearing even if it comes back as it was.
                    gap.dormant = Some(None);
                    return Phase::Down(gap);
                }
                Ok(format) => format,
            };
            if seen != Some(present) {
                // A device appeared, or the one there changed: start over.
                gap.dormant = None;
                gap.attempts = 0;
                gap.delay = self.timing.first_retry;
            } else if now >= gap.slow_retry {
                // The same device, still refusing: one attempt at the slow
                // cadence, so a device that recovers by itself is heard again.
                gap.slow_retry = now + self.timing.slow_retry;
            } else {
                return Phase::Down(gap);
            }
        }

        let opened = match self.host.current() {
            Err(_) => None,
            Ok(_) => self.open().ok(),
        };
        if let Some(open) = opened {
            self.go_live(&open, Some(&mut gap));
            self.shared.reopens.fetch_add(1, Ordering::AcqRel);
            return Phase::Playing(open);
        }
        gap.attempts += 1;
        if gap.attempts >= self.timing.attempts {
            if gap.dormant.is_none() {
                gap.dormant = Some(self.host.current().ok());
                gap.slow_retry = now + self.timing.slow_retry;
            }
            gap.next_attempt = now + self.timing.dormant_poll;
        } else {
            gap.next_attempt = now + gap.delay;
            gap.delay = (gap.delay * 2).min(self.timing.last_retry);
        }
        Phase::Down(gap)
    }

    /// Renders the mix the wall clock says the gap owes it, into nothing.
    fn keep_time(mixer: &mut Mixer, scratch: &mut [f32], engine: Format, gap: &mut Gap) {
        let rate = engine.sample_rate as u64;
        let width = (engine.channels as usize).max(1);
        let elapsed = gap.since.elapsed().as_nanos() as u64;
        let owed = (elapsed as u128 * rate as u128 / 1_000_000_000) as u64;
        let mut due = owed.saturating_sub(gap.rendered);
        let ceiling = rate * MAX_CATCH_UP_SECONDS;
        if due > ceiling {
            // Skip what is past the ceiling rather than render it.
            gap.rendered += due - ceiling;
            due = ceiling;
        }
        while due > 0 {
            let frames = (due as usize).min(KEEP_BLOCK);
            mixer.render(&mut scratch[..frames * width]);
            gap.rendered += frames as u64;
            due -= frames as u64;
        }
    }
}
