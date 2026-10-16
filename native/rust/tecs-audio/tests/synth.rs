//! The General MIDI synthesizer as a voice of the mixer, with no audio device.
//!
//! The tests that render real notes need a SoundFont, and none ships in the
//! tree: General MIDI sets are tens of megabytes and more. They read the one
//! `TECS_TEST_SOUNDFONT` names and skip, saying so, when it names nothing. The
//! scheduling grid itself is covered without one in `src/synth.rs`.

use std::sync::OnceLock;

use tecsaudio::command::{self, Command};
use tecsaudio::engine::Engine;
use tecsaudio::synth::{Port, Settings, BLOCK_FRAMES};

const RATE: u32 = 48_000;

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

fn play_synth(handle: u32, gain: f32) -> Command {
    let mut play = command(command::PLAY, handle);
    play.flags = command::FLAG_SYNTH;
    play.gain = gain;
    play
}

/// Names the SoundFont the environment points at, or nil to skip.
fn sound_font() -> Option<&'static str> {
    static PATH: OnceLock<Option<String>> = OnceLock::new();
    PATH.get_or_init(|| {
        let path = std::env::var("TECS_TEST_SOUNDFONT").ok()?;
        std::path::Path::new(&path).is_file().then_some(path)
    })
    .as_deref()
}

/// Opens an offline engine with one synthesizer started on voice `handle`.
fn started(path: &str, handle: u32, gain: f32) -> (Engine, Port) {
    started_with(path, handle, gain, &Settings::default())
}

fn started_with(path: &str, handle: u32, gain: f32, settings: &Settings) -> (Engine, Port) {
    let engine = Engine::open_offline(RATE, 2, 8);
    let font = engine.load_sound_font(path).expect("the SoundFont loads");
    let port = engine
        .open_synth(font, handle, settings)
        .expect("the synthesizer opens");
    engine.submit(&[play_synth(handle, gain)]);
    assert_eq!(engine.voice_count(), 1);
    (engine, port)
}

fn render(engine: &Engine, frames: usize) -> Vec<f32> {
    let mut out = vec![0.0f32; frames * 2];
    // In device-sized pieces, the way an output callback asks.
    for chunk in out.chunks_mut(512 * 2) {
        engine.render(chunk);
    }
    out
}

/// Returns the first frame holding any sound.
fn onset(out: &[f32]) -> Option<usize> {
    out.iter()
        .position(|sample| *sample != 0.0)
        .map(|index| index / 2)
}

#[test]
fn starts_nothing_for_a_synth_play_with_no_synthesizer_parked() {
    let engine = Engine::open_offline(RATE, 2, 8);
    engine.submit(&[play_synth(7, 1.0)]);
    assert_eq!(engine.voice_count(), 0);
    assert!(engine.open_synth(404, 7, &Settings::default()).is_err());
    assert!(!engine.last_error().is_empty());
}

#[test]
fn refuses_a_soundfont_path_that_names_nothing() {
    let engine = Engine::open_offline(RATE, 2, 8);
    assert!(engine.load_sound_font("no/such/font.sf2").is_err());
    assert!(engine.last_error().contains("cannot open"));
}

#[test]
fn lands_a_scheduled_note_on_its_block_and_runs_the_clock_with_the_mix() {
    let Some(path) = sound_font() else {
        eprintln!("skipped: TECS_TEST_SOUNDFONT names no SoundFont");
        return;
    };
    // Without reverb and chorus, whose LFO runs on the clock, a note is the
    // same samples wherever it starts, so a late one can be compared against
    // one at zero frame by frame.
    let dry = Settings {
        effects: false,
        ..Settings::default()
    };
    let (engine, mut port) = started_with(path, 1, 1.0, &dry);
    assert_eq!(port.now(), 0.0);
    assert!(port.send(0x90, 60, 110, 0.0));
    let reference = render(&engine, 9600);

    // A tenth of a second in is frame 4800, which is on the grid, so the note
    // lands on exactly that frame.
    let at = 4800;
    assert_eq!(at % BLOCK_FRAMES, 0);
    let (engine, mut port) = started_with(path, 1, 1.0, &dry);
    assert!(port.send(0x90, 60, 110, at as f64 / RATE as f64));
    let out = render(&engine, 9600);
    assert!(out[..at * 2].iter().all(|sample| *sample == 0.0));
    assert!(onset(&out).is_some(), "the note sounds");
    assert_eq!(&out[at * 2..], &reference[..(9600 - at) * 2]);

    // The clock is what the voice rendered, which runs at most one block
    // ahead of the mix it fed.
    let rendered = port.frames() as usize;
    assert!(
        (9600..=9600 + BLOCK_FRAMES).contains(&rendered),
        "{rendered}"
    );
}

