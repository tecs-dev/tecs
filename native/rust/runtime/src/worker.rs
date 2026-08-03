//! Owns byte channels and worker threads, each with a fresh LuaJIT state.
//!
//! `tecs.workers` calls the channel and spawn/join ABI through generated FFI;
//! Teal owns message serialization and the source executed by each worker.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::slice;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

type LuaState = c_void;

unsafe extern "C" {
    fn luaL_newstate() -> *mut LuaState;
    fn luaL_openlibs(state: *mut LuaState);
    fn luaL_loadbuffer(
        state: *mut LuaState,
        buffer: *const c_char,
        size: usize,
        name: *const c_char,
    ) -> c_int;
    fn lua_pcall(state: *mut LuaState, arguments: c_int, results: c_int, error: c_int) -> c_int;
    fn lua_close(state: *mut LuaState);
    fn lua_getfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_pushstring(state: *mut LuaState, value: *const c_char);
    fn lua_setfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_settop(state: *mut LuaState, index: c_int);
    fn lua_pushlightuserdata(state: *mut LuaState, value: *mut c_void);
    fn lua_tolstring(state: *mut LuaState, index: c_int, length: *mut usize) -> *const c_char;

    fn tecsRegistryInstall(state: *mut LuaState);
    fn tecsLuaModulesInstall(state: *mut LuaState);
    fn SDL_Log(format: *const c_char, ...);
}

struct ChannelState {
    messages: std::collections::VecDeque<Box<[u8]>>,
    bytes: usize,
    closed: bool,
}

const MAX_CHANNEL_MESSAGES: usize = 1024;
const MAX_CHANNEL_BYTES: usize = 256 * 1024 * 1024;

pub struct TecsChannel {
    state: Mutex<ChannelState>,
    arrived: Condvar,
}

struct Message {
    bytes: Box<[u8]>,
}

pub struct TecsWorker {
    thread: Option<JoinHandle<c_int>>,
}

fn lock_channel(channel: &TecsChannel) -> MutexGuard<'_, ChannelState> {
    channel
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[no_mangle]
pub extern "C" fn tecsChannelCreate() -> *mut TecsChannel {
    Box::into_raw(Box::new(TecsChannel {
        state: Mutex::new(ChannelState {
            messages: std::collections::VecDeque::new(),
            bytes: 0,
            closed: false,
        }),
        arrived: Condvar::new(),
    }))
}

/// # Safety
///
/// `channel` must be null or an owned channel pointer, destroyed once.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelDestroy(channel: *mut TecsChannel) {
    if !channel.is_null() {
        drop(unsafe { Box::from_raw(channel) });
    }
}

/// # Safety
///
/// `channel` must be null or a live channel pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelClose(channel: *mut TecsChannel) {
    let Some(channel) = (unsafe { channel.as_ref() }) else {
        return;
    };
    let mut state = lock_channel(channel);
    state.closed = true;
    channel.arrived.notify_all();
}

/// # Safety
///
/// `channel` must be a live channel pointer. When `size` is nonzero, `data`
/// must address that many readable bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelPush(
    channel: *mut TecsChannel,
    data: *const c_void,
    size: u32,
) -> bool {
    let Some(channel) = (unsafe { channel.as_ref() }) else {
        return false;
    };
    if data.is_null() && size != 0 {
        return false;
    }
    let bytes = if size == 0 {
        Box::new([])
    } else {
        unsafe { slice::from_raw_parts(data.cast::<u8>(), size as usize) }
            .to_vec()
            .into_boxed_slice()
    };
    let mut state = lock_channel(channel);
    if state.closed {
        return false;
    }
    if state.messages.len() >= MAX_CHANNEL_MESSAGES
        || state.bytes.saturating_add(bytes.len()) > MAX_CHANNEL_BYTES
    {
        return false;
    }
    state.bytes += bytes.len();
    state.messages.push_back(bytes);
    channel.arrived.notify_one();
    true
}

/// # Safety
///
/// `channel` and `out` must be live pointers. The returned message belongs to
/// the caller and must be released with `tecsChannelFree`.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelPop(
    channel: *mut TecsChannel,
    out: *mut *mut c_void,
    timeout_ms: i32,
) -> u32 {
    let Some(channel) = (unsafe { channel.as_ref() }) else {
        return 0;
    };
    if out.is_null() {
        return 0;
    }
    unsafe { *out = ptr::null_mut() };

    let mut state = lock_channel(channel);
    if timeout_ms < 0 {
        while state.messages.is_empty() && !state.closed {
            state = channel
                .arrived
                .wait(state)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    } else if timeout_ms > 0 {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms as u64);
        while state.messages.is_empty() && !state.closed {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            let waited = channel
                .arrived
                .wait_timeout(state, remaining)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state = waited.0;
            if waited.1.timed_out() {
                break;
            }
        }
    }

    let Some(bytes) = state.messages.pop_front() else {
        return 0;
    };
    state.bytes = state.bytes.saturating_sub(bytes.len());
    let size = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
    let message = Box::new(Message { bytes });
    unsafe { *out = Box::into_raw(message).cast() };
    size
}

