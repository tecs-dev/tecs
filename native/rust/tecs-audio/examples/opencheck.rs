//! Opens the default output and reports what it settled on.
//!
//! A manual smoke check for a real machine, kept out of the test suite because
//! a device is exactly what the suite is not allowed to need.

fn main() {
    eprintln!("opening the default output");
    let engine = tecsaudio::engine::Engine::open(48_000, 2, 8);
    eprintln!(
        "available={} rate={} channels={}",
        engine.available(),
        engine.sample_rate(),
        engine.channels()
    );
    if !engine.available() {
        eprintln!("reason: {}", engine.last_error());
    }
}
