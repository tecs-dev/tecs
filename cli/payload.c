/* The content root, carried inside the executable.
 *
 * A single-file `tecs` has nothing beside it: no compiled Lua, no Teal type
 * information, no shaders, no fonts, no templates, no notices. All of it is
 * deflated into one stream by scripts/genpayload.py and compiled in as an
 * array; this inflates that once at startup and answers two questions about it.
 *
 * **zlib rather than the engine's own inflater.** src/tecs/compress.tl is a
 * pure-Lua inflater written so that zlib would not be a dependency, and that
 * reasoning has expired: cmake/Revisions.cmake pins zlib, CMakeLists.txt links
 * it, and the FFI has a generated binding for it. Inflating here instead
 * removes a bootstrap ordering problem rather than adding a dependency. The
 * Lua inflater lives in a module that would itself have to come out of the
 * payload, along with the FFI loader and three generated bindings, so the
 * payload would need a second uncompressed section holding exactly the code
 * that reads the first one.
 *
 * **The whole archive is inflated, not one entry at a time.** It is read once,
 * written out once, and then the process is using files like any other. An
 * index over compressed entries would buy random access that nothing asks for.
 *
 * Two consumers. The host asks for the entry chunk by name, before any Lua has
 * run, which is what makes a payload build bootable at all. Lua asks for the
 * whole archive, which it unpacks into a cache directory the engine then reads
 * content from in the ordinary way.
 */

#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "payload.h"

/* Written by scripts/genpayload.py. */
extern const unsigned char tecsPayload[];
extern const size_t tecsPayloadSize;
extern const size_t tecsPayloadPlainSize;
extern const char tecsPayloadIdentity[];

#define TECS_PAYLOAD_MAGIC "TECSPAY1"
#define TECS_PAYLOAD_MAGIC_LENGTH 8

/* The inflated archive, held for the life of the process.
 *
 * Never freed. It is one allocation made before anything else and read for as
 * long as the program runs, and a payload build's whole content root is in it;
 * handing it back at exit would be bookkeeping for an address space that is
 * about to be discarded anyway. */
static unsigned char *archive = NULL;
static size_t archiveSize = 0;

static unsigned int readU32(const unsigned char *at)
{
    return (unsigned int)at[0] | ((unsigned int)at[1] << 8) | ((unsigned int)at[2] << 16) | ((unsigned int)at[3] << 24);
}

static unsigned int readU16(const unsigned char *at)
{
    return (unsigned int)at[0] | ((unsigned int)at[1] << 8);
}

/* Inflates the payload once. Answers false when it is absent or corrupt. */
static bool inflatePayload(void)
{
    if (archive) return true;
    if (tecsPayloadSize == 0) return false;

    unsigned char *plain = (unsigned char *)malloc(tecsPayloadPlainSize);
    if (!plain) return false;

    uLongf produced = (uLongf)tecsPayloadPlainSize;
    int status = uncompress(plain, &produced, tecsPayload, (uLong)tecsPayloadSize);
    if (status != Z_OK || produced != (uLongf)tecsPayloadPlainSize) {
        free(plain);
        return false;
    }
    if (produced < TECS_PAYLOAD_MAGIC_LENGTH + 4 || memcmp(plain, TECS_PAYLOAD_MAGIC, TECS_PAYLOAD_MAGIC_LENGTH) != 0) {
        free(plain);
        return false;
    }

    archive = plain;
    archiveSize = (size_t)produced;
    return true;
}

/* Finds one entry by name. The archive is walked rather than indexed: it is
 * consulted twice in the life of a process, once for the entry chunk and once
 * to unpack everything, so an index would cost more to build than the two
 * walks it saves. */
static bool find(const char *name, const unsigned char **data, size_t *length)
{
    if (!inflatePayload()) return false;

    size_t wanted = strlen(name);
    const unsigned char *at = archive + TECS_PAYLOAD_MAGIC_LENGTH;
    unsigned int count = readU32(at);
    at += 4;

    for (unsigned int i = 0; i < count; i++) {
        unsigned int nameLength = readU16(at);
        at += 2;
        const unsigned char *entryName = at;
        at += nameLength;
        unsigned int dataLength = readU32(at);
        at += 4;

        if (nameLength == wanted && memcmp(entryName, name, wanted) == 0) {
            *data = at;
            *length = dataLength;
            return true;
        }
        at += dataLength;
    }
    return false;
}

bool tecsPayloadPresent(void)
{
    return tecsPayloadSize != 0;
}

int tecsPayloadLoadChunk(lua_State *L, const char *name)
{
    const unsigned char *data = NULL;
    size_t length = 0;
    if (!find(name, &data, &length)) return -1;

    char chunkName[256];
    snprintf(chunkName, sizeof(chunkName), "@payload:%s", name);
    return luaL_loadbuffer(L, (const char *)data, length, chunkName);
}

/* payload.identity() -> string
 *
 * A digest of the uncompressed archive. Lua names the cache directory after it,
 * so two builds of the same tree share one and an upgraded binary never reads
 * the last one's unpacked copy. */
static int identityOf(lua_State *L)
{
    lua_pushstring(L, tecsPayloadIdentity);
    return 1;
}

/* payload.entries() -> { { name, bytes }, ... }
 *
 * Everything at once, because the caller is about to write all of it. */
static int entriesOf(lua_State *L)
{
    if (!inflatePayload()) {
        lua_pushnil(L);
        return 1;
    }

    const unsigned char *at = archive + TECS_PAYLOAD_MAGIC_LENGTH;
    unsigned int count = readU32(at);
    at += 4;

    lua_createtable(L, (int)count, 0);
    for (unsigned int i = 0; i < count; i++) {
        unsigned int nameLength = readU16(at);
        at += 2;
        const char *name = (const char *)at;
        at += nameLength;
        unsigned int dataLength = readU32(at);
        at += 4;

        lua_createtable(L, 2, 0);
        lua_pushlstring(L, name, nameLength);
        lua_rawseti(L, -2, 1);
        lua_pushlstring(L, (const char *)at, dataLength);
        lua_rawseti(L, -2, 2);
        lua_rawseti(L, -2, (int)i + 1);

        at += dataLength;
    }
    return 1;
}

static int openPayload(lua_State *L)
{
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, identityOf);
    lua_setfield(L, -2, "identity");
    lua_pushcfunction(L, entriesOf);
    lua_setfield(L, -2, "entries");
    return 1;
}

void tecsPayloadInstall(lua_State *L)
{
    if (!tecsPayloadPresent()) return;

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, openPayload);
    lua_setfield(L, -2, "tecs.payload");
    lua_pop(L, 2);
}
