//! Effects: what a Track's or a Bus's insert chain runs its signal through.
//!
//! Every effect is an [`Effect`]: built once on the control side for one rate
//! and channel count, then run in place on the render path, where it must not
//! allocate, lock or block. Parameters arrive as targets on exact frames (the
//! mixer splits its render there) and each effect ramps towards them, so a
//! change never clicks.
//!
//! The built-ins are the ones nearly every game wants: a lookahead limiter
//! that Master carries by default, a biquad filter, a three-band equalizer and
//! an algorithmic reverb for return buses. Anything else comes through the
//! Effect ABI in [`crate::abi`], which wraps a native vtable as an `Effect`.

/// One effect instance in an insert chain.
pub trait Effect: Send {
    /// Processes `frames` interleaved frames of `channels` in place.
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize);

    /// Sets parameter `id` to a target the effect ramps towards.
    fn param(&mut self, id: u32, value: f32);

    /// Clears whatever the effect remembers, its tail included.
    fn reset(&mut self);

    /// Frames the effect keeps sounding after its input falls silent, which is
    /// how long the strip it sits on stays awake.
    fn tail_frames(&self) -> u64 {
        0
    }

    /// Frames of delay it adds. Reported, not compensated.
    fn latency_frames(&self) -> u32 {
        0
    }
}

/// Built-in effect kinds, by the id Tecs names them with.
pub const LIMITER: u32 = 1;
pub const FILTER: u32 = 2;
pub const EQ: u32 = 3;
pub const REVERB: u32 = 4;

/// Builds a built-in effect for a rate and channel count, or nothing for an
/// id this crate does not know.
pub fn builtin(kind: u32, rate: u32, channels: usize) -> Option<Box<dyn Effect>> {
    let rate = rate.max(1) as f32;
    match kind {
        LIMITER => Some(Box::new(Limiter::new(rate, channels))),
        FILTER => Some(Box::new(Filter::new(rate, channels))),
        EQ => Some(Box::new(Equalizer::new(rate, channels))),
        REVERB => Some(Box::new(Reverb::new(rate, channels))),
        _ => None,
    }
}

/// A value that moves towards its target by a fixed fraction per step, so a
/// parameter change is a short glide rather than a step.
#[derive(Clone, Copy)]
struct Smoothed {
    value: f32,
    target: f32,
}

impl Smoothed {
    fn new(value: f32) -> Smoothed {
        Smoothed {
            value,
            target: value,
        }
    }

    /// Moves a step towards the target and reports whether it moved.
    fn advance(&mut self, rate: f32) -> bool {
        if self.value == self.target {
            return false;
        }
        let next = self.value + (self.target - self.value) * rate;
        self.value = if (next - self.target).abs() < 1e-6 * self.target.abs().max(1e-3) {
            self.target
        } else {
            next
        };
        true
    }
}

// ---------------------------------------------------------------------------
// Limiter
// ---------------------------------------------------------------------------

/// Limiter parameters.
pub const LIMITER_CEILING: u32 = 0;
pub const LIMITER_RELEASE: u32 = 1;

/// The most frames of lookahead a limiter holds.
const LOOKAHEAD_MAX: usize = 256;

/// A lookahead peak limiter: the gain reaches its floor before the peak that
/// needs it does, so nothing past the ceiling leaves it.
pub struct Limiter {
    channels: usize,
    lookahead: usize,
    /// Interleaved delay line, and the gain each delayed frame needs.
    delay: Vec<f32>,
    needs: Vec<f32>,
    cursor: usize,
    gain: f32,
    ceiling: f32,
    release: f32,
    rate: f32,
}

impl Limiter {
    pub fn new(rate: f32, channels: usize) -> Limiter {
        let lookahead = ((rate * 0.001) as usize).clamp(1, LOOKAHEAD_MAX);
        let mut limiter = Limiter {
            channels: channels.max(1),
            lookahead,
            delay: vec![0.0; lookahead * channels.max(1)],
            needs: vec![1.0; lookahead],
            cursor: 0,
            gain: 1.0,
            // -1 dBFS.
            ceiling: 0.891_251,
            release: 0.0,
            rate,
        };
        limiter.set_release(0.05);
        limiter
    }

