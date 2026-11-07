//! The plain data crossing the seam from Tecs.
//!
//! Both structs are `repr(C)` and hold nothing but fixed-width scalars, because
//! Tecs writes an array of them straight into memory and hands over a pointer
//! and a count. The layout here and the `cdef struct` in
//! `src/tecs/platform/audionative.nupp` describe the same bytes, so a field
//! added on one side has to be added on the other.

/// Starts a voice on the named clip.
pub const PLAY: u32 = 1;

/// Ends a voice, over `fade` seconds when that is positive.
pub const STOP: u32 = 2;

/// Holds a voice where it is.
pub const PAUSE: u32 = 3;

/// Lets a paused voice carry on.
pub const RESUME: u32 = 4;

/// Sets the amplitude a voice reaches the mix at.
pub const SET_GAIN: u32 = 5;

/// Sets a voice's playback rate.
pub const SET_PITCH: u32 = 6;

/// Sets whether a voice repeats, reading the `LOOP` flag.
pub const SET_LOOP: u32 = 7;

/// Places a voice at `x`, `y` and `z`.
pub const SET_POSITION: u32 = 8;

/// Pins a voice to the front pair at the gains in `x` and `y`.
pub const SET_STEREO: u32 = 9;

/// Returns a voice to unpositioned mixing.
pub const CLEAR_PLACEMENT: u32 = 10;

/// Scales the whole output.
pub const SET_MASTER_GAIN: u32 = 11;

/// Sets how a voice reads between source frames, reading the `NEAREST` flag.
pub const SET_RESAMPLE: u32 = 12;

/// Marks a command whose voice repeats forever.
pub const FLAG_LOOP: u32 = 1;

/// Marks a command carrying a position.
pub const FLAG_SPATIAL: u32 = 2;

/// Marks a command carrying explicit speaker gains.
pub const FLAG_STEREO: u32 = 4;

/// Marks a `PLAY` reading its input from the file rather than held samples.
pub const FLAG_STREAM: u32 = 8;

/// Marks a `PLAY` whose input is the synthesizer `tecs_audio_synth_open` or
/// `tecs_audio_fm_open` parked under the command's handle, rather than a clip.
pub const FLAG_SYNTH: u32 = 16;

/// Marks a `PLAY` or `SET_RESAMPLE` whose voice holds the source frame its
/// read position is in rather than interpolating to the next one.
///
/// That is the frame the integer part of the position names, as a tracker's
/// fixed-point step reads it, and it is what makes a voice reproduce a mix
/// computed that way sample for sample. Clear, the voice interpolates
/// linearly, which is the default.
pub const FLAG_NEAREST: u32 = 32;

/// Requests one operation.
///
/// One struct covers every operation, because the array crossing the seam has
/// to be one contiguous run of identical elements. A field the `kind` does not
/// claim carries whatever the sender's reused record left behind, so reading
/// one is a defect rather than a way to learn something.
///
/// `at` is the one field every kind claims. It schedules the command on the
/// output clock, which `Engine::now` reads, and the mixer splits its render at
/// that frame so the command takes effect on exactly that output sample.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Command {
    /// Selects the operation from this module's kind constants.
    pub kind: u32,
    /// Names the voice as the packed handle Tecs issued, and zero for an
    /// operation on the whole output.
    pub handle: u32,
    /// Selects the clip a `PLAY` reads.
    pub clip: u32,
    /// Carries the flag bits above.
    pub flags: u32,
    /// Sets linear amplitude for `PLAY`, `SET_GAIN` and `SET_MASTER_GAIN`.
    pub gain: f32,
    /// Sets the playback rate for `PLAY` and `SET_PITCH`.
    pub pitch: f32,
    /// Sets where a `PLAY` begins, in seconds.
    pub start: f32,
    /// Sets the fade duration in seconds, running in on a `PLAY` and out on a
    /// `STOP`.
    pub fade: f32,
    /// Sets the position in seconds a repeat returns to.
    pub loop_start: f32,
    /// Sets the position right of the listener, or the left-speaker gain for
    /// `SET_STEREO`.
    pub x: f32,
    /// Sets the position above the listener, or the right-speaker gain for
    /// `SET_STEREO`.
    pub y: f32,
    /// Sets the position behind the listener.
    pub z: f32,
    /// Schedules the command at this many seconds on the output clock: the
    /// frames the mixer has rendered over the output rate, rounded to the
    /// nearest frame. Zero, a negative time, a time that is not a number and
    /// a time already rendered all mean at once, which is the first frame of
    /// the next render. Commands due on the same frame apply in the order they
    /// were submitted.
    pub at: f64,
    /// Names the Track or Bus a strip command acts on, and the Track a `PLAY`
    /// sounds on, where zero is the default Track.
    pub target: u32,
    /// Selects a control, a Bus, a position in a chain or an effect
    /// parameter, by kind.
    pub param: u32,
    /// Carries an event's payload, or an effect's id.
    pub data: u64,
}

