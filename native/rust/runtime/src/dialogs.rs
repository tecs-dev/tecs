//! Owns asynchronous SDL file and folder dialogs and their callback results.
//!
//! `tecs.platform.os` calls this through the generated `dialogs` FFI table
//! and polls each opaque dialog; no SDL callback enters Teal.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::sync::{Mutex, MutexGuard};

#[repr(C)]
struct SdlDialogFileFilter {
    name: *const c_char,
    pattern: *const c_char,
}

type SdlDialogCallback = unsafe extern "C" fn(*mut c_void, *const *const c_char, c_int);

unsafe extern "C" {
    fn SDL_ShowOpenFileDialog(
        callback: SdlDialogCallback,
        userdata: *mut c_void,
        window: *mut c_void,
        filters: *const SdlDialogFileFilter,
        filter_count: c_int,
        default_location: *const c_char,
        allow_many: bool,
    );
    fn SDL_ShowSaveFileDialog(
        callback: SdlDialogCallback,
        userdata: *mut c_void,
        window: *mut c_void,
        filters: *const SdlDialogFileFilter,
        filter_count: c_int,
        default_location: *const c_char,
    );
    fn SDL_ShowOpenFolderDialog(
        callback: SdlDialogCallback,
        userdata: *mut c_void,
        window: *mut c_void,
        default_location: *const c_char,
        allow_many: bool,
    );
    fn SDL_GetError() -> *const c_char;
}

struct DialogState {
    ready: bool,
    abandoned: bool,
    cancelled: bool,
    filter: c_int,
    paths: Vec<CString>,
    error: Option<CString>,
}

pub struct TecsDialog {
    state: Mutex<DialogState>,
    filter_strings: Vec<(CString, CString)>,
    filters: Vec<SdlDialogFileFilter>,
    location: Option<CString>,
}

// SDL only reads these pointers, while the CString allocations and their
// pointer table remain owned by the boxed dialog.
unsafe impl Send for TecsDialog {}
unsafe impl Sync for TecsDialog {}

fn lock(dialog: &TecsDialog) -> MutexGuard<'_, DialogState> {
    dialog
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn cstring_lossy(bytes: &[u8]) -> CString {
    let clean = bytes
        .iter()
        .map(|byte| if *byte == 0 { b'?' } else { *byte })
        .collect::<Vec<_>>();
    CString::new(clean).expect("NUL bytes were replaced")
}

fn error_text(message: *const c_char) -> CString {
    if message.is_null() {
        return CString::new("file dialog failed").expect("static string has no NUL");
    }
    let bytes = unsafe { CStr::from_ptr(message) }.to_bytes();
    if bytes.is_empty() {
        CString::new("file dialog failed").expect("static string has no NUL")
    } else {
        cstring_lossy(bytes)
    }
}

unsafe extern "C" fn dialog_callback(
    userdata: *mut c_void,
    file_list: *const *const c_char,
    filter: c_int,
) {
    let mut paths = Vec::new();
    let error = if file_list.is_null() {
        Some(error_text(unsafe { SDL_GetError() }))
    } else {
        let mut index = 0;
        loop {
            let path = unsafe { *file_list.add(index) };
            if path.is_null() {
                break;
            }
            paths.push(unsafe { CStr::from_ptr(path) }.to_owned());
            index += 1;
        }
        None
    };
    unsafe { publish_dialog(userdata.cast(), filter, paths, error) };
}

/// Publishes a callback result and assumes ownership only when the caller has
/// already abandoned it. State inspection remains under the lock, so the side
/// that releases the allocation does so only after ownership has transferred.
unsafe fn publish_dialog(
    dialog: *mut TecsDialog,
    filter: c_int,
    paths: Vec<CString>,
    error: Option<CString>,
) {
    let Some(dialog_ref) = (unsafe { dialog.as_ref() }) else {
        return;
    };
    let abandoned = {
        let mut state = lock(dialog_ref);
        state.filter = filter;
        state.cancelled = error.is_none() && paths.is_empty();
        state.paths = paths;
        state.error = error;
        state.ready = true;
        state.abandoned
    };
    if abandoned {
        unsafe { drop(Box::from_raw(dialog)) };
    }
}

