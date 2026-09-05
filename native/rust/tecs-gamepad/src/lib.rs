//! The gamepad service Tecs reads controllers through.
//!
//! Tecs owns the policy: the layer stack, frame and fixed-step edges, deadzones
//! and the positional button vocabulary a game names. This crate owns the
//! platform: `gilrs` over `evdev` on Linux, XInput on Windows and `IOKit` on
//! macOS, plus the SDL community mapping database that makes `"south"` the same
//! physical button on every pad.
//!
//! `gilrs` was chosen over the alternatives because it is the only maintained
//! Rust crate covering all three desktop platforms behind one event enum with a
//! mapping database, and because it never asks for a callback. That second
//! property is what makes it usable here at all. `gilrs` does run a thread of
//! its own on macOS, where `IOHIDManager` needs a `CFRunLoop`, but that thread
//! posts to a channel rather than calling anything the caller supplied. Nothing
//! in this crate takes a function pointer, so a LuaJIT FFI callback can never
//! be entered from a thread the virtual machine did not create. Every
//! observation waits in a queue until the frame thread calls
//! `tecs_gamepad_drain`.
//!
//! ```no_run
//! use tecsgamepad::context::Context;
//!
//! // The deterministic path: no device, no thread, no platform backend.
//! let mut context = Context::open_detached();
//! assert_eq!(context.poll(), 0);
//! ```

pub mod codes;
pub mod context;

use std::ffi::{c_char, CString};
use std::sync::Mutex;

use codes::GamepadEvent;
use context::{Context, GamepadInfo};

/// What a call answers when it worked.
const STATUS_OK: i32 = 0;

/// What a call answers when it did not, with the reason left for
/// `tecs_gamepad_last_error`.
const STATUS_FAILED: i32 = 1;

/// Selects the event struct in `tecs_gamepad_layout`.
const LAYOUT_EVENT: u32 = 0;

/// Selects the info struct in `tecs_gamepad_layout`.
const LAYOUT_INFO: u32 = 1;

/// Selects the device-identifier struct in `tecs_gamepad_layout`.
const LAYOUT_DEVICE: u32 = 2;

/// One attached device's identifier.
///
/// A struct around one number rather than a bare number, because the managed
/// binding's array allocator takes a struct type. The layout matches
/// `cdef struct tecsGamepadDevice` in `src/tecs/platform/gamepadnative.nupp`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GamepadDevice {
    /// The identifier a `GamepadEvent` names the same device by.
    pub id: u32,
}

/// The reason a call with no context reports.
///
/// A null context has no place to keep a failure, so the one message it can
/// produce is kept here instead of allocated per call.
static NO_CONTEXT: Mutex<Option<CString>> = Mutex::new(None);

/// Borrows the context a handle names.
///
/// # Safety
///
/// The pointer must be one `tecs_gamepad_open` or
/// `tecs_gamepad_open_detached` returned and `tecs_gamepad_close` has not yet
/// been given.
unsafe fn borrow<'a>(handle: *mut Context) -> Option<&'a mut Context> {
    if handle.is_null() {
        None
    } else {
        Some(unsafe { &mut *handle })
    }
}

/// Opens the platform's gamepad source and returns the context reading it.
///
/// A machine with no gamepad support still answers with a context.
/// `tecs_gamepad_available` reports zero on one and nothing is ever read.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by
/// `tecs_gamepad_close`.
#[no_mangle]
pub extern "C" fn tecs_gamepad_open() -> *mut Context {
    Box::into_raw(Box::new(Context::open()))
}

/// Opens a context with no platform backend, for a deterministic test.
///
/// # Safety
///
/// The returned pointer is owned by the caller and freed by
/// `tecs_gamepad_close`.
#[no_mangle]
pub extern "C" fn tecs_gamepad_open_detached() -> *mut Context {
    Box::into_raw(Box::new(Context::open_detached()))
}

/// Stops every effect, closes the source and frees the context.
///
/// # Safety
///
/// The pointer must come from one of the open calls and must not be used again.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_close(context: *mut Context) {
    if context.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(context) });
}

/// Reports whether a real gamepad source opened.
///
/// # Safety
///
/// The pointer must be a live context or null.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_available(context: *mut Context) -> i32 {
    match unsafe { borrow(context) } {
        Some(context) => i32::from(context.available()),
        None => 0,
    }
}

/// Reads everything the platform produced since the previous poll.
///
/// Returns how many observations are waiting. This has to run on the thread
/// that owns the frame, because it is the only crossing where the platform's
/// work becomes Tecs's.
///
/// # Safety
///
/// The pointer must be a live context or null.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_poll(context: *mut Context) -> u32 {
    match unsafe { borrow(context) } {
        Some(context) => context.poll() as u32,
        None => 0,
    }
}

