//! Plays a tone on the default output and logs every change to it.
//!
//! A manual check for a real machine, kept out of the test suite because a
//! device is exactly what the suite is not allowed to need. Start it, then put
//! a Bluetooth headset through what breaks streams: turn its microphone on (a
//! call, a dictation, a voice memo), off again, take the headset off, switch
//! the output in the menu bar. Each change is logged with the format the device
//! reports and what the engine did about it, and the tone should come back
//! after each one while the mixer's clock keeps moving through the gap.
//!
//! ```text
//! cargo run -p tecs-audio --example reopencheck -- [seconds] [gain]
//! ```
//!
//! `gain` scales the tone, one by default; zero runs the same path silently.

use std::time::{Duration, Instant};

use tecsaudio::command::{self, Command};
use tecsaudio::device::CpalHost;
use tecsaudio::engine::Engine;
use tecsaudio::output::{Host, STATE_FAILED, STATE_OFFLINE, STATE_PLAYING, STATE_REOPENING};

const RATE: u32 = 48_000;

/// One second of a quiet 440 Hz sine, stereo 16-bit, which loops without a seam
/// because a second holds a whole number of its cycles.
fn tone() -> Vec<u8> {
    let frames = RATE;
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + frames * 4).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&RATE.to_le_bytes());
    bytes.extend_from_slice(&(RATE * 4).to_le_bytes());
    bytes.extend_from_slice(&4u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(frames * 4).to_le_bytes());
    for frame in 0..frames {
        let phase = 2.0 * std::f64::consts::PI * 440.0 * frame as f64 / RATE as f64;
        let sample = (phase.sin() * 0.15 * i16::MAX as f64) as i16;
        bytes.extend_from_slice(&sample.to_le_bytes());
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    bytes
}

fn state_name(state: u32) -> &'static str {
    match state {
        STATE_OFFLINE => "offline",
        STATE_PLAYING => "playing",
        STATE_REOPENING => "reopening",
        STATE_FAILED => "failed",
        _ => "unknown",
    }
}

fn main() {
    let seconds: u64 = std::env::args()
        .nth(1)
        .and_then(|value| value.parse().ok())
        .unwrap_or(300);
    let gain: f32 = std::env::args()
        .nth(2)
        .and_then(|value| value.parse().ok())
        .unwrap_or(1.0);

    let started = Instant::now();
    let stamp = || format!("[{:8.3}]", started.elapsed().as_secs_f64());

    let engine = Engine::open(RATE, 2, 8);
    if !engine.available() {
        eprintln!("{} no output: {}", stamp(), engine.last_error());
        std::process::exit(1);
    }
    let describe = |engine: &Engine| {
        engine
            .output_format()
            .map_or("none".to_string(), |format| format.describe())
    };
    eprintln!(
        "{} mix at {} Hz, {} channels; stream at {}",
        stamp(),
        engine.sample_rate(),
        engine.channels(),
        describe(&engine)
    );

    engine
        .load_clip_bytes("tone.wav", &tone(), 1)
        .expect("the tone decodes");
    engine.submit(&[Command {
        kind: command::PLAY,
        handle: 65_537,
        clip: 1,
        flags: command::FLAG_LOOP,
        gain,
        pitch: 1.0,
        start: 0.0,
        fade: 0.0,
        loop_start: 0.0,
        x: 0.0,
        y: 0.0,
        z: 0.0,
    }]);

    // A second host, asked directly, so the log shows what the device reports
    // beside what the engine made of it.
    let mut probe = CpalHost::new().expect("the default host");
    let mut device = probe.current();
    eprintln!("{} device reports {}", stamp(), show(&device));

    let mut state = engine.output_state();
    let mut drops = engine.output_drops();
    let mut reopens = engine.output_reopens();
    let mut last_clock = Instant::now();
    let deadline = started + Duration::from_secs(seconds);
    eprintln!("{} playing for {seconds} s; change the output now", stamp());
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));

        let reported = probe.current();
        if !same(&reported, &device) {
            eprintln!(
                "{} device format changed: {} -> {}",
                stamp(),
                show(&device),
                show(&reported)
            );
            device = reported;
        }
        if engine.output_drops() != drops {
            drops = engine.output_drops();
            eprintln!(
                "{} output dropped (#{drops}): {}",
                stamp(),
                engine.output_reason()
            );
        }
        if engine.output_reopens() != reopens {
            reopens = engine.output_reopens();
            eprintln!(
                "{} output reopened (#{reopens}) at {}",
                stamp(),
                describe(&engine)
            );
        }
        if engine.output_state() != state {
            state = engine.output_state();
            eprintln!("{} output state: {}", stamp(), state_name(state));
        }
        if last_clock.elapsed() >= Duration::from_secs(5) {
            last_clock = Instant::now();
            eprintln!(
                "{} mixer clock {:.3} s, state {}, stream {}",
                stamp(),
                engine.now(),
                state_name(engine.output_state()),
                describe(&engine)
            );
        }
    }
    eprintln!(
        "{} done: {drops} drops, {reopens} reopens, mixer clock {:.3} s",
        stamp(),
        engine.now()
    );
}

fn show(reported: &Result<tecsaudio::conform::Format, String>) -> String {
    match reported {
        Ok(format) => format.describe(),
        Err(reason) => format!("no output ({reason})"),
    }
}

fn same(
    a: &Result<tecsaudio::conform::Format, String>,
    b: &Result<tecsaudio::conform::Format, String>,
) -> bool {
    match (a, b) {
        (Ok(left), Ok(right)) => left == right,
        (Err(_), Err(_)) => true,
        _ => false,
    }
}
