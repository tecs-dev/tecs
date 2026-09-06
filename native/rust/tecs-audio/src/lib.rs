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

pub mod capture;
pub mod command;
pub mod decode;
pub mod device;
pub mod engine;
pub mod enumerate;
pub mod mixer;
pub mod source;
pub mod stream;

use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

use capture::Capture;
use command::{Command, Event};
use engine::Engine;
use enumerate::DeviceList;

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

/// The reason the most recent failing enumeration or microphone open gave.
///
/// Those two calls answer with a pointer rather than with a device, so there is
/// nothing for a reason to hang off the way `tecs_audio_last_error` hangs off an
/// engine. One process-wide slot is what is left, and the binding reads it
/// immediately after the call that failed.
static OPEN_ERROR: Mutex<Option<CString>> = Mutex::new(None);

/// Records the reason an enumeration or a microphone open is about to report.
fn set_open_error(reason: &str) {
    if let Ok(mut slot) = OPEN_ERROR.lock() {
        *slot = CString::new(reason).ok();
    }
}

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

/// Reports terminal output loss, separately from an intentionally offline engine.
/// # Safety
/// The pointer must be null or name a live engine.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_failed(device: *mut Engine) -> i32 {
    match unsafe { engine(device) } {
        None => 0,
        Some(value) => i32::from(value.failed()),
    }
}

/// Reports terminal capture loss; queued frames remain readable.
/// # Safety
/// The pointer must be null or name a live microphone.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_failed(microphone: *mut Capture) -> i32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => i32::from(value.failed()),
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

/// Returns the reason the most recent failing enumeration or microphone open
/// gave.
///
/// # Safety
///
/// The returned string stays valid until the next enumeration or microphone
/// open fails, so a caller reads it immediately after the call that failed.
#[no_mangle]
pub extern "C" fn tecs_audio_open_error() -> *const c_char {
    match OPEN_ERROR.lock() {
        Err(_) => std::ptr::null(),
        Ok(slot) => match slot.as_ref() {
            None => std::ptr::null(),
            Some(value) => value.as_ptr(),
        },
    }
}

/// Names every playback or recording device attached now.
///
/// The listing is a snapshot rather than a subscription: devices come and go
/// while a game runs, so an id held across a hotplug may name nothing.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by
/// `tecs_audio_devices_free`. A null return leaves the reason for
/// `tecs_audio_open_error`.
///
/// @return the listing, or null when the host produced none
#[no_mangle]
pub extern "C" fn tecs_audio_devices(recording: u32) -> *mut DeviceList {
    match enumerate::list(recording != 0) {
        Err(reason) => {
            set_open_error(&reason);
            std::ptr::null_mut()
        }
        Ok(listing) => Box::into_raw(Box::new(listing)),
    }
}

/// Borrows the listing a pointer names.
///
/// # Safety
///
/// The pointer must be one `tecs_audio_devices` returned and not yet freed.
unsafe fn listing<'a>(list: *mut DeviceList) -> Option<&'a DeviceList> {
    if list.is_null() {
        None
    } else {
        Some(unsafe { &*list })
    }
}

/// Reports how many devices a listing holds.
///
/// # Safety
///
/// The pointer must name a live listing.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_count(list: *mut DeviceList) -> u32 {
    match unsafe { listing(list) } {
        None => 0,
        Some(value) => value.entries.len() as u32,
    }
}

/// Reports the id of the device at `index`, counting from zero.
///
/// # Safety
///
/// The pointer must name a live listing.
///
/// @return the id, and zero for an index the listing does not hold
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_id(list: *mut DeviceList, index: u32) -> u32 {
    match unsafe { listing(list) }.and_then(|value| value.entries.get(index as usize)) {
        None => 0,
        Some(entry) => entry.id,
    }
}