impl Command {
    /// Reports whether a flag bit is set.
    pub fn has(&self, flag: u32) -> bool {
        self.flags & flag != 0
    }
}

/// Delivers `data` to a voice's source on the frame `at` names: a note, a
/// register write, whatever the voice's Decoder means by the 64 bits.
pub const EVENT: u32 = 13;

/// Creates Track `target`, routed to Bus `param`. Applies at once.
pub const TRACK_CREATE: u32 = 14;

/// Destroys Track `target`; its voices move to the default Track. At once.
pub const TRACK_DESTROY: u32 = 15;

/// Sets a Track control: `param` is a `TRACK_` constant, `gain` the value,
/// `x`, `y` and `z` a position or a speaker pair, `data` the Bus for
/// `TRACK_BUS`.
pub const TRACK_SET: u32 = 16;

/// Creates Bus `target`, summing into Bus `param` (zero is Master). At once.
pub const BUS_CREATE: u32 = 17;

/// Destroys Bus `target`; what routed to it routes to its parent. At once.
pub const BUS_DESTROY: u32 = 18;

/// Sets a Bus control: `param` is a `BUS_` constant, `gain` the value, `data`
/// the parent for `BUS_PARENT`.
pub const BUS_SET: u32 = 19;

/// Sets Track `target`'s send to return Bus `param` to level `gain`, post
/// fader. Zero removes it.
pub const SEND: u32 = 20;

/// Inserts the prepared effect `data` into the chain of Track `target`, or
/// of Bus `target` with `FLAG_BUS`, at position `param` (past the end
/// appends).
pub const EFFECT_INSERT: u32 = 21;

/// Removes effect `data` from whichever chain holds it.
pub const EFFECT_REMOVE: u32 = 22;

/// Sets parameter `param` of effect `data` to target `gain`.
pub const EFFECT_PARAM: u32 = 23;

/// Moves voice `handle` onto Track `target`.
pub const SET_TRACK: u32 = 24;

/// Track controls for `TRACK_SET`.
pub const TRACK_GAIN: u32 = 1;
pub const TRACK_MUTE: u32 = 2;
pub const TRACK_SOLO: u32 = 3;
pub const TRACK_BUS: u32 = 4;
pub const TRACK_POSITION: u32 = 5;
pub const TRACK_STEREO: u32 = 6;
pub const TRACK_UNPLACED: u32 = 7;

/// Bus controls for `BUS_SET`.
pub const BUS_GAIN: u32 = 1;
pub const BUS_MUTE: u32 = 2;
pub const BUS_PAUSE: u32 = 3;
pub const BUS_PARENT: u32 = 4;

/// Marks an `EFFECT_INSERT` as going on a Bus rather than a Track.
pub const FLAG_BUS: u32 = 64;

/// Reports that a voice has finished.
pub const EVENT_FINISHED: u32 = 1;

/// Reports something the mixer observed, for Tecs to collect on its own thread.
///
/// The handle is the one Tecs issued, so a report about a voice whose slot has
/// since been reused fails Tecs's own generation check and reaches nothing. The
/// mixer therefore needs no acknowledgement and keeps no slot table.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Event {
    /// Selects the observation from this module's event constants.
    pub kind: u32,
    /// Names the voice the observation is about.
    pub handle: u32,
}
