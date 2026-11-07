//! What an agent, or a test, uses to hear the mix without ears.
//!
//! A [`Tap`] records the mixer's output as it renders, on whichever thread
//! renders it: the device callback, the void output's supervisor, or the
//! caller of an offline render. Its buffer is allocated when the capture is
//! armed, on the control side, so the render path only copies.
//!
//! [`summarize`] turns a recording into numbers an agent can reason about:
//! peak, RMS, integrated loudness (ITU-R BS.1770, gated), clipped samples,
//! silent spans and onset times. [`wav`] turns it into a file a person can
//! play.

/// A recording of the mixer's output, filled on the render path.
pub struct Tap {
    samples: Vec<f32>,
    /// Interleaved samples written so far.
    written: usize,
    channels: u16,
    /// The output frame the recording began on.
    pub started: u64,
}

impl Tap {
    /// Creates a recording of up to `frames` frames, allocating it now.
    pub fn new(frames: usize, channels: u16, started: u64) -> Tap {
        Tap {
            samples: vec![0.0; frames * channels as usize],
            written: 0,
            channels,
            started,
        }
    }

    /// Copies as much of one rendered buffer as still fits.
    pub fn record(&mut self, out: &[f32]) {
        let room = self.samples.len() - self.written;
        let take = room.min(out.len());
        self.samples[self.written..self.written + take].copy_from_slice(&out[..take]);
        self.written += take;
    }

    /// Reports whether the recording has its frames.
    pub fn full(&self) -> bool {
        self.written == self.samples.len()
    }

    /// Reports the frames recorded so far.
    pub fn frames(&self) -> usize {
        self.written / (self.channels as usize).max(1)
    }

    /// Returns the interleaved samples recorded so far.
    pub fn samples(&self) -> &[f32] {
        &self.samples[..self.written]
    }

    /// Reports the channels each frame carries.
    pub fn channels(&self) -> u16 {
        self.channels
    }
}

/// Below this, in dBFS, a stretch counts as silent.
pub const SILENCE_DBFS: f64 = -60.0;

/// The shortest stretch reported as silent, in seconds.
pub const SILENCE_SECONDS: f64 = 0.05;

/// The most silent spans and onsets a summary carries.
pub const MAX_SPANS: usize = 16;
pub const MAX_ONSETS: usize = 64;

/// What a recording sounded like, in numbers.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Summary {
    pub frames: u64,
    pub seconds: f64,
    /// The largest absolute sample, linear, and in dBFS (negative infinity
    /// for digital silence).
    pub peak: f64,
    pub peak_dbfs: f64,
    /// The root mean square over every sample, linear, and in dBFS.
    pub rms: f64,
    pub rms_dbfs: f64,
    /// Integrated loudness in LUFS, gated as BS.1770-4 specifies, and negative
    /// infinity when every block falls under the absolute gate.
    pub lufs: f64,
    /// Samples at or beyond full scale.
    pub clipped: u64,
    /// Silent stretches, as start and end seconds into the recording.
    pub silent_count: u32,
    pub silent: [[f64; 2]; MAX_SPANS],
    /// Seconds into the recording where the level jumps, at most `MAX_ONSETS`.
    pub onset_count: u32,
    pub onsets: [f64; MAX_ONSETS],
}

fn dbfs(linear: f64) -> f64 {
    if linear <= 0.0 {
        f64::NEG_INFINITY
    } else {
        20.0 * linear.log10()
    }
}

/// One biquad section in direct form I.
#[derive(Clone, Copy)]
struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Biquad {
    fn run(&mut self, input: f64) -> f64 {
        let output = self.b[0] * input + self.b[1] * self.x[0] + self.b[2] * self.x[1]
            - self.a[0] * self.y[0]
            - self.a[1] * self.y[1];
        self.x = [input, self.x[0]];
        self.y = [output, self.y[0]];
        output
    }
}

/// The two K-weighting stages for a sample rate, derived from their analog
/// prototypes so any rate gets the filter BS.1770 specifies at 48 kHz.
fn k_weighting(rate: f64) -> [Biquad; 2] {
    // The high shelf.
    let f0 = 1_681.974_450_955_533;
    let gain = 3.999_843_853_973_347;
    let q = 0.707_175_236_955_419_6;
    let k = (std::f64::consts::PI * f0 / rate).tan();
    let vh = 10f64.powf(gain / 20.0);
    let vb = vh.powf(0.499_666_774_154_541_6);
    let a0 = 1.0 + k / q + k * k;
    let shelf = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    // The high pass.
    let f0 = 38.135_470_876_024_44;
    let q = 0.500_327_037_323_877_3;
    let k = (std::f64::consts::PI * f0 / rate).tan();
    let a0 = 1.0 + k / q + k * k;
    let pass = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    [shelf, pass]
}

