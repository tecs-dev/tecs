//! The voices, and the loop that turns them into one output buffer.
//!
//! This is a focused mixer rather than an adapted one, and the reason is
//! narrow. Tecs needs a voice to change whether it loops part way through and
//! to play out to its natural end when looping is turned off; it needs a loop
//! return point; it needs a fade-out started at stop time and clocked by the
//! audio thread; and it needs an explicit pair of left and right speaker gains
//! that is not a single normalized pan. No established Rust mixer offers all of
//! those together, and each one that offers some of them also owns the device
//! and its own decode graph, so adapting one would mean writing custom sources
//! or a custom backend for it and taking the dependency as well. The behavior
//! that is left after Tecs keeps the voice pool, the groups and the admission
//! limits is fractional-rate resampling, a linear gain envelope, a speaker gain
//! pair and a loop wrap, which is what this file is.
//!
//! Everything here runs under one lock. The output callback takes it to fill a
//! buffer and Tecs takes it to apply a command batch or read a position, which
//! makes a long hold on the Tecs side audible. Nothing here allocates, opens a
//! file or decodes: a `PLAY` arrives with its source already built.

use crate::command::{self, Command, Event};
use crate::source::{Source, MAX_CHANNELS};

/// Where a voice sits in the output.
#[derive(Clone, Copy, PartialEq)]
enum Placement {
    /// Maps source channels onto output channels unchanged.
    None,
    /// Folds the source to mono and places it against a listener at the origin.
    Spatial { x: f32, y: f32, z: f32 },
    /// Scales the left and right output channels by an explicit gain each.
    Stereo { left: f32, right: f32 },
}

/// How many source frames one voice pulls ahead of the resampler.
const STAGING_FRAMES: usize = 256;

/// How many times a looping voice may restart inside one output frame before
/// the mixer gives up on it.
///
/// A clip whose loop region holds no frames would otherwise spin here forever,
/// and a file that decodes to nothing is a real thing to be handed.
const MAX_LOOP_RESTARTS: u32 = 4;

/// One playback in progress.
struct Voice {
    handle: u32,
    source: Box<dyn Source>,
    gain: f32,
    pitch: f32,
    placement: Placement,
    repeating: bool,
    loop_start: f64,
    paused: bool,
    /// The envelope the fades move, multiplied with `gain`.
    envelope: f32,
    /// How far the envelope moves per output frame, and zero when it is at rest.
    envelope_step: f32,
    /// Set while a fade-out is running the voice down to silence.
    stopping: bool,
    /// The fractional position between `previous` and `upcoming`.
    fraction: f64,
    previous: [f32; MAX_CHANNELS],
    upcoming: [f32; MAX_CHANNELS],
    primed: bool,
    staging: Vec<f32>,
    staged: usize,
    consumed: usize,
    ended: bool,
}

impl Voice {
    /// Reports how far the read cursor advances per output frame.
    fn step(&self, output_rate: u32) -> f64 {
        if output_rate == 0 {
            return 0.0;
        }
        self.pitch as f64 * self.source.sample_rate() as f64 / output_rate as f64
    }

    /// Moves one source frame into `upcoming`, reporting whether it found one.
    ///
    /// A false answer is either the end of the input or a streamed source whose
    /// decoder has not kept up, and `ended` says which.
    fn pull(&mut self) -> bool {
        let channels = self.source.channels() as usize;
        if channels == 0 || channels > MAX_CHANNELS {
            self.ended = true;
            return false;
        }
        let mut restarts = 0;
        while self.consumed >= self.staged {
            self.staged = self.source.read(&mut self.staging);
            self.consumed = 0;
            if self.staged > 0 {
                break;
            }
            if !self.source.exhausted() {
                // A streamed voice whose feeder is behind. Silence for this
                // frame is the answer, not the end of the voice.
                return false;
            }
            if !self.repeating {
                self.ended = true;
                return false;
            }
            restarts += 1;
            if restarts > MAX_LOOP_RESTARTS || !self.source.seek(self.loop_start) {
                self.ended = true;
                return false;
            }
        }
        self.previous = self.upcoming;
        let from = self.consumed * channels;
        for channel in 0..channels {
            self.upcoming[channel] = self.staging[from + channel];
        }
        self.consumed += 1;
        true
    }

