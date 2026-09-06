//! Recording: a `cpal` input stream filling a ring the frame thread drains.
//!
//! The input callback runs on a thread this process never created, exactly as
//! the output callback does, so it does the same one thing: convert the block it
//! was handed to the layout the caller asked for and push it into a bounded
//! ring. Nothing reachable from inside it enters the Lua virtual machine,
//! allocates, or opens a file, and no function pointer of the caller's is ever
//! held. Captured frames reach Tecs only because `read` comes and takes them.
//!
//! The ring is bounded, which is the one behavior difference from the SDL
//! implementation this replaces. SDL grew its capture stream without limit, so a
//! game that stopped reading paid in memory and in latency forever. A bounded
//! ring drops the oldest frames instead and counts them, because the recent
//! second of audio is what a game that fell behind actually wants, and an
//! unbounded allocation driven by a realtime callback is not something to keep.

use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, StreamTrait};
use cpal::{FromSample, SizedSample};

use crate::enumerate;

/// Frames per second a capture opens at when the caller states no preference.
pub const DEFAULT_FREQUENCY: u32 = 48_000;

/// Channels a capture opens with when the caller states no preference.
pub const DEFAULT_CHANNELS: u16 = 1;

/// The channels one captured frame may carry.
///
/// The converter holds one frame on the stack across callbacks so interpolation
/// stays continuous, so this is a fixed width rather than an allocation.
pub const MAX_CAPTURE_CHANNELS: usize = 8;

/// Frames a capture holds when the caller states no preference, which is one
/// second at the default frequency.
pub const DEFAULT_BUFFER_FRAMES: u32 = DEFAULT_FREQUENCY;

/// A bounded interleaved store the callback fills and the frame thread drains.
///
/// Full, it drops the oldest frame to make room for the newest and counts it.
pub struct Ring {
    samples: Vec<f32>,
    channels: usize,
    capacity: usize,
    /// The frame the next read starts at.
    first: usize,
    /// The frames held now.
    held: usize,
    /// The frames overwritten since this ring was made.
    dropped: u64,
}

impl Ring {
    /// Creates a ring holding `frames` frames of `channels` samples each.
    pub fn new(frames: usize, channels: usize) -> Ring {
        let capacity = frames.max(1);
        let width = channels.max(1);
        Ring {
            samples: vec![0.0; capacity * width],
            channels: width,
            capacity,
            first: 0,
            held: 0,
            dropped: 0,
        }
    }

    /// Adds one frame, discarding the oldest when there is no room.
    pub fn push(&mut self, frame: &[f32]) {
        if self.held == self.capacity {
            self.first = (self.first + 1) % self.capacity;
            self.held -= 1;
            self.dropped = self.dropped.saturating_add(1);
        }
        let slot = (self.first + self.held) % self.capacity;
        let base = slot * self.channels;
        for index in 0..self.channels {
            self.samples[base + index] = frame.get(index).copied().unwrap_or(0.0);
        }
        self.held += 1;
    }

    /// Reports the complete frames ready to read.
    pub fn available(&self) -> usize {
        self.held
    }

    /// Reports the frames dropped to overrun since this ring was made.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Moves up to `max_frames` frames into `out` and returns how many it wrote.
    ///
    /// Writes no more than `out` holds, so a short buffer takes what fits and
    /// leaves the rest for the next call rather than losing it.
    pub fn read(&mut self, out: &mut [f32], max_frames: usize) -> usize {
        let fits = out.len() / self.channels;
        let mut frames = max_frames.min(self.held).min(fits);
        let written = frames;
        let mut target = 0;
        while frames > 0 {
            let base = self.first * self.channels;
            out[target..target + self.channels]
                .copy_from_slice(&self.samples[base..base + self.channels]);
            target += self.channels;
            self.first = (self.first + 1) % self.capacity;
            self.held -= 1;
            frames -= 1;
        }

        written
    }
}

