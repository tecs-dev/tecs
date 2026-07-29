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
    let Some(dialog) = (unsafe { userdata.cast::<TecsDialog>().as_ref() }) else {
        return;
    };
    let mut state = lock(dialog);
    state.filter = filter;
    if file_list.is_null() {
        state.error = Some(error_text(unsafe { SDL_GetError() }));
    } else {
        let mut index = 0;
        loop {
            let path = unsafe { *file_list.add(index) };
            if path.is_null() {
                break;
            }
            state.paths.push(unsafe { CStr::from_ptr(path) }.to_owned());
            index += 1;
        }
        state.cancelled = state.paths.is_empty();
    }
    state.ready = true;
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
