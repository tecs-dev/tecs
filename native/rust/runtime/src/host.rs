use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard};

use sdl3_sys::events::{
    SDL_Event, SDL_EventType, SDL_EVENT_CLIPBOARD_UPDATE, SDL_EVENT_DID_ENTER_BACKGROUND,
    SDL_EVENT_DID_ENTER_FOREGROUND, SDL_EVENT_DROP_BEGIN, SDL_EVENT_DROP_COMPLETE,
    SDL_EVENT_DROP_FILE, SDL_EVENT_DROP_POSITION, SDL_EVENT_DROP_TEXT, SDL_EVENT_LOW_MEMORY,
    SDL_EVENT_TERMINATING, SDL_EVENT_TEXT_EDITING, SDL_EVENT_TEXT_EDITING_CANDIDATES,
    SDL_EVENT_TEXT_INPUT, SDL_EVENT_WILL_ENTER_BACKGROUND, SDL_EVENT_WILL_ENTER_FOREGROUND,
};
use sdl3_sys::filesystem::SDL_GetBasePath;
use sdl3_sys::init::{SDL_AppResult, SDL_APP_CONTINUE, SDL_APP_FAILURE, SDL_APP_SUCCESS};
use sdl3_sys::log::SDL_Log;
use sdl3_sys::thread::{SDL_GetCurrentThreadID, SDL_ThreadID};
use sdl3_sys::timer::{SDL_GetPerformanceCounter, SDL_GetPerformanceFrequency, SDL_GetTicksNS};

use crate::mcodearena::{tecsMcodeArenaRelease, tecsMcodeArenaReserve};

type LuaState = c_void;
type LuaCFunction = unsafe extern "C" fn(*mut LuaState) -> c_int;

const LUA_REGISTRY_INDEX: c_int = -10_000;
const LUA_GLOBALS_INDEX: c_int = -10_002;
const LUA_NOREF: c_int = -2;
const LUA_TBOOLEAN: c_int = 1;
const LUA_TTABLE: c_int = 5;
const LUA_TFUNCTION: c_int = 6;
const INITIAL_EVENTS: usize = 256;
const BACKGROUND_BUDGET_NS: u64 = 250_000_000;
const ENTRY: &str = match option_env!("TECS_ENTRY") {
    Some(value) => value,
    None => "main.lua",
};
const CONTENT: &str = match option_env!("TECS_CONTENT") {
    Some(value) => value,
    None => "",
};

unsafe extern "C" {
    fn luaL_newstate() -> *mut LuaState;
    fn luaL_openlibs(state: *mut LuaState);
    fn luaL_loadfile(state: *mut LuaState, path: *const c_char) -> c_int;
    fn luaL_ref(state: *mut LuaState, table: c_int) -> c_int;
    fn luaL_traceback(
        state: *mut LuaState,
        from: *mut LuaState,
        message: *const c_char,
        level: c_int,
    );
    fn lua_close(state: *mut LuaState);
    fn lua_getfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_gettop(state: *mut LuaState) -> c_int;
    fn lua_insert(state: *mut LuaState, index: c_int);
    fn lua_pcall(state: *mut LuaState, arguments: c_int, results: c_int, error: c_int) -> c_int;
    fn lua_pushcclosure(state: *mut LuaState, function: LuaCFunction, captures: c_int);
    fn lua_pushinteger(state: *mut LuaState, value: i64);
    fn lua_pushlightuserdata(state: *mut LuaState, value: *mut c_void);
    fn lua_pushstring(state: *mut LuaState, value: *const c_char);
    fn lua_pushvalue(state: *mut LuaState, index: c_int);
    fn lua_rawgeti(state: *mut LuaState, table: c_int, key: c_int);
    fn lua_rawseti(state: *mut LuaState, table: c_int, key: c_int);
    fn lua_setfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_settop(state: *mut LuaState, index: c_int);
    fn lua_toboolean(state: *mut LuaState, index: c_int) -> c_int;
    fn lua_tolstring(state: *mut LuaState, index: c_int, length: *mut usize) -> *const c_char;
    fn lua_type(state: *mut LuaState, index: c_int) -> c_int;
    fn lua_createtable(state: *mut LuaState, array: c_int, records: c_int);

    fn tecsRegistryInstall(state: *mut LuaState);
    fn tecsLuaModulesInstall(state: *mut LuaState);
    #[cfg(feature = "payload")]
    fn tecsPayloadInstall(state: *mut LuaState);
    #[cfg(feature = "payload")]
    fn tecsPayloadLoadChunk(state: *mut LuaState, name: *const c_char) -> c_int;
}

