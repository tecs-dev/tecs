/* The native API registry.
 *
 * Every Lua state gets a table of library names to function-pointer tables,
 * installed before any Lua runs. That is what makes a statically linked target
 * work: `ffi.load` needs a shared object and a working `dlopen`, and iOS has
 * neither, but addresses taken at build time are just as callable.
 *
 * Worker states get the same table. A worker resolving its own libraries would
 * reintroduce the dependency on dynamic loading in the one place it is hardest
 * to notice, since a worker failing to start looks like a worker that had
 * nothing to do.
 */

#include <lua.h>
#include <lauxlib.h>

#include "registry.h"

/* Each generated table declares its accessor. Kept as declarations rather than
 * an include so a target can link a subset: a release with packaged shaders
 * links no shader compiler, and the entries for it are simply absent. */
#define TECS2D_API(name, struct_) extern const void *tecs2d_##name##_api(void);
#include "registry_entries.h"
#undef TECS2D_API

void tecs2dRegistryInstall(lua_State *L)
{
    lua_newtable(L);

#define TECS2D_API(name, struct_) \
    lua_pushlightuserdata(L, (void *)tecs2d_##name##_api()); \
    lua_setfield(L, -2, #name);
#include "registry_entries.h"
#undef TECS2D_API

    lua_setglobal(L, "__tecs2dRegistry");
}