/// Brings a device's own rate and channel count to the layout that was asked
/// for.
///
/// SDL converted a capture stream itself, so a game asked for 48000 mono and got
/// it whatever the hardware ran at. `cpal` hands over the device's own layout
/// instead, and a game that had to resample its own microphone input would be
/// doing on the frame thread what belongs here, so this keeps the old contract:
/// what a caller asked for is what `read` returns.
pub struct Converter {
    /// Input frames consumed per output frame.
    ratio: f64,
    /// Where the next output frame sits between `previous` and the input frame
    /// being consumed, in input frames.
    phase: f64,
    /// The last input frame consumed, kept across callbacks so a block boundary
    /// is not a discontinuity.
    previous: [f32; MAX_CAPTURE_CHANNELS],
    primed: bool,
    in_channels: usize,
    out_channels: usize,
}

impl Converter {
    /// Creates a converter from one layout to another.
    pub fn new(in_rate: u32, in_channels: u16, out_rate: u32, out_channels: u16) -> Converter {
        let ratio = if in_rate == 0 || out_rate == 0 {
            1.0
        } else {
            f64::from(in_rate) / f64::from(out_rate)
        };
        Converter {
            ratio,
            phase: 0.0,
            previous: [0.0; MAX_CAPTURE_CHANNELS],
            primed: false,
            in_channels: (in_channels as usize).clamp(1, MAX_CAPTURE_CHANNELS),
            out_channels: (out_channels as usize).clamp(1, MAX_CAPTURE_CHANNELS),
        }
    }

    /// Converts one captured block and pushes every output frame into `ring`.
    pub fn feed(&mut self, input: &[f32], ring: &mut Ring) {
        let frames = input.len() / self.in_channels;
        let mut current = [0.0f32; MAX_CAPTURE_CHANNELS];
        let mut out = [0.0f32; MAX_CAPTURE_CHANNELS];
        for frame in 0..frames {
            let base = frame * self.in_channels;
            self.map(&input[base..base + self.in_channels], &mut current);
            if !self.primed {
                // The very first frame becomes the left end of the first
                // interpolation and produces no output of its own, so a capture
                // is one input frame behind for its whole life. That is the
                // latency any interpolating resampler carries, and it is one
                // frame rather than a buffer.
                self.previous = current;
                self.phase = 0.0;
                self.primed = true;
                continue;
            }
            while self.phase < 1.0 {
                let blend = self.phase as f32;
                for (channel, target) in out.iter_mut().take(self.out_channels).enumerate() {
                    let from = self.previous[channel];
                    *target = from + (current[channel] - from) * blend;
                }
                ring.push(&out[..self.out_channels]);
                self.phase += self.ratio;
            }
            self.phase -= 1.0;
            self.previous = current;
        }
    }

    /// Lays one input frame out across the channels that were asked for.
    ///
    /// One input channel reaches every output channel, one output channel takes
    /// the average of the input, and any other mismatch copies what it can and
    /// leaves the rest silent.
    fn map(&self, frame: &[f32], out: &mut [f32; MAX_CAPTURE_CHANNELS]) {
        if self.in_channels == self.out_channels {
            out[..self.out_channels].copy_from_slice(&frame[..self.out_channels]);
            return;
        }
        if self.in_channels == 1 {
            out[..self.out_channels].fill(frame[0]);
            return;
        }
        if self.out_channels == 1 {
            let mut total = 0.0f32;
            for value in frame.iter() {
                total += *value;
            }
            out[0] = total / self.in_channels as f32;
            return;
        }
        let shared = self.in_channels.min(self.out_channels);
        out[..shared].copy_from_slice(&frame[..shared]);
        out[shared..self.out_channels].fill(0.0);
    }
}

/// One recording stream and the frames it has captured but not yet handed over.
pub struct Capture {
    ring: Arc<Mutex<Ring>>,
    /// Frames the input callback threw away because the frame thread held the
    /// ring. Counted apart from the ring's own overwrites because it cannot be
    /// counted inside a lock the callback did not get, and added to the same
    /// total, because a caller asking what it lost does not care which way.
    contended: Arc<AtomicU64>,
    failed: Arc<AtomicBool>,
    /// Kept because dropping it stops the capture. None for an offline capture,
    /// which is fed by `write` instead of by a device.
    stream: Option<cpal::Stream>,
    frequency: u32,
    channels: u16,
    running: bool,
    last_error: Mutex<String>,
    /// The same reason as a C string, so the binding can borrow it. Replaced
    /// rather than added to.
    reported: Mutex<CString>,
}

