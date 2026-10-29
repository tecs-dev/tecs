//! The device's layout, met from the mix's.
//!
//! The mixer runs at the engine's own rate and channel count for the whole life
//! of the engine, because every clock a game schedules against is counted in
//! mixer frames: a voice's position, a fade, and the synthesizers and chips
//! that render as voices. The device is whatever the default output is at the
//! moment, and a Bluetooth headset that turns its microphone on drops from
//! 48 000 Hz stereo to 24 000 or 16 000 Hz mono under a running game. A
//! conformer sits between the two inside the output callback: it pulls mixer
//! frames, folds them to the channels it carries, resamples those to the
//! device rate and spreads them over the device channels.
//!
//! It runs on the realtime thread, so everything it needs is allocated by
//! [`Conformer::new`], which the supervising thread calls when it opens a
//! stream. A callback asking for more frames than one pass holds is served in
//! several passes rather than by growing a buffer.
//!
//! The resampler is a windowed sinc. A linear interpolator is what each voice
//! already uses to meet the mixer rate, and that is acceptable there because a
//! clip is band-limited at its own rate; here it is not, because the mix at
//! 48 000 Hz carries content up to 24 kHz and a 24 000 Hz device can carry
//! only half of it. Interpolating would fold everything above 12 kHz back into
//! the audible band, so the kernel's cutoff follows the lower of the two
//! Nyquist frequencies. When the two rates agree there is no kernel and frames
//! are copied through unchanged, which is the common case and costs what the
//! callback cost before it existed.

use crate::source::MAX_CHANNELS;

/// The output frames one pass converts.
const BLOCK: usize = 1024;

/// The sinc's zero crossings on each side of the centre tap, at the cutoff.
///
/// Sixteen keeps the passband ripple and the stopband below what a float mix
/// resolves, and the cost is about thirty taps per sample per channel when the
/// rates are close and seventy when the device runs at half the mix's rate.
const ZERO_CROSSINGS: f64 = 16.0;

/// The share of the lower Nyquist frequency the kernel passes, leaving the rest
/// for the transition band.
const PASSBAND: f64 = 0.95;

/// The kernel phases tabulated per input frame. Coefficients between two
/// phases are blended linearly, so this bounds table size rather than accuracy.
const PHASES: usize = 128;

/// The Kaiser window's shape parameter: about ninety decibels of stopband.
const KAISER_BETA: f64 = 9.0;

/// One layout: frames per second and interleaved channels per frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Format {
    pub sample_rate: u32,
    pub channels: u16,
}

impl Format {
    /// Describes the layout the way a log line reads it.
    pub fn describe(&self) -> String {
        let unit = if self.channels == 1 {
            "channel"
        } else {
            "channels"
        };
        format!("{} Hz, {} {unit}", self.sample_rate, self.channels)
    }
}

/// A tabulated windowed-sinc kernel.
struct Kernel {
    /// Taps on each side of the output position; a row holds twice this.
    half: usize,
    /// `PHASES + 1` rows of `2 * half` taps, one per phase from zero to one
    /// whole frame inclusive, so a blend always has a row above it.
    table: Vec<f32>,
}

impl Kernel {
    /// Builds the kernel for one rate pair.
    fn new(engine_rate: u32, device_rate: u32) -> Kernel {
        let ratio = (device_rate as f64 / engine_rate as f64).min(1.0);
        let cutoff = PASSBAND * ratio;
        let half = (ZERO_CROSSINGS / cutoff).ceil() as usize;
        let width = 2 * half;
        let mut table = vec![0.0f32; (PHASES + 1) * width];
        let norm = bessel_i0(KAISER_BETA);
        for phase in 0..=PHASES {
            let fraction = phase as f64 / PHASES as f64;
            let row = &mut table[phase * width..(phase + 1) * width];
            let mut sum = 0.0f64;
            let mut taps = vec![0.0f64; width];
            for (tap, value) in taps.iter_mut().enumerate() {
                // The distance from the output position to this input frame,
                // in input frames.
                let distance = fraction + half as f64 - 1.0 - tap as f64;
                let x = distance / half as f64;
                let window = if x.abs() >= 1.0 {
                    0.0
                } else {
                    bessel_i0(KAISER_BETA * (1.0 - x * x).sqrt()) / norm
                };
                *value = cutoff * sinc(cutoff * distance) * window;
                sum += *value;
            }
            // Each row sums to one, so a constant passes at exactly its level
            // whatever the phase.
            for (target, value) in row.iter_mut().zip(taps.iter()) {
                *target = (*value / sum) as f32;
            }
        }
        Kernel { half, table }
    }
}

