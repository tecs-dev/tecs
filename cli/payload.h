/* The content root carried inside the executable.
 *
 * Two of these are called from the Rust host, which is compiled with
 * TECS_PAYLOAD only in a single-file build. Every other configuration has a
 * directory beside the binary and this file is not compiled at all.
 */

#ifndef TECS_PAYLOAD_H
#define TECS_PAYLOAD_H

#include <stdbool.h>
#include <stdio.h>

#include <lua.h>

/* Whether this binary was built with one. */
bool tecsPayloadPresent(void);

/* Pushes the named chunk onto the stack, compiled but not run.
 *
 * Answers what `luaL_loadfile` would: 0 on success, a Lua error code with a
 * message on the stack on a syntax error, and -1 when the payload has no such
 * entry, which is the case the host falls back to a file for. */
int tecsPayloadLoadChunk(lua_State *L, const char *name);

/* Announces the payload to Lua as the module `tecs.payload`.
 *
 * Called beside the native registry, before any Lua runs, for the same reason:
 * the first chunk loaded is already the one that needs it. */
void tecsPayloadInstall(lua_State *L);

#endif
