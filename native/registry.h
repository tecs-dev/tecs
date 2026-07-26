/* The native API registry. See registry.c for why it exists. */

#ifndef TECS_REGISTRY_H
#define TECS_REGISTRY_H

struct lua_State;

/* Installs the registry as a global in `L`. Called for the main state and for
 * every worker state before any Lua in it runs. */
void tecsRegistryInstall(struct lua_State *L);

#endif
