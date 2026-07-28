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
 *
 * Two things here are not merely plumbing. Events are copied into one of two
 * owned batches which swap at the top of an iteration, so an event arriving
 * while Lua is draining survives to the next one. And the six lifecycle events
 * SDL refuses to queue are recognised here and answered here, because the
 * moment they arrive is the only moment a game has.
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
#include "luamods.h"
#include "mcodearena.h"

/* A single-file build has no directory beside the executable, so the entry
 * chunk and everything under it come out of an array compiled in. Everything
 * else has a content root on disk and does not compile this at all, which is
 * why the two calls below are the whole of the difference. */
#ifdef TECS_PAYLOAD
#include "payload.h"
#endif

typedef struct TecsHost TecsHost;

#ifndef TECS_ENTRY
#define TECS_ENTRY "main.lua"
#endif

/* Where content sits relative to the executable. The build knows the layout it
 * installed, so it says; nothing here guesses and nothing resolves against the
 * working directory, which is meaningless once an application is launched by
 * anything other than a shell. */
#ifndef TECS_CONTENT
#define TECS_CONTENT ""
#endif

/* Events arriving in one iteration before growth. Sized past a burst of mouse
 * motion so warmup reaches steady state and stays there. */
#define TECS_EVENTS_INITIAL 256

/* What a backgrounding hook may take before the host says so.
 *
 * iOS allows roughly five seconds from the callback returning and Android
 * rather less, so this sits well inside both. It is not there to enforce the
 * platform's deadline, which the host cannot do; it is there to catch the one
 * mistake this path cannot afford, which is a game walking its world inside the
 * callback instead of flushing a checkpoint it prepared during a frame. */
#define TECS_BACKGROUND_BUDGET_NS (250 * SDL_NS_PER_MS)

/* One iteration's worth of events, and everything they point at.
 *
 * Two of these exist. One is handed to Lua and is immutable for the length of
 * an iteration; the other receives whatever SDL delivers meanwhile. Subtracting
 * a drained count from a single shared array cannot do this job: growing it for
 * a new event would reallocate the array Lua is reading, and releasing the
 * payloads of the events Lua consumed would free strings out of a list a later
 * event is still recorded in. Ownership is per batch, so neither can happen. */
typedef struct TecsEventBatch {
    /* Copied out of SDL_AppEvent, whose pointer is only valid for that call. */
    SDL_Event *events;
    /* Arrival stamp per entry of `events`, grown with it, so an event and its
     * stamp share an index for the whole life of the batch. */
    Uint64 *arrivals;
    uint32_t count;
    uint32_t capacity;
    /* Everything this batch allocated to own a payload, freed together when the
     * batch is released. */
    void **owned;
    uint32_t ownedCount;
    uint32_t ownedCapacity;
} TecsEventBatch;

/* The six events SDL dispatches from its event watcher instead of queueing
 * them, in the order a platform sends them, one bit each.
 *
 * One hook per event rather than one for the group. Giving memory back, saving
 * state, releasing a graphics device, recovering one and resetting a clock are
 * different jobs with different deadlines, and a game that has an answer for
 * one of them should not be handed the other five to sort out. */
static const struct {
    Uint32 type;
    uint32_t bit;
    const char *method;
} LIFECYCLE[] = {
    {SDL_EVENT_LOW_MEMORY, 0x01u, "_lowMemory"},
    {SDL_EVENT_WILL_ENTER_BACKGROUND, 0x02u, "_willEnterBackground"},
    {SDL_EVENT_DID_ENTER_BACKGROUND, 0x04u, "_didEnterBackground"},
    {SDL_EVENT_WILL_ENTER_FOREGROUND, 0x08u, "_willEnterForeground"},
    {SDL_EVENT_DID_ENTER_FOREGROUND, 0x10u, "_didEnterForeground"},
    {SDL_EVENT_TERMINATING, 0x20u, "_terminating"},
};

#define TECS_LIFECYCLE_COUNT ((int)(sizeof(LIFECYCLE) / sizeof(LIFECYCLE[0])))

