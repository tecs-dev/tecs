//! The PCM Decoder, built in, spoken through the same vtable an extension
//! hands over.
//!
//! Nearly every game plays encoded audio files, so this one stays in the
//! crate: symphonia decodes the bytes of a whole file, in any format it
//! links, when the Playback opens, and the instance reads them back. `Clip`
//! playback reaches the same decoder without the vtable; this is what a Sound
//! that names the `"pcm"` Decoder plays through, and the proof that the ABI
//! carries a real decoder.

use std::ffi::c_void;

use crate::abi::{DecoderFormat, DecoderVTable, ABI_VERSION};
use crate::decode;

struct Instance {
    samples: Vec<f32>,
    channels: usize,
    rate: u32,
    cursor: usize,
}

fn decoded(bytes: *const u8, bytes_len: usize) -> Option<decode::Decoded> {
    if bytes.is_null() || bytes_len == 0 {
        return None;
    }
    let slice = unsafe { std::slice::from_raw_parts(bytes, bytes_len) };
    decode::decode_bytes("pcm sound", slice).ok()
}

unsafe extern "C" fn describe(
    _params: *const u8,
    _params_len: usize,
    bytes: *const u8,
    bytes_len: usize,
    _output_rate: u32,
    out: *mut DecoderFormat,
) -> i32 {
    let Some(found) = decoded(bytes, bytes_len) else {
        return 1;
    };
    let frames = found.samples.len() / (found.channels.max(1) as usize);
    unsafe {
        *out = DecoderFormat {
            channels: found.channels as u32,
            sample_rate: found.sample_rate,
            length: frames as f64 / found.sample_rate.max(1) as f64,
            flags: 0,
            reserved: 0,
        }
    };
    0
}

unsafe extern "C" fn open(
    _params: *const u8,
    _params_len: usize,
    bytes: *const u8,
    bytes_len: usize,
    _output_rate: u32,
) -> *mut c_void {
    match decoded(bytes, bytes_len) {
        None => std::ptr::null_mut(),
        Some(found) => Box::into_raw(Box::new(Instance {
            channels: found.channels.max(1) as usize,
            rate: found.sample_rate,
            samples: found.samples,
            cursor: 0,
        })) as *mut c_void,
    }
}

unsafe extern "C" fn render(instance: *mut c_void, out: *mut f32, frames: u32) -> u32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let total = state.samples.len() / state.channels;
    let count = (frames as usize).min(total - state.cursor.min(total));
    let from = state.cursor * state.channels;
    let target = unsafe { std::slice::from_raw_parts_mut(out, count * state.channels) };
    target.copy_from_slice(&state.samples[from..from + count * state.channels]);
    state.cursor += count;
    count as u32
}

unsafe extern "C" fn event(_instance: *mut c_void, _frame: u32, _data: u64) {}

unsafe extern "C" fn seek(instance: *mut c_void, seconds: f64) -> i32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let total = state.samples.len() / state.channels;
    state.cursor = ((seconds.max(0.0) * state.rate as f64) as usize).min(total);
    0
}

unsafe extern "C" fn close(instance: *mut c_void) {
    drop(unsafe { Box::from_raw(instance as *mut Instance) });
}

/// The PCM Decoder's vtable.
pub static VTABLE: DecoderVTable = DecoderVTable {
    abi_version: ABI_VERSION,
    struct_size: std::mem::size_of::<DecoderVTable>() as u32,
    describe,
    open,
    render,
    event,
    seek: Some(seek),
    close,
};