/// Integrated loudness of interleaved samples, with every channel weighted
/// one, which is BS.1770's weight for left, right and centre.
fn loudness(samples: &[f32], channels: usize, rate: u32) -> f64 {
    let frames = samples.len() / channels;
    let block = (rate as usize * 4) / 10;
    let hop = block / 4;
    if frames < block || hop == 0 {
        return f64::NEG_INFINITY;
    }
    let mut filters: Vec<[Biquad; 2]> = (0..channels).map(|_| k_weighting(rate as f64)).collect();
    // Per hop, per channel, the sum of squares of the weighted signal.
    let hops = frames / hop;
    let mut energy = vec![0.0f64; hops * channels];
    for frame in 0..hops * hop {
        let slot = frame / hop;
        for channel in 0..channels {
            let [shelf, pass] = &mut filters[channel];
            let weighted = pass.run(shelf.run(samples[frame * channels + channel] as f64));
            energy[slot * channels + channel] += weighted * weighted;
        }
    }
    // Overlapping 400 ms blocks are four hops each.
    let mut blocks: Vec<f64> = Vec::new();
    for start in 0..=hops.saturating_sub(4) {
        let mut sum = 0.0;
        for channel in 0..channels {
            let mut z = 0.0;
            for slot in start..start + 4 {
                z += energy[slot * channels + channel];
            }
            sum += z / block as f64;
        }
        blocks.push(sum);
    }
    let lufs = |power: f64| -0.691 + 10.0 * power.log10();
    let gated: Vec<f64> = blocks
        .iter()
        .copied()
        .filter(|power| lufs(*power) > -70.0)
        .collect();
    if gated.is_empty() {
        return f64::NEG_INFINITY;
    }
    let mean = gated.iter().sum::<f64>() / gated.len() as f64;
    let threshold = lufs(mean) - 10.0;
    let kept: Vec<f64> = gated
        .into_iter()
        .filter(|power| lufs(*power) > threshold)
        .collect();
    if kept.is_empty() {
        return f64::NEG_INFINITY;
    }
    lufs(kept.iter().sum::<f64>() / kept.len() as f64)
}

impl Summary {
    /// Writes the summary as one JSON object, with silence as `null` where
    /// a level is negative infinity, which JSON cannot spell.
    pub fn to_json(&self) -> String {
        fn number(value: f64) -> String {
            if value.is_finite() {
                format!("{value:.6}")
            } else {
                "null".to_string()
            }
        }
        let silent: Vec<String> = self.silent[..self.silent_count as usize]
            .iter()
            .map(|span| format!("[{},{}]", number(span[0]), number(span[1])))
            .collect();
        let onsets: Vec<String> = self.onsets[..self.onset_count as usize]
            .iter()
            .map(|at| number(*at))
            .collect();
        format!(
            "{{\"frames\":{},\"seconds\":{},\"peak\":{},\"peakDbfs\":{},\"rms\":{},\"rmsDbfs\":{},\"lufs\":{},\"clipped\":{},\"silent\":[{}],\"onsets\":[{}]}}",
            self.frames,
            number(self.seconds),
            number(self.peak),
            number(self.peak_dbfs),
            number(self.rms),
            number(self.rms_dbfs),
            number(self.lufs),
            self.clipped,
            silent.join(","),
            onsets.join(",")
        )
    }
}

