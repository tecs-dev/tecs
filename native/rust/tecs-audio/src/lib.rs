//! The audio service Tecs plays sound through.
//!
//! Tecs owns the policy: voice slots, generation-packed handles, group gain and
//! mute and pause, keyed admission limits, and the `Sound` component. This
//! crate owns the device, the decoders and the mix. Between them is one array
//! of `repr(C)` commands per frame, drained observations coming back, and two
//! queries that need an answer inside the call.
//!
//! Nothing here calls into Nupp. A `cpal` output callback runs on a thread the
//! Lua virtual machine never created, and a LuaJIT FFI callback entered from
//! such a thread is undefined behavior, so this crate exposes no function
//! pointer parameter anywhere and reports a finished voice by leaving it where
//! `tecs_audio_drain` collects it on the frame thread.
//!
//! ```no_run
//! use tecsaudio::engine::Engine;
//!
//! // The deterministic path: no device, no output thread, no clock.
//! let engine = Engine::open_offline(48_000, 2, 32);
//! let mut buffer = vec![0.0f32; 2 * 512];
//! engine.render(&mut buffer);
//! ```

pub mod command;
pub mod decode;
pub mod device;
pub mod engine;
pub mod mixer;
pub mod source;
pub mod stream;

use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

use command::{Command, Event};
use engine::Engine;

/// What a call answers when it worked.
const STATUS_OK: i32 = 0;

/// What a call answers when it did not, with the reason left for
/// `tecs_audio_last_error`.
const STATUS_FAILED: i32 = 1;

/// The decoder names this build linked, joined by commas.
///
/// Built once and kept, because the binding reads it as a borrowed C string and
/// the answer cannot change while the process runs.
static DECODERS: Mutex<Option<CString>> = Mutex::new(None);

/// What a load settled on.
///
/// The layout matches `cdef struct tecsAudioClipInfo` in
/// `src/tecs/platform/audionative.nupp`.
#[repr(C)]
pub struct ClipInfo {
    /// The audio duration in seconds, and zero when the input cannot say.
    pub duration: f32,
    /// Nonzero when decoded samples stay in memory.
    pub resident: i32,
}

/// Borrows the engine a device pointer names.
///
/// # Safety
///
/// The pointer must be one `tecs_audio_open` or `tecs_audio_open_offline`
/// returned and `tecs_audio_close` has not yet been given.
unsafe fn engine<'a>(device: *mut Engine) -> Option<&'a mut Engine> {
    if device.is_null() {
        None
    } else {
        Some(unsafe { &mut *device })
    }
}

/// Opens the default output and returns the device driving it.
///
/// A machine with no sound still answers with a device. `tecs_audio_available`
/// reports false on one, every command is still accepted, and nothing is heard.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by `tecs_audio_close`.
#[no_mangle]
pub extern "C" fn tecs_audio_open(frequency: u32, channels: u32, max_voices: u32) -> *mut Engine {
    let opened = Engine::open(frequency, channels as u16, max_voices as usize);
    Box::into_raw(Box::new(opened))
}

/// Opens a device-free engine whose buffers the caller renders itself.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by `tecs_audio_close`.
#[no_mangle]
pub extern "C" fn tecs_audio_open_offline(
    frequency: u32,
    channels: u32,
    max_voices: u32,
) -> *mut Engine {
    let opened = Engine::open_offline(frequency, channels as u16, max_voices as usize);
    Box::into_raw(Box::new(opened))
}

/// Stops every voice, closes the output and frees the device.
///
/// # Safety
///
/// The pointer must come from one of the open calls and must not be used again.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_close(device: *mut Engine) {
    if device.is_null() {
        return;
    }
    let mut owned = unsafe { Box::from_raw(device) };
    owned.close();
}

/// Reports whether a real output opened.
///
/// # Safety
///
/// The pointer must name a live device.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_available(device: *mut Engine) -> i32 {
    match unsafe { engine(device) } {
        None => 0,
        Some(value) => i32::from(value.available()),
    }
}

/// Reports the frames per second the output runs at.
///
/// # Safety
///
/// The pointer must name a live device.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_frequency(device: *mut Engine) -> u32 {
    match unsafe { engine(device) } {
        None => 0,
        Some(value) => value.sample_rate(),
    }
}

/// Reports the channels the output runs with.
///
/// # Safety
///
/// The pointer must name a live device.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_channels(device: *mut Engine) -> u32 {
    match unsafe { engine(device) } {
        None => 0,
        Some(value) => u32::from(value.channels()),
    }
}

/// Applies `count` commands in order.
///
/// # Safety
///
/// `commands` must point at `count` readable, initialized commands, and the
/// device must be live. The array stays the caller's: this copies whatever it
/// keeps before returning.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_submit(
    device: *mut Engine,
    commands: *const Command,
    count: u32,
) {
    let value = match unsafe { engine(device) } {
        None => return,
        Some(value) => value,
    };
    if commands.is_null() || count == 0 {
        return;
    }
    let batch = unsafe { std::slice::from_raw_parts(commands, count as usize) };
    value.submit(batch);
}

