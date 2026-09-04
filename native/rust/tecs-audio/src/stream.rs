//! Streamed playback, decoded ahead of the output callback.
//!
//! A streamed voice reads its file for itself, and reading a file inside the
//! output callback is the mistake this module exists to avoid. One feeder
//! thread owns every open decoder and tops up a small queue of blocks per
//! voice; the mixer pops from that queue and never touches a decoder, a file
//! handle or an allocator.
//!
//! A queue that runs dry is a gap rather than the end of the voice. The mixer
//! tells the two apart through `Source::exhausted`, which reports the end only
//! once the feeder has said the input ran out and the queue has emptied behind
//! it.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::decode::Streamer;
use crate::source::Source;

/// Frames one decoded block carries.
const BLOCK_FRAMES: usize = 2048;

/// Frames a voice keeps decoded ahead of the output, which is half a second at
/// 48000 and enough to cover a scheduling gap without holding a large clip's
/// worth of memory per voice.
const TARGET_FRAMES: usize = 24_000;

/// How long the feeder waits when every queue is full.
const IDLE: Duration = Duration::from_millis(5);

/// Decoded frames and the position of the first of them.
///
/// The position travels with the block so a voice can answer `tell` without the
/// feeder and the mixer agreeing about anything except this struct.
struct Block {
    start: f64,
    samples: Vec<f32>,
}

/// What the feeder and one voice share.
struct Shared {
    state: Mutex<State>,
    closed: AtomicBool,
}

/// The queue, and the two facts either side needs from the other.
struct State {
    ready: VecDeque<Block>,
    /// Buffers the mixer has finished with, so a steady stream allocates
    /// nothing after the first half second.
    spare: Vec<Vec<f32>>,
    queued: usize,
    /// A position the voice asked for, waiting for the feeder to honor it.
    request: Option<f64>,
    /// Set once the feeder has read the input to its end.
    finished: bool,
}

/// Reads a clip from its file, one voice at a time.
pub struct StreamSource {
    shared: Arc<Shared>,
    channels: u16,
    sample_rate: u32,
    current: Option<Block>,
    offset: usize,
    position: f64,
    /// Set while a seek this voice asked for is still outstanding, so the voice
    /// does not read the end of the input as the end of itself.
    awaiting: bool,
}

impl StreamSource {
    /// Reports the position in seconds this source will next produce.
    fn advance(&mut self, frames: usize) {
        if self.sample_rate > 0 {
            self.position += frames as f64 / self.sample_rate as f64;
        }
    }
}

impl Source for StreamSource {
    fn channels(&self) -> u16 {
        self.channels
    }

    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    fn read(&mut self, out: &mut [f32]) -> usize {
        let channels = self.channels as usize;
        if channels == 0 {
            return 0;
        }
        let wanted = out.len() / channels;
        let mut written = 0;
        while written < wanted {
            if self.current.is_none() {
                // A contended lock is the feeder pushing a block, which takes
                // long enough to be worth not waiting for inside the output
                // callback. The gap is one buffer.
                let mut state = match self.shared.state.try_lock() {
                    Err(_) => break,
                    Ok(value) => value,
                };
                match state.ready.pop_front() {
                    None => break,
                    Some(block) => {
                        state.queued -= block.samples.len() / channels;
                        drop(state);
                        self.position = block.start;
                        self.current = Some(block);
                        self.offset = 0;
                        self.awaiting = false;
                    }
                }
            }
            let block = match self.current.as_ref() {
                None => break,
                Some(value) => value,
            };
            let frames = block.samples.len() / channels;
            let available = frames - self.offset;
            let count = available.min(wanted - written);
            let from = self.offset * channels;
            let into = written * channels;
            out[into..into + count * channels]
                .copy_from_slice(&block.samples[from..from + count * channels]);
            self.offset += count;
            written += count;
            if self.offset >= frames {
                if let Some(block) = self.current.take() {
                    if let Ok(mut state) = self.shared.state.try_lock() {
                        state.spare.push(block.samples);
                    }
                }
            }
        }
        self.advance(written);
        written
    }

    fn seek(&mut self, seconds: f64) -> bool {
        let mut state = match self.shared.state.lock() {
            Err(_) => return false,
            Ok(value) => value,
        };
        let discarded: Vec<Block> = state.ready.drain(..).collect();
        for block in discarded {
            state.spare.push(block.samples);
        }
        state.queued = 0;
        state.finished = false;
        state.request = Some(seconds.max(0.0));
        drop(state);
        if let Some(block) = self.current.take() {
            if let Ok(mut state) = self.shared.state.lock() {
                state.spare.push(block.samples);
            }
        }
        self.offset = 0;
        self.position = seconds.max(0.0);
        self.awaiting = true;
        true
    }

    fn position(&self) -> f64 {
        self.position
    }