/// Returns the display name of the device at `index`, counting from zero.
///
/// # Safety
///
/// The pointer must name a live listing, and the returned string stays valid
/// until that listing is freed.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_name(
    list: *mut DeviceList,
    index: u32,
) -> *const c_char {
    match unsafe { listing(list) }.and_then(|value| value.entries.get(index as usize)) {
        None => std::ptr::null(),
        Some(entry) => entry.name.as_ptr(),
    }
}

/// Reports the preferred frames per second of the device at `index`.
///
/// # Safety
///
/// The pointer must name a live listing.
///
/// @return the frequency, and zero when the device would not say
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_frequency(list: *mut DeviceList, index: u32) -> u32 {
    match unsafe { listing(list) }.and_then(|value| value.entries.get(index as usize)) {
        None => 0,
        Some(entry) => entry.frequency,
    }
}

/// Reports the preferred channels per frame of the device at `index`.
///
/// # Safety
///
/// The pointer must name a live listing.
///
/// @return the channels, and zero when the device would not say
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_channels(list: *mut DeviceList, index: u32) -> u32 {
    match unsafe { listing(list) }.and_then(|value| value.entries.get(index as usize)) {
        None => 0,
        Some(entry) => u32::from(entry.channels),
    }
}

/// Frees a listing and every name in it.
///
/// # Safety
///
/// The pointer must come from `tecs_audio_devices` and must not be used again.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_devices_free(list: *mut DeviceList) {
    if list.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(list) });
}

/// Opens a recording device and starts it.
///
/// A non-empty `name` selects a device from the current listing and wins over
/// `id`, because a name survives a run and an id is only meaningful for the
/// listing that produced it. Neither given takes the platform's default.
///
/// # Safety
///
/// `name` must be null or a NUL-terminated string. The returned pointer is
/// owned by the caller and freed by `tecs_audio_microphone_close`. A null
/// return leaves the reason for `tecs_audio_open_error`.
///
/// @return the open capture, or null when nothing opened
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_open_microphone(
    id: u32,
    name: *const c_char,
    frequency: u32,
    channels: u32,
    buffer_frames: u32,
) -> *mut Capture {
    let wanted = if name.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(name) }.to_str() {
            Err(_) => {
                set_open_error("the device name is not valid UTF-8");
                return std::ptr::null_mut();
            }
            Ok(text) => Some(text),
        }
    };
    match Capture::open(id, wanted, frequency, channels as u16, buffer_frames) {
        Err(reason) => {
            set_open_error(&reason);
            std::ptr::null_mut()
        }
        Ok(opened) => Box::into_raw(Box::new(opened)),
    }
}

/// Opens a capture with no device, whose frames the caller supplies.
///
/// This is what a test takes. Opening a real recording device reaches the same
/// platform machinery an output open does, and on macOS that can block without
/// bound inside the audio daemon, so no headless suite may take the device
/// path.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by
/// `tecs_audio_microphone_close`.
#[no_mangle]
pub extern "C" fn tecs_audio_open_microphone_offline(
    frequency: u32,
    channels: u32,
    buffer_frames: u32,
) -> *mut Capture {
    let opened = Capture::open_offline(frequency, channels as u16, buffer_frames);
    Box::into_raw(Box::new(opened))
}

/// Borrows the capture a pointer names.
///
/// # Safety
///
/// The pointer must be one of the microphone open calls returned and
/// `tecs_audio_microphone_close` has not yet been given.
unsafe fn capture<'a>(microphone: *mut Capture) -> Option<&'a mut Capture> {
    if microphone.is_null() {
        None
    } else {
        Some(unsafe { &mut *microphone })
    }
}

/// Stops capture, discards what was not read, and frees the microphone.
///
/// # Safety
///
/// The pointer must come from one of the microphone open calls and must not be
/// used again.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_close(microphone: *mut Capture) {
    if microphone.is_null() {
        return;
    }
    let mut owned = unsafe { Box::from_raw(microphone) };
    owned.close();
}

/// Reports the frames per second a read answers in.
///
/// # Safety
///
/// The pointer must name a live microphone.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_frequency(microphone: *mut Capture) -> u32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => value.frequency(),
    }
}