struct TecsHost {
    lua_State *L;
    /* Registry index of the application returned by the entry chunk. */
    int application;

    /* Guards the batches and the deferred set.
     *
     * SDL_AppEvent runs on whichever thread SDL dispatched from. For the six
     * lifecycle events that is whichever thread produced them, which SDL says
     * itself where it keeps its own result in an atomic "since events might
     * land from any thread" (SDL_main_callbacks.c). */
    SDL_Mutex *lock;
    TecsEventBatch batches[2];
    /* Receiving new events, and being read by the iteration in progress. */
    TecsEventBatch *live;
    TecsEventBatch *draining;

    /* The thread SDL_AppInit ran on, which is the only one that may enter Lua. */
    SDL_ThreadID owner;
    /* Non-zero while a Lua call this host made is on the stack. */
    int luaActive;
    /* Lifecycle hooks a guard refused, replayed at the next iteration. */
    uint32_t deferred;

    /* True between WILL_ENTER_BACKGROUND and DID_ENTER_FOREGROUND, so a save
     * runs once per backgrounding rather than once per event that mentions it. */
    SDL_AtomicInt background;
    /* Latched by TERMINATING. Nothing is deferred past it, because there is no
     * iteration after it to replay into. */
    SDL_AtomicInt terminating;

    /* Performance counter reading that corresponds to ticks zero, and the
     * factor that turns a nanosecond count into counter ticks. */
    Uint64 counterEpoch;
    double counterPerNanosecond;

    bool shutdownCalled;
};

/* ---------------------------------------------------------------- batches */

static bool reserve(TecsEventBatch *batch, uint32_t needed)
{
    if (needed <= batch->capacity) return true;

    uint32_t capacity = batch->capacity ? batch->capacity : TECS_EVENTS_INITIAL;
    while (capacity < needed) capacity *= 2;

    /* The capacity is only advanced once both grew, so a partial failure leaves
     * one array longer than the batch claims rather than the two disagreeing
     * about where their last element is. */
    Uint64 *stamps = (Uint64 *)SDL_realloc(batch->arrivals, capacity * sizeof(Uint64));
    if (!stamps) return false;
    batch->arrivals = stamps;

    SDL_Event *grown = (SDL_Event *)SDL_realloc(batch->events, capacity * sizeof(SDL_Event));
    if (!grown) return false;
    batch->events = grown;

    batch->capacity = capacity;
    return true;
}

/* Records an allocation the batch owns, so it is freed with the batch rather
 * than tracked by whichever event happens to point at it. */
static bool retain(TecsEventBatch *batch, void *block)
{
    if (!block) return false;
    if (batch->ownedCount == batch->ownedCapacity) {
        uint32_t capacity = batch->ownedCapacity ? batch->ownedCapacity * 2 : 32;
        void **grown = (void **)SDL_realloc(batch->owned, capacity * sizeof(void *));
        if (!grown) return false;
        batch->owned = grown;
        batch->ownedCapacity = capacity;
    }
    batch->owned[batch->ownedCount++] = block;
    return true;
}

static char *ownString(TecsEventBatch *batch, const char *text)
{
    if (!text) return NULL;
    char *copy = SDL_strdup(text);
    if (!copy) return NULL;
    if (!retain(batch, copy)) {
        SDL_free(copy);
        return NULL;
    }
    return copy;
}

static char **ownStrings(TecsEventBatch *batch, const char *const *items, int count)
{
    if (!items || count <= 0) return NULL;
    char **copies = (char **)SDL_calloc((size_t)count, sizeof(char *));
    if (!copies) return NULL;
    if (!retain(batch, copies)) {
        SDL_free(copies);
        return NULL;
    }
    for (int i = 0; i < count; i++) copies[i] = ownString(batch, items[i]);
    return copies;
}