    fn set_release(&mut self, seconds: f32) {
        let frames = (seconds.max(0.001) * self.rate).max(1.0);
        self.release = 1.0 - (-1.0 / frames).exp();
    }
}

impl Effect for Limiter {
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        let width = self.channels.min(channels);
        for frame in 0..frames {
            let base = frame * channels;
            let mut peak = 0.0f32;
            for channel in 0..width {
                peak = peak.max(buffer[base + channel].abs());
            }
            let need = if peak > self.ceiling {
                self.ceiling / peak
            } else {
                1.0
            };
            // Swap the incoming frame into the delay line, taking out the one
            // that has waited the lookahead.
            let slot = self.cursor;
            self.needs[slot] = need;
            let mut floor = 1.0f32;
            for value in &self.needs {
                floor = floor.min(*value);
            }
            if floor < self.gain {
                // The window holds every frame still in the delay line, so
                // dropping to its floor now has the gain down a lookahead
                // before the peak that needs it leaves.
                self.gain = floor;
            } else {
                self.gain += (floor - self.gain) * self.release;
            }
            for channel in 0..width {
                let delayed = self.delay[slot * self.channels + channel];
                self.delay[slot * self.channels + channel] = buffer[base + channel];
                let out = delayed * self.gain;
                // The ceiling is a promise, so it holds even where the
                // envelope rounds.
                buffer[base + channel] = out.clamp(-self.ceiling, self.ceiling);
            }
            self.cursor = (self.cursor + 1) % self.lookahead;
        }
    }

    fn param(&mut self, id: u32, value: f32) {
        match id {
            LIMITER_CEILING => self.ceiling = value.clamp(0.001, 1.0),
            LIMITER_RELEASE => self.set_release(value),
            _ => {}
        }
    }

    fn reset(&mut self) {
        self.delay.iter_mut().for_each(|value| *value = 0.0);
        self.needs.iter_mut().for_each(|value| *value = 1.0);
        self.gain = 1.0;
    }

    fn latency_frames(&self) -> u32 {
        self.lookahead as u32
    }
}

// ---------------------------------------------------------------------------
// Biquad filter
// ---------------------------------------------------------------------------

/// Filter shapes, the RBJ cookbook's.
pub const SHAPE_LOWPASS: u32 = 0;
pub const SHAPE_HIGHPASS: u32 = 1;
pub const SHAPE_BANDPASS: u32 = 2;
pub const SHAPE_NOTCH: u32 = 3;
pub const SHAPE_PEAK: u32 = 4;
pub const SHAPE_LOWSHELF: u32 = 5;
pub const SHAPE_HIGHSHELF: u32 = 6;

/// Filter parameters.
pub const FILTER_SHAPE: u32 = 0;
pub const FILTER_FREQUENCY: u32 = 1;
pub const FILTER_Q: u32 = 2;
pub const FILTER_GAIN: u32 = 3;

/// The most channels a filter keeps state for.
const FILTER_CHANNELS: usize = 8;

/// Frames between coefficient updates while a parameter glides.
const GLIDE_FRAMES: usize = 32;