    /// Starts a fade to `target` over `seconds`, or moves there at once.
    fn fade_to(&mut self, target: f32, seconds: f32, output_rate: u32) {
        if seconds <= 0.0 || output_rate == 0 {
            self.envelope = target;
            self.envelope_step = 0.0;
            return;
        }
        let frames = (seconds * output_rate as f32).max(1.0);
        self.envelope_step = (target - self.envelope) / frames;
    }
}

/// Mixes every voice into one output buffer.
pub struct Mixer {
    voices: Vec<Voice>,
    events: Vec<Event>,
    master_gain: f32,
    output_rate: u32,
    output_channels: u16,
    max_voices: usize,
}

impl Mixer {
    /// Creates an empty mixer for one output layout.
    pub fn new(output_rate: u32, output_channels: u16, max_voices: usize) -> Mixer {
        Mixer {
            voices: Vec::with_capacity(max_voices),
            events: Vec::with_capacity(max_voices),
            master_gain: 1.0,
            output_rate,
            output_channels,
            max_voices,
        }
    }

    /// Reports how many voices are sounding, paused ones included.
    pub fn voice_count(&self) -> usize {
        self.voices.len()
    }

    /// Returns the index of the voice a handle names.
    fn index_of(&self, handle: u32) -> Option<usize> {
        self.voices.iter().position(|voice| voice.handle == handle)
    }

    /// Reports a voice's read position in seconds, or `None` for a handle that
    /// names nothing.
    pub fn position(&self, handle: u32) -> Option<f64> {
        self.index_of(handle)
            .map(|index| self.voices[index].source.position())
    }

    /// Moves a voice's read position and reports whether the input accepted it.
    pub fn seek(&mut self, handle: u32, seconds: f64) -> bool {
        match self.index_of(handle) {
            None => false,
            Some(index) => {
                let voice = &mut self.voices[index];
                if !voice.source.seek(seconds.max(0.0)) {
                    return false;
                }
                // The interpolator holds two frames from before the seek, and
                // playing them after it would be a click at the new position.
                voice.staged = 0;
                voice.consumed = 0;
                voice.primed = false;
                voice.fraction = 0.0;
                voice.previous = [0.0; MAX_CHANNELS];
                voice.upcoming = [0.0; MAX_CHANNELS];
                true
            }
        }
    }

    /// Moves every observation since the last drain into `out` and returns how
    /// many it wrote.
    pub fn drain(&mut self, out: &mut [Event]) -> usize {
        let count = self.events.len().min(out.len());
        out[..count].copy_from_slice(&self.events[..count]);
        self.events.drain(..count);
        count
    }

    /// Ends every voice without a fade and reports each one finished.
    pub fn stop_all(&mut self) {
        for voice in self.voices.drain(..) {
            self.events.push(Event {
                kind: command::EVENT_FINISHED,
                handle: voice.handle,
            });
        }
    }