/* Deep-copies whatever an event points at and repoints the copy at the result.
 *
 * SDL keeps the strings on text, composition, drop and clipboard events in a
 * pool it recycles as soon as the callback returns, and the batch outlives that
 * call by a whole frame. Retaining the pointers would hand Lua a string that
 * had already been reused; copying here is what makes a recognised kind mean a
 * usable payload. Anything that fails to copy becomes an empty payload rather
 * than a dangling one, because a lost drop is recoverable and a freed pointer
 * read from Lua is not. */
static void ownPayload(TecsEventBatch *batch, SDL_Event *copy)
{
    switch (copy->type) {
    case SDL_EVENT_TEXT_INPUT: copy->text.text = ownString(batch, copy->text.text); break;

    case SDL_EVENT_TEXT_EDITING: copy->edit.text = ownString(batch, copy->edit.text); break;

    case SDL_EVENT_TEXT_EDITING_CANDIDATES:
        copy->edit_candidates.candidates = (const char *const *)ownStrings(batch, copy->edit_candidates.candidates,
                                                                           copy->edit_candidates.num_candidates);
        if (!copy->edit_candidates.candidates) {
            copy->edit_candidates.num_candidates = 0;
            copy->edit_candidates.selected_candidate = -1;
        }
        break;

    case SDL_EVENT_DROP_BEGIN:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_COMPLETE:
        copy->drop.source = ownString(batch, copy->drop.source);
        copy->drop.data = ownString(batch, copy->drop.data);
        break;

    case SDL_EVENT_CLIPBOARD_UPDATE:
        copy->clipboard.mime_types = (const char **)ownStrings(batch, (const char *const *)copy->clipboard.mime_types,
                                                               copy->clipboard.num_mime_types);
        if (!copy->clipboard.mime_types) copy->clipboard.num_mime_types = 0;
        break;

    default: break;
    }
}

/* Frees every payload a drained batch owned. The event and stamp arrays
 * themselves are kept and reused; only what they pointed at goes. */
static void releaseBatch(TecsEventBatch *batch)
{
    for (uint32_t i = 0; i < batch->ownedCount; i++) SDL_free(batch->owned[i]);
    batch->ownedCount = 0;
    batch->count = 0;
}

static void destroyBatch(TecsEventBatch *batch)
{
    releaseBatch(batch);
    SDL_free(batch->events);
    SDL_free(batch->arrivals);
    SDL_free(batch->owned);
}

/* Copies an event and everything it points at into the batch receiving events. */
static bool appendEvent(TecsHost *host, const SDL_Event *event, Uint64 arrival)
{
    SDL_LockMutex(host->lock);
    TecsEventBatch *batch = host->live;
    bool ok = reserve(batch, batch->count + 1);
    if (ok) {
        batch->arrivals[batch->count] = arrival;
        batch->events[batch->count] = *event;
        ownPayload(batch, &batch->events[batch->count]);
        batch->count++;
    }
    SDL_UnlockMutex(host->lock);
    return ok;
}

/* ------------------------------------------------------------------ clock */

/* Fixes the offset between the clock SDL stamps events on and the one the
 * engine measures frames with.
 *
 * SDL stamps events with SDL_GetTicksNS and the engine's clock reads
 * SDL_GetPerformanceCounter. SDL derives the first from the second today, but
 * nothing in its API promises that, so the offset is measured rather than
 * assumed: one reading of each, bracketed so the gap between the two calls does
 * not enter the result. Both clocks are monotonic, so one measurement holds for
 * the life of the process. */
static void calibrate(TecsHost *host)
{
    host->counterPerNanosecond = (double)SDL_GetPerformanceFrequency() * 1e-9;

    Uint64 before = SDL_GetPerformanceCounter();
    Uint64 ticks = SDL_GetTicksNS();
    Uint64 after = SDL_GetPerformanceCounter();

    double counter = ((double)before + (double)after) * 0.5;
    host->counterEpoch = (Uint64)(counter - (double)ticks * host->counterPerNanosecond);
}