#[derive(Clone, Copy, Default)]
struct Coefficients {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

fn coefficients(shape: u32, rate: f32, frequency: f32, q: f32, gain_db: f32) -> Coefficients {
    let frequency = frequency.clamp(10.0, rate * 0.49);
    let q = q.max(0.05);
    let w0 = 2.0 * std::f32::consts::PI * frequency / rate;
    let (sin, cos) = w0.sin_cos();
    let alpha = sin / (2.0 * q);
    let a = 10f32.powf(gain_db / 40.0);
    let (b0, b1, b2, a0, a1, a2) = match shape {
        SHAPE_HIGHPASS => (
            (1.0 + cos) / 2.0,
            -(1.0 + cos),
            (1.0 + cos) / 2.0,
            1.0 + alpha,
            -2.0 * cos,
            1.0 - alpha,
        ),
        SHAPE_BANDPASS => (alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cos, 1.0 - alpha),
        SHAPE_NOTCH => (1.0, -2.0 * cos, 1.0, 1.0 + alpha, -2.0 * cos, 1.0 - alpha),
        SHAPE_PEAK => (
            1.0 + alpha * a,
            -2.0 * cos,
            1.0 - alpha * a,
            1.0 + alpha / a,
            -2.0 * cos,
            1.0 - alpha / a,
        ),
        SHAPE_LOWSHELF => {
            let root = 2.0 * a.sqrt() * alpha;
            (
                a * ((a + 1.0) - (a - 1.0) * cos + root),
                2.0 * a * ((a - 1.0) - (a + 1.0) * cos),
                a * ((a + 1.0) - (a - 1.0) * cos - root),
                (a + 1.0) + (a - 1.0) * cos + root,
                -2.0 * ((a - 1.0) + (a + 1.0) * cos),
                (a + 1.0) + (a - 1.0) * cos - root,
            )
        }
        SHAPE_HIGHSHELF => {
            let root = 2.0 * a.sqrt() * alpha;
            (
                a * ((a + 1.0) + (a - 1.0) * cos + root),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * cos),
                a * ((a + 1.0) + (a - 1.0) * cos - root),
                (a + 1.0) - (a - 1.0) * cos + root,
                2.0 * ((a - 1.0) - (a + 1.0) * cos),
                (a + 1.0) - (a - 1.0) * cos - root,
            )
        }
        // Low pass, and anything unknown.
        _ => (
            (1.0 - cos) / 2.0,
            1.0 - cos,
            (1.0 - cos) / 2.0,
            1.0 + alpha,
            -2.0 * cos,
            1.0 - alpha,
        ),
    };
    Coefficients {
        b0: b0 / a0,
        b1: b1 / a0,
        b2: b2 / a0,
        a1: a1 / a0,
        a2: a2 / a0,
    }
}

/// One biquad with its own coefficients and per-channel state.
struct Section {
    shape: u32,
    frequency: Smoothed,
    q: Smoothed,
    gain: Smoothed,
    rate: f32,
    coefficients: Coefficients,
    state: [[f32; 4]; FILTER_CHANNELS],
}

impl Section {
    fn new(rate: f32, shape: u32, frequency: f32, q: f32, gain: f32) -> Section {
        Section {
            shape,
            frequency: Smoothed::new(frequency),
            q: Smoothed::new(q),
            gain: Smoothed::new(gain),
            rate,
            coefficients: coefficients(shape, rate, frequency, q, gain),
            state: [[0.0; 4]; FILTER_CHANNELS],
        }
    }

    fn glide(&mut self) {
        let moved = self.frequency.advance(0.25) | self.q.advance(0.25) | self.gain.advance(0.25);
        if moved {
            self.coefficients = coefficients(
                self.shape,
                self.rate,
                self.frequency.value,
                self.q.value,
                self.gain.value,
            );
        }
    }

    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        let width = channels.min(FILTER_CHANNELS);
        let mut frame = 0;
        while frame < frames {
            self.glide();
            let end = (frame + GLIDE_FRAMES).min(frames);
            let c = self.coefficients;
            for index in frame..end {
                for channel in 0..width {
                    let slot = index * channels + channel;
                    let [x1, x2, y1, y2] = self.state[channel];
                    let x = buffer[slot];
                    let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
                    // Flush denormals, which cost more than the filter.
                    let y = if y.abs() < 1e-20 { 0.0 } else { y };
                    self.state[channel] = [x, x1, y, y1];
                    buffer[slot] = y;
                }
            }
            frame = end;
        }
    }

    fn reset(&mut self) {
        self.state = [[0.0; 4]; FILTER_CHANNELS];
    }
}

