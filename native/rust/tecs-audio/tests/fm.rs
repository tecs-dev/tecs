//! An emulated FM chip as a voice of the mixer, with no audio device.
//!
//! The emulator is the ymfm-oxide crate, which holds itself to ymfm sample for
//! sample, and the scheduling grid is tested in `src/fm.rs`; this covers what lies between them and the output: the parked
//! source a `PLAY` takes, resampling from the chip's rate, the voice gain, and
//! a clock that stops with the voice.

use tecsaudio::command::{self, Command};
use tecsaudio::engine::Engine;
use tecsaudio::fm::{FmPort, Kind, RegisterWrite, RATE as CHIP_RATE};

const RATE: u32 = 48_000;

/// A held sine on channel 0 at 440 Hz, keyed on.
const NOTE: [(u16, u16); 8] = [
    (0x20, 0x01),
    (0x23, 0x21),
    (0x40, 0x3f),
    (0x43, 0x00),
    (0x63, 0xf0),
    (0x83, 0x0f),
    (0xa0, 0x41),
    (0xb0, 0x32),
];

fn command(kind: u32, handle: u32) -> Command {
    Command {
        kind,
        handle,
        clip: 0,
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

fn started(kind: Kind, gain: f32) -> (Engine, FmPort) {
    let engine = Engine::open_offline(RATE, 2, 8);
    let port = engine
        .open_fm(1, kind, kind.default_clock())
        .expect("the chip opens");
    let mut play = command(command::PLAY, 1);
    play.flags = command::FLAG_SYNTH;
    play.gain = gain;
    engine.submit(&[play]);
    assert_eq!(engine.voice_count(), 1);
    (engine, port)
}

fn note() -> Vec<RegisterWrite> {
    NOTE.iter()
        .map(|(register, value)| RegisterWrite {
            register: *register,
            value: *value,
        })
        .collect()
}

fn render(engine: &Engine, frames: usize) -> Vec<f32> {
    let mut out = vec![0.0f32; frames * 2];
    for chunk in out.chunks_mut(512 * 2) {
        engine.render(chunk);
    }
    out
}

fn onset(out: &[f32]) -> Option<usize> {
    out.iter()
        .position(|sample| *sample != 0.0)
        .map(|index| index / 2)
}

#[test]
fn starts_nothing_for_an_fm_play_with_no_chip_parked() {
    let engine = Engine::open_offline(RATE, 2, 8);
    let mut play = command(command::PLAY, 9);
    play.flags = command::FLAG_SYNTH;
    engine.submit(&[play]);
    assert_eq!(engine.voice_count(), 0);
}

#[test]
fn plays_a_scheduled_note_resampled_to_the_output() {
    let (engine, mut port) = started(Kind::Ym3812, 1.0);
    assert_eq!(port.now(), 0.0);
    // A tenth of a second in, on the chip clock.
    assert!(port.writes(&note(), 0.1, false));
    let out = render(&engine, 9600);
    let start = onset(&out).expect("the note sounds");
    // The chip lands the note on sample 4972 of its own clock, which the
    // voice reaches at output frame 4972 * 48000 / 49715, give or take the
    // resampler's one frame of interpolation.
    let expected = (4972.0 * f64::from(RATE) / f64::from(CHIP_RATE)) as usize;
    assert!(
        (expected..=expected + 2).contains(&start),
        "the note starts at {start}"
    );
    // Mono on both sides.
    assert!(out
        .as_chunks::<2>()
        .0
        .iter()
        .all(|frame| frame[0] == frame[1]));
    // The clock is chip samples, running at most a frame or two ahead of the
    // mix it fed.
    let rendered = port.frames() as f64 / f64::from(CHIP_RATE);
    assert!(
        (rendered - 9600.0 / f64::from(RATE)).abs() < 3.0 / f64::from(RATE),
        "{rendered}"
    );
}

#[test]
fn renders_the_same_schedule_to_the_same_samples() {
    let mut takes = Vec::new();
    for _ in 0..2 {
        let (engine, mut port) = started(Kind::Ymf262, 1.0);
        // NEW on, and channel 0 panned to both sides, which with NEW on it
        // has to be to sound at all.
        assert!(port.write(0x105, 0x01, 0.0));
        assert!(port.write(0xc0, 0x30, 0.0));
        for step in 0..4 {
            let at = f64::from(step) * 0.05;
            assert!(port.writes(&note(), at, false));
            assert!(port.write(0xa0, 0x41 + step as u8 * 0x20, at + 0.01));
            assert!(port.write(0xb0, 0x12, at + 0.04));
        }
        takes.push(render(&engine, RATE as usize / 4));
    }
    assert!(takes[0].iter().any(|sample| *sample != 0.0));
    assert_eq!(takes[0], takes[1]);
}

#[test]
fn scales_the_chip_by_its_voice_gain() {
    let mut levels = Vec::new();
    for gain in [1.0f32, 0.5, 0.0] {
        let (engine, mut port) = started(Kind::Ym3812, 1.0);
        let mut set = command(command::SET_GAIN, 1);
        set.gain = gain;
        engine.submit(&[set]);
        assert!(port.writes(&note(), 0.0, false));
        levels.push(render(&engine, 4800));
    }
    assert!(levels[0].iter().any(|sample| *sample != 0.0));
    for (full, half) in levels[0].iter().zip(levels[1].iter()) {
        assert!((full * 0.5 - half).abs() < 1e-6);
    }
    assert!(levels[2].iter().all(|sample| *sample == 0.0));
}

#[test]
fn holds_the_clock_while_the_voice_is_paused() {
    let (engine, port) = started(Kind::Ym3812, 1.0);
    render(&engine, 1024);
    let before = port.frames();
    assert!(before > 0);
    engine.submit(&[command(command::PAUSE, 1)]);
    render(&engine, 4800);
    assert_eq!(port.frames(), before, "a paused voice does not advance");
    engine.submit(&[command(command::RESUME, 1)]);
    render(&engine, 1024);
    assert!(port.frames() > before);
}

#[test]
fn plays_a_chip_at_a_rate_of_its_own_through_the_same_voice() {
    // A YM2612 at the Mega Drive's clock renders at 53 267 frames a second,
    // and the voice resamples it like any other rate.
    let (engine, mut port) = started(Kind::Ym2612, 1.0);
    assert_eq!(port.rate(), 53_267);
    let mut writes = vec![(0xb0, 0x07), (0xb4, 0xc0)];
    for operator in [0x00, 0x04, 0x08, 0x0c] {
        writes.push((0x30 + operator, 0x01));
        writes.push((0x40 + operator, 0x00));
        writes.push((0x50 + operator, 0x1f));
        writes.push((0x80 + operator, 0x0f));
    }
    writes.extend([(0xa4, 0x22), (0xa0, 0x69), (0x28, 0xf0)]);
    for (register, value) in writes {
        assert!(port.write(register, value, 0.05));
    }
    let out = render(&engine, 4800);
    // The YM2612's DAC holds a small offset on a silent chip, as the real
    // one's ladder effect does, so the onset is where the output leaves it.
    let rest = out[0];
    let start = out
        .iter()
        .position(|sample| (sample - rest).abs() > 0.01)
        .map(|index| index / 2)
        .expect("the note sounds");
    // Frame 2664 of the chip's clock, the first at or after 0.05 seconds.
    let expected = (2664.0 * f64::from(RATE) / 53_267.0) as usize;
    assert!(
        (expected..=expected + 2).contains(&start),
        "the note starts at {start}"
    );
}