/* Where the wait a player feels began, on the counter the engine's clock reads.
 *
 * The event's own stamp, not a reading taken here. SDL stamps an event when it
 * is produced, and translates a driver's timestamp onto its own clock rather
 * than passing it through, clamped so it can never be in the future
 * (Cocoa_GetEventTimestamp, UIKit_GetEventTimestamp). Reading the counter here
 * instead would date every event from the pump that delivered it, and the main
 * thread cannot pump while it is blocked in swapchain acquire, which is where a
 * vsynced loop spends its wait. Everything that arrived during that block would
 * be dated to the end of it, so the measurement would understate latency by
 * exactly the interval it exists to catch.
 *
 * The six lifecycle events carry no stamp: SDL_SendAppEvent hands them straight
 * to the event watchers with `timestamp` left at zero rather than queueing them.
 * Those are dated where they were delivered, which is as close as anything gets
 * and is not read anyway, since `events.isInput` excludes them. */
static Uint64 arrivalOf(const TecsHost *host, const SDL_Event *event)
{
    Uint64 stamp = event->common.timestamp;
    if (stamp == 0) return SDL_GetPerformanceCounter();
    return host->counterEpoch + (Uint64)((double)stamp * host->counterPerNanosecond);
}

/* -------------------------------------------------------------------- Lua */

static int traceback(lua_State *L)
{
    const char *message = lua_tostring(L, 1);
    luaL_traceback(L, L, message ? message : "(non-string error)", 1);
    return 1;
}

/* Calls application:<method>(...) with `extra` arguments already pushed by
 * `push`, and reports failure with a traceback.
 *
 * A method that is `required` and absent is an error. A lifecycle hook that is
 * absent is not: the host offers six and a game answers the ones it has
 * something to do about. */
static bool callMethod(TecsHost *host, const char *method, void (*push)(lua_State *, TecsHost *), int extra,
                       bool required)
{
    lua_State *L = host->L;
    int base = lua_gettop(L);

    lua_pushcfunction(L, traceback);
    lua_rawgeti(L, LUA_REGISTRYINDEX, host->application);
    lua_getfield(L, -1, method);

    if (!lua_isfunction(L, -1)) {
        if (required) SDL_Log("tecs: application has no %s method", method);
        lua_settop(L, base);
        return !required;
    }

    /* Method call, so the application is its own first argument. */
    lua_pushvalue(L, -2);
    if (push) push(L, host);

    /* Held across the call, so an event arriving on this thread meanwhile can
     * see that the state is busy and refuse to re-enter it. */
    host->luaActive++;
    bool failed = lua_pcall(L, 1 + extra, 1, base + 1) != 0;
    host->luaActive--;

    if (failed) {
        SDL_Log("tecs: %s", lua_tostring(L, -1));
        lua_settop(L, base);
        return false;
    }

    /* A method that returns false asks for an orderly stop. */
    bool keepGoing = !lua_isboolean(L, -1) || lua_toboolean(L, -1);
    lua_settop(L, base);
    return keepGoing;
}

/* The batch is handed over as a pointer and a count rather than exposed through
 * functions Lua has to resolve. C owns its lifetime either way, and this keeps
 * the host's symbols out of the dynamic namespace entirely. The arrival stamps
 * travel beside it as a second array rather than inside the events, since an
 * SDL_Event has nowhere to put one. */
static void pushQueue(lua_State *L, TecsHost *host)
{
    TecsEventBatch *batch = host->draining;
    lua_pushlightuserdata(L, batch->events);
    lua_pushinteger(L, (lua_Integer)batch->count);
    lua_pushlightuserdata(L, batch->arrivals);
}

/* -------------------------------------------------------------- lifecycle */

/* SDL dispatches six events from its event watcher rather than queueing them
 * (SDL_main_callbacks.c, ShouldDispatchImmediately). SDL_SendAppEvent does not
 * queue them at all: "We won't actually queue this event, it needs to be
 * handled in this call stack by an event watcher". The reason is on Android,
 * where the app blocks as soon as backgrounding has been sent, and the comment
 * in Android_OnPause says what that means for an application: "The application
 * should do any life cycle handling in an event filter while the event was
 * being queued." Under SDL_MAIN_USE_CALLBACKS that event filter is
 * SDL_AppEvent.
 *
 * So this is the only moment a game has. Copying the event into a batch for the
 * next iteration misses it: on Android the next iteration is after resume, and
 * on iOS SDL has stopped the display link by then. */