/// Fills `events` with everything observed since the last drain.
///
/// # Safety
///
/// `events` must point at `capacity` writable events, and the device must be
/// live.
///
/// @return how many events were written
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_drain(
    device: *mut Engine,
    events: *mut Event,
    capacity: u32,
) -> u32 {
    let value = match unsafe { engine(device) } {
        None => return 0,
        Some(value) => value,
    };
    if events.is_null() || capacity == 0 {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(events, capacity as usize) };
    value.drain(out) as u32
}

/// Reads a file and holds it under `clip`.
///
/// # Safety
///
/// `path` must be a NUL-terminated string, `info` must be writable, and the
/// device must be live.
///
/// @return zero when the clip loaded, and one with the reason left for
///     `tecs_audio_last_error` when it did not
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_load_clip(
    device: *mut Engine,
    path: *const c_char,
    clip: u32,
    mode: u32,
    stream_seconds: f32,
    info: *mut ClipInfo,
) -> i32 {
    let value = match unsafe { engine(device) } {
        None => return STATUS_FAILED,
        Some(value) => value,
    };
    if path.is_null() || info.is_null() {
        return STATUS_FAILED;
    }
    let text = match unsafe { CStr::from_ptr(path) }.to_str() {
        Err(_) => return STATUS_FAILED,
        Ok(text) => text,
    };
    match value.load_clip(text, clip, mode, stream_seconds) {
        Err(_) => STATUS_FAILED,
        Ok(loaded) => {
            unsafe {
                (*info).duration = loaded.duration as f32;
                (*info).resident = i32::from(loaded.resident);
            }
            STATUS_OK
        }
    }
}

/// Drops whatever a clip index holds.
///
/// # Safety
///
/// The pointer must name a live device.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_release_clip(device: *mut Engine, clip: u32) {
    if let Some(value) = unsafe { engine(device) } {
        value.release_clip(clip);
    }
}

/// Reports a voice's read position.
///
/// # Safety
///
/// The pointer must name a live device.
///
/// @return seconds from the start of the clip, and a negative number when the
///     handle names nothing
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_position(device: *mut Engine, handle: u32) -> f32 {
    match unsafe { engine(device) } {
        None => -1.0,
        Some(value) => value.position(handle) as f32,
    }
}

/// Moves a voice's read position.
///
/// # Safety
///
/// The pointer must name a live device.
///
/// @return nonzero when the input accepted the seek
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_seek(device: *mut Engine, handle: u32, seconds: f32) -> i32 {
    match unsafe { engine(device) } {
        None => 0,
        Some(value) => i32::from(value.seek(handle, seconds as f64)),
    }
}

/// Fills `out` with the mix, for a device-free engine.
///
/// # Safety
///
/// `out` must point at `frames` times the channel count writable floats, and
/// the device must be live.
///
/// @return the frames written, and zero for an engine driving a real output
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_render(device: *mut Engine, out: *mut f32, frames: u32) -> u32 {
    let value = match unsafe { engine(device) } {
        None => return 0,
        Some(value) => value,
    };
    if out.is_null() || frames == 0 {
        return 0;
    }
    let samples = frames as usize * value.channels() as usize;
    let span = unsafe { std::slice::from_raw_parts_mut(out, samples) };
    value.render(span) as u32
}

/// Selects the command struct in `tecs_audio_layout`.
pub const LAYOUT_COMMAND: u32 = 0;

/// Selects the event struct in `tecs_audio_layout`.
pub const LAYOUT_EVENT: u32 = 1;

/// Selects the clip-info struct in `tecs_audio_layout`.
pub const LAYOUT_CLIP_INFO: u32 = 2;

/// Reports the size in bytes of one struct crossing the seam.
///
/// The binding checks these against what LuaJIT computed for its own `cdef`
/// declarations before it sends anything. Two descriptions of one memory layout
/// can drift, and the failure a drift produces is a voice that plays at the
/// wrong pitch rather than a call that does not link, so it is worth one
/// comparison at open.
///
/// @return the size in bytes, and zero for a selector this build does not know
#[no_mangle]
pub extern "C" fn tecs_audio_layout(kind: u32) -> u32 {
    let size = match kind {
        LAYOUT_COMMAND => std::mem::size_of::<Command>(),
        LAYOUT_EVENT => std::mem::size_of::<Event>(),
        LAYOUT_CLIP_INFO => std::mem::size_of::<ClipInfo>(),
        _ => 0,
    };
    size as u32
}