/// Summarizes interleaved samples at `rate`.
pub fn summarize(samples: &[f32], channels: u16, rate: u32) -> Summary {
    let width = (channels as usize).max(1);
    let frames = samples.len() / width;
    let mut summary = Summary {
        frames: frames as u64,
        seconds: if rate == 0 {
            0.0
        } else {
            frames as f64 / rate as f64
        },
        peak: 0.0,
        peak_dbfs: f64::NEG_INFINITY,
        rms: 0.0,
        rms_dbfs: f64::NEG_INFINITY,
        lufs: f64::NEG_INFINITY,
        clipped: 0,
        silent_count: 0,
        silent: [[0.0; 2]; MAX_SPANS],
        onset_count: 0,
        onsets: [0.0; MAX_ONSETS],
    };
    if frames == 0 || rate == 0 {
        return summary;
    }
    let mut squares = 0.0f64;
    for sample in samples {
        let value = (*sample as f64).abs();
        summary.peak = summary.peak.max(value);
        squares += value * value;
        if value >= 1.0 {
            summary.clipped += 1;
        }
    }
    summary.rms = (squares / samples.len() as f64).sqrt();
    summary.peak_dbfs = dbfs(summary.peak);
    summary.rms_dbfs = dbfs(summary.rms);
    summary.lufs = loudness(samples, width, rate);

    // Ten-millisecond windows drive both the silence and the onset reports.
    let window = (rate as usize / 100).max(1);
    let windows = frames.div_ceil(window);
    let mut levels = Vec::with_capacity(windows);
    for index in 0..windows {
        let from = index * window * width;
        let to = ((index + 1) * window * width).min(samples.len());
        let mut sum = 0.0f64;
        for sample in &samples[from..to] {
            sum += (*sample as f64) * (*sample as f64);
        }
        levels.push(dbfs((sum / (to - from) as f64).sqrt()));
    }
    let seconds_of = |index: usize| (index * window) as f64 / rate as f64;
    let shortest = (SILENCE_SECONDS * 100.0).ceil() as usize;
    let mut quiet_from: Option<usize> = None;
    // One past the end closes a silent stretch that runs to the end.
    for (index, level) in levels.iter().map(Some).chain([None]).enumerate() {
        let quiet = level.is_some_and(|value| *value < SILENCE_DBFS);
        match (quiet, quiet_from) {
            (true, None) => quiet_from = Some(index),
            (false, Some(from)) => {
                if index - from >= shortest && (summary.silent_count as usize) < MAX_SPANS {
                    summary.silent[summary.silent_count as usize] =
                        [seconds_of(from), seconds_of(index).min(summary.seconds)];
                    summary.silent_count += 1;
                }
                quiet_from = None;
            }
            _ => {}
        }
    }
    // An onset is a window at least 12 dB above the quietest of the four
    // before it, and above the silence floor, at most one per 50 ms.
    let mut last: Option<usize> = None;
    for index in 0..windows {
        if levels[index] < SILENCE_DBFS {
            continue;
        }
        let from = index.saturating_sub(4);
        let before = levels[from..index]
            .iter()
            .copied()
            .fold(f64::INFINITY, f64::min);
        let rose = index == 0 || before == f64::NEG_INFINITY || levels[index] - before >= 12.0;
        let spaced = last.is_none_or(|previous| index - previous >= 5);
        if rose && spaced && (summary.onset_count as usize) < MAX_ONSETS {
            summary.onsets[summary.onset_count as usize] = seconds_of(index);
            summary.onset_count += 1;
            last = Some(index);
        }
    }
    summary
}

/// Encodes interleaved samples as a 32-bit float WAV file.
pub fn wav(samples: &[f32], channels: u16, rate: u32) -> Vec<u8> {
    let data = (samples.len() * 4) as u32;
    let mut bytes = Vec::with_capacity(44 + data as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&3u16.to_le_bytes());
    bytes.extend_from_slice(&channels.to_le_bytes());
    bytes.extend_from_slice(&rate.to_le_bytes());
    bytes.extend_from_slice(&(rate * channels as u32 * 4).to_le_bytes());
    bytes.extend_from_slice(&(channels * 4).to_le_bytes());
    bytes.extend_from_slice(&32u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data.to_le_bytes());
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(seconds: f64, amplitude: f32, rate: u32) -> Vec<f32> {
        let frames = (seconds * rate as f64) as usize;
        let mut out = Vec::with_capacity(frames * 2);
        for frame in 0..frames {
            let value = amplitude
                * (2.0 * std::f64::consts::PI * 1000.0 * frame as f64 / rate as f64).sin() as f32;
            out.push(value);
            out.push(value);
        }
        out
    }

    #[test]
    fn a_full_scale_stereo_sine_at_one_kilohertz_reads_about_zero_lufs_less_three() {
        // BS.1770's reference: a 0 dBFS 1 kHz sine in both channels of a
        // stereo pair reads -3.01 LKFS per channel, summed to about 0.
        let summary = summarize(&sine(3.0, 1.0, 48_000), 2, 48_000);
        assert!((summary.lufs - 0.0).abs() < 0.2, "got {}", summary.lufs);
        assert!((summary.peak - 1.0).abs() < 1e-3);
        assert!((summary.rms_dbfs + 3.01).abs() < 0.05);
    }

    #[test]
    fn reports_silence_clipping_and_an_onset() {
        let rate = 48_000;
        let mut samples = vec![0.0f32; rate as usize]; // half a second, stereo
        samples.extend(sine(0.5, 1.2, rate));
        let summary = summarize(&samples, 2, rate);
        assert!(summary.clipped > 0);
        assert_eq!(summary.silent_count, 1);
        assert!(summary.silent[0][0] == 0.0 && (summary.silent[0][1] - 0.5).abs() < 0.011);
        assert!(summary.onset_count >= 1);
        assert!(
            (summary.onsets[0] - 0.5).abs() < 0.011,
            "{:?}",
            &summary.onsets[..1]
        );
        assert_eq!(summarize(&[0.0; 4800], 2, rate).lufs, f64::NEG_INFINITY);
    }

    #[test]
    fn a_tap_keeps_only_the_frames_it_was_armed_for() {
        let mut tap = Tap::new(3, 2, 10);
        tap.record(&[1.0, 1.0, 2.0, 2.0]);
        tap.record(&[3.0, 3.0, 4.0, 4.0]);
        assert!(tap.full());
        assert_eq!(tap.samples(), &[1.0, 1.0, 2.0, 2.0, 3.0, 3.0]);
        assert_eq!(&wav(tap.samples(), 2, 48_000)[..4], b"RIFF");
    }
}
