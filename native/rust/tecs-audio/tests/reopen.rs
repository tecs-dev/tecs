//! An output that survives its device changing under it.
//!
//! A fake host stands in for the platform: its device can change rate and
//! channel count mid-stream (reporting it the way a device-pinned CoreAudio
//! stream does, or not at all, the way a default-output one can), stop calling
//! back, disappear and come back. The engine is opened against it exactly as
//! against `cpal`, and what the fake device heard is what these check.
//!
//! The fake's callback thread counts every allocation made inside the feed, and
//! every test ends by checking that count is still zero.

use std::alloc::{GlobalAlloc, Layout, System};
use std::any::Any;
use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tecsaudio::command::{self, Command, Event};
use tecsaudio::conform::Format;
use tecsaudio::engine::Engine;
use tecsaudio::output::{Host, Tap, Timing, STATE_PLAYING, STATE_REOPENING};

/// Counts the allocations a thread makes while its flag is up.
struct Counting;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
}

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

fn note() {
    if COUNTING.try_with(Cell::get).unwrap_or(false) {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    }
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note();
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note();
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        note();
        unsafe { System.realloc(pointer, layout, size) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

const STEREO_48K: Format = Format {
    sample_rate: 48_000,
    channels: 2,
};

const MONO_24K: Format = Format {
    sample_rate: 24_000,
    channels: 1,
};

const MONO_16K: Format = Format {
    sample_rate: 16_000,
    channels: 1,
};

/// How the fake device behaves when its format moves under an open stream.
#[derive(Clone, Copy, PartialEq)]
enum Change {
    /// Reports the stream lost and stops, as a device-pinned CoreAudio stream
    /// does on a nominal-rate change.
    Invalidate,
    /// Keeps calling at the old format and says nothing, as a default-output
    /// unit converting internally can.
    Silent,
}

/// The fake device, as the test drives it.
struct DeviceState {
    /// The format it runs at, and `None` while it is detached.
    format: Option<Format>,
    change: Change,
    /// Set to stop calling back without a word.
    stalled: bool,
    /// Set to refuse every open.
    refuse: bool,
}

/// What the test and the fake host share.
struct Control {
    state: Mutex<DeviceState>,
    opens: AtomicU32,
    /// Every stream the device opened, with what it heard.
    heard: Mutex<Vec<(Format, Vec<f32>)>>,
}

impl Control {
    fn new(format: Format) -> Arc<Control> {
        Arc::new(Control {
            state: Mutex::new(DeviceState {
                format: Some(format),
                change: Change::Invalidate,
                stalled: false,
                refuse: false,
            }),
            opens: AtomicU32::new(0),
            heard: Mutex::new(Vec::new()),
        })
    }

    fn set(&self, change: impl FnOnce(&mut DeviceState)) {
        change(&mut self.state.lock().unwrap());
    }

    /// The last `count` samples the newest stream heard, and its format.
    fn tail(&self, count: usize) -> (Format, Vec<f32>) {
        let heard = self.heard.lock().unwrap();
        let (format, samples) = heard.last().expect("a stream opened");
        let from = samples.len().saturating_sub(count);
        (*format, samples[from..].to_vec())
    }

    fn streams(&self) -> usize {
        self.heard.lock().unwrap().len()
    }
}

struct FakeHost {
    control: Arc<Control>,
}

/// A fake stream: its callback thread, stopped and joined on drop.
struct FakeStream {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for FakeStream {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Host for FakeHost {
    fn current(&mut self) -> Result<Format, String> {
        self.control
            .state
            .lock()
            .unwrap()
            .format
            .ok_or_else(|| "no device attached".to_string())
    }

    fn open(&mut self, tap: Tap) -> Result<(Box<dyn Any>, Format), String> {
        self.control.opens.fetch_add(1, Ordering::AcqRel);
        let format = {
            let state = self.control.state.lock().unwrap();
            if state.refuse {
                return Err("the device refused the stream".to_string());
            }
            state
                .format
                .ok_or_else(|| "no device attached".to_string())?
        };
        let mut feed = tap.feed(format);
        let alarm = tap.alarm();
        let stop = Arc::new(AtomicBool::new(false));
        let control = Arc::clone(&self.control);
        let index = {
            let mut heard = control.heard.lock().unwrap();
            heard.push((format, Vec::new()));
            heard.len() - 1
        };
        let halt = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            // An odd buffer size, so the conformer's passes never line up
            // with it.
            let frames = 300;
            let mut buffer = vec![0.0f32; frames * format.channels as usize];
            let period = Duration::from_secs_f64(frames as f64 / format.sample_rate as f64);
            while !halt.load(Ordering::Acquire) {
                let (now, change, stalled) = {
                    let state = control.state.lock().unwrap();
                    (state.format, state.change, state.stalled)
                };
                match now {
                    None => {
                        alarm.lost("Device disconnected");
                        return;
                    }
                    Some(value) if value != format && change == Change::Invalidate => {
                        alarm.lost("Device sample rate changed");
                        return;
                    }
                    _ => {}
                }
                if stalled {
                    thread::sleep(period);
                    continue;
                }
                COUNTING.with(|flag| flag.set(true));
                feed.fill(&mut buffer, |value| value);
                COUNTING.with(|flag| flag.set(false));
                control.heard.lock().unwrap()[index]
                    .1
                    .extend_from_slice(&buffer);
                thread::sleep(period);
            }
        });
        Ok((
            Box::new(FakeStream {
                stop,
                thread: Some(thread),
            }),
            format,
        ))
    }
}

/// Fast enough that a test takes a fraction of a second per change.
fn timing() -> Timing {
    Timing {
        tick: Duration::from_millis(2),
        poll: Duration::from_millis(20),
        stall: Duration::from_millis(200),
        first_retry: Duration::from_millis(5),
        last_retry: Duration::from_millis(40),
        attempts: 4,
        dormant_poll: Duration::from_millis(20),
        slow_retry: Duration::from_secs(60),
    }
}

fn open(control: &Arc<Control>) -> Engine {
    let shared = Arc::clone(control);
    let engine = Engine::open_with(
        move || Ok(FakeHost { control: shared }),
        timing(),
        48_000,
        2,
        8,
    );
    assert!(engine.available(), "the fake output opens");
    engine
}

/// A WAV of one second of stereo 16-bit PCM at a constant half-scale level.
fn level_wav() -> Vec<u8> {
    let frames: u32 = 48_000;
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + frames * 4).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&48_000u32.to_le_bytes());
    bytes.extend_from_slice(&192_000u32.to_le_bytes());
    bytes.extend_from_slice(&4u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(frames * 4).to_le_bytes());
    for _ in 0..frames * 2 {
        bytes.extend_from_slice(&16_384i16.to_le_bytes());
    }
    bytes
}