/// Reports the interleaved channels per frame a read answers with.
///
/// # Safety
///
/// The pointer must name a live microphone.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_channels(microphone: *mut Capture) -> u32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => u32::from(value.channels()),
    }
}

/// Reports the complete frames ready to read without waiting.
///
/// # Safety
///
/// The pointer must name a live microphone.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_available(microphone: *mut Capture) -> u32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => value.available_frames() as u32,
    }
}

/// Reports the frames dropped to overrun since the microphone opened.
///
/// A capture holds a bounded number of frames, so a game that stops reading
/// loses the oldest rather than growing without limit. This counts what it
/// lost, saturating rather than wrapping.
///
/// # Safety
///
/// The pointer must name a live microphone.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_overruns(microphone: *mut Capture) -> u32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => u32::try_from(value.overruns()).unwrap_or(u32::MAX),
    }
}

/// Moves up to `max_frames` captured frames into `out`.
///
/// # Safety
///
/// `out` must point at `max_frames` times the channel count writable floats,
/// and the microphone must be live.
///
/// @return the frames written, and a negative number with the reason left for
///     `tecs_audio_microphone_last_error` when nothing could be read
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_read(
    microphone: *mut Capture,
    out: *mut f32,
    max_frames: u32,
) -> i32 {
    let value = match unsafe { capture(microphone) } {
        None => return -1,
        Some(value) => value,
    };
    if max_frames == 0 {
        return 0;
    }
    if out.is_null() {
        return -1;
    }
    let samples = max_frames as usize * value.channels().max(1) as usize;
    let span = unsafe { std::slice::from_raw_parts_mut(out, samples) };
    match value.read(span, max_frames as usize) {
        Err(_) => -1,
        Ok(frames) => frames as i32,
    }
}

/// Puts frames in where a device callback would, for an offline capture.
///
/// # Safety
///
/// `samples` must point at `frames` times the channel count readable floats,
/// and the microphone must be live.
///
/// @return the frames accepted, and zero while the capture is paused
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_write(
    microphone: *mut Capture,
    samples: *const f32,
    frames: u32,
) -> u32 {
    let value = match unsafe { capture(microphone) } {
        None => return 0,
        Some(value) => value,
    };
    if samples.is_null() || frames == 0 {
        return 0;
    }
    let count = frames as usize * value.channels().max(1) as usize;
    let span = unsafe { std::slice::from_raw_parts(samples, count) };

    value.write(span) as u32
}

/// Stops the device filling the buffer, keeping what is already in it.
///
/// # Safety
///
/// The pointer must name a live microphone.
///
/// @return nonzero when the capture stopped, and zero with the reason left for
///     `tecs_audio_microphone_last_error`
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_pause(microphone: *mut Capture) -> i32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => i32::from(value.pause()),
    }
}

/// Starts the device filling the buffer again.
///
/// # Safety
///
/// The pointer must name a live microphone.
///
/// @return nonzero when the capture started, and zero with the reason left for
///     `tecs_audio_microphone_last_error`
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_resume(microphone: *mut Capture) -> i32 {
    match unsafe { capture(microphone) } {
        None => 0,
        Some(value) => i32::from(value.resume()),
    }
}

