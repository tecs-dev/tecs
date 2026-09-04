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

/// Marks a command whose voice repeats forever.
pub const FLAG_LOOP: u32 = 1;

/// Marks a command carrying a position.
pub const FLAG_SPATIAL: u32 = 2;

/// Marks a command carrying explicit speaker gains.
pub const FLAG_STEREO: u32 = 4;

/// Marks a `PLAY` reading its input from the file rather than held samples.
pub const FLAG_STREAM: u32 = 8;

/// Requests one operation.
///
/// One struct covers every operation, because the array crossing the seam has
/// to be one contiguous run of identical elements. A field the `kind` does not
/// claim carries whatever the sender's reused record left behind, so reading
/// one is a defect rather than a way to learn something.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
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
}

impl Command {
    /// Reports whether a flag bit is set.
    pub fn has(&self, flag: u32) -> bool {
        self.flags & flag != 0
    }
}

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