static int lifecycleIndex(Uint32 type)
{
    for (int i = 0; i < TECS_LIFECYCLE_COUNT; i++) {
        if (LIFECYCLE[i].type == type) return i;
    }
    return -1;
}

/* Applies the transition an event carries, on whatever thread it arrived on and
 * whether or not the hook beside it can run, and answers whether the transition
 * was a new one. Nothing here touches Lua. */
static bool applyLifecycle(TecsHost *host, Uint32 type)
{
    switch (type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
        /* One save per backgrounding, decided by the swap rather than by a read
         * and a later write, since the two events can arrive on two threads. A
         * platform that repeats the event must not make a game write its file
         * twice; the second write is the one that would be interrupted. */
        return SDL_CompareAndSwapAtomicInt(&host->background, 0, 1);
    case SDL_EVENT_DID_ENTER_FOREGROUND: SDL_SetAtomicInt(&host->background, 0); return true;
    case SDL_EVENT_TERMINATING: SDL_SetAtomicInt(&host->terminating, 1); return true;
    default: return true;
    }
}

/* Whether Lua may be entered from here.
 *
 * Two refusals. SDL_AppEvent is called from whichever thread produced the
 * event, and a Lua state may only be entered from the thread that owns it. And
 * a hook running while a call this host already made is on the stack would
 * re-enter the state from inside world:update, where the world is halfway
 * through applying a frame's mutations.
 *
 * `luaActive` is read only once the thread check has passed, so it is read on
 * the one thread that writes it. */
static bool canEnterLua(const TecsHost *host)
{
    if (SDL_GetCurrentThreadID() != host->owner) return false;
    return host->luaActive == 0;
}

/* Runs one lifecycle hook and says what it cost when that is worth saying. */
static void runLifecycleHook(TecsHost *host, int index)
{
    if (LIFECYCLE[index].type != SDL_EVENT_WILL_ENTER_BACKGROUND) {
        callMethod(host, LIFECYCLE[index].method, NULL, 0, false);
        return;
    }

    Uint64 started = SDL_GetTicksNS();
    callMethod(host, LIFECYCLE[index].method, NULL, 0, false);
    Uint64 spent = SDL_GetTicksNS() - started;
    if (spent > TECS_BACKGROUND_BUDGET_NS) {
        SDL_Log("tecs: _willEnterBackground took %" SDL_PRIu64 " ms; flush a prepared checkpoint rather than "
                "building one here",
                spent / SDL_NS_PER_MS);
    }
}

/* Dispatches the hook for a lifecycle event, or records that it could not.
 *
 * A refused dispatch is replayed at the top of the next iteration, which is
 * correct rather than useful: on Android there is no next iteration until the
 * app is resumed. The deferral exists so nothing is silently dropped, not as a
 * second way of meeting the deadline. Past TERMINATING there is no iteration at
 * all, so a refusal there is reported instead of recorded. */
static void dispatchLifecycle(TecsHost *host, int index)
{
    if (canEnterLua(host)) {
        runLifecycleHook(host, index);
        return;
    }

    if (SDL_GetAtomicInt(&host->terminating) == 1) {
        SDL_Log("tecs: %s could not run; the Lua state was busy and the process is terminating",
                LIFECYCLE[index].method);
        return;
    }

    SDL_LockMutex(host->lock);
    host->deferred |= LIFECYCLE[index].bit;
    SDL_UnlockMutex(host->lock);
}

/* Runs the hooks that could not run when their events arrived, in the order the
 * platform sent them. */
static void drainDeferred(TecsHost *host)
{
    SDL_LockMutex(host->lock);
    uint32_t pending = host->deferred;
    host->deferred = 0;
    SDL_UnlockMutex(host->lock);

    if (pending == 0) return;
    for (int i = 0; i < TECS_LIFECYCLE_COUNT; i++) {
        if (pending & LIFECYCLE[i].bit) runLifecycleHook(host, i);
    }
}