/// Returns the decoder names this build linked, joined by commas.
///
/// # Safety
///
/// The returned pointer stays valid for the life of the process.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_decoders(_device: *mut Engine) -> *const c_char {
    let mut slot = match DECODERS.lock() {
        Err(_) => return std::ptr::null(),
        Ok(value) => value,
    };
    if slot.is_none() {
        let joined = decode::decoder_names().join(",");
        *slot = CString::new(joined).ok();
    }
    match slot.as_ref() {
        None => std::ptr::null(),
        Some(value) => value.as_ptr(),
    }
}

/// Returns the reason the most recent failing call gave.
///
/// # Safety
///
/// The pointer must name a live device, and the returned string stays valid
/// until the next call on that device.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_last_error(device: *mut Engine) -> *const c_char {
    let value = match unsafe { engine(device) } {
        None => return std::ptr::null(),
        Some(value) => value,
    };
    value.last_error_cstr()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// Builds a command batch the way Tecs does, then crosses it as C would.
    #[test]
    fn crosses_a_command_batch_and_drains_what_it_produced() {
        let device = tecs_audio_open_offline(48_000, 2, 8);
        assert!(!device.is_null());

        let stop = Command {
            kind: command::STOP,
            handle: 65_537,
            clip: 0,
            flags: 0,
            gain: 1.0,
            pitch: 1.0,
            start: 0.0,
            fade: 0.0,
            loop_start: 0.0,
            x: 0.0,
            y: 0.0,
            z: 0.0,
        };
        unsafe {
            // Nothing is sounding, so the stop reaches no voice and produces no
            // observation. This is the stale-handle case Tecs relies on.
            tecs_audio_submit(device, &stop, 1);
            let mut events = [Event { kind: 0, handle: 0 }; 4];
            assert_eq!(tecs_audio_drain(device, events.as_mut_ptr(), 4), 0);

            assert_eq!(tecs_audio_frequency(device), 48_000);
            assert_eq!(tecs_audio_channels(device), 2);
            assert_eq!(tecs_audio_available(device), 0);

            let mut buffer = vec![1.0f32; 2 * 16];
            assert_eq!(tecs_audio_render(device, buffer.as_mut_ptr(), 16), 16);
            assert!(buffer.iter().all(|value| *value == 0.0));

            tecs_audio_close(device);
        }
    }

    #[test]
    fn reports_a_load_failure_through_the_status_and_the_reason() {
        let device = tecs_audio_open_offline(48_000, 2, 8);
        let path = CString::new("no/such/file.ogg").expect("the literal has no NUL");
        let mut info = ClipInfo {
            duration: 0.0,
            resident: 0,
        };
        unsafe {
            let status =
                tecs_audio_load_clip(device, path.as_ptr(), 1, engine::MODE_AUTO, 10.0, &mut info);
            assert_eq!(status, STATUS_FAILED);
            let reason = tecs_audio_last_error(device);
            assert!(!reason.is_null());
            assert!(!CStr::from_ptr(reason).to_bytes().is_empty());
            tecs_audio_close(device);
        }
    }

    #[test]
    fn tolerates_a_null_device_on_every_entry_point() {
        let null: *mut Engine = std::ptr::null_mut();
        unsafe {
            assert_eq!(tecs_audio_available(null), 0);
            assert_eq!(tecs_audio_frequency(null), 0);
            assert_eq!(tecs_audio_channels(null), 0);
            assert_eq!(tecs_audio_drain(null, std::ptr::null_mut(), 0), 0);
            assert_eq!(tecs_audio_position(null, 1), -1.0);
            assert_eq!(tecs_audio_seek(null, 1, 0.0), 0);
            assert_eq!(tecs_audio_render(null, std::ptr::null_mut(), 0), 0);
            assert!(tecs_audio_last_error(null).is_null());
            tecs_audio_submit(null, std::ptr::null(), 0);
            tecs_audio_release_clip(null, 1);
            tecs_audio_close(null);
        }
    }

    #[test]
    fn reports_the_size_of_every_struct_crossing_the_seam() {
        assert_eq!(tecs_audio_layout(LAYOUT_COMMAND), 48);
        assert_eq!(tecs_audio_layout(LAYOUT_EVENT), 8);
        assert_eq!(tecs_audio_layout(LAYOUT_CLIP_INFO), 8);
        assert_eq!(tecs_audio_layout(99), 0);
    }

    #[test]
    fn names_the_decoders_this_build_linked() {
        let device = tecs_audio_open_offline(48_000, 2, 8);
        unsafe {
            let names = tecs_audio_decoders(device);
            assert!(!names.is_null());
            let text = CStr::from_ptr(names).to_str().expect("the names are UTF-8");
            // Codec names rather than container names, because that is what the
            // decoder registry can be asked. The pin is on the feature set this
            // crate selects rather than on the whole list.
            assert!(text.contains("flac"), "got {text}");
            assert!(text.contains("vorbis"), "got {text}");
            assert!(text.contains("pcm_s16le"), "got {text}");
            tecs_audio_close(device);
        }
    }
}