    /// Applies one command, taking the source a `PLAY` was prepared with.
    ///
    /// The source arrives already built, because opening and decoding a file
    /// under the lock the output callback also takes would be heard.
    pub fn apply(&mut self, command: &Command, source: Option<Box<dyn Source>>) {
        match command.kind {
            command::PLAY => self.start(command, source),
            command::STOP => self.stop(command),
            command::PAUSE => self.set_paused(command.handle, true),
            command::RESUME => self.set_paused(command.handle, false),
            command::SET_GAIN => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].gain = command.gain;
                }
            }
            command::SET_PITCH => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].pitch = command.pitch;
                }
            }
            command::SET_LOOP => {
                if let Some(index) = self.index_of(command.handle) {
                    // Turning repetition off lets the voice play out to its end
                    // rather than cutting it, which is the whole point of the
                    // setting being live.
                    self.voices[index].repeating = command.has(command::FLAG_LOOP);
                }
            }
            command::SET_POSITION => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::Spatial {
                        x: command.x,
                        y: command.y,
                        z: command.z,
                    };
                }
            }
            command::SET_STEREO => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::Stereo {
                        left: command.x,
                        right: command.y,
                    };
                }
            }
            command::CLEAR_PLACEMENT => {
                if let Some(index) = self.index_of(command.handle) {
                    self.voices[index].placement = Placement::None;
                }
            }
            command::SET_MASTER_GAIN => self.master_gain = command.gain,
            _ => {}
        }
    }

    /// Starts a voice, dropping the request when the pool is full or the caller
    /// prepared no source.
    fn start(&mut self, command: &Command, source: Option<Box<dyn Source>>) {
        let mut source = match source {
            None => return,
            Some(value) => value,
        };
        if self.voices.len() >= self.max_voices || command.handle == 0 {
            return;
        }
        if command.start > 0.0 {
            source.seek(command.start as f64);
        }
        let placement = if command.has(command::FLAG_SPATIAL) {
            Placement::Spatial {
                x: command.x,
                y: command.y,
                z: command.z,
            }
        } else if command.has(command::FLAG_STEREO) {
            Placement::Stereo {
                left: command.x,
                right: command.y,
            }
        } else {
            Placement::None
        };
        let mut voice = Voice {
            handle: command.handle,
            source,
            gain: command.gain,
            pitch: command.pitch,
            placement,
            repeating: command.has(command::FLAG_LOOP),
            loop_start: command.loop_start.max(0.0) as f64,
            paused: false,
            envelope: 1.0,
            envelope_step: 0.0,
            stopping: false,
            fraction: 0.0,
            previous: [0.0; MAX_CHANNELS],
            upcoming: [0.0; MAX_CHANNELS],
            primed: false,
            staging: vec![0.0; STAGING_FRAMES * MAX_CHANNELS],
            staged: 0,
            consumed: 0,
            ended: false,
        };
        if command.fade > 0.0 {
            voice.envelope = 0.0;
            voice.fade_to(1.0, command.fade, self.output_rate);
        }
        self.voices.push(voice);
    }

    /// Ends a voice at once, or starts the fade that will.
    fn stop(&mut self, command: &Command) {
        let index = match self.index_of(command.handle) {
            None => return,
            Some(value) => value,
        };
        if command.fade > 0.0 {
            let rate = self.output_rate;
            let voice = &mut self.voices[index];
            // A paused voice does not advance, so its fade would never finish.
            voice.paused = false;
            voice.stopping = true;
            voice.fade_to(0.0, command.fade, rate);
            return;
        }
        let voice = self.voices.remove(index);
        self.events.push(Event {
            kind: command::EVENT_FINISHED,
            handle: voice.handle,
        });
    }

    /// Holds a voice where it is, or lets it carry on.
    fn set_paused(&mut self, handle: u32, paused: bool) {
        if let Some(index) = self.index_of(handle) {
            let voice = &mut self.voices[index];
            // A voice fading out to its end is not one a pause may hold, or the
            // fade would never finish and the voice would never be reaped.
            if !voice.stopping {
                voice.paused = paused;
            }
        }
    }

    /// Fills `out` with the mix and reports every voice that ended inside it.
    ///
    /// `out` is interleaved at the mixer's own channel count, and whatever it
    /// held is overwritten rather than added to.
    pub fn render(&mut self, out: &mut [f32]) {
        for sample in out.iter_mut() {
            *sample = 0.0;
        }
        let channels = self.output_channels as usize;
        if channels == 0 || self.output_rate == 0 {
            return;
        }
        let frames = out.len() / channels;
        let rate = self.output_rate;
        let mut index = 0;
        while index < self.voices.len() {
            render_voice(&mut self.voices[index], out, channels, frames, rate);
            if self.voices[index].ended {
                let voice = self.voices.remove(index);
                self.events.push(Event {
                    kind: command::EVENT_FINISHED,
                    handle: voice.handle,
                });
            } else {
                index += 1;
            }
        }
        if self.master_gain != 1.0 {
            for sample in out.iter_mut() {
                *sample *= self.master_gain;
            }
        }
    }
}

