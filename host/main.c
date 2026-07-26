/* tecs2d host.
 *
 * Owns the process and nothing else: create a Lua state, hand it argv, run
 * the entry chunk. Every platform capability reaches Lua through FFI, so
 * this file has no reason to grow.
 */

#include <stdio.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifndef TECS2D_ENTRY
#define TECS2D_ENTRY "main.lua"
#endif

static int traceback(lua_State *L)
{
    const char *msg = lua_tostring(L, 1);
    luaL_traceback(L, L, msg ? msg : "(non-string error)", 1);
    return 1;
}

int main(int argc, char **argv)
{
    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "tecs2d: cannot create Lua state\n");
        return 1;
    }
    luaL_openlibs(L);

    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    const char *entry = TECS2D_ENTRY;
    if (argc > 1 && strcmp(argv[1], "--entry") == 0 && argc > 2) {
        entry = argv[2];
    }

    lua_pushcfunction(L, traceback);
    int handler = lua_gettop(L);

    if (luaL_loadfile(L, entry) != 0) {
        fprintf(stderr, "tecs2d: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    if (lua_pcall(L, 0, 0, handler) != 0) {
        fprintf(stderr, "tecs2d: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
