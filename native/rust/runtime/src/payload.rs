//! Reads the build-generated compressed archive carried inside an executable.
//!
//! The host installs it as `tecs.payload` and prefers its carried entry chunk.
//! The embedded Teal CLI then reads the archive with `require("tecs.payload")`.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::Read;
use std::ptr;
use std::slice;
use std::sync::OnceLock;

use flate2::read::ZlibDecoder;

type LuaState = c_void;
type LuaCFunction = unsafe extern "C" fn(*mut LuaState) -> c_int;

const MAGIC: &[u8; 8] = b"TECSPAY1";
const LUA_GLOBALS_INDEX: c_int = -10_002;

unsafe extern "C" {
    static tecsPayload: u8;
    static tecsPayloadSize: usize;
    static tecsPayloadPlainSize: usize;
    static tecsPayloadIdentity: c_char;

    fn luaL_loadbuffer(
        state: *mut LuaState,
        buffer: *const c_char,
        size: usize,
        name: *const c_char,
    ) -> c_int;
    fn lua_createtable(state: *mut LuaState, array: c_int, records: c_int);
    fn lua_getfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_pushcclosure(state: *mut LuaState, function: LuaCFunction, captures: c_int);
    fn lua_pushlstring(state: *mut LuaState, value: *const c_char, length: usize);
    fn lua_pushnil(state: *mut LuaState);
    fn lua_pushstring(state: *mut LuaState, value: *const c_char);
    fn lua_rawseti(state: *mut LuaState, index: c_int, key: c_int);
    fn lua_setfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_settop(state: *mut LuaState, index: c_int);
}

static ARCHIVE: OnceLock<Option<Box<[u8]>>> = OnceLock::new();

fn payload_bytes() -> &'static [u8] {
    let size = unsafe { tecsPayloadSize };
    if size == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr::addr_of!(tecsPayload), size) }
    }
}

fn archive() -> Option<&'static [u8]> {
    ARCHIVE
        .get_or_init(|| {
            let compressed = payload_bytes();
            if compressed.is_empty() {
                return None;
            }
            let expected = unsafe { tecsPayloadPlainSize };
            let mut plain = Vec::with_capacity(expected);
            ZlibDecoder::new(compressed).read_to_end(&mut plain).ok()?;
            if plain.len() != expected || !plain.starts_with(MAGIC) {
                return None;
            }
            Some(plain.into_boxed_slice())
        })
        .as_deref()
}

fn take_u16(bytes: &[u8], at: &mut usize) -> Option<usize> {
    let value = u16::from_le_bytes(bytes.get(*at..*at + 2)?.try_into().ok()?);
    *at += 2;
    Some(value as usize)
}

fn take_u32(bytes: &[u8], at: &mut usize) -> Option<usize> {
    let value = u32::from_le_bytes(bytes.get(*at..*at + 4)?.try_into().ok()?);
    *at += 4;
    Some(value as usize)
}

fn entries() -> Option<Vec<(&'static [u8], &'static [u8])>> {
    let bytes = archive()?;
    let mut at = MAGIC.len();
    let count = take_u32(bytes, &mut at)?;
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        let name_length = take_u16(bytes, &mut at)?;
        let name = bytes.get(at..at.checked_add(name_length)?)?;
        at += name_length;
        let data_length = take_u32(bytes, &mut at)?;
        let data = bytes.get(at..at.checked_add(data_length)?)?;
        at += data_length;
        entries.push((name, data));
    }
    (at == bytes.len()).then_some(entries)
}

fn find(name: &[u8]) -> Option<&'static [u8]> {
    entries()?
        .into_iter()
        .find_map(|(entry_name, data)| (entry_name == name).then_some(data))
}

unsafe extern "C" fn identity_of(state: *mut LuaState) -> c_int {
    unsafe { lua_pushstring(state, ptr::addr_of!(tecsPayloadIdentity)) };
    1
}

unsafe extern "C" fn entries_of(state: *mut LuaState) -> c_int {
    let Some(entries) = entries() else {
        unsafe { lua_pushnil(state) };
        return 1;
    };
    unsafe {
        lua_createtable(
            state,
            c_int::try_from(entries.len()).unwrap_or(c_int::MAX),
            0,
        );
        for (index, (name, data)) in entries.into_iter().enumerate() {
            lua_createtable(state, 2, 0);
            lua_pushlstring(state, name.as_ptr().cast(), name.len());
            lua_rawseti(state, -2, 1);
            lua_pushlstring(state, data.as_ptr().cast(), data.len());
            lua_rawseti(state, -2, 2);
            lua_rawseti(state, -2, c_int::try_from(index + 1).unwrap_or(c_int::MAX));
        }
    }
    1
}

unsafe extern "C" fn open_payload(state: *mut LuaState) -> c_int {
    unsafe {
        lua_createtable(state, 0, 2);
        lua_pushcclosure(state, identity_of, 0);
        lua_setfield(state, -2, c"identity".as_ptr());
        lua_pushcclosure(state, entries_of, 0);
        lua_setfield(state, -2, c"entries".as_ptr());
    }
    1
}

#[no_mangle]
pub extern "C" fn tecsPayloadPresent() -> bool {
    unsafe { tecsPayloadSize != 0 }
}

/// Loads a carried Lua chunk, returning -1 when the payload has no such entry.
///
/// # Safety
///
/// `state` must be a live Lua state and `name` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn tecsPayloadLoadChunk(state: *mut LuaState, name: *const c_char) -> c_int {
    if state.is_null() || name.is_null() {
        return -1;
    }
    let name = unsafe { CStr::from_ptr(name) };
    let Some(data) = find(name.to_bytes()) else {
        return -1;
    };
    let chunk_name = CString::new(format!("@payload:{}", name.to_string_lossy()))
        .expect("C string input contains no interior NUL");
    unsafe { luaL_loadbuffer(state, data.as_ptr().cast(), data.len(), chunk_name.as_ptr()) }
}

/// Announces the carried archive as `tecs.payload` through `package.preload`.
///
/// # Safety
///
/// `state` must be a live Lua state owned by the calling thread.
#[no_mangle]
pub unsafe extern "C" fn tecsPayloadInstall(state: *mut LuaState) {
    if state.is_null() || !tecsPayloadPresent() {
        return;
    }
    unsafe {
        lua_getfield(state, LUA_GLOBALS_INDEX, c"package".as_ptr());
        lua_getfield(state, -1, c"preload".as_ptr());
        lua_pushcclosure(state, open_payload, 0);
        lua_setfield(state, -2, c"tecs.payload".as_ptr());
        lua_settop(state, -3);
    }
}