fn play(handle: u32, looping: bool) -> Command {
    Command {
        kind: command::PLAY,
        handle,
        clip: 1,
        flags: if looping { command::FLAG_LOOP } else { 0 },
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

/// Starts a looping half-scale level, so every stream should hear 0.5.
fn start_level(engine: &Engine) {
    engine
        .load_clip_bytes("level.wav", &level_wav(), 1)
        .expect("the level decodes");
    engine.submit(&[play(65_537, true)]);
}

fn wait_until(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        thread::sleep(Duration::from_millis(2));
    }
}

/// Waits for the newest stream to have heard the level for a while.
fn hears_the_level(control: &Control, format: Format) {
    wait_until("the newest stream hears the level", || {
        let (heard, tail) = control.tail(600);
        heard == format
            && tail.len() == 600
            && tail.iter().all(|value| (*value - 0.5).abs() < 2.0e-3)
    });
}

fn no_callback_allocated() {
    assert_eq!(
        ALLOCATIONS.load(Ordering::Relaxed),
        0,
        "an output callback allocated"
    );
}

#[test]
fn reopens_at_each_new_format_and_back_with_the_mix_unchanged() {
    let control = Control::new(STEREO_48K);
    let engine = open(&control);
    start_level(&engine);
    hears_the_level(&control, STEREO_48K);
    assert_eq!(engine.output_format(), Some(STEREO_48K));

    // The headset turns its microphone on.
    control.set(|state| state.format = Some(MONO_24K));
    wait_until("the output reopens at 24 kHz mono", || {
        engine.output_reopens() == 1 && engine.output_format() == Some(MONO_24K)
    });
    hears_the_level(&control, MONO_24K);
    assert_eq!(engine.output_drops(), 1);
    // Whichever saw it first: the stream's own report, or the format poll.
    let reason = engine.output_reason();
    assert!(
        reason.contains("Device sample rate changed") || reason.contains("format changed"),
        "the reason was {reason:?}"
    );

    // And off again.
    control.set(|state| state.format = Some(STEREO_48K));
    wait_until("the output reopens at 48 kHz stereo", || {
        engine.output_reopens() == 2 && engine.output_format() == Some(STEREO_48K)
    });
    hears_the_level(&control, STEREO_48K);

    assert_eq!(engine.output_state(), STATE_PLAYING);
    assert!(engine.available() && !engine.failed());
    // The mix never moved.
    assert_eq!(engine.sample_rate(), 48_000);
    assert_eq!(engine.channels(), 2);
    assert_eq!(engine.voice_count(), 1);
    no_callback_allocated();
}

#[test]
fn finds_a_format_change_nothing_reported_by_polling() {
    let control = Control::new(STEREO_48K);
    control.set(|state| state.change = Change::Silent);
    let engine = open(&control);
    start_level(&engine);
    hears_the_level(&control, STEREO_48K);

    control.set(|state| state.format = Some(MONO_16K));
    wait_until("the output reopens at 16 kHz mono", || {
        engine.output_format() == Some(MONO_16K)
    });
    hears_the_level(&control, MONO_16K);
    assert_eq!(
        engine.output_reason(),
        "the output's format changed from 48000 Hz, 2 channels to 16000 Hz, 1 channel"
    );
    no_callback_allocated();
}

#[test]
fn replaces_a_stream_that_stops_calling_back() {
    let control = Control::new(STEREO_48K);
    let engine = open(&control);
    start_level(&engine);
    hears_the_level(&control, STEREO_48K);

    let before = engine.now();
    let wall = Instant::now();
    control.set(|state| state.stalled = true);
    wait_until("the stalled stream is dropped", || {
        engine.output_drops() == 1
    });
    assert!(engine.output_reason().contains("stopped asking for audio"));
    control.set(|state| state.stalled = false);
    wait_until("a new stream opens", || engine.output_reopens() == 1);
    hears_the_level(&control, STEREO_48K);
    // The gap is counted from the last callback, not from when the stall was
    // noticed, so the clock lost nothing to the stall timeout either.
    let advanced = engine.now() - before;
    let elapsed = wall.elapsed().as_secs_f64();
    assert!(
        advanced > elapsed * 0.8 && advanced < elapsed + 0.05,
        "the clock moved {advanced} s in {elapsed} s across a stall"
    );
    no_callback_allocated();
}

#[test]
fn keeps_the_clock_running_while_the_device_is_gone_and_resumes_when_it_returns() {
    let control = Control::new(STEREO_48K);
    let opened = Instant::now();
    let engine = open(&control);
    start_level(&engine);
    hears_the_level(&control, STEREO_48K);

    control.set(|state| state.format = None);
    wait_until("the output drops", || {
        engine.output_state() == STATE_REOPENING
    });
    assert!(engine.output_reason().contains("Device disconnected"));
    assert_eq!(engine.output_format(), None);

    let before = engine.now();
    let wall = Instant::now();
    thread::sleep(Duration::from_millis(300));
    let advanced = engine.now() - before;
    let elapsed = wall.elapsed().as_secs_f64();
    assert!(
        advanced > elapsed * 0.8 && advanced < elapsed * 1.2,
        "the clock moved {advanced} s in {elapsed} s with no device"
    );
    assert_eq!(engine.output_state(), STATE_REOPENING);

    control.set(|state| state.format = Some(MONO_24K));
    wait_until("the output reopens", || engine.output_reopens() == 1);
    hears_the_level(&control, MONO_24K);
    assert_eq!(engine.output_state(), STATE_PLAYING);

    // The clock tracked the wall clock across the whole run, gap included.
    let total = opened.elapsed().as_secs_f64();
    let clock = engine.now();
    // A device renders a buffer ahead of what it has played, hence the margin.
    assert!(
        clock > total * 0.8 && clock < total + 0.05,
        "the clock reads {clock} s after {total} s"
    );
    assert_eq!(
        engine.voice_count(),
        1,
        "the looping level is still sounding"
    );
    no_callback_allocated();
}

#[test]
fn reports_a_voice_finished_in_the_gap() {
    let control = Control::new(STEREO_48K);
    let engine = open(&control);
    engine
        .load_clip_bytes("level.wav", &level_wav(), 1)
        .expect("the level decodes");
    control.set(|state| state.format = None);
    wait_until("the output drops", || {
        engine.output_state() == STATE_REOPENING
    });

    let mut short = play(65_537, false);
    short.start = 0.9;
    engine.submit(&[short]);
    // A tenth of a second of clip, which only the supervisor's rendering can
    // run out while no device is attached.
    let mut out = [Event { kind: 0, handle: 0 }; 8];
    let mut seen = false;
    wait_until("the one-shot finishes with no device", || {
        let count = engine.drain(&mut out);
        seen |= out[..count].iter().any(|event| event.handle == 65_537);
        seen
    });
    assert_eq!(engine.output_state(), STATE_REOPENING);
    no_callback_allocated();
}

#[test]
fn stops_retrying_a_refusing_device_and_recovers_when_another_appears() {
    let control = Control::new(STEREO_48K);
    let engine = open(&control);
    start_level(&engine);
    hears_the_level(&control, STEREO_48K);

    control.set(|state| {
        state.refuse = true;
        state.format = Some(MONO_24K);
    });
    wait_until("the output drops", || engine.output_drops() == 1);
    // The first open, then the bounded attempts, then nothing.
    let bounded = 1 + timing().attempts;
    wait_until("the attempts run out", || {
        control.opens.load(Ordering::Acquire) == bounded
    });
    thread::sleep(Duration::from_millis(200));
    assert_eq!(control.opens.load(Ordering::Acquire), bounded);
    assert_eq!(engine.output_state(), STATE_REOPENING);
    assert!(!engine.failed(), "a dormant output has not failed");

    // The device goes, and a different one comes.
    control.set(|state| {
        state.refuse = false;
        state.format = None;
    });
    thread::sleep(Duration::from_millis(60));
    control.set(|state| state.format = Some(STEREO_48K));
    wait_until("the new device is opened", || engine.output_reopens() == 1);
    hears_the_level(&control, STEREO_48K);
    assert_eq!(control.streams(), 2);
    no_callback_allocated();
}