    fn exhausted(&self) -> bool {
        if self.current.is_some() || self.awaiting {
            return false;
        }
        match self.shared.state.try_lock() {
            // An unreadable queue is the feeder holding it, which is never the
            // end of the input.
            Err(_) => false,
            Ok(state) => state.finished && state.ready.is_empty(),
        }
    }
}

impl Drop for StreamSource {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
    }
}

/// One open decoder the feeder owns.
struct Feed {
    shared: Arc<Shared>,
    streamer: Streamer,
    next: f64,
}

/// Decodes ahead for every streamed voice on one output.
pub struct Feeder {
    inbox: Arc<Mutex<Vec<Feed>>>,
    running: Arc<AtomicBool>,
}

impl Feeder {
    /// Starts the thread that keeps streamed voices fed.
    pub fn start() -> Feeder {
        let inbox: Arc<Mutex<Vec<Feed>>> = Arc::new(Mutex::new(Vec::new()));
        let running = Arc::new(AtomicBool::new(true));
        let thread_inbox = Arc::clone(&inbox);
        let thread_running = Arc::clone(&running);
        thread::Builder::new()
            .name("tecs-audio-decode".to_string())
            .spawn(move || run(thread_inbox, thread_running))
            .expect("the audio decode thread starts");
        Feeder { inbox, running }
    }

    /// Takes an open decoder and returns the source a voice reads it through.
    ///
    /// The caller opens the file, so this never blocks on one.
    pub fn attach(&self, streamer: Streamer, start: f64) -> StreamSource {
        let channels = streamer.channels();
        let sample_rate = streamer.sample_rate();
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                ready: VecDeque::new(),
                spare: Vec::new(),
                queued: 0,
                request: if start > 0.0 { Some(start) } else { None },
                finished: false,
            }),
            closed: AtomicBool::new(false),
        });
        if let Ok(mut inbox) = self.inbox.lock() {
            inbox.push(Feed {
                shared: Arc::clone(&shared),
                streamer,
                next: start.max(0.0),
            });
        }
        StreamSource {
            shared,
            channels,
            sample_rate,
            current: None,
            offset: 0,
            position: start.max(0.0),
            // The first block has not arrived, and an empty queue before it
            // does is not the end of the input.
            awaiting: true,
        }
    }
}

impl Drop for Feeder {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
    }
}

/// Keeps every attached decoder ahead of its voice until the feeder stops.
fn run(inbox: Arc<Mutex<Vec<Feed>>>, running: Arc<AtomicBool>) {
    let mut feeds: Vec<Feed> = Vec::new();
    while running.load(Ordering::Acquire) {
        if let Ok(mut waiting) = inbox.lock() {
            feeds.append(&mut waiting);
        }
        let mut worked = false;
        let mut index = 0;
        while index < feeds.len() {
            if feeds[index].shared.closed.load(Ordering::Acquire) {
                feeds.swap_remove(index);
                continue;
            }
            worked |= top_up(&mut feeds[index]);
            index += 1;
        }
        if !worked {
            thread::sleep(IDLE);
        }
    }
}

/// Decodes at most one block for a voice, reporting whether it produced one.
fn top_up(feed: &mut Feed) -> bool {
    let channels = feed.streamer.channels() as usize;
    if channels == 0 {
        return false;
    }
    let (request, mut buffer) = {
        let mut state = match feed.shared.state.lock() {
            Err(_) => return false,
            Ok(value) => value,
        };
        let request = state.request.take();
        if request.is_none() && (state.finished || state.queued >= TARGET_FRAMES) {
            return false;
        }
        (request, state.spare.pop().unwrap_or_default())
    };

    if let Some(seconds) = request {
        // A refused seek leaves the reader where it was, which is the honest
        // answer to a decoder that cannot reach the point.
        if feed.streamer.seek(seconds) {
            feed.next = seconds;
        }
    }

    buffer.clear();
    // A decoder that failed is treated as one that ran out, because a voice
    // that stops is a better answer than one that never ends.
    let more = feed
        .streamer
        .read(&mut buffer, BLOCK_FRAMES * channels)
        .unwrap_or_default();
    let frames = buffer.len() / channels;

    let mut state = match feed.shared.state.lock() {
        Err(_) => return false,
        Ok(value) => value,
    };
    if state.request.is_some() {
        // The voice moved while this block was decoding, so it belongs to a
        // position nothing is going to play.
        state.spare.push(buffer);
        return true;
    }
    if frames > 0 {
        state.ready.push_back(Block {
            start: feed.next,
            samples: buffer,
        });
        state.queued += frames;
        if feed.streamer.sample_rate() > 0 {
            feed.next += frames as f64 / feed.streamer.sample_rate() as f64;
        }
    } else {
        state.spare.push(buffer);
    }
    if !more {
        state.finished = true;
    }
    frames > 0
}
