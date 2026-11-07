//! The Decoder and Effect ABIs: how a separately built library plays a kind
//! of Sound, or processes a strip's signal, inside the tecs mixer.
//!
//! This crate is only the types, so an extension depends on it and not on the
//! mixer. `tecs-audio` re-exports it.
//!
//! Each is a versioned C vtable a library hands over as a pointer. Tecs owns
//! the queue, the scheduling and the timing, so an implementation only
//! renders, or processes, and applies what it is given on the frames it is
//! given: every one gets sample-accurate scheduling for free.
//!
//! Threads. `describe`, `open` and `close` run on a control thread, which is
//! any thread but the audio thread: allocate there. `render`, `event`,
//! `process`, `param` and `reset` run on the audio thread, under the rules
//! the mixer keeps itself: no allocation, no lock, no blocking. `seek` runs
//! on a control thread. A library must not assume which control thread.
//!
//! Compatibility. `abi_version` must equal the version this crate speaks, and
//! `struct_size` must be at least the size of the vtable this crate reads, so
//! the vtable can grow at its end without breaking a library built earlier.
//!
//! Every function pointer but `seek` is required.

use std::ffi::c_void;

/// The ABI version both vtables speak.
pub const ABI_VERSION: u32 = 1;

/// What a Decoder reports a Sound renders as.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DecoderFormat {
    /// Interleaved channels per frame, one to eight.
    pub channels: u32,
    /// Frames per second the instance renders at. The mixer resamples.
    pub sample_rate: u32,
    /// Seconds of audio, or a negative number for a stream that ends when it
    /// says so, such as a sequenced instrument.
    pub length: f64,
    /// `FORMAT_` bits.
    pub flags: u32,
    /// Zero; room to grow.
    pub reserved: u32,
}

/// The Decoder takes timed events, so the mixer reads it a frame at a time
/// and an event lands within a frame of its time. One that takes none is
/// read ahead, which is cheaper.
pub const FORMAT_SEQUENCED: u32 = 1;

/// The Decoder vtable a library exports.
#[repr(C)]
pub struct DecoderVTable {
    pub abi_version: u32,
    pub struct_size: u32,
    /// Fills `out` with the format the Sound renders as, and returns zero, or
    /// returns non-zero when it cannot play these bytes. Control thread.
    pub describe: unsafe extern "C" fn(
        params: *const u8,
        params_len: usize,
        bytes: *const u8,
        bytes_len: usize,
        output_rate: u32,
        out: *mut DecoderFormat,
    ) -> i32,
    /// Builds one per-Playback instance, allocating everything it will need,
    /// or returns null. Control thread.
    pub open: unsafe extern "C" fn(
        params: *const u8,
        params_len: usize,
        bytes: *const u8,
        bytes_len: usize,
        output_rate: u32,
    ) -> *mut c_void,
    /// Writes up to `frames` interleaved frames and returns how many. Fewer
    /// than asked means the Playback has ended. Audio thread.
    pub render: unsafe extern "C" fn(instance: *mut c_void, out: *mut f32, frames: u32) -> u32,
    /// Applies one timed event before the frame `frame` of the next render
    /// call, which the mixer always makes zero by splitting its render on
    /// the event's frame. Audio thread.
    pub event: unsafe extern "C" fn(instance: *mut c_void, frame: u32, data: u64),
    /// Moves the instance to `seconds` and returns zero, or non-zero when it
    /// cannot. Optional: null for a Decoder that does not seek. Control
    /// thread, applied before the next render.
    pub seek: Option<unsafe extern "C" fn(instance: *mut c_void, seconds: f64) -> i32>,
    /// Frees the instance. Control thread, never the audio thread.
    pub close: unsafe extern "C" fn(instance: *mut c_void),
}

/// What an Effect reports about itself for a set of parameters.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct EffectInfo {
    /// Frames of delay the effect adds.
    pub latency: u32,
    /// Frames it keeps sounding after its input falls silent.
    pub tail: u64,
}

/// The Effect vtable a library exports.
#[repr(C)]
pub struct EffectVTable {
    pub abi_version: u32,
    pub struct_size: u32,
    /// Fills `out` and returns zero, or returns non-zero for parameters it
    /// cannot honour. Control thread.
    pub describe: unsafe extern "C" fn(
        params: *const u8,
        params_len: usize,
        rate: u32,
        channels: u32,
        out: *mut EffectInfo,
    ) -> i32,
    /// Builds an instance for one rate and channel count, allocating
    /// everything, or returns null. Control thread.
    pub open: unsafe extern "C" fn(
        params: *const u8,
        params_len: usize,
        rate: u32,
        channels: u32,
    ) -> *mut c_void,
    /// Processes `frames` interleaved frames in place. Audio thread.
    pub process: unsafe extern "C" fn(instance: *mut c_void, buffer: *mut f32, frames: u32),
    /// Sets a parameter target before frame `frame` of the next process call,
    /// zero as for a Decoder event, to be ramped by the effect. Audio thread.
    pub param: unsafe extern "C" fn(instance: *mut c_void, id: u32, value: f32, frame: u32),
    /// Clears the instance's state, its tail included. Audio thread.
    pub reset: unsafe extern "C" fn(instance: *mut c_void),
    /// Frees the instance. Control thread.
    pub close: unsafe extern "C" fn(instance: *mut c_void),
}

/// Packs a MIDI message into a sequenced Decoder event, as `tecs-gm` reads it.
pub const fn midi_event(status: u8, data1: u8, data2: u8) -> u64 {
    status as u64 | (data1 as u64) << 8 | (data2 as u64) << 16
}

/// The operation an event carries above its payload; zero is the Decoder's
/// own message, the others are what every sequenced Decoder is asked for.
///
/// Bit 40, not the top byte, so every event stays below 2^53 and crosses
/// from a language whose numbers are doubles without losing a bit. A payload
/// is at most 40 bits.
pub const EVENT_OP_SHIFT: u32 = 40;
pub const EVENT_OP_MESSAGE: u64 = 0;
/// Silences every sound the instance holds, gracefully unless bit 0 of the
/// payload asks for at once; bits 8 to 15 name a channel, 0xFF for all.
pub const EVENT_OP_NOTES_OFF: u64 = 1;
/// Returns the instance to its state at open.
pub const EVENT_OP_RESET: u64 = 2;
/// A Decoder's second kind of message, such as a chip's port write.
pub const EVENT_OP_PORT: u64 = 3;

/// Splits an event into its operation and payload.
pub const fn split_event(data: u64) -> (u64, u64) {
    (data >> EVENT_OP_SHIFT, data & ((1 << EVENT_OP_SHIFT) - 1))
}
