/* The native API registry. See registry.c for why it exists. */

#ifndef TECS2D_REGISTRY_H
#define TECS2D_REGISTRY_H

struct lua_State;

/* Installs the registry as a global in `L`. Called for the main state and for
 * every worker state before any Lua in it runs. */
void tecs2dRegistryInstall(struct lua_State *L);

#endif