/// Copies at most `capacity` waiting observations into `events`.
///
/// Returns how many were written. A short buffer is not an error: the rest wait
/// for the next call.
///
/// # Safety
///
/// `events` must point to `capacity` writable `GamepadEvent` values.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_drain(
    context: *mut Context,
    events: *mut GamepadEvent,
    capacity: u32,
) -> u32 {
    let Some(context) = (unsafe { borrow(context) }) else {
        return 0;
    };
    if events.is_null() || capacity == 0 {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(events, capacity as usize) };
    context.drain(out) as u32
}

/// Writes the identifiers of every attached device into `devices`.
///
/// Returns how many were written, which is what a caller reconciling its own
/// device list against the platform reads.
///
/// # Safety
///
/// `devices` must point to `capacity` writable `u32` values.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_attached(
    context: *mut Context,
    devices: *mut GamepadDevice,
    capacity: u32,
) -> u32 {
    let Some(context) = (unsafe { borrow(context) }) else {
        return 0;
    };
    let found = context.attached();
    if devices.is_null() || capacity == 0 {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(devices, capacity as usize) };
    let written = found.len().min(out.len());
    for (slot, id) in out.iter_mut().zip(found.iter().copied()).take(written) {
        *slot = GamepadDevice { id };
    }
    written as u32
}

/// Fills `info` with what one device reports about itself.
///
/// # Safety
///
/// `info` must point to one writable `GamepadInfo`.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_info(
    context: *mut Context,
    device: u32,
    info: *mut GamepadInfo,
) -> i32 {
    if info.is_null() {
        return STATUS_FAILED;
    }
    let Some(context) = (unsafe { borrow(context) }) else {
        set_no_context();
        return STATUS_FAILED;
    };
    unsafe { *info = context.info(device) };
    STATUS_OK
}

/// Reports whether one device has the control a code names.
///
/// `kind` is zero for a positional button and one for an axis. Returns zero
/// when the device is gone, when the code names nothing, or when the device
/// does not have it.
///
/// # Safety
///
/// The pointer must be a live context or null.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_has(
    context: *mut Context,
    device: u32,
    kind: u32,
    code: u32,
) -> i32 {
    match unsafe { borrow(context) } {
        Some(context) => i32::from(context.has(device, kind, code)),
        None => 0,
    }
}

