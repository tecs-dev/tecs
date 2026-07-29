//! Mirrors SDL log output into a newline-delimited JSON file.
//!
//! `tecs.log` calls this through the generated `logsink` FFI table to install
//! the sink, register Teal logger names, and restore SDL's previous output.

use std::ffi::{c_char, c_int, c_void, CStr};
use std::fs::File;
use std::io::Write;
use std::ptr;
use std::sync::{Mutex, MutexGuard, OnceLock};

type SdlLogOutput = unsafe extern "C" fn(*mut c_void, c_int, c_int, *const c_char);

unsafe extern "C" {
    fn SDL_GetLogOutputFunction(callback: *mut Option<SdlLogOutput>, userdata: *mut *mut c_void);
    fn SDL_SetLogOutputFunction(callback: Option<SdlLogOutput>, userdata: *mut c_void);
    fn SDL_GetTicks() -> u64;
}

struct LogState {
    previous: Option<SdlLogOutput>,
    previous_userdata: usize,
    installed: bool,
    file: Option<File>,
    category_base: c_int,
    categories: Vec<Option<Vec<u8>>>,
}

static STATE: OnceLock<Mutex<LogState>> = OnceLock::new();

fn state() -> &'static Mutex<LogState> {
    STATE.get_or_init(|| {
        Mutex::new(LogState {
            previous: None,
            previous_userdata: 0,
            installed: false,
            file: None,
            category_base: 0,
            categories: vec![None; 128],
        })
    })
}

fn lock() -> MutexGuard<'static, LogState> {
    state()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn priority_name(priority: c_int) -> &'static [u8] {
    match priority {
        1 => b"TRACE",
        2 => b"VERBOSE",
        3 => b"DEBUG",
        4 => b"INFO",
        5 => b"WARN",
        6 => b"ERROR",
        7 => b"CRITICAL",
        _ => b"UNKNOWN",
    }
}

fn builtin_category(category: c_int) -> &'static [u8] {
    match category {
        0 => b"sdl.application",
        1 => b"sdl.error",
        2 => b"sdl.assert",
        3 => b"sdl.system",
        4 => b"sdl.audio",
        5 => b"sdl.video",
        6 => b"sdl.render",
        7 => b"sdl.input",
        9 => b"sdl.gpu",
        _ => b"sdl",
    }
}

fn write_escaped(output: &mut Vec<u8>, text: &[u8]) {
    for byte in text {
        match *byte {
            b'"' => output.extend_from_slice(br#"\""#),
            b'\\' => output.extend_from_slice(br#"\\"#),
            b'\n' => output.extend_from_slice(br#"\n"#),
            b'\r' => output.extend_from_slice(br#"\r"#),
            b'\t' => output.extend_from_slice(br#"\t"#),
            byte if byte < 0x20 => {
                output.extend_from_slice(format!("\\u{byte:04x}").as_bytes());
            }
            byte => output.push(byte),
        }
    }
}

unsafe extern "C" fn sink(
    _userdata: *mut c_void,
    category: c_int,
    priority: c_int,
    message: *const c_char,
) {
    let (previous, userdata) = {
        let state = lock();
        (state.previous, state.previous_userdata as *mut c_void)
    };
    if let Some(previous) = previous {
        unsafe { previous(userdata, category, priority, message) };
    }

    let message = if message.is_null() {
        &b""[..]
    } else {
        unsafe { CStr::from_ptr(message) }.to_bytes()
    };
    let mut state = lock();
    if state.file.is_none() {
        return;
    }
    let index = category - state.category_base;
    let logger = if state.category_base > 0 && index >= 0 {
        state
            .categories
            .get(index as usize)
            .and_then(Option::as_deref)
            .unwrap_or_else(|| builtin_category(category))
    } else {
        builtin_category(category)
    };

    let mut line = Vec::with_capacity(message.len() + logger.len() + 96);
    line.extend_from_slice(
        format!(
            "{{\"time\":{:.3},\"level\":\"",
            unsafe { SDL_GetTicks() } as f64 / 1000.0
        )
        .as_bytes(),
    );
    line.extend_from_slice(priority_name(priority));
    line.extend_from_slice(b"\",\"logger\":\"");
    write_escaped(&mut line, logger);
    line.extend_from_slice(b"\",\"message\":\"");
    write_escaped(&mut line, message);
    line.extend_from_slice(b"\"}\n");

    if let Some(file) = state.file.as_mut() {
        let _ = file.write_all(&line);
        let _ = file.flush();
    }
}

/// # Safety
///
/// `path` must name a NUL-terminated UTF-8 path for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsLogSinkOpen(path: *const c_char) -> bool {
    if path.is_null() {
        return false;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy();
    let Ok(file) = File::create(path.as_ref()) else {
        return false;
    };

    let should_install = {
        let mut state = lock();
        state.file = Some(file);
        if state.installed {
            false
        } else {
            let mut previous = None;
            let mut userdata = ptr::null_mut();
            unsafe { SDL_GetLogOutputFunction(&mut previous, &mut userdata) };
            state.previous = previous;
            state.previous_userdata = userdata as usize;
            state.installed = true;
            true
        }
    };
    if should_install {
        unsafe { SDL_SetLogOutputFunction(Some(sink), ptr::null_mut()) };
    }
    true
}

/// # Safety
///
/// `name` must name a NUL-terminated string for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsLogSinkCategory(base: c_int, category: c_int, name: *const c_char) {
    if name.is_null() {
        return;
    }
    let mut state = lock();
    state.category_base = base;
    let index = category - base;
    if index < 0 {
        return;
    }
    let Some(slot) = state.categories.get_mut(index as usize) else {
        return;
    };
    *slot = Some(unsafe { CStr::from_ptr(name) }.to_bytes().to_vec());
}

#[no_mangle]
pub extern "C" fn tecsLogSinkClose() {
    let (previous, userdata, was_installed) = {
        let mut state = lock();
        state.file = None;
        let installed = state.installed;
        state.installed = false;
        (
            state.previous,
            state.previous_userdata as *mut c_void,
            installed,
        )
    };
    if was_installed {
        unsafe { SDL_SetLogOutputFunction(previous, userdata) };
    }
}