/// Adds one voice into the output buffer.
fn render_voice(voice: &mut Voice, out: &mut [f32], channels: usize, frames: usize, rate: u32) {
    if voice.paused || voice.ended {
        return;
    }
    let step = voice.step(rate);
    let source_channels = voice.source.channels() as usize;
    if source_channels == 0 || source_channels > MAX_CHANNELS {
        voice.ended = true;
        return;
    }
    if !voice.primed {
        // Two frames of context before the first interpolation, so the voice
        // starts on real samples rather than on the zeros it was built with.
        if !voice.pull() {
            return;
        }
        voice.pull();
        voice.primed = true;
    }

    let mut frame = [0.0f32; MAX_CHANNELS];
    for position in 0..frames {
        while voice.fraction >= 1.0 {
            if !voice.pull() {
                // Either the input ended, which `ended` records, or a streamed
                // one is behind. Both leave the rest of this buffer alone.
                return;
            }
            voice.fraction -= 1.0;
        }
        let blend = voice.fraction as f32;
        for (channel, value) in frame.iter_mut().enumerate().take(source_channels) {
            let previous = voice.previous[channel];
            *value = previous + (voice.upcoming[channel] - previous) * blend;
        }

        if voice.envelope_step != 0.0 {
            voice.envelope += voice.envelope_step;
            if voice.envelope_step > 0.0 && voice.envelope >= 1.0 {
                voice.envelope = 1.0;
                voice.envelope_step = 0.0;
            } else if voice.envelope_step < 0.0 && voice.envelope <= 0.0 {
                voice.envelope = 0.0;
                voice.envelope_step = 0.0;
                if voice.stopping {
                    voice.ended = true;
                    return;
                }
            }
        }
        let level = voice.gain * voice.envelope;
        let (left, right) = speaker_gains(voice.placement);
        let base = position * channels;

        match voice.placement {
            Placement::Spatial { .. } => {
                // A positioned voice folds to mono before it is placed, because
                // a position and a stereo image are two answers to the same
                // question.
                let sum: f32 = frame.iter().take(source_channels).sum();
                let mono = sum / source_channels as f32 * level;
                out[base] += mono * left;
                if channels > 1 {
                    out[base + 1] += mono * right;
                }
            }
            _ => {
                for channel in 0..channels.min(2) {
                    let side = if channel == 0 { left } else { right };
                    let value = if source_channels == 1 {
                        frame[0]
                    } else {
                        frame[channel.min(source_channels - 1)]
                    };
                    out[base + channel] += value * level * side;
                }
            }
        }

        voice.fraction += step;
    }
}

