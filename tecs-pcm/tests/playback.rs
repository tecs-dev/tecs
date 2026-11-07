//! End-to-end playback with no audio device.
//!
//! These drive the whole path a game takes: a file on disk, a load that picks
//! residency, a command batch crossing the seam, rendered frames, and the
//! finished voice coming back. They need no output device and no assets in the
//! tree, because the WAV they read is written here first.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use std::cell::RefCell;
use std::collections::HashMap;
use tecsaudio::command::{self, Command, Event};

use tecs_pcm::{MODE_AUTO, MODE_RESIDENT, MODE_STREAM};
use tecsaudio::engine::Engine;

const RATE: u32 = 48_000;

/// Names one temporary file per test, so a parallel run does not collide.
static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A WAV file this test wrote, removed when the test ends.
struct Fixture {
    path: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// Writes a stereo 16-bit WAV holding `frames` of a constant sample.
fn write_wav(frames: usize, value: i16) -> Fixture {
    let index = COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("tecs-audio-playback-{index}-{frames}.wav"));

    let channels: u16 = 2;
    let bits: u16 = 16;
    let block_align = channels * bits / 8;
    let data_len = frames as u32 * block_align as u32;

    let mut bytes: Vec<u8> = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&channels.to_le_bytes());
    bytes.extend_from_slice(&RATE.to_le_bytes());
    bytes.extend_from_slice(&(RATE * block_align as u32).to_le_bytes());
    bytes.extend_from_slice(&block_align.to_le_bytes());
    bytes.extend_from_slice(&bits.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    for _ in 0..frames {
        bytes.extend_from_slice(&value.to_le_bytes());
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    fs::write(&path, &bytes).expect("the temporary directory is writable");

    Fixture { path }
}

/// What a load reports, as the engine's own clip table used to.
struct Loaded {
    resident: bool,
    duration: f64,
}

/// An offline engine with the PCM Decoder registered, and the clips the test
/// loaded through `tecs-pcm`, by the number the test calls them.
struct Rig {
    engine: Engine,
    decoder: u32,
    clips: RefCell<HashMap<u32, u64>>,
}

impl Rig {
    fn new() -> Rig {
        let engine = Engine::open_offline(RATE, 2, 8);
        let decoder = unsafe { engine.register_decoder(tecs_pcm::tecs_pcm_decoder()) }
            .expect("the PCM vtable");
        Rig {
            engine,
            decoder,
            clips: RefCell::new(HashMap::new()),
        }
    }

    fn load_clip(
        &self,
        path: &str,
        clip: u32,
        mode: u32,
        stream_seconds: f32,
    ) -> Result<Loaded, String> {
        let (id, info) = tecs_pcm::load(path, mode, stream_seconds)?;
        self.clips.borrow_mut().insert(clip, id);
        Ok(Loaded {
            resident: info.resident != 0,
            duration: info.duration,
        })
    }

    fn release_clip(&self, clip: u32) {
        if let Some(id) = self.clips.borrow_mut().remove(&clip) {
            tecs_pcm::tecs_pcm_release(id);
        }
    }

    /// Opens a Playback through the Decoder for every PLAY, then submits.
    fn submit(&self, commands: &[Command]) {
        let mut sent = Vec::with_capacity(commands.len());
        for entry in commands {
            let mut entry = *entry;
            if entry.kind == command::PLAY {
                let id = self.clips.borrow().get(&entry.clip).copied().unwrap_or(0);
                let params = tecs_pcm::Params { clip: id };
                let bytes = unsafe {
                    std::slice::from_raw_parts(
                        &params as *const tecs_pcm::Params as *const u8,
                        std::mem::size_of::<tecs_pcm::Params>(),
                    )
                };
                let _ = self
                    .engine
                    .open_decoded(self.decoder, entry.handle, bytes, &[]);
                entry.flags |= command::FLAG_SYNTH;
            }
            sent.push(entry);
        }
        self.engine.submit(&sent);
    }

    fn render(&self, out: &mut [f32]) -> usize {
        self.engine.render(out)
    }

    fn drain(&self, out: &mut [Event]) -> usize {
        self.engine.drain(out)
    }

    fn voice_count(&self) -> usize {
        self.engine.voice_count()
    }
}

/// Builds the command Tecs sends to start a voice.
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

/// Collects every finished handle waiting on the engine.
fn finished(engine: &Rig) -> Vec<u32> {
    let mut out = [Event { kind: 0, handle: 0 }; 16];
    let count = engine.drain(&mut out);
    out[..count].iter().map(|event| event.handle).collect()
}

/// Renders until the mix carries sound, or gives up.
fn wait_for_sound(engine: &Rig, frames: usize) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let mut buffer = vec![0.0f32; frames * 2];
        engine.render(&mut buffer);
        if buffer.iter().any(|value| *value != 0.0) {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    false
}

#[test]
fn plays_a_resident_clip_from_a_file_and_reports_it_finished() {
    let fixture = write_wav(RATE as usize / 10, 16_000);
    let engine = Rig::new();

    let loaded = engine
        .load_clip(
            fixture.path.to_str().expect("the path is UTF-8"),
            1,
            MODE_RESIDENT,
            10.0,
        )
        .expect("the generated WAV loads");
    assert!(loaded.resident);
    assert!(
        (loaded.duration - 0.1).abs() < 0.01,
        "got {}",
        loaded.duration
    );

    engine.submit(&[play(65_537, 1)]);
    assert_eq!(engine.voice_count(), 1);

    let mut buffer = vec![0.0f32; 2 * 256];
    engine.render(&mut buffer);
    assert!(buffer.iter().any(|value| *value > 0.4), "the clip is heard");
    assert!(finished(&engine).is_empty());

    // Past the clip's length, so the voice runs out inside this buffer.
    let mut rest = vec![0.0f32; 2 * (RATE as usize / 10)];
    engine.render(&mut rest);
    assert_eq!(engine.voice_count(), 0);
    assert_eq!(finished(&engine), vec![65_537]);
}

#[test]
fn plays_a_streamed_clip_through_the_decode_ahead_feeder() {
    let fixture = write_wav(RATE as usize / 2, 16_000);
    let engine = Rig::new();

    let loaded = engine
        .load_clip(
            fixture.path.to_str().expect("the path is UTF-8"),
            1,
            MODE_STREAM,
            10.0,
        )
        .expect("the generated WAV opens");
    assert!(!loaded.resident, "the mode forces streaming");

    engine.submit(&[play(65_537, 1)]);
    assert_eq!(engine.voice_count(), 1);
    // The first block arrives from the feeder thread rather than from this one,
    // so an empty buffer before it lands is a gap and not the end of the voice.
    assert!(wait_for_sound(&engine, 256), "the stream reaches the mix");
    assert_eq!(engine.voice_count(), 1);

    let mut stop = play(65_537, 1);
    stop.kind = command::STOP;
    stop.clip = 0;
    engine.submit(&[stop]);
    assert_eq!(engine.voice_count(), 0);
    assert_eq!(finished(&engine), vec![65_537]);
}

#[test]
fn measures_a_clip_against_the_streaming_threshold() {
    let fixture = write_wav(RATE as usize / 2, 16_000);
    let path = fixture.path.to_str().expect("the path is UTF-8");
    let engine = Rig::new();

    let held = engine
        .load_clip(path, 1, MODE_AUTO, 10.0)
        .expect("half a second is under a ten second threshold");
    assert!(held.resident);

    let streamed = engine
        .load_clip(path, 2, MODE_AUTO, 0.1)
        .expect("half a second is over a tenth of a second");
    assert!(!streamed.resident);
    assert!(
        (streamed.duration - 0.5).abs() < 0.01,
        "got {}",
        streamed.duration
    );
}

#[test]
fn keeps_a_voice_reading_samples_a_released_clip_no_longer_holds() {
    let fixture = write_wav(RATE as usize / 4, 16_000);
    let engine = Rig::new();
    engine
        .load_clip(
            fixture.path.to_str().expect("the path is UTF-8"),
            1,
            MODE_RESIDENT,
            10.0,
        )
        .expect("the generated WAV loads");

    engine.submit(&[play(65_537, 1)]);
    engine.release_clip(1);

    // The voice holds its own reference, so releasing the clip under it does
    // not cut the sound.
    let mut buffer = vec![0.0f32; 2 * 256];
    engine.render(&mut buffer);
    assert!(buffer.iter().any(|value| *value > 0.4));
    assert_eq!(engine.voice_count(), 1);

    // A later play finds nothing, because the clip is gone.
    engine.submit(&[play(65_538, 1)]);
    assert_eq!(engine.voice_count(), 1);
}

#[test]
fn sums_a_resident_and_a_streamed_voice_into_one_mix() {
    let fixture = write_wav(RATE as usize / 2, 8_000);
    let path = fixture.path.to_str().expect("the path is UTF-8");
    let engine = Rig::new();
    engine
        .load_clip(path, 1, MODE_RESIDENT, 10.0)
        .expect("the generated WAV loads");
    engine
        .load_clip(path, 2, MODE_STREAM, 10.0)
        .expect("the generated WAV opens");

    // The streamed voice starts first and is given time to reach the mix,
    // because its first block comes from the feeder thread. Starting the
    // resident one afterwards means a render right now carries both.
    engine.submit(&[play(65_538, 2)]);
    assert!(wait_for_sound(&engine, 256));
    engine.submit(&[play(65_537, 1)]);
    assert_eq!(engine.voice_count(), 2);

    let mut buffer = vec![0.0f32; 2 * 256];
    engine.render(&mut buffer);
    let peak = buffer.iter().cloned().fold(0.0f32, f32::max);
    // One voice alone reaches about a quarter, so a sum past that is the two
    // of them rather than either one.
    assert!(peak > 0.3, "got {peak}");
}