struct EventBatch {
    events: Vec<SDL_Event>,
    arrivals: Vec<u64>,
    strings: Vec<CString>,
    pointer_arrays: Vec<Box<[*const c_char]>>,
}

impl EventBatch {
    fn with_capacity(capacity: usize) -> Self {
        Self {
            events: Vec::with_capacity(capacity),
            arrivals: Vec::with_capacity(capacity),
            strings: Vec::new(),
            pointer_arrays: Vec::new(),
        }
    }

    fn clear(&mut self) {
        self.events.clear();
        self.arrivals.clear();
        self.pointer_arrays.clear();
        self.strings.clear();
    }

    unsafe fn own_string(&mut self, source: *const c_char) -> *const c_char {
        if source.is_null() {
            return ptr::null();
        }
        self.strings
            .push(unsafe { CStr::from_ptr(source) }.to_owned());
        self.strings
            .last()
            .expect("the string was just inserted")
            .as_ptr()
    }

    unsafe fn own_strings(
        &mut self,
        source: *const *const c_char,
        count: c_int,
    ) -> *const *const c_char {
        if source.is_null() || count <= 0 {
            return ptr::null();
        }
        let mut pointers = Vec::with_capacity(count as usize);
        for index in 0..count as usize {
            pointers.push(unsafe { self.own_string(*source.add(index)) });
        }
        self.pointer_arrays.push(pointers.into_boxed_slice());
        self.pointer_arrays
            .last()
            .expect("the pointer array was just inserted")
            .as_ptr()
    }

    unsafe fn push(&mut self, source: *const SDL_Event, arrival: u64) {
        let mut event = unsafe { *source };
        let event_type = event.event_type();
        match event_type {
            SDL_EVENT_TEXT_INPUT => {
                event.text.text = unsafe { self.own_string(event.text.text) };
            }
            SDL_EVENT_TEXT_EDITING => {
                event.edit.text = unsafe { self.own_string(event.edit.text) };
            }
            SDL_EVENT_TEXT_EDITING_CANDIDATES => {
                let count = unsafe { event.edit_candidates.num_candidates };
                let candidates =
                    unsafe { self.own_strings(event.edit_candidates.candidates, count) };
                event.edit_candidates.candidates = candidates;
                if candidates.is_null() {
                    event.edit_candidates.num_candidates = 0;
                    event.edit_candidates.selected_candidate = -1;
                }
            }
            SDL_EVENT_DROP_BEGIN
            | SDL_EVENT_DROP_FILE
            | SDL_EVENT_DROP_TEXT
            | SDL_EVENT_DROP_POSITION
            | SDL_EVENT_DROP_COMPLETE => {
                event.drop.source = unsafe { self.own_string(event.drop.source) };
                event.drop.data = unsafe { self.own_string(event.drop.data) };
            }
            SDL_EVENT_CLIPBOARD_UPDATE => {
                let count = unsafe { event.clipboard.num_mime_types };
                let types =
                    unsafe { self.own_strings(event.clipboard.mime_types.cast_const(), count) };
                event.clipboard.mime_types = types.cast_mut();
                if types.is_null() {
                    event.clipboard.num_mime_types = 0;
                }
            }
            _ => {}
        }
        self.events.push(event);
        self.arrivals.push(arrival);
    }
}

// SDL_Event contains borrowed pointers which are replaced with allocations
// owned by the batch before the batch crosses threads.
unsafe impl Send for EventBatch {}

struct Queues {
    live: EventBatch,
    spare: EventBatch,
}

struct Host {
    lua: *mut LuaState,
    application: c_int,
    owner: SDL_ThreadID,
    queues: Mutex<Queues>,
    lua_active: AtomicI32,
    deferred: AtomicU32,
    background: AtomicBool,
    terminating: AtomicBool,
    counter_epoch: u64,
    counter_per_nanosecond: f64,
    shutdown_called: bool,
}