/// Returns the reason the most recent failing microphone call gave.
///
/// # Safety
///
/// The pointer must name a live microphone, and the returned string stays valid
/// until the next call on it.
#[no_mangle]
pub unsafe extern "C" fn tecs_audio_microphone_last_error(
    microphone: *mut Capture,
) -> *const c_char {
    match unsafe { capture(microphone) } {
        None => std::ptr::null(),
        Some(value) => value.last_error_cstr(),
    }
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
    fn crosses_a_capture_over_the_offline_microphone() {
        let microphone = tecs_audio_open_microphone_offline(48_000, 1, 4);
        assert!(!microphone.is_null());
        unsafe {
            assert_eq!(tecs_audio_microphone_frequency(microphone), 48_000);
            assert_eq!(tecs_audio_microphone_channels(microphone), 1);
            assert_eq!(tecs_audio_microphone_available(microphone), 0);

            let fed = [0.5f32, -0.5];
            assert_eq!(tecs_audio_microphone_write(microphone, fed.as_ptr(), 2), 2);
            assert_eq!(tecs_audio_microphone_available(microphone), 2);

            let mut out = [0.0f32; 4];
            assert_eq!(
                tecs_audio_microphone_read(microphone, out.as_mut_ptr(), 4),
                2
            );
            assert_eq!(&out[..2], &[0.5, -0.5]);
            assert_eq!(tecs_audio_microphone_overruns(microphone), 0);

            assert_ne!(tecs_audio_microphone_pause(microphone), 0);
            assert_eq!(tecs_audio_microphone_write(microphone, fed.as_ptr(), 2), 0);
            assert_ne!(tecs_audio_microphone_resume(microphone), 0);
            assert_eq!(tecs_audio_microphone_write(microphone, fed.as_ptr(), 2), 2);

            tecs_audio_microphone_close(microphone);
        }
    }

    #[test]
    fn counts_what_an_unread_capture_overran() {
        let microphone = tecs_audio_open_microphone_offline(48_000, 1, 2);
        unsafe {
            let fed = [1.0f32, 2.0, 3.0, 4.0];
            tecs_audio_microphone_write(microphone, fed.as_ptr(), 4);
            assert_eq!(tecs_audio_microphone_available(microphone), 2);
            assert_eq!(tecs_audio_microphone_overruns(microphone), 2);
            tecs_audio_microphone_close(microphone);
        }
    }

    #[test]
    fn tolerates_a_null_microphone_and_a_null_listing() {
        let absent_microphone: *mut Capture = std::ptr::null_mut();
        let absent_listing: *mut DeviceList = std::ptr::null_mut();
        unsafe {
            assert_eq!(tecs_audio_microphone_frequency(absent_microphone), 0);
            assert_eq!(tecs_audio_microphone_channels(absent_microphone), 0);
            assert_eq!(tecs_audio_microphone_available(absent_microphone), 0);
            assert_eq!(tecs_audio_microphone_overruns(absent_microphone), 0);
            assert_eq!(
                tecs_audio_microphone_read(absent_microphone, std::ptr::null_mut(), 4),
                -1
            );
            assert_eq!(
                tecs_audio_microphone_write(absent_microphone, std::ptr::null(), 4),
                0
            );
            assert_eq!(tecs_audio_microphone_pause(absent_microphone), 0);
            assert_eq!(tecs_audio_microphone_resume(absent_microphone), 0);
            assert!(tecs_audio_microphone_last_error(absent_microphone).is_null());
            tecs_audio_microphone_close(absent_microphone);

            assert_eq!(tecs_audio_devices_count(absent_listing), 0);
            assert_eq!(tecs_audio_devices_id(absent_listing, 0), 0);
            assert!(tecs_audio_devices_name(absent_listing, 0).is_null());
            assert_eq!(tecs_audio_devices_frequency(absent_listing, 0), 0);
            assert_eq!(tecs_audio_devices_channels(absent_listing, 0), 0);
            tecs_audio_devices_free(absent_listing);
        }
    }

    #[test]
    fn reports_an_open_reason_after_a_failing_open() {
        // No device is touched: a channel count past what the capture path
        // carries is refused before anything reaches the platform.
        let microphone =
            unsafe { tecs_audio_open_microphone(0, std::ptr::null(), 48_000, 64, 1_024) };
        assert!(microphone.is_null());
        let reason = tecs_audio_open_error();
        assert!(!reason.is_null());
        let text = unsafe { CStr::from_ptr(reason) }
            .to_str()
            .expect("the reason is UTF-8");
        assert!(text.contains("channels"), "got {text}");
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