impl Capture {
    /// Opens a recording device and starts it.
    ///
    /// A name selects a device from the current listing, an id selects a
    /// position in it, and neither takes the platform's default. Capture is
    /// running when this returns, so frames accumulate from here whether or not
    /// anything reads them.
    ///
    /// @return the open capture, or the reason nothing opened
    pub fn open(
        id: u32,
        name: Option<&str>,
        frequency: u32,
        channels: u16,
        buffer_frames: u32,
    ) -> Result<Capture, String> {
        if channels as usize > MAX_CAPTURE_CHANNELS {
            return Err(format!(
                "a capture carries at most {MAX_CAPTURE_CHANNELS} channels, and {channels} were asked for"
            ));
        }
        let device = enumerate::find_input(id, name)?;
        let supported = device
            .default_input_config()
            .map_err(|error| format!("no default input configuration: {error}"))?;
        let format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();

        let ring = Arc::new(Mutex::new(Ring::new(
            buffer_frames.max(1) as usize,
            channels as usize,
        )));
        let contended = Arc::new(AtomicU64::new(0));
        let failed = Arc::new(AtomicBool::new(false));
        let converter = Converter::new(config.sample_rate, config.channels, frequency, channels);
        let stream = match format {
            cpal::SampleFormat::F32 => build::<f32>(
                &device,
                &config,
                &ring,
                &contended,
                Arc::clone(&failed),
                converter,
            ),
            cpal::SampleFormat::I16 => build::<i16>(
                &device,
                &config,
                &ring,
                &contended,
                Arc::clone(&failed),
                converter,
            ),
            cpal::SampleFormat::U16 => build::<u16>(
                &device,
                &config,
                &ring,
                &contended,
                Arc::clone(&failed),
                converter,
            ),
            cpal::SampleFormat::I32 => build::<i32>(
                &device,
                &config,
                &ring,
                &contended,
                Arc::clone(&failed),
                converter,
            ),
            other => Err(format!("unsupported input sample format {other:?}")),
        }?;
        stream
            .play()
            .map_err(|error| format!("the input stream did not start: {error}"))?;

        Ok(Capture {
            ring,
            contended,
            failed,
            stream: Some(stream),
            frequency,
            channels,
            running: true,
            last_error: Mutex::new(String::new()),
            reported: Mutex::new(CString::default()),
        })
    }

    /// Creates a capture with no device, whose frames the caller supplies.
    ///
    /// This is the deterministic path, and the only one a test may take:
    /// `write` puts frames in where a device callback would, and everything
    /// downstream of that behaves exactly as it does for a real microphone.
    pub fn open_offline(frequency: u32, channels: u16, buffer_frames: u32) -> Capture {
        let width = (channels as usize).clamp(1, MAX_CAPTURE_CHANNELS);
        Capture {
            ring: Arc::new(Mutex::new(Ring::new(buffer_frames.max(1) as usize, width))),
            contended: Arc::new(AtomicU64::new(0)),
            failed: Arc::new(AtomicBool::new(false)),
            stream: None,
            frequency,
            channels: width as u16,
            running: true,
            last_error: Mutex::new(String::new()),
            reported: Mutex::new(CString::default()),
        }
    }

    /// Reports the frames per second `read` answers in.
    pub fn frequency(&self) -> u32 {
        self.frequency
    }

    /// Reports the interleaved channels per frame `read` answers with.
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Reports the complete frames ready to read without waiting.
    pub fn available_frames(&self) -> usize {
        match self.ring.lock() {
            Err(_) => 0,
            Ok(ring) => ring.available(),
        }
    }

    /// Reports the frames dropped to overrun since this capture opened.
    pub fn overruns(&self) -> u64 {
        let lost = self.contended.load(Ordering::Relaxed);
        match self.ring.lock() {
            Err(_) => lost,
            Ok(ring) => ring.dropped().saturating_add(lost),
        }
    }