#[test]
fn renders_the_same_schedule_to_the_same_samples() {
    let Some(path) = sound_font() else {
        eprintln!("skipped: TECS_TEST_SOUNDFONT names no SoundFont");
        return;
    };
    let mut takes = Vec::new();
    for _ in 0..2 {
        let (engine, mut port) = started(path, 1, 1.0);
        for (step, key) in [60u8, 62, 64, 65].iter().enumerate() {
            let at = step as f64 * 0.05;
            assert!(port.send(0x90, *key, 100, at));
            assert!(port.send(0x80, *key, 0, at + 0.04));
        }
        takes.push(render(&engine, RATE as usize / 4));
    }
    assert!(takes[0].iter().any(|sample| *sample != 0.0));
    assert_eq!(takes[0], takes[1]);
}

#[test]
fn scales_the_synthesizer_by_its_voice_gain() {
    let Some(path) = sound_font() else {
        eprintln!("skipped: TECS_TEST_SOUNDFONT names no SoundFont");
        return;
    };
    // The policy above composes group gain and mute into the voice gain, so
    // a voice gain is what a group setting reaches the synthesizer as.
    let mut levels = Vec::new();
    for gain in [1.0f32, 0.5, 0.0] {
        let (engine, mut port) = started(path, 1, 1.0);
        let mut set = command(command::SET_GAIN, 1);
        set.gain = gain;
        engine.submit(&[set]);
        assert!(port.send(0x90, 60, 110, 0.0));
        levels.push(render(&engine, 4800));
    }
    for (full, half) in levels[0].iter().zip(levels[1].iter()) {
        assert!((full * 0.5 - half).abs() < 1e-6);
    }
    assert!(levels[2].iter().all(|sample| *sample == 0.0));
}

#[test]
fn cuts_every_note_at_once_and_releases_them_otherwise() {
    let Some(path) = sound_font() else {
        eprintln!("skipped: TECS_TEST_SOUNDFONT names no SoundFont");
        return;
    };
    // Without reverb and chorus nothing rings past a note, so a cut is exact.
    let dry = Settings {
        effects: false,
        ..Settings::default()
    };
    let (engine, mut port) = started_with(path, 1, 1.0, &dry);
    assert!(port.send(0x90, 60, 110, 0.0));
    render(&engine, 4800);
    assert!(port.notes_off(None, true));
    let cut = render(&engine, 4800);
    let first_silent = BLOCK_FRAMES * 2;
    assert!(
        cut[first_silent * 2..].iter().all(|sample| *sample == 0.0),
        "an immediate cut silences the next block on"
    );

    let (engine, mut port) = started_with(path, 1, 1.0, &dry);
    assert!(port.send(0x90, 60, 110, 0.0));
    render(&engine, 4800);
    assert!(port.notes_off(Some(0), false));
    let released = render(&engine, 4800);
    assert!(
        released[first_silent * 2..]
            .iter()
            .any(|sample| *sample != 0.0),
        "a release still sounds as it fades"
    );

    let (engine, mut port) = started(path, 1, 1.0);
    // A reset discards a note scheduled before it.
    assert!(port.send(0x90, 60, 110, 0.05));
    assert!(port.reset());
    let after = render(&engine, 9600);
    assert!(after.iter().all(|sample| *sample == 0.0));
}

#[test]
fn holds_the_clock_while_the_voice_is_paused() {
    let Some(path) = sound_font() else {
        eprintln!("skipped: TECS_TEST_SOUNDFONT names no SoundFont");
        return;
    };
    let (engine, port) = started(path, 1, 1.0);
    render(&engine, 1024);
    let before = port.frames();
    engine.submit(&[command(command::PAUSE, 1)]);
    render(&engine, 4800);
    assert_eq!(port.frames(), before, "a paused voice does not advance");
    engine.submit(&[command(command::RESUME, 1)]);
    render(&engine, 1024);
    assert!(port.frames() > before);
}