/// # Safety
///
/// `message` must be null or a live message returned by `tecsChannelPop`.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelData(message: *mut c_void) -> *mut c_void {
    let Some(message) = (unsafe { message.cast::<Message>().as_mut() }) else {
        return ptr::null_mut();
    };
    message.bytes.as_mut_ptr().cast()
}

/// # Safety
///
/// `message` must be null or an owned message returned by `tecsChannelPop`.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelFree(message: *mut c_void) {
    if !message.is_null() {
        drop(unsafe { Box::from_raw(message.cast::<Message>()) });
    }
}

/// # Safety
///
/// `channel` must be null or a live channel pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelCount(channel: *mut TecsChannel) -> u32 {
    let Some(channel) = (unsafe { channel.as_ref() }) else {
        return 0;
    };
    u32::try_from(lock_channel(channel).messages.len()).unwrap_or(u32::MAX)
}

/// Reports whether the channel is closed, so a reader can tell an empty queue
/// from one nothing will ever arrive on again.
///
/// # Safety
///
/// `channel` must be null or a live channel pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsChannelIsClosed(channel: *mut TecsChannel) -> bool {
    let Some(channel) = (unsafe { channel.as_ref() }) else {
        return true;
    };
    lock_channel(channel).closed
}

unsafe fn set_pointer(state: *mut LuaState, name: &CStr, value: *mut c_void) {
    unsafe {
        lua_pushlightuserdata(state, value);
        lua_setglobal_compat(state, name);
    }
}

unsafe fn lua_setglobal_compat(state: *mut LuaState, name: &CStr) {
    unsafe { lua_setfield(state, -10_002, name.as_ptr()) };
}

fn worker_entry(
    source: CString,
    lua_path: Option<CString>,
    to_worker: usize,
    from_worker: usize,
) -> c_int {
    let state = unsafe { luaL_newstate() };
    if state.is_null() {
        return 1;
    }
    unsafe {
        luaL_openlibs(state);
        tecsRegistryInstall(state);
        tecsLuaModulesInstall(state);

        if let Some(lua_path) = lua_path {
            lua_getfield(state, -10_002, c"package".as_ptr());
            lua_pushstring(state, lua_path.as_ptr());
            lua_setfield(state, -2, c"path".as_ptr());
            lua_settop(state, -2);
        }

        set_pointer(
            state,
            c"__tecsWorkerIn",
            to_worker as *mut TecsChannel as *mut c_void,
        );
        set_pointer(
            state,
            c"__tecsWorkerOut",
            from_worker as *mut TecsChannel as *mut c_void,
        );

        let failed = luaL_loadbuffer(
            state,
            source.as_ptr(),
            source.as_bytes().len(),
            c"=worker".as_ptr(),
        ) != 0
            || lua_pcall(state, 0, 0, 0) != 0;
        if failed {
            let message = lua_tolstring(state, -1, ptr::null_mut());
            SDL_Log(
                c"tecs worker: %s".as_ptr(),
                if message.is_null() {
                    c"unknown error".as_ptr()
                } else {
                    message
                },
            );
            lua_close(state);
            // The spawner may be parked on a result. Closing the outbox is the
            // only signal that no result is coming, and it must reach a worker
            // that raised as surely as one that ran to the end.
            tecsChannelClose(from_worker as *mut TecsChannel);
            return 1;
        }
        lua_close(state);
        tecsChannelClose(from_worker as *mut TecsChannel);
    }
    0
}

/// # Safety
///
/// `source` must name a NUL-terminated Lua chunk. `lua_path` may be null or
/// name a NUL-terminated package path. Both channel pointers must remain live
/// until the worker is joined.
#[no_mangle]
pub unsafe extern "C" fn tecsWorkerSpawn(
    source: *const c_char,
    lua_path: *const c_char,
    to_worker: *mut TecsChannel,
    from_worker: *mut TecsChannel,
) -> *mut TecsWorker {
    if source.is_null() || to_worker.is_null() || from_worker.is_null() {
        return ptr::null_mut();
    }
    let source = unsafe { CStr::from_ptr(source) }.to_owned();
    let lua_path = if lua_path.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(lua_path) }.to_owned())
    };
    let to_worker = to_worker as usize;
    let from_worker = from_worker as usize;
    let thread = match thread::Builder::new()
        .name("tecs.worker".to_owned())
        .spawn(move || worker_entry(source, lua_path, to_worker, from_worker))
    {
        Ok(thread) => thread,
        Err(_) => return ptr::null_mut(),
    };
    Box::into_raw(Box::new(TecsWorker {
        thread: Some(thread),
    }))
}

/// # Safety
///
/// `worker` must be null or an owned worker pointer, joined once.
#[no_mangle]
pub unsafe extern "C" fn tecsWorkerJoin(worker: *mut TecsWorker) -> c_int {
    if worker.is_null() {
        return 1;
    }
    let mut worker = unsafe { Box::from_raw(worker) };
    worker
        .thread
        .take()
        .expect("worker thread is present")
        .join()
        .unwrap_or(1)
}