/// A single biquad: low or high pass, band pass, notch, peak or shelf.
pub struct Filter {
    section: Section,
}

impl Filter {
    pub fn new(rate: f32, _channels: usize) -> Filter {
        Filter {
            section: Section::new(
                rate,
                SHAPE_LOWPASS,
                20_000.0,
                std::f32::consts::FRAC_1_SQRT_2,
                0.0,
            ),
        }
    }
}

impl Effect for Filter {
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        self.section.process(buffer, frames, channels);
    }

    fn param(&mut self, id: u32, value: f32) {
        match id {
            FILTER_SHAPE => {
                self.section.shape = value as u32;
                let s = &self.section;
                self.section.coefficients =
                    coefficients(s.shape, s.rate, s.frequency.value, s.q.value, s.gain.value);
            }
            FILTER_FREQUENCY => self.section.frequency.target = value,
            FILTER_Q => self.section.q.target = value,
            FILTER_GAIN => self.section.gain.target = value,
            _ => {}
        }
    }

    fn reset(&mut self) {
        self.section.reset();
    }
}

/// Equalizer parameters: gain in dB and frequency per band, and the middle
/// band's Q.
pub const EQ_LOW_GAIN: u32 = 0;
pub const EQ_LOW_FREQUENCY: u32 = 1;
pub const EQ_MID_GAIN: u32 = 2;
pub const EQ_MID_FREQUENCY: u32 = 3;
pub const EQ_MID_Q: u32 = 4;
pub const EQ_HIGH_GAIN: u32 = 5;
pub const EQ_HIGH_FREQUENCY: u32 = 6;

/// Three bands: a low shelf, a peak and a high shelf, all flat by default.
pub struct Equalizer {
    bands: [Section; 3],
}

impl Equalizer {
    pub fn new(rate: f32, _channels: usize) -> Equalizer {
        Equalizer {
            bands: [
                Section::new(
                    rate,
                    SHAPE_LOWSHELF,
                    200.0,
                    std::f32::consts::FRAC_1_SQRT_2,
                    0.0,
                ),
                Section::new(rate, SHAPE_PEAK, 1_000.0, 1.0, 0.0),
                Section::new(
                    rate,
                    SHAPE_HIGHSHELF,
                    5_000.0,
                    std::f32::consts::FRAC_1_SQRT_2,
                    0.0,
                ),
            ],
        }
    }
}

impl Effect for Equalizer {
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        for band in &mut self.bands {
            // A flat band at rest passes the signal untouched; skip it.
            if band.gain.value == 0.0 && band.gain.target == 0.0 {
                continue;
            }
            band.process(buffer, frames, channels);
        }
    }

    fn param(&mut self, id: u32, value: f32) {
        match id {
            EQ_LOW_GAIN => self.bands[0].gain.target = value,
            EQ_LOW_FREQUENCY => self.bands[0].frequency.target = value,
            EQ_MID_GAIN => self.bands[1].gain.target = value,
            EQ_MID_FREQUENCY => self.bands[1].frequency.target = value,
            EQ_MID_Q => self.bands[1].q.target = value,
            EQ_HIGH_GAIN => self.bands[2].gain.target = value,
            EQ_HIGH_FREQUENCY => self.bands[2].frequency.target = value,
            _ => {}
        }
    }

    fn reset(&mut self) {
        for band in &mut self.bands {
            band.reset();
        }
    }
}

// ---------------------------------------------------------------------------
// Reverb
// ---------------------------------------------------------------------------

/// Reverb parameters, each from zero to one.
pub const REVERB_SIZE: u32 = 0;
pub const REVERB_DAMPING: u32 = 1;
pub const REVERB_WET: u32 = 2;
pub const REVERB_DRY: u32 = 3;
pub const REVERB_WIDTH: u32 = 4;