// Lua is only entered on `owner`. Other threads can touch the atomics and the
// event queue, whose SDL pointers have been deep-copied first.
unsafe impl Send for Host {}
unsafe impl Sync for Host {}

fn lock_queues(host: &Host) -> MutexGuard<'_, Queues> {
    host.queues
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn clean_cstring(text: impl AsRef<[u8]>) -> CString {
    CString::new(
        text.as_ref()
            .iter()
            .map(|byte| if *byte == 0 { b'?' } else { *byte })
            .collect::<Vec<_>>(),
    )
    .expect("NUL bytes were replaced")
}

fn log_message(message: impl AsRef<[u8]>) {
    let message = clean_cstring(message);
    unsafe { SDL_Log(c"%s".as_ptr(), message.as_ptr()) };
}

unsafe extern "C" fn traceback(state: *mut LuaState) -> c_int {
    let message = unsafe { lua_tolstring(state, 1, ptr::null_mut()) };
    let message = if message.is_null() {
        c"(non-string error)".as_ptr()
    } else {
        message
    };
    unsafe { luaL_traceback(state, state, message, 1) };
    1
}

enum MethodResult {
    Continue,
    Stop,
    Failed,
}

unsafe fn call_method(
    host: &Host,
    method: &CStr,
    push: Option<unsafe fn(*mut LuaState, &Host)>,
    extra: c_int,
    required: bool,
) -> MethodResult {
    let state = host.lua;
    let base = unsafe { lua_gettop(state) };
    unsafe {
        lua_pushcclosure(state, traceback, 0);
        lua_rawgeti(state, LUA_REGISTRY_INDEX, host.application);
        lua_getfield(state, -1, method.as_ptr());
    }
    if unsafe { lua_type(state, -1) } != LUA_TFUNCTION {
        if required {
            log_message(format!(
                "tecs: application has no {} method",
                method.to_string_lossy()
            ));
        }
        unsafe { lua_settop(state, base) };
        return if required {
            MethodResult::Failed
        } else {
            MethodResult::Continue
        };
    }
    unsafe { lua_pushvalue(state, -2) };
    if let Some(push) = push {
        unsafe { push(state, host) };
    }
    host.lua_active.fetch_add(1, Ordering::Relaxed);
    let failed = unsafe { lua_pcall(state, 1 + extra, 1, base + 1) } != 0;
    host.lua_active.fetch_sub(1, Ordering::Relaxed);
    if failed {
        let message = unsafe { lua_tolstring(state, -1, ptr::null_mut()) };
        if message.is_null() {
            log_message("tecs: unknown Lua error");
        } else {
            log_message(unsafe { CStr::from_ptr(message) }.to_bytes());
        }
        unsafe { lua_settop(state, base) };
        return MethodResult::Failed;
    }
    let keep_going =
        unsafe { lua_type(state, -1) } != LUA_TBOOLEAN || unsafe { lua_toboolean(state, -1) } != 0;
    unsafe { lua_settop(state, base) };
    if keep_going {
        MethodResult::Continue
    } else {
        MethodResult::Stop
    }
}

unsafe fn push_queue(state: *mut LuaState, host: &Host) {
    let queues = lock_queues(host);
    unsafe {
        lua_pushlightuserdata(state, queues.spare.events.as_ptr().cast_mut().cast());
        lua_pushinteger(
            state,
            i64::try_from(queues.spare.events.len()).unwrap_or(i64::MAX),
        );
        lua_pushlightuserdata(state, queues.spare.arrivals.as_ptr().cast_mut().cast());
    }
}

fn lifecycle(event_type: SDL_EventType) -> Option<(u32, &'static CStr)> {
    match event_type {
        SDL_EVENT_LOW_MEMORY => Some((0x01, c"_lowMemory")),
        SDL_EVENT_WILL_ENTER_BACKGROUND => Some((0x02, c"_willEnterBackground")),
        SDL_EVENT_DID_ENTER_BACKGROUND => Some((0x04, c"_didEnterBackground")),
        SDL_EVENT_WILL_ENTER_FOREGROUND => Some((0x08, c"_willEnterForeground")),
        SDL_EVENT_DID_ENTER_FOREGROUND => Some((0x10, c"_didEnterForeground")),
        SDL_EVENT_TERMINATING => Some((0x20, c"_terminating")),
        _ => None,
    }
}