unsafe fn copy_optional(value: *const c_char) -> Option<CString> {
    (!value.is_null()).then(|| unsafe { CStr::from_ptr(value) }.to_owned())
}

unsafe fn create_dialog(
    names: *const *const c_char,
    patterns: *const *const c_char,
    filter_count: c_int,
    location: *const c_char,
) -> *mut TecsDialog {
    if filter_count < 0 || (filter_count > 0 && (names.is_null() || patterns.is_null())) {
        return ptr::null_mut();
    }
    let mut filter_strings = Vec::with_capacity(filter_count as usize);
    for index in 0..filter_count as usize {
        let name = unsafe { *names.add(index) };
        let pattern = unsafe { *patterns.add(index) };
        if name.is_null() || pattern.is_null() {
            return ptr::null_mut();
        }
        filter_strings.push((
            unsafe { CStr::from_ptr(name) }.to_owned(),
            unsafe { CStr::from_ptr(pattern) }.to_owned(),
        ));
    }
    let filters = filter_strings
        .iter()
        .map(|(name, pattern)| SdlDialogFileFilter {
            name: name.as_ptr(),
            pattern: pattern.as_ptr(),
        })
        .collect();
    Box::into_raw(Box::new(TecsDialog {
        state: Mutex::new(DialogState {
            ready: false,
            abandoned: false,
            cancelled: false,
            filter: -1,
            paths: Vec::new(),
            error: None,
        }),
        filter_strings,
        filters,
        location: unsafe { copy_optional(location) },
    }))
}

/// # Safety
///
/// String pointers and arrays must remain readable for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogOpenFile(
    window: *mut c_void,
    names: *const *const c_char,
    patterns: *const *const c_char,
    filter_count: c_int,
    location: *const c_char,
    multiple: bool,
) -> *mut TecsDialog {
    let dialog = unsafe { create_dialog(names, patterns, filter_count, location) };
    let Some(held) = (unsafe { dialog.as_ref() }) else {
        return ptr::null_mut();
    };
    unsafe {
        SDL_ShowOpenFileDialog(
            dialog_callback,
            dialog.cast(),
            window,
            held.filters.as_ptr(),
            held.filters.len() as c_int,
            held.location
                .as_ref()
                .map_or(ptr::null(), |path| path.as_ptr()),
            multiple,
        );
    }
    dialog
}

/// # Safety
///
/// String pointers and arrays must remain readable for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogSaveFile(
    window: *mut c_void,
    names: *const *const c_char,
    patterns: *const *const c_char,
    filter_count: c_int,
    location: *const c_char,
) -> *mut TecsDialog {
    let dialog = unsafe { create_dialog(names, patterns, filter_count, location) };
    let Some(held) = (unsafe { dialog.as_ref() }) else {
        return ptr::null_mut();
    };
    unsafe {
        SDL_ShowSaveFileDialog(
            dialog_callback,
            dialog.cast(),
            window,
            held.filters.as_ptr(),
            held.filters.len() as c_int,
            held.location
                .as_ref()
                .map_or(ptr::null(), |path| path.as_ptr()),
        );
    }
    dialog
}