/// The normalized sinc, sin(pi x) / (pi x).
fn sinc(x: f64) -> f64 {
    if x.abs() < 1.0e-12 {
        1.0
    } else {
        let angle = std::f64::consts::PI * x;
        angle.sin() / angle
    }
}

/// The zeroth-order modified Bessel function of the first kind, by its series.
fn bessel_i0(x: f64) -> f64 {
    let quarter = x * x / 4.0;
    let mut term = 1.0;
    let mut sum = 1.0;
    for k in 1..64 {
        term *= quarter / (k as f64 * k as f64);
        sum += term;
        if term < sum * 1.0e-17 {
            break;
        }
    }
    sum
}

/// Converts the mix to one device layout, inside the output callback.
pub struct Conformer {
    engine_channels: usize,
    device_channels: usize,
    /// The channels resampled: one for a mono device, and otherwise as many as
    /// the mix and the device share.
    carried: usize,
    device_rate: u64,
    /// The whole input frames the read position moves per output frame.
    step_whole: usize,
    /// The remainder of that step, in device-rate parts of an input frame.
    step_part: u64,
    kernel: Option<Kernel>,
    /// Mixer frames as the mixer laid them out.
    mixed: Vec<f32>,
    /// Folded input frames at the engine rate, with the kernel's left context
    /// in front.
    history: Vec<f32>,
    filled: usize,
    /// The input frame the next output frame sits on or after.
    position: usize,
    /// How far past `position` it sits, in device-rate parts of an input frame.
    /// Exact integer arithmetic, so the read position never drifts however
    /// long the stream runs.
    remainder: u64,
    /// One pass of output at the device layout, converted to the device's
    /// sample type by the caller.
    converted: Vec<f32>,
    coefficients: Vec<f32>,
}

impl Conformer {
    /// Builds the conversion from the engine's layout to a device's.
    ///
    /// Allocates everything the callback will touch, so call it off the
    /// realtime thread.
    pub fn new(engine: Format, device: Format) -> Conformer {
        let engine_channels = (engine.channels as usize).max(1);
        let device_channels = (device.channels as usize).max(1);
        let carried = if device_channels == 1 {
            1
        } else {
            engine_channels.min(device_channels).min(MAX_CHANNELS)
        };
        let engine_rate = engine.sample_rate.max(1);
        let device_rate = device.sample_rate.max(1);
        let kernel = if engine_rate == device_rate {
            None
        } else {
            Some(Kernel::new(engine_rate, device_rate))
        };
        let half = kernel.as_ref().map_or(0, |kernel| kernel.half);
        // The most input one pass can need: the span its outputs cover, the
        // kernel's reach on both sides, and a frame of rounding either way.
        let reach = (BLOCK as u64 * engine_rate as u64).div_ceil(device_rate as u64) as usize;
        let capacity = match kernel {
            None => BLOCK,
            Some(_) => reach + 2 * half + 4,
        };
        Conformer {
            engine_channels,
            device_channels,
            carried,
            device_rate: device_rate as u64,
            step_whole: (engine_rate / device_rate) as usize,
            step_part: (engine_rate % device_rate) as u64,
            mixed: vec![0.0; capacity * engine_channels],
            history: vec![
                0.0;
                if kernel.is_some() {
                    capacity * carried
                } else {
                    0
                }
            ],
            // The left context starts as silence, and the first output frame
            // sits on the first mixer frame.
            filled: half,
            position: half,
            remainder: 0,
            converted: vec![0.0; BLOCK * device_channels],
            coefficients: vec![0.0; 2 * half],
            kernel,
        }
    }