/// Returns the left and right gains a placement contributes.
fn speaker_gains(placement: Placement) -> (f32, f32) {
    match placement {
        Placement::None => (1.0, 1.0),
        Placement::Stereo { left, right } => (left.max(0.0), right.max(0.0)),
        Placement::Spatial { x, y, z } => {
            let distance = (x * x + y * y + z * z).sqrt();
            // Inverse attenuation rather than inverse square, so a sound one
            // unit away is half as loud rather than as loud as one at the
            // listener's ear. The scale between world units and this is the
            // game's to choose, which is why nothing here is configurable.
            let attenuation = 1.0 / (1.0 + distance);
            let pan = if distance > 0.0 { x / distance } else { 0.0 };
            // Equal power, so a sound crossing the listener keeps its level
            // instead of dipping in the middle.
            let left = ((1.0 - pan) * 0.5).max(0.0).sqrt();
            let right = ((1.0 + pan) * 0.5).max(0.0).sqrt();
            (attenuation * left, attenuation * right)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::ResidentSource;
    use std::sync::Arc;

    const RATE: u32 = 48_000;

    fn constant(frames: usize, value: f32) -> Box<dyn Source> {
        let samples: Arc<[f32]> = vec![value; frames * 2].into();
        Box::new(ResidentSource::new(samples, 2, RATE))
    }

    fn ramp(frames: usize) -> Box<dyn Source> {
        let mut samples = Vec::with_capacity(frames * 2);
        for index in 0..frames {
            samples.push(index as f32);
            samples.push(index as f32);
        }
        Box::new(ResidentSource::new(samples.into(), 2, RATE))
    }

    fn play(handle: u32) -> Command {
        Command {
            kind: command::PLAY,
            handle,
            clip: 1,
            flags: 0,
            gain: 1.0,
            pitch: 1.0,
            start: 0.0,
            fade: 0.0,
            loop_start: 0.0,
            x: 0.0,
            y: 0.0,
            z: 0.0,
        }
    }

    fn plain(kind: u32, handle: u32) -> Command {
        let mut command = play(handle);
        command.kind = kind;
        command.clip = 0;
        command
    }

    fn finished(mixer: &mut Mixer) -> Vec<u32> {
        let mut out = [Event { kind: 0, handle: 0 }; 16];
        let count = mixer.drain(&mut out);
        out[..count].iter().map(|event| event.handle).collect()
    }

    #[test]
    fn mixes_a_resident_voice_at_its_own_gain() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.gain = 0.5;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 16];
        mixer.render(&mut out);
        assert!((out[0] - 0.5).abs() < 1e-5, "got {}", out[0]);
        assert!((out[1] - 0.5).abs() < 1e-5);
        assert_eq!(mixer.voice_count(), 1);
    }

    #[test]
    fn reports_a_voice_finished_when_its_input_runs_out() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(4, 1.0)));
        let mut out = vec![0.0f32; 64];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn keeps_a_repeating_voice_going_and_lets_it_finish_when_looping_stops() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        mixer.apply(&command, Some(constant(4, 1.0)));

        let mut out = vec![0.0f32; 200];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 1, "a looping voice does not run out");
        assert!(out[100] != 0.0, "it is still producing sound");

        // Clearing the flag lets the voice play out rather than cutting it.
        let mut off = plain(command::SET_LOOP, 7);
        off.flags = 0;
        mixer.apply(&off, None);
        assert_eq!(mixer.voice_count(), 1);
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn returns_a_repeat_to_its_loop_point() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        // Two frames in, out of four.
        command.loop_start = 2.0 / RATE as f32;
        mixer.apply(&command, Some(ramp(4)));

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        // The intro frames are heard once and the tail repeats, so the ramp
        // never falls back below the loop point after the first pass.
        let heard: Vec<f32> = out.iter().step_by(2).copied().collect();
        assert!(heard[0] < 1.0);
        assert!(
            heard[5..].iter().all(|value| *value >= 1.5),
            "after the first pass the voice stays past the loop point: {heard:?}"
        );
    }

    #[test]
    fn runs_a_fade_out_to_silence_before_ending_the_voice() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_LOOP;
        mixer.apply(&command, Some(constant(1024, 1.0)));

        let mut stop = plain(command::STOP, 7);
        // Sixteen output frames of ramp.
        stop.fade = 16.0 / RATE as f32;
        mixer.apply(&stop, None);

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 1, "the fade is still running");
        assert!(out[0] > out[14], "the voice is on the way down");
        assert!(finished(&mut mixer).is_empty());

        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn runs_a_fade_in_from_silence() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.fade = 32.0 / RATE as f32;
        mixer.apply(&command, Some(constant(1024, 1.0)));

        let mut out = vec![0.0f32; 2 * 8];
        mixer.render(&mut out);
        assert!(out[0] < 0.2, "it starts near silence: {}", out[0]);
        assert!(out[14] > out[0], "and rises");
    }

    #[test]
    fn ends_a_voice_at_once_when_a_stop_carries_no_fade() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(1024, 1.0)));
        mixer.apply(&plain(command::STOP, 7), None);
        assert_eq!(mixer.voice_count(), 0);
        assert_eq!(finished(&mut mixer), vec![7]);
    }

    #[test]
    fn holds_a_paused_voice_without_ending_it() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(8, 1.0)));
        mixer.apply(&plain(command::PAUSE, 7), None);

        let mut out = vec![0.0f32; 2 * 64];
        mixer.render(&mut out);
        assert!(out.iter().all(|value| *value == 0.0));
        assert_eq!(mixer.voice_count(), 1);

        mixer.apply(&plain(command::RESUME, 7), None);
        mixer.render(&mut out);
        assert!(out[0] != 0.0);
    }

    #[test]
    fn resamples_a_pitched_voice_over_a_longer_stretch() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut half = play(7);
        half.pitch = 0.5;
        mixer.apply(&half, Some(constant(32, 1.0)));
        let mut out = vec![0.0f32; 2 * 40];
        mixer.render(&mut out);
        // Half rate reaches only half way through the input, so the voice
        // survives a buffer that would have exhausted it at rate one.
        assert_eq!(mixer.voice_count(), 1);

        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut double = play(9);
        double.pitch = 2.0;
        mixer.apply(&double, Some(constant(32, 1.0)));
        mixer.render(&mut out);
        assert_eq!(mixer.voice_count(), 0);
    }

    #[test]
    fn scales_the_speakers_separately_for_an_explicit_pair() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_STEREO;
        command.x = 0.8;
        command.y = 0.2;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.8).abs() < 1e-5, "got {}", out[0]);
        assert!((out[1] - 0.2).abs() < 1e-5, "got {}", out[1]);
    }

    #[test]
    fn places_a_positioned_voice_and_attenuates_it_with_distance() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.flags = command::FLAG_SPATIAL;
        command.x = 1.0;
        mixer.apply(&command, Some(constant(64, 1.0)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!(
            out[1] > out[0],
            "a sound on the right is louder on the right"
        );
        assert!(out[1] < 1.0, "and quieter than one at the listener");

        // The placement is exclusive: setting a pan replaces the position.
        let mut pan = plain(command::SET_STEREO, 7);
        pan.x = 1.0;
        pan.y = 1.0;
        mixer.apply(&pan, None);
        mixer.render(&mut out);
        assert!((out[0] - 1.0).abs() < 1e-5);
        assert!((out[1] - 1.0).abs() < 1e-5);

        mixer.apply(&plain(command::CLEAR_PLACEMENT, 7), None);
        mixer.render(&mut out);
        assert!((out[0] - 1.0).abs() < 1e-5);
    }

    #[test]
    fn scales_the_whole_mix_with_master_gain() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(64, 1.0)));
        let mut master = plain(command::SET_MASTER_GAIN, 0);
        master.gain = 0.25;
        mixer.apply(&master, None);
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.25).abs() < 1e-5, "got {}", out[0]);
    }

    #[test]
    fn sums_every_voice_into_one_buffer() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(64, 0.25)));
        mixer.apply(&play(8), Some(constant(64, 0.25)));
        let mut out = vec![0.0f32; 2 * 4];
        mixer.render(&mut out);
        assert!((out[0] - 0.5).abs() < 1e-5, "got {}", out[0]);
    }

    #[test]
    fn refuses_a_voice_past_the_pool_ceiling() {
        let mut mixer = Mixer::new(RATE, 2, 2);
        mixer.apply(&play(7), Some(constant(64, 1.0)));
        mixer.apply(&play(8), Some(constant(64, 1.0)));
        mixer.apply(&play(9), Some(constant(64, 1.0)));
        assert_eq!(mixer.voice_count(), 2);
    }

    #[test]
    fn ignores_a_command_naming_no_voice() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&plain(command::STOP, 404), None);
        mixer.apply(&plain(command::PAUSE, 404), None);
        mixer.apply(&plain(command::SET_GAIN, 404), None);
        assert_eq!(mixer.voice_count(), 0);
        assert!(finished(&mut mixer).is_empty());
    }

    #[test]
    fn reads_and_moves_a_voice_position() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(RATE as usize, 1.0)));
        assert_eq!(mixer.position(7), Some(0.0));
        assert!(mixer.seek(7, 0.5));
        let position = mixer.position(7).expect("the voice is sounding");
        assert!((position - 0.5).abs() < 1e-3, "got {position}");
        assert_eq!(mixer.position(404), None);
        assert!(!mixer.seek(404, 0.5));
    }

    #[test]
    fn starts_a_voice_at_an_offset() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        let mut command = play(7);
        command.start = 0.5;
        mixer.apply(&command, Some(constant(RATE as usize, 1.0)));
        let position = mixer.position(7).expect("the voice is sounding");
        assert!((position - 0.5).abs() < 1e-3, "got {position}");
    }

    #[test]
    fn drains_no_more_observations_than_the_caller_has_room_for() {
        let mut mixer = Mixer::new(RATE, 2, 8);
        mixer.apply(&play(7), Some(constant(8, 1.0)));
        mixer.apply(&play(8), Some(constant(8, 1.0)));
        mixer.apply(&plain(command::STOP, 7), None);
        mixer.apply(&plain(command::STOP, 8), None);

        let mut out = [Event { kind: 0, handle: 0 }; 1];
        assert_eq!(mixer.drain(&mut out), 1);
        assert_eq!(out[0].handle, 7);
        assert_eq!(mixer.drain(&mut out), 1);
        assert_eq!(out[0].handle, 8);
        assert_eq!(mixer.drain(&mut out), 0);
    }
}
