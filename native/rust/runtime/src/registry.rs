//! Installs build-generated native function tables into each Lua state.
//!
//! Host and worker bootstrap call this before Teal runs. `tecs.ffi.loader`
//! reads the resulting `__tecsRegistry`; Teal does not call this ABI directly.

use std::ffi::{c_char, c_int, c_void};
use std::slice;

type LuaState = c_void;

unsafe extern "C" {
    fn lua_createtable(state: *mut LuaState, array: c_int, records: c_int);
    fn lua_pushlightuserdata(state: *mut LuaState, value: *mut c_void);
    fn lua_setfield(state: *mut LuaState, index: c_int, name: *const c_char);
}

/// Installs generated native API tables into a Lua state.
///
/// The build owns the list of generated APIs. Rust owns the Lua stack
/// operation; generated C only resolves the selected accessor symbols into
/// parallel name and pointer arrays.
///
/// # Safety
///
/// `state` must be a live Lua state. `names` and `tables` must each address
/// `count` entries, and every name must be NUL terminated.
#[no_mangle]
pub unsafe extern "C" fn tecsRegistryInstallTables(
    state: *mut LuaState,
    count: usize,
    names: *const *const c_char,
    tables: *const *const c_void,
) {
    if state.is_null() || (count != 0 && (names.is_null() || tables.is_null())) {
        return;
    }
    let names = unsafe { slice::from_raw_parts(names, count) };
    let tables = unsafe { slice::from_raw_parts(tables, count) };
    unsafe {
        lua_createtable(state, 0, c_int::try_from(count).unwrap_or(c_int::MAX));
        for (name, table) in names.iter().zip(tables) {
            if !name.is_null() && !table.is_null() {
                lua_pushlightuserdata(state, (*table).cast_mut());
                lua_setfield(state, -2, *name);
            }
        }
        lua_setfield(state, -10_002, c"__tecsRegistry".as_ptr());
    }
}