    /// Fills `out` from `render`, which writes whole mixer frames at the
    /// engine's layout into the slice it is given.
    ///
    /// `convert` turns a float sample into the device's sample type. A trailing
    /// partial frame, which no device asks for, is written as silence.
    pub fn fill<T, R, C>(&mut self, out: &mut [T], mut render: R, convert: C)
    where
        R: FnMut(&mut [f32]),
        C: Fn(f32) -> T,
    {
        let width = self.device_channels;
        let frames = out.len() / width;
        let mut done = 0;
        while done < frames {
            let count = BLOCK.min(frames - done);
            self.pass(count, &mut render);
            let span = &mut out[done * width..(done + count) * width];
            for (target, value) in span.iter_mut().zip(self.converted.iter()) {
                *target = convert(*value);
            }
            done += count;
        }
        for target in out[frames * width..].iter_mut() {
            *target = convert(0.0);
        }
    }

    /// Produces `count` output frames into `converted`.
    fn pass<R: FnMut(&mut [f32])>(&mut self, count: usize, render: &mut R) {
        match self.kernel {
            None => self.copy_through(count, render),
            Some(_) => self.resample(count, render),
        }
    }

    /// Converts the layout alone, for a device at the engine's rate.
    fn copy_through<R: FnMut(&mut [f32])>(&mut self, count: usize, render: &mut R) {
        let engine = self.engine_channels;
        let span = &mut self.mixed[..count * engine];
        render(span);
        let mut folded = [0.0f32; MAX_CHANNELS];
        for frame in 0..count {
            fold(
                &self.mixed[frame * engine..(frame + 1) * engine],
                &mut folded[..self.carried],
            );
            spread(
                &folded[..self.carried],
                &mut self.converted
                    [frame * self.device_channels..(frame + 1) * self.device_channels],
            );
        }
    }

    /// Converts the rate and the layout.
    fn resample<R: FnMut(&mut [f32])>(&mut self, count: usize, render: &mut R) {
        let kernel = match &self.kernel {
            None => return,
            Some(value) => value,
        };
        let half = kernel.half;
        let width = 2 * half;
        let carried = self.carried;
        let engine = self.engine_channels;

        // The input the last output frame of this pass reaches.
        let span = (count as u64 - 1) * self.step_part + self.remainder;
        let last =
            self.position + (count - 1) * self.step_whole + (span / self.device_rate) as usize;
        let needed = last + half + 1;
        if needed > self.filled {
            let fresh = needed - self.filled;
            render(&mut self.mixed[..fresh * engine]);
            for frame in 0..fresh {
                let at = (self.filled + frame) * carried;
                fold(
                    &self.mixed[frame * engine..(frame + 1) * engine],
                    &mut self.history[at..at + carried],
                );
            }
            self.filled = needed;
        }

        let mut folded = [0.0f32; MAX_CHANNELS];
        for frame in 0..count {
            let phase = self.remainder as f64 / self.device_rate as f64 * PHASES as f64;
            let row = (phase as usize).min(PHASES - 1);
            let blend = (phase - row as f64) as f32;
            let below = &kernel.table[row * width..(row + 1) * width];
            let above = &kernel.table[(row + 1) * width..(row + 2) * width];
            for ((target, low), high) in self.coefficients.iter_mut().zip(below).zip(above) {
                *target = low + (high - low) * blend;
            }
            let first = self.position + 1 - half;
            for (channel, value) in folded.iter_mut().enumerate().take(carried) {
                let mut sum = 0.0f32;
                for (tap, coefficient) in self.coefficients.iter().enumerate() {
                    sum += coefficient * self.history[(first + tap) * carried + channel];
                }
                *value = sum;
            }
            spread(
                &folded[..carried],
                &mut self.converted
                    [frame * self.device_channels..(frame + 1) * self.device_channels],
            );

            self.position += self.step_whole;
            self.remainder += self.step_part;
            if self.remainder >= self.device_rate {
                self.remainder -= self.device_rate;
                self.position += 1;
            }
        }

        // Keep only the left context the next output frame reaches back to.
        let keep_from = self.position + 1 - half;
        if keep_from > 0 {
            self.history
                .copy_within(keep_from * carried..self.filled * carried, 0);
            self.filled -= keep_from;
            self.position -= keep_from;
        }
    }
}

