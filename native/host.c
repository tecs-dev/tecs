/* Application host.
 *
 * SDL drives the loop, not Lua. This is not a preference: iOS owns the run
 * loop and never returns control for a blocking `while` to sit in, so a host
 * that cannot be entered by callback cannot run there at all. The same shape
 * works on desktop, so there is one lifecycle rather than one per platform.
 *
 * The callbacks are implemented in C and reach Lua through the Lua C API. They
 * are deliberately not FFI callbacks: a LuaJIT FFI callback invoked from a
 * foreign entry point is both a trace barrier and, from a thread the VM did
 * not create, unsafe.
 *
 * The entry chunk returns an application, which the host retains and calls
 * back into. Everything above these four functions is Lua.
 */

#include <stdlib.h>
#include <string.h>

#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "registry.h"

typedef struct Tecs2dHost Tecs2dHost;

#ifndef TECS2D_ENTRY
#define TECS2D_ENTRY "main.lua"
#endif

/* Events arriving in one iteration before growth. Sized past a burst of mouse
 * motion so warmup reaches steady state and stays there. */
#define TECS2D_EVENTS_INITIAL 256

struct Tecs2dHost {
    lua_State *L;
    /* Registry index of the application returned by the entry chunk. */
    int application;
    /* Copied out of SDL_AppEvent, whose pointer is only valid for that call. */
    SDL_Event *events;
    uint32_t count;
    uint32_t capacity;
    bool shutdownCalled;
};

/* ------------------------------------------------------------------ queue */

static bool reserveEvents(Tecs2dHost *host, uint32_t needed)
{
    if (needed <= host->capacity) return true;

    uint32_t capacity = host->capacity ? host->capacity : TECS2D_EVENTS_INITIAL;
    while (capacity < needed) capacity *= 2;

    SDL_Event *grown = (SDL_Event *)SDL_realloc(host->events,
                                                capacity * sizeof(SDL_Event));
    if (!grown) return false;
    host->events = grown;
    host->capacity = capacity;
    return true;
}

/* ------------------------------------------------------------------- Lua */

static int traceback(lua_State *L)
{
    const char *message = lua_tostring(L, 1);
    luaL_traceback(L, L, message ? message : "(non-string error)", 1);
    return 1;
}

/* Calls application:<method>(...) with `extra` arguments already pushed by
 * `push`, and reports failure with a traceback. */
static bool callMethod(Tecs2dHost *host, const char *method,
                       void (*push)(lua_State *, Tecs2dHost *), int extra)
{
    lua_State *L = host->L;
    int base = lua_gettop(L);

    lua_pushcfunction(L, traceback);
    lua_rawgeti(L, LUA_REGISTRYINDEX, host->application);
    lua_getfield(L, -1, method);

    if (!lua_isfunction(L, -1)) {
        SDL_Log("tecs2d: application has no %s method", method);
        lua_settop(L, base);
        return false;
    }

    /* Method call, so the application is its own first argument. */
    lua_pushvalue(L, -2);
    if (push) push(L, host);

    if (lua_pcall(L, 1 + extra, 1, base + 1) != 0) {
        SDL_Log("tecs2d: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        return false;
    }

    /* A method that returns false asks for an orderly stop. */
    bool keepGoing = !lua_isboolean(L, -1) || lua_toboolean(L, -1);
    lua_settop(L, base);
    return keepGoing;
}

/* The queue is handed over as a pointer and a count rather than exposed
 * through functions Lua has to resolve. C owns its lifetime either way, and
 * this keeps the host's symbols out of the dynamic namespace entirely. */
static void pushQueue(lua_State *L, Tecs2dHost *host)
{
    lua_pushlightuserdata(L, host->events);
    lua_pushinteger(L, (lua_Integer)host->count);
}

/* -------------------------------------------------------------- callbacks */

SDL_AppResult SDL_AppInit(void **appstate, int argc, char **argv)
{
    Tecs2dHost *host = (Tecs2dHost *)SDL_calloc(1, sizeof(Tecs2dHost));
    if (!host) return SDL_APP_FAILURE;
    host->application = LUA_NOREF;
    *appstate = host;

    host->L = luaL_newstate();
    if (!host->L) {
        SDL_Log("tecs2d: cannot create Lua state");
        return SDL_APP_FAILURE;
    }
    luaL_openlibs(host->L);

    /* Before any Lua runs, so the first require can already reach the
     * libraries through it rather than trying to load them by name. */
    tecs2dRegistryInstall(host->L);

    lua_State *L = host->L;
    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    const char *entry = TECS2D_ENTRY;
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--entry") == 0) entry = argv[i + 1];
    }

    lua_pushcfunction(L, traceback);
    if (luaL_loadfile(L, entry) != 0 || lua_pcall(L, 0, 1, -2) != 0) {
        SDL_Log("tecs2d: %s", lua_tostring(L, -1));
        return SDL_APP_FAILURE;
    }

    /* The entry chunk returns its application, which the host retains for the
     * life of the process. */
    if (!lua_istable(L, -1)) {
        SDL_Log("tecs2d: %s must return tecs2d.application(config)", entry);
        return SDL_APP_FAILURE;
    }
    host->application = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);

    if (!reserveEvents(host, TECS2D_EVENTS_INITIAL)) return SDL_APP_FAILURE;
    if (!callMethod(host, "_init", NULL, 0)) return SDL_APP_FAILURE;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    Tecs2dHost *host = (Tecs2dHost *)appstate;

    /* Copied rather than dispatched here. The pointer is only valid for this
     * call, and dispatching mid-frame would show the application a world that
     * is halfway through an update. */
    if (!reserveEvents(host, host->count + 1)) return SDL_APP_FAILURE;
    host->events[host->count++] = *event;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
    Tecs2dHost *host = (Tecs2dHost *)appstate;
    bool keepGoing = callMethod(host, "_iterate", pushQueue, 2);

    /* Drained whether or not the iteration succeeded, so a failing frame does
     * not replay its events into the next one. */
    host->count = 0;

    if (!keepGoing) {
        /* Distinguishing a requested stop from a failed one is the
         * application's job; it logs before returning false. */
        return SDL_APP_SUCCESS;
    }
    return SDL_APP_CONTINUE;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result)
{
    (void)result;
    Tecs2dHost *host = (Tecs2dHost *)appstate;
    if (!host) return;

    /* Exactly once, however the loop ended. */
    if (host->L && host->application != LUA_NOREF && !host->shutdownCalled) {
        host->shutdownCalled = true;
        callMethod(host, "_shutdown", NULL, 0);
    }

    if (host->L) lua_close(host->L);
    SDL_free(host->events);
    SDL_free(host);
}
