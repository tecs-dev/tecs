/* Lua modules that are linked in rather than loaded from a file.
 *
 * A target that forbids dlopen cannot find a `.so` on a search path, so a Lua
 * C module has to be compiled into the executable and announced through
 * package.preload. This is the same reasoning as the native registry, one
 * layer up: registry.c hands out C function pointers for the FFI, and this
 * hands out Lua module openers.
 */

#include <lua.h>
#include <lauxlib.h>

#include "luamods.h"

int luaopen_cjson(lua_State *L);

static void preload(lua_State *L, const char *name, lua_CFunction opener)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, opener);
    lua_setfield(L, -2, name);
    lua_pop(L, 2);
}

void tecs2dLuaModulesInstall(lua_State *L)
{
    preload(L, "cjson", luaopen_cjson);
}