/// Returns one of a device's strings, or null when it has none.
///
/// `which` is zero for the display name, one for the identity a saved binding
/// matches on, and two for the name the operating system reports. The pointer
/// is owned by the context and is valid only until the next call to this
/// function.
///
/// # Safety
///
/// The pointer must be a live context or null, and the result must not outlive
/// the next call.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_string(
    context: *mut Context,
    device: u32,
    which: u32,
) -> *const c_char {
    let Some(context) = (unsafe { borrow(context) }) else {
        return std::ptr::null();
    };
    match context.string(device, which) {
        Some(value) => value.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Plays one rumble effect, replacing whatever the device was playing.
///
/// `low` and `high` are linear strengths from zero to one for the low and high
/// frequency motors, and `seconds` is how long the effect runs. A zero or
/// negative duration stops the device instead. Returns zero when the effect
/// started or stopped, and one when the platform has no force feedback for the
/// device.
///
/// # Safety
///
/// The pointer must be a live context or null.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_rumble(
    context: *mut Context,
    device: u32,
    low: f32,
    high: f32,
    seconds: f32,
) -> i32 {
    let Some(context) = (unsafe { borrow(context) }) else {
        set_no_context();
        return STATUS_FAILED;
    };
    if context.rumble(device, low, high, seconds) {
        STATUS_OK
    } else {
        STATUS_FAILED
    }
}

/// Returns the last failure, or null when nothing has failed.
///
/// The pointer is owned by the context and is valid until the next failure.
///
/// # Safety
///
/// The pointer must be a live context or null.
#[no_mangle]
pub unsafe extern "C" fn tecs_gamepad_last_error(context: *mut Context) -> *const c_char {
    let Some(context) = (unsafe { borrow(context) }) else {
        let held = NO_CONTEXT.lock().ok();
        return held
            .and_then(|value| value.as_ref().map(|text| text.as_ptr()))
            .unwrap_or(std::ptr::null());
    };
    match context.failure() {
        Some(value) => value.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Reports the byte size this build compiled one of its shared structs as.
///
/// The binding compares this against its own declaration at open, because two
/// descriptions of one layout drift silently and the failure that produces is a
/// button read at the wrong offset rather than a call that will not link.
#[no_mangle]
pub extern "C" fn tecs_gamepad_layout(kind: u32) -> u32 {
    match kind {
        LAYOUT_EVENT => std::mem::size_of::<GamepadEvent>() as u32,
        LAYOUT_INFO => std::mem::size_of::<GamepadInfo>() as u32,
        LAYOUT_DEVICE => std::mem::size_of::<GamepadDevice>() as u32,
        _ => 0,
    }
}

/// Records the one failure a null context can report.
fn set_no_context() {
    if let Ok(mut held) = NO_CONTEXT.lock() {
        if held.is_none() {
            *held = CString::new("tecsgamepad was given no context").ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The smoke test that touches the real platform source.
    ///
    /// Ignored by default and run with `cargo test -p tecs-gamepad -- --ignored`
    /// on a machine somebody is watching. Opening the real source starts device
    /// enumeration, and on macOS that means a run loop on a thread of its own,
    /// which the ordinary suite has no business starting. What it proves is
    /// that opening, polling, draining and closing survive a round trip on this
    /// platform, with or without a controller plugged in.
    #[test]
    #[ignore = "opens the platform's real gamepad source"]
    fn opens_polls_and_closes_the_real_source() {
        let context = tecs_gamepad_open();
        assert!(!context.is_null());
        let mut events = [GamepadEvent::new_device(0, 0); 16];
        let mut devices = [GamepadDevice::default(); 16];
        unsafe {
            let attached = tecs_gamepad_attached(context, devices.as_mut_ptr(), 16);
            for slot in devices.iter().take(attached as usize) {
                let mut info = GamepadInfo::missing();
                assert_eq!(tecs_gamepad_info(context, slot.id, &mut info), STATUS_OK);
                assert!(!tecs_gamepad_string(context, slot.id, 1).is_null());
            }
            for _ in 0..8 {
                let waiting = tecs_gamepad_poll(context);
                let drained = tecs_gamepad_drain(context, events.as_mut_ptr(), 16);
                assert!(drained <= waiting.min(16));
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            tecs_gamepad_close(context);
        }
    }

    #[test]
    fn a_null_context_answers_every_call() {
        let null = std::ptr::null_mut();
        unsafe {
            assert_eq!(tecs_gamepad_available(null), 0);
            assert_eq!(tecs_gamepad_poll(null), 0);
            assert_eq!(tecs_gamepad_drain(null, std::ptr::null_mut(), 0), 0);
            assert_eq!(tecs_gamepad_attached(null, std::ptr::null_mut(), 0), 0);
            assert_eq!(tecs_gamepad_has(null, 0, 0, 1), 0);
            assert_eq!(tecs_gamepad_string(null, 0, 0), std::ptr::null());
            assert_eq!(tecs_gamepad_rumble(null, 0, 1.0, 1.0, 1.0), STATUS_FAILED);
            assert!(!tecs_gamepad_last_error(null).is_null());
            tecs_gamepad_close(null);
        }
    }

    #[test]
    fn a_detached_context_opens_drains_and_closes() {
        let context = tecs_gamepad_open_detached();
        assert!(!context.is_null());
        let mut events = [GamepadEvent::new_device(0, 0); 4];
        unsafe {
            assert_eq!(tecs_gamepad_available(context), 0);
            assert_eq!(tecs_gamepad_poll(context), 0);
            assert_eq!(tecs_gamepad_drain(context, events.as_mut_ptr(), 4), 0);
            let mut info = GamepadInfo::missing();
            assert_eq!(tecs_gamepad_info(context, 0, &mut info), STATUS_OK);
            assert_eq!(info, GamepadInfo::missing());
            assert_eq!(tecs_gamepad_has(context, 0, 0, 1), 0);
            assert_eq!(tecs_gamepad_last_error(context), std::ptr::null());
            tecs_gamepad_close(context);
        }
    }

    /// Pins the layouts the Nupp binding declares against this build.
    #[test]
    fn layout_is_what_the_binding_declares() {
        assert_eq!(tecs_gamepad_layout(LAYOUT_EVENT), 16);
        assert_eq!(tecs_gamepad_layout(LAYOUT_INFO), 16);
        assert_eq!(tecs_gamepad_layout(LAYOUT_DEVICE), 4);
        assert_eq!(tecs_gamepad_layout(99), 0);
        assert_eq!(std::mem::align_of::<GamepadEvent>(), 4);
        assert_eq!(std::mem::align_of::<GamepadInfo>(), 4);
    }
}