fn apply_lifecycle(host: &Host, event_type: SDL_EventType) -> bool {
    match event_type {
        SDL_EVENT_WILL_ENTER_BACKGROUND => host
            .background
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok(),
        SDL_EVENT_DID_ENTER_FOREGROUND => {
            host.background.store(false, Ordering::Release);
            true
        }
        SDL_EVENT_TERMINATING => {
            host.terminating.store(true, Ordering::Release);
            true
        }
        _ => true,
    }
}

unsafe fn run_lifecycle(host: &Host, event_type: SDL_EventType, method: &CStr) {
    if event_type != SDL_EVENT_WILL_ENTER_BACKGROUND {
        unsafe { call_method(host, method, None, 0, false) };
        return;
    }
    let started = unsafe { SDL_GetTicksNS() };
    unsafe { call_method(host, method, None, 0, false) };
    let spent = unsafe { SDL_GetTicksNS() }.saturating_sub(started);
    if spent > BACKGROUND_BUDGET_NS {
        log_message(format!(
            "tecs: _willEnterBackground took {} ms; flush a prepared checkpoint rather than building one here",
            spent / 1_000_000
        ));
    }
}

unsafe fn dispatch_lifecycle(host: &Host, event_type: SDL_EventType, bit: u32, method: &CStr) {
    if SDL_GetCurrentThreadID() == host.owner && host.lua_active.load(Ordering::Acquire) == 0 {
        unsafe { run_lifecycle(host, event_type, method) };
    } else if host.terminating.load(Ordering::Acquire) {
        log_message(format!(
            "tecs: {} could not run; the Lua state was busy and the process is terminating",
            method.to_string_lossy()
        ));
    } else {
        host.deferred.fetch_or(bit, Ordering::AcqRel);
    }
}

unsafe fn drain_deferred(host: &Host) {
    let pending = host.deferred.swap(0, Ordering::AcqRel);
    for event_type in [
        SDL_EVENT_LOW_MEMORY,
        SDL_EVENT_WILL_ENTER_BACKGROUND,
        SDL_EVENT_DID_ENTER_BACKGROUND,
        SDL_EVENT_WILL_ENTER_FOREGROUND,
        SDL_EVENT_DID_ENTER_FOREGROUND,
        SDL_EVENT_TERMINATING,
    ] {
        let Some((bit, method)) = lifecycle(event_type) else {
            continue;
        };
        if pending & bit != 0 {
            unsafe { run_lifecycle(host, event_type, method) };
        }
    }
}

fn arrival_of(host: &Host, event: &SDL_Event) -> u64 {
    let stamp = unsafe { event.common.timestamp };
    if stamp == 0 {
        return unsafe { SDL_GetPerformanceCounter() };
    }
    host.counter_epoch
        .saturating_add((stamp as f64 * host.counter_per_nanosecond) as u64)
}

