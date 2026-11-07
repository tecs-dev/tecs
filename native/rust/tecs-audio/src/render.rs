//! The render side: the mixer, and the two queues that are all the control
//! side shares with it.
//!
//! Whatever renders, the device callback, the void output's supervisor or a
//! caller stepping a memory output, holds the render side and nothing else.
//! It takes the control side's messages off one queue at the start of each
//! render, mixes, publishes the clock, the voices' positions and the meters
//! for queries to read, and puts what it observed and what it finished with on
//! the other queue. The control side never waits for it: a query reads what
//! was published, and a message that finds the queue full waits on the control
//! side for the next call.
//!
//! The render side is behind a mutex, but only renderers take it: the
//! callback, the supervisor while no stream is open, and the control thread
//! itself only when nothing else renders (an offline or memory output, or a
//! held void one), which is the inline mode tests and offline rendering use.
//! The published values sit behind mutexes of their own, which the render side
//! only ever tries, so a query that holds one costs a skipped publish, never a
//! wait.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crate::command::{Command, Event};
use crate::effects::Effect;
use crate::listen::Tap;
use crate::mixer::{Fresh, Leftover, Mixer, Prepared, Storage, StripMeter};
use crate::queue::{Consumer, Producer};
use crate::source::Source;

/// Messages the control side sends the render side.
// Carried by value, not boxed: boxing would allocate on the render side.
#[allow(clippy::large_enum_variant)]
pub enum Message {
    /// A command, with what the control side built for it.
    Command {
        command: Command,
        source: Option<Box<dyn Source>>,
        effect: Option<Box<dyn Effect>>,
        fresh: Option<Fresh>,
        voice: Option<Prepared>,
    },
    /// Room for more strips.
    Storage(Storage),
    /// Moves a voice's read position.
    Seek { handle: u32, seconds: f64 },
    /// Ends every voice and drops the schedule.
    StopAll,
}

/// What the render side hands back.
// Carried by value, not boxed: boxing would allocate on the render side.
#[allow(clippy::large_enum_variant)]
pub enum Report {
    Event(Event),
    Leftover(Leftover),
    Storage(Storage),
    Message(Message),
}

/// What queries read, written by the render side as it renders.
pub struct Published {
    pub frames: AtomicU64,
    pub late: AtomicU64,
    pub voices: AtomicUsize,
    /// Each sounding voice's handle and read position.
    pub positions: Mutex<Vec<(u32, f64)>>,
    /// Every strip's meter since the control side last read it.
    pub meters: Mutex<Vec<StripMeter>>,
    /// A recording of the output, armed by the control side.
    pub tap: Mutex<Option<Tap>>,
}

impl Published {
    pub fn new(max_voices: usize) -> Published {
        let published = Published {
            frames: AtomicU64::new(0),
            late: AtomicU64::new(0),
            voices: AtomicUsize::new(0),
            positions: Mutex::new(Vec::with_capacity(max_voices)),
            meters: Mutex::new(Vec::with_capacity(64)),
            tap: Mutex::new(None),
        };
        // The first lock of a std mutex can allocate the platform mutex
        // behind it (a pthread mutex on macOS is boxed lazily), so take each
        // once here rather than let the render side's first try be it.
        drop(published.positions.lock());
        drop(published.meters.lock());
        drop(published.tap.lock());
        published
    }
}

/// The mixer and its ends of the two queues.
pub struct RenderSide {
    mixer: Mixer,
    inbox: Consumer<Message>,
    outbox: Producer<Report>,
    /// What did not fit in the outbox, kept for the next render. Its room is
    /// reserved when the render side is made.
    held: Vec<Report>,
    published: Arc<Published>,
}

/// Reports the render side holds back before the outbox has room.
const HELD_REPORTS: usize = 4096;

impl RenderSide {
    pub fn new(
        mut mixer: Mixer,
        inbox: Consumer<Message>,
        outbox: Producer<Report>,
        published: Arc<Published>,
        max_voices: usize,
    ) -> RenderSide {
        mixer.set_bounded(true);
        mixer.reserve_bounded(2 * max_voices + 64, 64, 16, 8192);
        RenderSide {
            mixer,
            inbox,
            outbox,
            held: Vec::with_capacity(HELD_REPORTS),
            published,
        }
    }

    /// Applies every message waiting.
    pub fn pump(&mut self) {
        while let Some(message) = self.inbox.pop() {
            self.apply(message);
        }
        self.hand_back();
    }

    fn apply(&mut self, message: Message) {
        match message {
            Message::Command {
                command,
                source,
                effect,
                fresh,
                voice,
            } => {
                if command.kind == crate::command::PLAY {
                    self.mixer.submit_voice(&command, voice);
                } else if fresh.is_some() {
                    self.mixer.apply_structure_with(&command, fresh);
                } else if let Some(effect) = effect {
                    self.mixer.submit_effect(&command, effect);
                } else {
                    self.mixer.submit(&command, source);
                }
            }
            Message::Storage(storage) => {
                let old = self.mixer.adopt(storage);
                self.report(Report::Storage(old));
            }
            Message::Seek { handle, seconds } => {
                self.mixer.seek(handle, seconds);
            }
            Message::StopAll => self.mixer.stop_all(),
        }
    }

    /// Mixes into `out`, after applying what waits, and publishes.
    pub fn render(&mut self, out: &mut [f32]) {
        while let Some(message) = self.inbox.pop() {
            self.apply(message);
        }
        self.mixer.render(out);
        if let Ok(mut tap) = self.published.tap.try_lock() {
            if let Some(tap) = tap.as_mut() {
                tap.record(out);
            }
        }
        self.publish();
        self.hand_back();
    }

    fn publish(&mut self) {
        let published = &self.published;
        published
            .frames
            .store(self.mixer.frames(), Ordering::Release);
        published.late.store(self.mixer.late(), Ordering::Release);
        published
            .voices
            .store(self.mixer.voice_count(), Ordering::Release);
        if let Ok(mut positions) = published.positions.try_lock() {
            self.mixer.positions_into(&mut positions);
        }
        if let Ok(mut meters) = published.meters.try_lock() {
            self.mixer.merge_meters(&mut meters);
        }
    }

    fn report(&mut self, report: Report) {
        if let Err(back) = self.outbox.push(report) {
            if self.held.len() < self.held.capacity() {
                self.held.push(back);
            } else {
                // Past every bound the render side keeps: the value is lost
                // rather than freed here. Draining once a frame never comes
                // near this.
                std::mem::forget(back);
            }
        }
    }

    /// Moves what the mixer observed and finished with onto the outbox.
    #[allow(clippy::result_large_err)]
    fn hand_back(&mut self) {
        while let Some(report) = self.held.pop() {
            if let Err(back) = self.outbox.push(report) {
                self.held.push(back);
                return;
            }
        }
        let outbox = &mut self.outbox;
        let held = &mut self.held;
        self.mixer
            .drain_events(|event| match outbox.push(Report::Event(event)) {
                Ok(()) => true,
                Err(_) => false,
            });
        self.mixer
            .drain_leftovers(|leftover| match outbox.push(Report::Leftover(leftover)) {
                Ok(()) => Ok(()),
                Err(Report::Leftover(back)) => {
                    if held.len() < held.capacity() {
                        held.push(Report::Leftover(back));
                        Ok(())
                    } else {
                        Err(back)
                    }
                }
                Err(_) => Ok(()),
            });
    }

    /// The mixer, for the inline mode, whose caller is the only renderer.
    pub fn mixer(&mut self) -> &mut Mixer {
        &mut self.mixer
    }
}