    /// Moves up to `max_frames` captured frames into `out`.
    ///
    /// @return the frames written, or the reason nothing could be read
    pub fn read(&self, out: &mut [f32], max_frames: usize) -> Result<usize, String> {
        match self.ring.lock() {
            Err(_) => Err(self.fail("the capture buffer is poisoned".to_string())),
            Ok(mut ring) => {
                let frames = ring.read(out, max_frames);
                if frames == 0 && max_frames > 0 && self.failed() {
                    Err(self
                        .fail("the input stream failed; close and reopen the microphone".into()))
                } else {
                    Ok(frames)
                }
            }
        }
    }

    /// Puts frames in where a device callback would, for an offline capture.
    ///
    /// @return the frames accepted, and zero while the capture is paused
    pub fn write(&self, samples: &[f32]) -> usize {
        if !self.running || self.failed() {
            return 0;
        }
        let width = self.channels.max(1) as usize;
        let frames = samples.len() / width;
        match self.ring.lock() {
            Err(_) => 0,
            Ok(mut ring) => {
                for frame in 0..frames {
                    let base = frame * width;
                    ring.push(&samples[base..base + width]);
                }
                frames
            }
        }
    }

    /// Stops the device filling the buffer, keeping what is already in it.
    ///
    /// @return whether the stream stopped, with the reason left for
    ///     `last_error`
    pub fn pause(&mut self) -> bool {
        if let Some(stream) = self.stream.as_ref() {
            if let Err(error) = stream.pause() {
                self.fail(format!("the input stream did not pause: {error}"));
                return false;
            }
        }
        self.running = false;

        true
    }

    /// Starts the device filling the buffer again.
    ///
    /// @return whether the stream started, with the reason left for
    ///     `last_error`
    pub fn resume(&mut self) -> bool {
        if self.failed() {
            self.fail("the input stream failed; close and reopen the microphone".into());
            return false;
        }
        if let Some(stream) = self.stream.as_ref() {
            if let Err(error) = stream.play() {
                self.fail(format!("the input stream did not start: {error}"));
                return false;
            }
        }
        self.running = true;

        true
    }

    /// Reports whether the capture is filling its buffer.
    pub fn running(&self) -> bool {
        self.running && !self.failed()
    }

    /// Reports terminal stream failure while allowing buffered frames to drain.
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    /// Stops capture and drops the stream.
    ///
    /// Whatever was captured and not yet read goes with it, which is why a last
    /// `read` belongs before this rather than after.
    pub fn close(&mut self) {
        self.stream = None;
        self.running = false;
        if let Ok(mut ring) = self.ring.lock() {
            let width = ring.channels;
            *ring = Ring::new(1, width);
        }
    }

    /// Returns the reason the most recent failing call gave.
    pub fn last_error(&self) -> String {
        match self.last_error.lock() {
            Err(_) => String::new(),
            Ok(value) => value.clone(),
        }
    }

    /// Returns the same reason as a borrowed C string.
    ///
    /// The pointer aliases storage this capture owns and the next call replaces
    /// it, so a caller reads the string before doing anything else here.
    pub fn last_error_cstr(&self) -> *const c_char {
        let text = CString::new(self.last_error()).unwrap_or_default();
        match self.reported.lock() {
            Err(_) => std::ptr::null(),
            Ok(mut slot) => {
                *slot = text;
                slot.as_ptr()
            }
        }
    }

    /// Records the reason a call is about to report.
    fn fail(&self, reason: String) -> String {
        if let Ok(mut slot) = self.last_error.lock() {
            *slot = reason.clone();
        }
        reason
    }
}