unsafe fn initialize(
    appstate: *mut *mut c_void,
    argc: c_int,
    argv: *mut *mut c_char,
) -> SDL_AppResult {
    tecsMcodeArenaReserve();
    if appstate.is_null() || argc < 0 || (argc > 0 && argv.is_null()) {
        return SDL_APP_FAILURE;
    }
    let before = unsafe { SDL_GetPerformanceCounter() };
    let ticks = unsafe { SDL_GetTicksNS() };
    let after = unsafe { SDL_GetPerformanceCounter() };
    let scale = unsafe { SDL_GetPerformanceFrequency() } as f64 * 1e-9;
    let epoch = (((before as f64 + after as f64) * 0.5) - ticks as f64 * scale) as u64;

    let lua = unsafe { luaL_newstate() };
    if lua.is_null() {
        log_message("tecs: cannot create Lua state");
        return SDL_APP_FAILURE;
    }
    let mut host = Box::new(Host {
        lua,
        application: LUA_NOREF,
        owner: SDL_GetCurrentThreadID(),
        queues: Mutex::new(Queues {
            live: EventBatch::with_capacity(INITIAL_EVENTS),
            spare: EventBatch::with_capacity(INITIAL_EVENTS),
        }),
        lua_active: AtomicI32::new(0),
        deferred: AtomicU32::new(0),
        background: AtomicBool::new(false),
        terminating: AtomicBool::new(false),
        counter_epoch: epoch,
        counter_per_nanosecond: scale,
        shutdown_called: false,
    });
    unsafe { *appstate = (&mut *host as *mut Host).cast() };

    unsafe {
        luaL_openlibs(lua);
        tecsRegistryInstall(lua);
        tecsLuaModulesInstall(lua);
        #[cfg(feature = "payload")]
        tecsPayloadInstall(lua);
    }

    unsafe { lua_createtable(lua, argc, 0) };
    let arguments = if argc == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(argv, argc as usize) }
    };
    for (index, argument) in arguments.iter().enumerate() {
        unsafe {
            lua_pushstring(lua, *argument);
            lua_rawseti(lua, -2, c_int::try_from(index).unwrap_or(c_int::MAX));
        }
    }
    unsafe { lua_setfield(lua, LUA_GLOBALS_INDEX, c"arg".as_ptr()) };

    let base = unsafe { SDL_GetBasePath() };
    let content = if base.is_null() {
        None
    } else {
        Some(format!(
            "{}{}",
            unsafe { CStr::from_ptr(base) }.to_string_lossy(),
            CONTENT
        ))
    };
    if let Some(content) = content.as_deref() {
        let content_c = clean_cstring(content);
        unsafe {
            lua_pushstring(lua, content_c.as_ptr());
            lua_setfield(lua, LUA_GLOBALS_INDEX, c"__tecsContent".as_ptr());
        }
        let root = std::env::var("TECS_LUA")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| content.to_owned());
        unsafe {
            lua_getfield(lua, LUA_GLOBALS_INDEX, c"package".as_ptr());
            lua_getfield(lua, -1, c"path".as_ptr());
        }
        let had = unsafe { lua_tolstring(lua, -1, ptr::null_mut()) };
        let had = if had.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(had) }
                .to_string_lossy()
                .into_owned()
        };
        let path = clean_cstring(format!("{root}/?.lua;{root}/?/init.lua;{had}"));
        unsafe {
            lua_settop(lua, -2);
            lua_pushstring(lua, path.as_ptr());
            lua_setfield(lua, -2, c"path".as_ptr());
            lua_settop(lua, -2);
        }
    }

    // `--entry` is a private leading host option. Looking for it later would
    // mistake a forwarded game argument of the same spelling for another
    // bootstrap.
    let entry = (arguments.len() > 2
        && !arguments[1].is_null()
        && unsafe { CStr::from_ptr(arguments[1]) }.to_bytes() == b"--entry"
        && !arguments[2].is_null())
    .then(|| unsafe { CStr::from_ptr(arguments[2]) }.to_owned());
    let configured_entry = clean_cstring(ENTRY);
    let carried = entry.as_deref().unwrap_or(configured_entry.as_c_str());
    let resolved = entry.clone().unwrap_or_else(|| {
        clean_cstring(
            content
                .as_ref()
                .map_or_else(|| ENTRY.to_owned(), |root| format!("{root}{ENTRY}")),
        )
    });

    #[cfg(feature = "payload")]
    let mut compiled = unsafe { tecsPayloadLoadChunk(lua, carried.as_ptr()) };
    #[cfg(not(feature = "payload"))]
    let mut compiled = {
        let _ = carried;
        -1
    };
    if compiled < 0 {
        compiled = unsafe { luaL_loadfile(lua, resolved.as_ptr()) };
    }

    unsafe { lua_pushcclosure(lua, traceback, 0) };
    #[cfg(not(feature = "payload"))]
    unsafe {
        // A game entry expects the engine global before its first line. The
        // embedded CLI is different: it must unpack and prepend its payload
        // before requiring the engine. Trying here can resolve the project's
        // manifest (`./tecs.lua`) as the engine while running inside a game.
        lua_getfield(lua, LUA_GLOBALS_INDEX, c"require".as_ptr());
        lua_pushstring(lua, c"tecs".as_ptr());
        if lua_pcall(lua, 1, 0, 0) != 0 {
            lua_settop(lua, -2);
        }
    }
    unsafe { lua_insert(lua, -2) };
    let loaded = compiled == 0 && unsafe { lua_pcall(lua, 0, 1, -2) } == 0;
    if !loaded {
        let message = unsafe { lua_tolstring(lua, -1, ptr::null_mut()) };
        if message.is_null() {
            log_message("tecs: cannot load entry");
        } else {
            log_message(unsafe { CStr::from_ptr(message) }.to_bytes());
        }
        Box::leak(host);
        return SDL_APP_FAILURE;
    }
    if unsafe { lua_type(lua, -1) } != LUA_TTABLE {
        log_message(format!(
            "tecs: {} must return tecs.application.create(config)",
            resolved.to_string_lossy()
        ));
        Box::leak(host);
        return SDL_APP_FAILURE;
    }
    host.application = unsafe { luaL_ref(lua, LUA_REGISTRY_INDEX) };
    unsafe { lua_settop(lua, 0) };
    if !matches!(
        unsafe { call_method(&host, c"_init", None, 0, true) },
        MethodResult::Continue
    ) {
        Box::leak(host);
        return SDL_APP_FAILURE;
    }
    tecsMcodeArenaRelease();
    Box::leak(host);
    SDL_APP_CONTINUE
}

