/* Linked-in Lua C modules. See luamods.c. */

#ifndef TECS2D_LUAMODS_H
#define TECS2D_LUAMODS_H

#include <lua.h>

/* Announces every compiled-in module through package.preload, so `require`
 * finds them without a search path. Call before any Lua runs. */
void tecs2dLuaModulesInstall(lua_State *L);

#endif
