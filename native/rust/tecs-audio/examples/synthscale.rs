//! Plays a C major scale on the default output through the synthesizer.
//!
//! A manual check for a real machine, kept out of the test suite because it
//! opens the output device, which on macOS can block without bound when the
//! audio daemon is unreachable. It takes the SoundFont as its argument or from
//! `TECS_TEST_SOUNDFONT`, and says it skipped when given neither.
//!
//! ```text
//! cargo run -p tecs-audio --example synthscale -- path/to/FluidR3_GM.sf2
//! ```

use std::time::Duration;

use tecsaudio::command::{self, Command};
use tecsaudio::engine::Engine;
use tecsaudio::synth::Settings;

fn main() {
    let path = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("TECS_TEST_SOUNDFONT").ok());
    let Some(path) = path else {
        eprintln!("skipped: name a SoundFont as the argument or in TECS_TEST_SOUNDFONT");
        return;
    };

    let engine = Engine::open(48_000, 2, 8);
    if !engine.available() {
        eprintln!("no output device: {}", engine.last_error());
    }
    let font = match engine.load_sound_font(&path) {
        Ok(font) => font,
        Err(reason) => {
            eprintln!("{reason}");
            std::process::exit(1);
        }
    };
    let handle = 1;
    let mut port = engine
        .open_synth(font, handle, &Settings::default())
        .expect("the synthesizer opens");
    engine.submit(&[Command {
        kind: command::PLAY,
        handle,
        clip: 0,
        flags: command::FLAG_SYNTH,
        gain: 1.0,
        pitch: 1.0,
        start: 0.0,
        fade: 0.0,
        loop_start: 0.0,
        x: 0.0,
        y: 0.0,
        z: 0.0,
    }]);

    // Scheduled ahead in one go, a quarter of a second apart, against the
    // synthesizer clock rather than against when this thread wakes up.
    let start = port.now() + 0.1;
    let keys = [60u8, 62, 64, 65, 67, 69, 71, 72];
    for (step, key) in keys.iter().enumerate() {
        let at = start + step as f64 * 0.25;
        port.send(0x90, *key, 100, at);
        port.send(0x80, *key, 0, at + 0.22);
    }
    std::thread::sleep(Duration::from_millis(3000));
    eprintln!(
        "played {} notes; the synthesizer clock reads {:.3} s",
        keys.len(),
        port.now()
    );
}
