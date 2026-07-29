use std::ffi::{c_char, c_int, c_void};

type LuaState = c_void;
type LuaCFunction = unsafe extern "C" fn(*mut LuaState) -> c_int;

unsafe extern "C" {
    fn lua_getfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_pushcclosure(state: *mut LuaState, function: LuaCFunction, captures: c_int);
    fn lua_setfield(state: *mut LuaState, index: c_int, name: *const c_char);
    fn lua_settop(state: *mut LuaState, index: c_int);
    fn luaopen_cjson(state: *mut LuaState) -> c_int;
}

/// Announces each linked Lua C module through `package.preload`.
///
/// # Safety
///
/// `state` must be a live Lua state owned by the calling thread.
#[no_mangle]
pub unsafe extern "C" fn tecsLuaModulesInstall(state: *mut LuaState) {
    if state.is_null() {
        return;
    }
    unsafe {
        lua_getfield(state, -10_002, c"package".as_ptr());
        lua_getfield(state, -1, c"preload".as_ptr());
        lua_pushcclosure(state, luaopen_cjson, 0);
        lua_setfield(state, -2, c"cjson".as_ptr());
        lua_settop(state, -3);
    }
}