/// Builds the input stream for one sample format.
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    ring: &Arc<Mutex<Ring>>,
    contended: &Arc<AtomicU64>,
    failed: Arc<AtomicBool>,
    mut converter: Converter,
) -> Result<cpal::Stream, String>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let failure_callback = Arc::clone(&failed);
    let held = Arc::clone(ring);
    let lost = Arc::clone(contended);
    let channels = config.channels.max(1) as usize;
    let mut scratch: Vec<f32> = Vec::new();
    device
        .build_input_stream(
            *config,
            move |input: &[T], _info: &cpal::InputCallbackInfo| {
                if input.is_empty() || failed.load(Ordering::Acquire) {
                    return;
                }
                if scratch.len() < input.len() {
                    // Only on the first callbacks and after a buffer-size
                    // change, which is where an allocation here is affordable.
                    scratch.resize(input.len(), 0.0);
                }
                let span = &mut scratch[..input.len()];
                for (target, source) in span.iter_mut().zip(input.iter()) {
                    *target = source.to_sample::<f32>();
                }
                // Dropping the block when the frame thread holds the lock costs
                // one buffer of audio; waiting on it in a realtime callback
                // costs a glitch in whatever else the device is playing. What
                // it cost is counted, so `overruns` reports every frame lost
                // rather than only the ones a full ring overwrote.
                match held.try_lock() {
                    Err(_) => {
                        let frames = (input.len() / channels) as u64;
                        lost.fetch_add(frames, Ordering::Relaxed);
                    }
                    Ok(mut guard) => converter.feed(span, &mut guard),
                }
            },
            move |_error| {
                failure_callback.store(true, Ordering::Release);
            },
            None,
        )
        .map_err(|error| format!("the input stream did not open: {error}"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn stream_failure_drains_then_refuses_reads_and_resume() {
        let mut capture = super::Capture::open_offline(48000, 1, 8);
        assert_eq!(capture.write(&[1.0, 2.0]), 2);
        capture
            .failed
            .store(true, std::sync::atomic::Ordering::Release);
        assert!(capture.failed());
        assert!(!capture.running());
        assert_eq!(capture.write(&[3.0]), 0);
        let mut output = [0.0; 4];
        assert_eq!(capture.read(&mut output, 4).unwrap(), 2);
        assert_eq!(&output[..2], &[1.0, 2.0]);
        assert!(capture
            .read(&mut output, 4)
            .unwrap_err()
            .contains("input stream failed"));
        assert!(!capture.resume());
        assert!(capture.failed());
    }

    use super::*;

    #[test]
    fn hands_back_the_frames_it_was_given_in_order() {
        let mut ring = Ring::new(4, 2);
        ring.push(&[1.0, 2.0]);
        ring.push(&[3.0, 4.0]);
        assert_eq!(ring.available(), 2);

        let mut out = [0.0f32; 4];
        assert_eq!(ring.read(&mut out, 2), 2);
        assert_eq!(out, [1.0, 2.0, 3.0, 4.0]);
        assert_eq!(ring.available(), 0);
        assert_eq!(ring.dropped(), 0);
    }

    #[test]
    fn drops_the_oldest_frames_when_nothing_reads() {
        let mut ring = Ring::new(2, 1);
        ring.push(&[1.0]);
        ring.push(&[2.0]);
        ring.push(&[3.0]);
        assert_eq!(ring.available(), 2);
        assert_eq!(ring.dropped(), 1);

        let mut out = [0.0f32; 2];
        assert_eq!(ring.read(&mut out, 8), 2);
        // The newest two survive, which is what a game that fell behind wants.
        assert_eq!(out, [2.0, 3.0]);
    }

    #[test]
    fn leaves_what_a_short_buffer_could_not_take() {
        let mut ring = Ring::new(4, 1);
        for value in 1..=4 {
            ring.push(&[value as f32]);
        }
        let mut out = [0.0f32; 2];
        assert_eq!(ring.read(&mut out, 4), 2);
        assert_eq!(out, [1.0, 2.0]);
        assert_eq!(ring.available(), 2);
    }

    #[test]
    fn passes_a_matching_layout_through_unchanged() {
        let mut converter = Converter::new(48_000, 1, 48_000, 1);
        let mut ring = Ring::new(8, 1);
        // Three frames in, two out: the first is the left end of the first
        // interpolation and the third is waiting to be the right end of the
        // next one.
        converter.feed(&[0.25, 0.5, 0.75], &mut ring);
        let mut out = [0.0f32; 8];
        assert_eq!(ring.read(&mut out, 8), 2);
        assert_eq!(&out[..2], &[0.25, 0.5]);

        // The carry survives the block boundary, so the fourth frame produces
        // the third output rather than starting again.
        converter.feed(&[1.0], &mut ring);
        assert_eq!(ring.read(&mut out, 8), 1);
        assert_eq!(out[0], 0.75);
    }

    #[test]
    fn halves_the_frame_count_when_the_device_runs_twice_as_fast() {
        let mut converter = Converter::new(48_000, 1, 24_000, 1);
        let mut ring = Ring::new(64, 1);
        let input: Vec<f32> = (0..64).map(|index| index as f32).collect();
        converter.feed(&input, &mut ring);
        // One output frame per two input frames, less the primed first frame.
        assert_eq!(ring.available(), 32);
    }

    #[test]
    fn doubles_the_frame_count_when_the_device_runs_half_as_fast() {
        let mut converter = Converter::new(24_000, 1, 48_000, 1);
        let mut ring = Ring::new(256, 1);
        let input: Vec<f32> = (0..64).map(|index| index as f32).collect();
        converter.feed(&input, &mut ring);
        assert_eq!(ring.available(), 126);
    }

    #[test]
    fn folds_a_stereo_device_into_the_mono_that_was_asked_for() {
        let mut converter = Converter::new(48_000, 2, 48_000, 1);
        let mut ring = Ring::new(8, 1);
        converter.feed(&[1.0, 0.0, 0.5, 0.5], &mut ring);
        let mut out = [0.0f32; 8];
        assert_eq!(ring.read(&mut out, 8), 1);
        assert_eq!(out[0], 0.5);
    }

    #[test]
    fn spreads_a_mono_device_across_the_channels_that_were_asked_for() {
        let mut converter = Converter::new(48_000, 1, 48_000, 2);
        let mut ring = Ring::new(8, 2);
        converter.feed(&[0.75, 0.25], &mut ring);
        let mut out = [0.0f32; 8];
        assert_eq!(ring.read(&mut out, 8), 1);
        assert_eq!(&out[..2], &[0.75, 0.75]);
    }

    #[test]
    fn drains_what_an_offline_capture_was_fed() {
        let capture = Capture::open_offline(48_000, 1, 4);
        assert_eq!(capture.frequency(), 48_000);
        assert_eq!(capture.channels(), 1);
        assert_eq!(capture.write(&[1.0, 2.0]), 2);
        assert_eq!(capture.available_frames(), 2);

        let mut out = [0.0f32; 4];
        assert_eq!(capture.read(&mut out, 4).expect("the ring is live"), 2);
        assert_eq!(&out[..2], &[1.0, 2.0]);
        assert_eq!(capture.overruns(), 0);
    }

    #[test]
    fn counts_the_frames_an_offline_capture_overran() {
        let capture = Capture::open_offline(48_000, 1, 2);
        capture.write(&[1.0, 2.0, 3.0, 4.0]);
        assert_eq!(capture.available_frames(), 2);
        assert_eq!(capture.overruns(), 2);
    }

    #[test]
    fn takes_nothing_while_paused_and_takes_again_after_resume() {
        let mut capture = Capture::open_offline(48_000, 1, 8);
        assert!(capture.pause());
        assert!(!capture.running());
        assert_eq!(capture.write(&[1.0]), 0);
        assert_eq!(capture.available_frames(), 0);

        assert!(capture.resume());
        assert_eq!(capture.write(&[1.0]), 1);
        assert_eq!(capture.available_frames(), 1);
    }

    #[test]
    fn discards_what_was_captured_when_it_closes() {
        let mut capture = Capture::open_offline(48_000, 1, 8);
        capture.write(&[1.0, 2.0]);
        capture.close();
        assert_eq!(capture.available_frames(), 0);
        assert_eq!(capture.write(&[3.0]), 0);
        // Closing twice is the same as closing once.
        capture.close();
        assert_eq!(capture.available_frames(), 0);
    }
}
