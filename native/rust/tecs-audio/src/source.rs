//! What a voice reads its samples from.
//!
//! A source is sequential rather than randomly addressed, because a streamed
//! one has no other shape to offer. Rate conversion and interpolation therefore
//! live in the voice above rather than here, and a source only has to hand back
//! whole frames at its own rate and say where it is.

use std::sync::Arc;

/// The greatest number of channels one source frame may carry.
///
/// The voice above keeps two frames of interpolation state on the stack, so the
/// width has to be a constant. Eight covers every layout a game asset arrives
/// in, and a wider file is refused at load rather than truncated here.
pub const MAX_CHANNELS: usize = 8;

/// Reads interleaved samples for one voice.
pub trait Source: Send {
    /// Reports the number of interleaved channels each frame carries.
    fn channels(&self) -> u16;

    /// Reports the frames per second the samples were decoded at.
    fn sample_rate(&self) -> u32;

    /// Fills `out` with whole frames and returns how many it wrote.
    ///
    /// Zero means the source produced nothing this call. That is the end of the
    /// input when `exhausted` also reports true, and otherwise a streamed
    /// source whose decoder has not kept up, which the caller answers with
    /// silence rather than with the end of the voice.
    fn read(&mut self, out: &mut [f32]) -> usize;

    /// Moves the read position to `seconds` from the start of the input and
    /// reports whether the input accepted it.
    fn seek(&mut self, seconds: f64) -> bool;

    /// Reports the position in seconds of the next frame `read` will return.
    fn position(&self) -> f64;

    /// Reports whether the input has run out.
    fn exhausted(&self) -> bool;
}

/// Reads a clip whose decoded samples stay in memory.
///
/// Every voice on one clip shares the same samples through an `Arc`, so
/// starting a second voice on a loaded clip costs a reference count rather than
/// a copy.
pub struct ResidentSource {
    samples: Arc<[f32]>,
    channels: u16,
    sample_rate: u32,
    cursor: usize,
}

impl ResidentSource {
    /// Creates a source reading shared decoded samples from the start.
    pub fn new(samples: Arc<[f32]>, channels: u16, sample_rate: u32) -> ResidentSource {
        ResidentSource {
            samples,
            channels,
            sample_rate,
            cursor: 0,
        }
    }

    /// Reports how many frames the clip holds.
    fn frames(&self) -> usize {
        if self.channels == 0 {
            0
        } else {
            self.samples.len() / self.channels as usize
        }
    }
}

impl Source for ResidentSource {
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
        let available = self.frames().saturating_sub(self.cursor);
        let count = wanted.min(available);
        if count == 0 {
            return 0;
        }
        let from = self.cursor * channels;
        out[..count * channels].copy_from_slice(&self.samples[from..from + count * channels]);
        self.cursor += count;
        count
    }

    fn seek(&mut self, seconds: f64) -> bool {
        // Rounded rather than truncated. A loop point is written in seconds and
        // arrives as a float, so truncating puts the repeat one sample before
        // the point the game asked for every time the conversion falls short.
        let target = (seconds.max(0.0) * self.sample_rate as f64).round() as usize;
        self.cursor = target.min(self.frames());
        true
    }

    fn position(&self) -> f64 {
        if self.sample_rate == 0 {
            0.0
        } else {
            self.cursor as f64 / self.sample_rate as f64
        }
    }

    fn exhausted(&self) -> bool {
        self.cursor >= self.frames()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stereo_ramp(frames: usize) -> Arc<[f32]> {
        let mut samples = Vec::with_capacity(frames * 2);
        for index in 0..frames {
            samples.push(index as f32);
            samples.push(-(index as f32));
        }
        samples.into()
    }

    #[test]
    fn reads_whole_frames_until_it_runs_out() {
        let mut source = ResidentSource::new(stereo_ramp(3), 2, 48_000);
        let mut out = [0.0f32; 4];
        assert_eq!(source.read(&mut out), 2);
        assert_eq!(out, [0.0, -0.0, 1.0, -1.0]);
        assert!(!source.exhausted());
        assert_eq!(source.read(&mut out), 1);
        assert!(source.exhausted());
        assert_eq!(source.read(&mut out), 0);
    }

    #[test]
    fn moves_and_reports_its_position_in_seconds() {
        let mut source = ResidentSource::new(stereo_ramp(48_000), 2, 48_000);
        assert_eq!(source.position(), 0.0);
        assert!(source.seek(0.5));
        assert!((source.position() - 0.5).abs() < 1e-9);
        let mut out = [0.0f32; 2];
        assert_eq!(source.read(&mut out), 1);
        assert_eq!(out[0], 24_000.0);
    }

    #[test]
    fn clamps_a_seek_past_the_end_rather_than_running_off_it() {
        let mut source = ResidentSource::new(stereo_ramp(10), 2, 48_000);
        assert!(source.seek(1000.0));
        assert!(source.exhausted());
        let mut out = [0.0f32; 2];
        assert_eq!(source.read(&mut out), 0);
    }
}