/// Comb and all-pass lengths at 44.1 kHz, the classic Schroeder-Moorer tuning
/// Freeverb made public domain, and the stereo spread between channels.
const COMBS: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const ALLPASSES: [usize; 4] = [556, 441, 341, 225];
const SPREAD: usize = 23;

struct Comb {
    buffer: Vec<f32>,
    cursor: usize,
    store: f32,
}

impl Comb {
    fn run(&mut self, input: f32, feedback: f32, damp: f32) -> f32 {
        let output = self.buffer[self.cursor];
        self.store = output * (1.0 - damp) + self.store * damp;
        self.buffer[self.cursor] = input + self.store * feedback;
        self.cursor = (self.cursor + 1) % self.buffer.len();
        output
    }
}

struct Allpass {
    buffer: Vec<f32>,
    cursor: usize,
}

impl Allpass {
    fn run(&mut self, input: f32) -> f32 {
        let delayed = self.buffer[self.cursor];
        let output = delayed - input;
        self.buffer[self.cursor] = input + delayed * 0.5;
        self.cursor = (self.cursor + 1) % self.buffer.len();
        output
    }
}

/// An algorithmic room: eight parallel combs into four all-passes per side.
///
/// A return bus is where it belongs, at full wet and no dry, with sends
/// setting how much of each Track reaches it.
pub struct Reverb {
    combs: [Vec<Comb>; 2],
    allpasses: [Vec<Allpass>; 2],
    size: Smoothed,
    damping: Smoothed,
    wet: Smoothed,
    dry: Smoothed,
    width: Smoothed,
    rate: f32,
}

impl Reverb {
    pub fn new(rate: f32, _channels: usize) -> Reverb {
        let scale = rate / 44_100.0;
        let make = |side: usize| -> (Vec<Comb>, Vec<Allpass>) {
            let offset = side * SPREAD;
            (
                COMBS
                    .iter()
                    .map(|length| Comb {
                        buffer: vec![0.0; (((length + offset) as f32) * scale).max(1.0) as usize],
                        cursor: 0,
                        store: 0.0,
                    })
                    .collect(),
                ALLPASSES
                    .iter()
                    .map(|length| Allpass {
                        buffer: vec![0.0; (((length + offset) as f32) * scale).max(1.0) as usize],
                        cursor: 0,
                    })
                    .collect(),
            )
        };
        let (left_combs, left_allpasses) = make(0);
        let (right_combs, right_allpasses) = make(1);
        Reverb {
            combs: [left_combs, right_combs],
            allpasses: [left_allpasses, right_allpasses],
            size: Smoothed::new(0.5),
            damping: Smoothed::new(0.5),
            wet: Smoothed::new(1.0),
            dry: Smoothed::new(0.0),
            width: Smoothed::new(1.0),
            rate,
        }
    }
}