/* -------------------------------------------------------------- callbacks */

SDL_AppResult SDL_AppInit(void **appstate, int argc, char **argv)
{
    /* Before anything, because its whole value is being there before the
     * loader and the graphics driver have taken the address space a compiled
     * trace has to live in. */
    tecsMcodeArenaReserve();

    TecsHost *host = (TecsHost *)SDL_calloc(1, sizeof(TecsHost));
    if (!host) return SDL_APP_FAILURE;
    host->application = LUA_NOREF;
    host->owner = SDL_GetCurrentThreadID();
    host->live = &host->batches[0];
    host->draining = &host->batches[1];
    *appstate = host;

    host->lock = SDL_CreateMutex();
    if (!host->lock) {
        SDL_Log("tecs: cannot create the event lock");
        return SDL_APP_FAILURE;
    }
    calibrate(host);

    host->L = luaL_newstate();
    if (!host->L) {
        SDL_Log("tecs: cannot create Lua state");
        return SDL_APP_FAILURE;
    }
    luaL_openlibs(host->L);

    /* Before any Lua runs, so the first require can already reach the
     * libraries through it rather than trying to load them by name. */
    tecsRegistryInstall(host->L);
    tecsLuaModulesInstall(host->L);
#ifdef TECS_PAYLOAD
    tecsPayloadInstall(host->L);
#endif

    lua_State *L = host->L;
    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    /* The content root, which the engine reads assets from and which holds the
     * entry chunk unless one was named. SDL_GetBasePath is the executable's own
     * directory, or a bundle's resources where there is one. */
    const char *base = SDL_GetBasePath();
    char *content = NULL;
    if (base) {
        SDL_asprintf(&content, "%s%s", base, TECS_CONTENT);
    }
    if (content) {
        lua_pushstring(L, content);
        lua_setglobal(L, "__tecsContent");

        /* The content root goes on package.path here rather than in every
         * entry file, so a game's first line can be the game. TECS_LUA wins
         * where it is set, which is how a development run reads out of a build
         * tree rather than out of an installed one. */
        const char *over = SDL_getenv("TECS_LUA");
        const char *root = over ? over : content;
        lua_getglobal(L, "package");
        lua_getfield(L, -1, "path");
        const char *had = lua_tostring(L, -1);
        char *path = NULL;
        SDL_asprintf(&path, "%s/?.lua;%s/?/init.lua;%s", root, root, had ? had : "");
        lua_pop(L, 1);
        lua_pushstring(L, path);
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);
        SDL_free(path);
    }

    char *resolved = NULL;
    const char *entry = NULL;
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--entry") == 0) entry = argv[i + 1];
    }

    /* What to ask a payload for, kept before the path below is built. A payload
     * is keyed by relative name and `entry` becomes an absolute path resolved
     * against the executable, which would match nothing. */
    const char *carried = entry ? entry : TECS_ENTRY;

    if (!entry) {
        if (content) SDL_asprintf(&resolved, "%s%s", content, TECS_ENTRY);
        entry = resolved ? resolved : TECS_ENTRY;
    }
    SDL_free(content);

    /* From the payload where there is one and the name is in it, and from a
     * file otherwise. A payload build still honours `--entry`, because that is
     * how `tecs run` hands off to a game whose chunk is on disk and could not
     * have been compiled in. */
    int compiled = -1;
#ifdef TECS_PAYLOAD
    compiled = tecsPayloadLoadChunk(L, carried);
#else
    (void)carried;