/// # Safety
///
/// `location` may be null or must name a NUL-terminated string for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogOpenFolder(
    window: *mut c_void,
    location: *const c_char,
    multiple: bool,
) -> *mut TecsDialog {
    let dialog = unsafe { create_dialog(ptr::null(), ptr::null(), 0, location) };
    let Some(held) = (unsafe { dialog.as_ref() }) else {
        return ptr::null_mut();
    };
    unsafe {
        SDL_ShowOpenFolderDialog(
            dialog_callback,
            dialog.cast(),
            window,
            held.location
                .as_ref()
                .map_or(ptr::null(), |path| path.as_ptr()),
            multiple,
        );
    }
    dialog
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogReady(dialog: *mut TecsDialog) -> bool {
    unsafe { dialog.as_ref() }.is_none_or(|dialog| lock(dialog).ready)
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogCancelled(dialog: *mut TecsDialog) -> bool {
    unsafe { dialog.as_ref() }.is_some_and(|dialog| lock(dialog).cancelled)
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogFilter(dialog: *mut TecsDialog) -> c_int {
    unsafe { dialog.as_ref() }.map_or(-1, |dialog| lock(dialog).filter)
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogPathCount(dialog: *mut TecsDialog) -> c_int {
    unsafe { dialog.as_ref() }.map_or(0, |dialog| {
        c_int::try_from(lock(dialog).paths.len()).unwrap_or(c_int::MAX)
    })
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogPath(dialog: *mut TecsDialog, index: c_int) -> *const c_char {
    let Some(dialog) = (unsafe { dialog.as_ref() }) else {
        return ptr::null();
    };
    if index < 0 {
        return ptr::null();
    }
    lock(dialog)
        .paths
        .get(index as usize)
        .map_or(ptr::null(), |path| path.as_ptr())
}

/// # Safety
///
/// `dialog` must be null or a live dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogError(dialog: *mut TecsDialog) -> *const c_char {
    let Some(dialog) = (unsafe { dialog.as_ref() }) else {
        return c"cannot allocate file-dialog state".as_ptr();
    };
    lock(dialog)
        .error
        .as_ref()
        .map_or(ptr::null(), |error| error.as_ptr())
}

/// # Safety
///
/// `dialog` must be null or an owned, completed dialog pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogDestroy(dialog: *mut TecsDialog) {
    if !dialog.is_null() {
        let dialog = unsafe { Box::from_raw(dialog) };
        debug_assert_eq!(dialog.filter_strings.len(), dialog.filters.len());
        drop(dialog);
    }
}

/// Releases the caller's ownership while SDL still retains its callback.
/// The callback destroys the state after publishing its otherwise-unobserved
/// result; a result already published is destroyed here.
///
/// # Safety
///
/// `dialog` must be null or a live dialog pointer that the caller owns.
#[no_mangle]
pub unsafe extern "C" fn tecsDialogAbandon(dialog: *mut TecsDialog) {
    let Some(dialog_ref) = (unsafe { dialog.as_ref() }) else {
        return;
    };
    let ready = {
        let mut state = lock(dialog_ref);
        if state.ready {
            true
        } else {
            state.abandoned = true;
            false
        }
    };
    if ready {
        unsafe { drop(Box::from_raw(dialog)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};
    use std::thread;

    #[test]
    fn marks_a_pending_dialog_abandoned_until_completion() {
        let dialog = unsafe { create_dialog(ptr::null(), ptr::null(), 0, ptr::null()) };
        assert!(!dialog.is_null());
        unsafe { tecsDialogAbandon(dialog) };
        assert!(lock(unsafe { &*dialog }).abandoned);

        unsafe { publish_dialog(dialog, -1, Vec::new(), None) };
    }

    #[test]
    fn abandon_releases_an_already_completed_dialog() {
        let dialog = unsafe { create_dialog(ptr::null(), ptr::null(), 0, ptr::null()) };
        assert!(!dialog.is_null());
        unsafe { publish_dialog(dialog, -1, Vec::new(), None) };

        unsafe { tecsDialogAbandon(dialog) };
    }

    #[test]
    fn completion_and_abandonment_can_race_repeatedly() {
        for _ in 0..2_000 {
            let dialog = unsafe { create_dialog(ptr::null(), ptr::null(), 0, ptr::null()) };
            assert!(!dialog.is_null());
            let pointer = dialog as usize;
            let barrier = Arc::new(Barrier::new(2));
            let callback_barrier = barrier.clone();
            let callback = thread::spawn(move || {
                callback_barrier.wait();
                unsafe {
                    publish_dialog(
                        pointer as *mut TecsDialog,
                        -1,
                        vec![CString::new("/tmp/result").unwrap()],
                        None,
                    )
                };
            });

            barrier.wait();
            unsafe { tecsDialogAbandon(dialog) };
            callback.join().unwrap();
        }
    }
}