#[no_mangle]
pub unsafe extern "C" fn SDL_AppInit(
    appstate: *mut *mut c_void,
    argc: c_int,
    argv: *mut *mut c_char,
) -> SDL_AppResult {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        initialize(appstate, argc, argv)
    }))
    .unwrap_or_else(|_| {
        log_message("tecs: Rust panic in SDL_AppInit");
        SDL_APP_FAILURE
    })
}

#[no_mangle]
pub unsafe extern "C" fn SDL_AppEvent(
    appstate: *mut c_void,
    event: *mut SDL_Event,
) -> SDL_AppResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(host) = (unsafe { appstate.cast::<Host>().as_ref() }) else {
            return SDL_APP_FAILURE;
        };
        let Some(event) = (unsafe { event.as_ref() }) else {
            return SDL_APP_FAILURE;
        };
        let event_type = event.event_type();
        let transition = lifecycle(event_type);
        let dispatch = transition.is_some() && apply_lifecycle(host, event_type);
        {
            let mut queues = lock_queues(host);
            unsafe { queues.live.push(event, arrival_of(host, event)) };
        }
        if dispatch {
            let (bit, method) = transition.expect("the transition was present");
            unsafe { dispatch_lifecycle(host, event_type, bit, method) };
        }
        SDL_APP_CONTINUE
    }))
    .unwrap_or_else(|_| {
        log_message("tecs: Rust panic in SDL_AppEvent");
        SDL_APP_FAILURE
    })
}

#[no_mangle]
pub unsafe extern "C" fn SDL_AppIterate(appstate: *mut c_void) -> SDL_AppResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(host) = (unsafe { appstate.cast::<Host>().as_ref() }) else {
            return SDL_APP_FAILURE;
        };
        unsafe { drain_deferred(host) };
        {
            let mut queues = lock_queues(host);
            let spare =
                std::mem::replace(&mut queues.spare, EventBatch::with_capacity(INITIAL_EVENTS));
            let ready = std::mem::replace(&mut queues.live, spare);
            queues.spare = ready;
        }
        let result = unsafe { call_method(host, c"_iterate", Some(push_queue), 3, true) };
        {
            let mut queues = lock_queues(host);
            queues.spare.clear();
        }
        match result {
            MethodResult::Continue => SDL_APP_CONTINUE,
            MethodResult::Stop => SDL_APP_SUCCESS,
            MethodResult::Failed => SDL_APP_FAILURE,
        }
    }))
    .unwrap_or_else(|_| {
        log_message("tecs: Rust panic in SDL_AppIterate");
        SDL_APP_FAILURE
    })
}

#[no_mangle]
pub unsafe extern "C" fn SDL_AppQuit(appstate: *mut c_void, _result: SDL_AppResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if appstate.is_null() {
            return;
        }
        let mut host = unsafe { Box::from_raw(appstate.cast::<Host>()) };
        if !host.lua.is_null() && host.application != LUA_NOREF && !host.shutdown_called {
            host.shutdown_called = true;
            unsafe { call_method(&host, c"_shutdown", None, 0, true) };
        }
        if !host.lua.is_null() {
            unsafe { lua_close(host.lua) };
            host.lua = ptr::null_mut();
        }
    }))
    .map_err(|_| log_message("tecs: Rust panic in SDL_AppQuit"));
}