impl Effect for Reverb {
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        let glide = 1.0 - (-1.0 / (0.02 * self.rate)).exp();
        for frame in 0..frames {
            self.size.advance(glide);
            self.damping.advance(glide);
            self.wet.advance(glide);
            self.dry.advance(glide);
            self.width.advance(glide);
            let feedback = 0.7 + self.size.value * 0.28;
            let damp = self.damping.value * 0.4;
            let base = frame * channels;
            let left_in = buffer[base];
            let right_in = if channels > 1 {
                buffer[base + 1]
            } else {
                left_in
            };
            // Freeverb's fixed input gain keeps the combs out of overload.
            let input = (left_in + right_in) * 0.015;
            let mut outs = [0.0f32; 2];
            for ((out, combs), allpasses) in outs
                .iter_mut()
                .zip(&mut self.combs)
                .zip(&mut self.allpasses)
            {
                let mut sum = 0.0;
                for comb in combs.iter_mut() {
                    sum += comb.run(input, feedback, damp);
                }
                for allpass in allpasses.iter_mut() {
                    sum = allpass.run(sum);
                }
                *out = sum;
            }
            let wet = self.wet.value * 3.0;
            let wet1 = wet * (self.width.value / 2.0 + 0.5);
            let wet2 = wet * ((1.0 - self.width.value) / 2.0);
            let dry = self.dry.value;
            buffer[base] = outs[0] * wet1 + outs[1] * wet2 + left_in * dry;
            if channels > 1 {
                buffer[base + 1] = outs[1] * wet1 + outs[0] * wet2 + right_in * dry;
            }
        }
    }

    fn param(&mut self, id: u32, value: f32) {
        let value = value.clamp(0.0, 1.0);
        match id {
            REVERB_SIZE => self.size.target = value,
            REVERB_DAMPING => self.damping.target = value,
            REVERB_WET => self.wet.target = value,
            REVERB_DRY => self.dry.target = value,
            REVERB_WIDTH => self.width.target = value,
            _ => {}
        }
    }

    fn reset(&mut self) {
        for side in 0..2 {
            for comb in &mut self.combs[side] {
                comb.buffer.iter_mut().for_each(|value| *value = 0.0);
                comb.store = 0.0;
            }
            for allpass in &mut self.allpasses[side] {
                allpass.buffer.iter_mut().for_each(|value| *value = 0.0);
            }
        }
    }

    fn tail_frames(&self) -> u64 {
        // Long enough for the largest room to fall 60 dB.
        (self.rate * (1.0 + self.size.value * 7.0)) as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limiter_holds_its_ceiling_and_passes_quiet_signal() {
        let mut limiter = Limiter::new(48_000.0, 2);
        let mut loud = vec![2.0f32; 2 * 4800];
        limiter.process(&mut loud, 4800, 2);
        assert!(
            loud.iter().all(|value| value.abs() <= 0.891_252),
            "nothing passes the ceiling"
        );
        let mut quiet = vec![0.25f32; 2 * 48_000];
        let mut fresh = Limiter::new(48_000.0, 2);
        fresh.process(&mut quiet, 48_000, 2);
        assert!(
            (quiet[2 * 47_000] - 0.25).abs() < 1e-4,
            "a quiet signal passes unchanged"
        );
        assert_eq!(fresh.latency_frames(), 48);
    }

    #[test]
    fn a_low_pass_filter_takes_out_the_highs() {
        let rate = 48_000.0;
        let mut filter = Filter::new(rate, 1);
        filter.param(FILTER_FREQUENCY, 500.0);
        // Let the glide settle on silence first.
        let mut settle = vec![0.0f32; 4800];
        filter.process(&mut settle, 4800, 1);
        let mut high: Vec<f32> = (0..4800)
            .map(|frame| (2.0 * std::f32::consts::PI * 8_000.0 * frame as f32 / rate).sin())
            .collect();
        filter.process(&mut high, 4800, 1);
        let peak = high[2400..]
            .iter()
            .fold(0.0f32, |most, value| most.max(value.abs()));
        assert!(peak < 0.02, "8 kHz through a 500 Hz low pass: {peak}");
    }

    #[test]
    fn a_reverb_rings_after_its_input_stops() {
        let mut reverb = Reverb::new(48_000.0, 2);
        let mut buffer = vec![0.0f32; 2 * 9600];
        buffer[0] = 1.0;
        buffer[1] = 1.0;
        reverb.process(&mut buffer, 9600, 2);
        let late = buffer[2 * 4800..]
            .iter()
            .fold(0.0f32, |most, value| most.max(value.abs()));
        assert!(late > 1e-4, "an impulse still rings 100 ms later");
        assert!(reverb.tail_frames() > 48_000);
    }

    #[test]
    fn a_flat_equalizer_passes_its_input_unchanged() {
        let mut eq = Equalizer::new(48_000.0, 2);
        let mut buffer: Vec<f32> = (0..960).map(|index| (index as f32 * 0.01).sin()).collect();
        let before = buffer.clone();
        eq.process(&mut buffer, 480, 2);
        assert_eq!(buffer, before);
    }
}