#endif
    if (compiled < 0) compiled = luaL_loadfile(L, entry);

    lua_pushcfunction(L, traceback);
    /* The engine is loaded before a game's first line, so `tecs` is simply
     * there. Requiring it is what sets the global, and asking every file to do
     * that is ceremony a game should never have to think about: a game writes
     * `tecs.newWorld()` in any file and it works.
     *
     * A tool running under a plain interpreter never reaches this, so the
     * headless property holds: nothing outside the host pays for the engine
     * unless it asks. */
    lua_getglobal(L, "require");
    lua_pushstring(L, "tecs");
    if (lua_pcall(L, 1, 0, -3) != 0) {
        SDL_Log("tecs: %s", lua_tostring(L, -1));
        SDL_free(resolved);
        return SDL_APP_FAILURE;
    }

    lua_insert(L, -2);
    int loaded = compiled == 0 && lua_pcall(L, 0, 1, -2) == 0;
    if (!loaded) {
        SDL_Log("tecs: %s", lua_tostring(L, -1));
        SDL_free(resolved);
        return SDL_APP_FAILURE;
    }

    /* The entry chunk returns its application, which the host retains for the
     * life of the process. */
    if (!lua_istable(L, -1)) {
        SDL_Log("tecs: %s must return tecs.application(config)", entry);
        SDL_free(resolved);
        return SDL_APP_FAILURE;
    }
    SDL_free(resolved);
    host->application = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);

    if (!reserve(host->live, TECS_EVENTS_INITIAL)) return SDL_APP_FAILURE;
    if (!reserve(host->draining, TECS_EVENTS_INITIAL)) return SDL_APP_FAILURE;
    if (!callMethod(host, "_init", NULL, 0, true)) return SDL_APP_FAILURE;

    /* The window and the device exist, so everything that maps at startup has
     * mapped. What was held is now the free address space this state and every
     * worker compile into for the rest of the run. */
    tecsMcodeArenaRelease();
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    TecsHost *host = (TecsHost *)appstate;

    /* The transition first, because it is the part that holds on whatever thread
     * this is and whether or not Lua can be reached from here. */
    int lifecycle = lifecycleIndex(event->type);
    bool dispatch = lifecycle >= 0 && applyLifecycle(host, event->type);

    /* Copied rather than dispatched. The pointer is only valid for this call,
     * and dispatching an ordinary event here would show the application a world
     * that is halfway through an update. What the event points at is copied
     * too, for the same reason applied one level down. */
    if (!appendEvent(host, event, arrivalOf(host, event))) return SDL_APP_FAILURE;

    /* A lifecycle event is both dispatched and queued: the hook is where a game
     * meets the platform's deadline, and the event stream is where it observes
     * the change like any other. Those answer different questions.
     *
     * Outside the batch lock, because a hook is game code, game code may push
     * an event, and an event pushed from in there re-enters this function. */
    if (dispatch) dispatchLifecycle(host, lifecycle);

    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
    TecsHost *host = (TecsHost *)appstate;

    /* Before the iteration, so a save that could not run at the instant the
     * platform asked for it still runs ahead of the frame that follows it. */
    drainDeferred(host);

    /* The batch Lua is about to read stops receiving here, and everything SDL
     * delivers during the iteration lands in the other one. Handing over a
     * batch that was still being appended to would let a growth reallocate the
     * array Lua is reading, and zeroing a shared count on the way out would
     * discard whatever arrived while the iteration ran. */
    SDL_LockMutex(host->lock);
    TecsEventBatch *ready = host->live;
    host->live = host->draining;
    host->draining = ready;
    SDL_UnlockMutex(host->lock);

    bool keepGoing = callMethod(host, "_iterate", pushQueue, 3, true);

    /* Released after the call rather than before the swap, so what Lua read
     * stays valid for exactly as long as Lua was reading it. Released whether
     * or not the iteration succeeded, so a failing frame does not replay its
     * events into the next one. The batch now receiving events is untouched. */
    releaseBatch(host->draining);

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
    TecsHost *host = (TecsHost *)appstate;
    if (!host) return;

    /* Exactly once, however the loop ended. */
    if (host->L && host->application != LUA_NOREF && !host->shutdownCalled) {
        host->shutdownCalled = true;
        callMethod(host, "_shutdown", NULL, 0, true);
    }

    if (host->L) lua_close(host->L);
    destroyBatch(&host->batches[0]);
    destroyBatch(&host->batches[1]);
    if (host->lock) SDL_DestroyMutex(host->lock);
    SDL_free(host);
}