/// Folds one mixer frame to the carried channels.
///
/// A mono device hears the mean of left and right, which keeps a centred sound
/// at its level and cannot clip where a sum could. The mixer places every voice
/// on the first two channels, so a wider mix has nothing further to fold.
fn fold(frame: &[f32], out: &mut [f32]) {
    if out.len() == 1 && frame.len() > 1 {
        out[0] = (frame[0] + frame[1]) * 0.5;
        return;
    }
    for (target, value) in out.iter_mut().zip(frame.iter()) {
        *target = *value;
    }
}

/// Spreads the carried channels over one device frame.
///
/// A mono mix goes to both the left and the right speaker, and a device with
/// more channels than the mix carries hears silence on the rest.
fn spread(carried: &[f32], out: &mut [f32]) {
    if carried.len() == 1 && out.len() > 1 {
        out[0] = carried[0];
        out[1] = carried[0];
        for target in out[2..].iter_mut() {
            *target = 0.0;
        }
        return;
    }
    for (index, target) in out.iter_mut().enumerate() {
        *target = carried.get(index).copied().unwrap_or(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENGINE: Format = Format {
        sample_rate: 48_000,
        channels: 2,
    };

    /// A stereo signal source counting the frames it has produced.
    struct Signal {
        frame: u64,
        value: fn(u64) -> (f32, f32),
    }

    impl Signal {
        fn render(&mut self, out: &mut [f32]) {
            for pair in out.chunks_mut(2) {
                let (left, right) = (self.value)(self.frame);
                pair[0] = left;
                pair[1] = right;
                self.frame += 1;
            }
        }
    }

    fn sine(frame: u64, hertz: f64) -> f32 {
        (2.0 * std::f64::consts::PI * hertz * frame as f64 / 48_000.0).sin() as f32 * 0.5
    }

    /// Runs `frames` device frames through a conformer in one call.
    fn run(device: Format, frames: usize, value: fn(u64) -> (f32, f32)) -> (Vec<f32>, u64) {
        let mut conformer = Conformer::new(ENGINE, device);
        let mut signal = Signal { frame: 0, value };
        let mut out = vec![0.0f32; frames * device.channels as usize];
        conformer.fill(&mut out, |span| signal.render(span), |value| value);
        (out, signal.frame)
    }

    #[test]
    fn copies_frames_unchanged_when_the_layouts_agree() {
        let (out, pulled) = run(ENGINE, 3000, |frame| (frame as f32, -(frame as f32)));
        assert_eq!(pulled, 3000);
        for frame in 0..3000 {
            assert_eq!(out[frame * 2], frame as f32);
            assert_eq!(out[frame * 2 + 1], -(frame as f32));
        }
    }

    #[test]
    fn folds_to_the_mean_of_left_and_right_for_a_mono_device() {
        let device = Format {
            sample_rate: 48_000,
            channels: 1,
        };
        let (out, _) = run(device, 100, |_| (0.8, 0.2));
        assert!(out.iter().all(|value| (*value - 0.5).abs() < 1.0e-6));
    }

    #[test]
    fn spreads_the_mix_over_a_wider_device_and_leaves_the_rest_silent() {
        let device = Format {
            sample_rate: 48_000,
            channels: 6,
        };
        let (out, _) = run(device, 10, |_| (0.25, 0.75));
        for frame in out.chunks(6) {
            assert_eq!(frame, &[0.25, 0.75, 0.0, 0.0, 0.0, 0.0]);
        }
    }

    #[test]
    fn keeps_a_constant_at_its_level_through_a_rate_change() {
        for (rate, channels) in [(24_000, 1), (16_000, 1), (44_100, 2), (96_000, 2)] {
            let device = Format {
                sample_rate: rate,
                channels,
            };
            let (out, _) = run(device, 4096, |_| (0.5, 0.5));
            // Past the kernel's reach into the silence before the first frame.
            for value in out[200 * channels as usize..].iter() {
                assert!(
                    (*value - 0.5).abs() < 1.0e-3,
                    "{rate} Hz renders {value} for a constant 0.5"
                );
            }
        }
    }

    #[test]
    fn reproduces_a_tone_at_the_device_rate() {
        let device = Format {
            sample_rate: 44_100,
            channels: 2,
        };
        let (out, pulled) = run(device, 8192, |frame| {
            let value = sine(frame, 1000.0);
            (value, value)
        });
        // Output frame k sits on input time k * 48000 / 44100, with no delay.
        let step = 48_000.0 / 44_100.0;
        for frame in 200..8192 {
            let time = frame as f64 * step;
            let want = (2.0 * std::f64::consts::PI * 1000.0 * time / 48_000.0).sin() * 0.5;
            let got = out[frame * 2] as f64;
            assert!(
                (got - want).abs() < 2.0e-3,
                "frame {frame}: {got}, expected {want}"
            );
        }
        // The mixer is pulled at its own rate: about 48000 frames for every
        // 44100 the device takes, plus the kernel's look-ahead.
        let expected = (8192.0 * step) as u64;
        assert!(
            pulled >= expected && pulled < expected + 64,
            "pulled {pulled}"
        );
    }

    #[test]
    fn removes_what_the_device_rate_cannot_carry() {
        // 20 kHz is above a 24 000 Hz device's Nyquist frequency, and
        // interpolating would fold it down to 4 kHz instead of removing it.
        let device = Format {
            sample_rate: 24_000,
            channels: 1,
        };
        let (out, _) = run(device, 8192, |frame| {
            let value = sine(frame, 20_000.0);
            (value, value)
        });
        let tail = &out[512..];
        let power = tail.iter().map(|value| value * value).sum::<f32>() / tail.len() as f32;
        assert!(
            power.sqrt() < 1.0e-3,
            "a 20 kHz tone leaks at rms {}",
            power.sqrt()
        );
    }

    #[test]
    fn renders_the_same_stream_whatever_size_the_callbacks_ask_for() {
        let device = Format {
            sample_rate: 22_050,
            channels: 1,
        };
        let value: fn(u64) -> (f32, f32) = |frame| (sine(frame, 440.0), sine(frame, 660.0));
        let (whole, _) = run(device, 6000, value);

        let mut conformer = Conformer::new(ENGINE, device);
        let mut signal = Signal { frame: 0, value };
        let mut pieces = Vec::new();
        for size in [1usize, 7, 2500, 3, 1024, 1025, 1440].iter().cycle() {
            if pieces.len() >= 6000 {
                break;
            }
            let mut out = vec![0.0f32; *size];
            conformer.fill(&mut out, |span| signal.render(span), |value| value);
            pieces.extend_from_slice(&out);
        }
        for (index, (a, b)) in whole.iter().zip(pieces.iter()).enumerate() {
            assert!((a - b).abs() < 1.0e-6, "sample {index}: {a} against {b}");
        }
    }
}
