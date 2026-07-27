/* Worker threads and channels.
 *
 * This is native for one reason: a LuaJIT FFI callback invoked from a thread
 * the VM did not create is unsafe, so a thread entry point cannot be a Lua
 * function. Everything above the entry point stays in Lua. Serialization in
 * particular is not here; the caller encodes with string.buffer and hands over
 * bytes, so this file never learns what a message contains.
 *
 * Each worker owns a fresh lua_State. LuaJIT has no shared mutable heap across
 * threads, so a worker cannot touch the spawning state's objects at all, and
 * the channels below are the entire interface between them.
 */

#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "worker.h"
#include "registry.h"
#include "luamods.h"

typedef struct Message {
    struct Message *next;
    uint32_t size;
    unsigned char data[];
} Message;

struct TecsChannel {
    SDL_Mutex *lock;
    SDL_Condition *arrived;
    Message *head;
    Message *tail;
    uint32_t count;
    /* Set when the owner is shutting down, so a blocked pop can return. */
    bool closed;
};

struct TecsWorker {
    SDL_Thread *thread;
    char *source;
    char *luaPath;
    TecsChannel *toWorker;
    TecsChannel *fromWorker;
};

/* ---------------------------------------------------------------- channels */

TecsChannel *tecsChannelCreate(void)
{
    TecsChannel *channel = (TecsChannel *)SDL_calloc(1, sizeof(TecsChannel));
    if (!channel) return NULL;
    channel->lock = SDL_CreateMutex();
    channel->arrived = SDL_CreateCondition();
    if (!channel->lock || !channel->arrived) {
        if (channel->lock) SDL_DestroyMutex(channel->lock);
        if (channel->arrived) SDL_DestroyCondition(channel->arrived);
        SDL_free(channel);
        return NULL;
    }
    return channel;
}

void tecsChannelDestroy(TecsChannel *channel)
{
    if (!channel) return;
    Message *message = channel->head;
    while (message) {
        Message *next = message->next;
        SDL_free(message);
        message = next;
    }
    SDL_DestroyCondition(channel->arrived);
    SDL_DestroyMutex(channel->lock);
    SDL_free(channel);
}

/* Wakes every blocked reader so they can observe the close and stop. */
void tecsChannelClose(TecsChannel *channel)
{
    if (!channel) return;
    SDL_LockMutex(channel->lock);
    channel->closed = true;
    SDL_BroadcastCondition(channel->arrived);
    SDL_UnlockMutex(channel->lock);
}

bool tecsChannelPush(TecsChannel *channel, const void *data, uint32_t size)
{
    Message *message = (Message *)SDL_malloc(sizeof(Message) + size);
    if (!message) return false;
    message->next = NULL;
    message->size = size;
    if (size) memcpy(message->data, data, size);

    SDL_LockMutex(channel->lock);
    if (channel->tail) {
        channel->tail->next = message;
    } else {
        channel->head = message;
    }
    channel->tail = message;
    channel->count++;
    SDL_SignalCondition(channel->arrived);
    SDL_UnlockMutex(channel->lock);
    return true;
}

/* Returns the message size and stores a freshly allocated copy in *out, which
 * the caller releases with tecsChannelFree. Returns 0 when nothing arrived
 * before the timeout, or when the channel closed. A negative timeout waits
 * indefinitely; zero polls. */
uint32_t tecsChannelPop(TecsChannel *channel, void **out, int32_t timeoutMs)
{
    SDL_LockMutex(channel->lock);
    while (!channel->head && !channel->closed) {
        if (timeoutMs == 0) {
            SDL_UnlockMutex(channel->lock);
            return 0;
        }
        if (timeoutMs < 0) {
            SDL_WaitCondition(channel->arrived, channel->lock);
        } else if (SDL_WaitConditionTimeout(channel->arrived, channel->lock, timeoutMs) == false) {
            SDL_UnlockMutex(channel->lock);
            return 0;
        }
    }

    Message *message = channel->head;
    if (!message) {
        SDL_UnlockMutex(channel->lock);
        return 0;
    }
    channel->head = message->next;
    if (!channel->head) channel->tail = NULL;
    channel->count--;
    SDL_UnlockMutex(channel->lock);

    *out = message;
    return message->size;
}

/* The payload begins after the header; callers read from here. */
void *tecsChannelData(void *message)
{
    return ((Message *)message)->data;
}

void tecsChannelFree(void *message)
{
    SDL_free(message);
}

uint32_t tecsChannelCount(TecsChannel *channel)
{
    SDL_LockMutex(channel->lock);
    uint32_t count = channel->count;
    SDL_UnlockMutex(channel->lock);
    return count;
}

/* ----------------------------------------------------------------- workers */

static void setPointer(lua_State *L, const char *name, void *value)
{
    lua_pushlightuserdata(L, value);
    lua_setglobal(L, name);
}

static int workerEntry(void *data)
{
    TecsWorker *worker = (TecsWorker *)data;

    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);

    /* A worker resolving its own libraries would reintroduce the dependency on
     * dynamic loading in the place it is hardest to notice: a worker that
     * fails to start looks like a worker that had nothing to do. */
    tecsRegistryInstall(L);
    tecsLuaModulesInstall(L);

    if (worker->luaPath) {
        lua_getglobal(L, "package");
        lua_pushstring(L, worker->luaPath);
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);
    }

    /* The channels reach Lua as light userdata, which the FFI casts to a
     * pointer. There is no other way in: the worker shares no Lua heap with
     * the state that spawned it. */
    setPointer(L, "__tecsWorkerIn", worker->toWorker);
    setPointer(L, "__tecsWorkerOut", worker->fromWorker);

    if (luaL_loadbuffer(L, worker->source, strlen(worker->source), "=worker") || lua_pcall(L, 0, 0, 0)) {
        const char *message = lua_tostring(L, -1);
        SDL_Log("tecs worker: %s", message ? message : "unknown error");
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}

TecsWorker *tecsWorkerSpawn(const char *source, const char *luaPath, TecsChannel *toWorker, TecsChannel *fromWorker)
{
    TecsWorker *worker = (TecsWorker *)SDL_calloc(1, sizeof(TecsWorker));
    if (!worker) return NULL;

    /* Copied because the spawning state's strings are its own to collect. */
    worker->source = SDL_strdup(source);
    worker->luaPath = luaPath ? SDL_strdup(luaPath) : NULL;
    worker->toWorker = toWorker;
    worker->fromWorker = fromWorker;

    worker->thread = SDL_CreateThread(workerEntry, "tecs.worker", worker);
    if (!worker->thread) {
        SDL_free(worker->source);
        SDL_free(worker->luaPath);
        SDL_free(worker);
        return NULL;
    }
    return worker;
}

int tecsWorkerJoin(TecsWorker *worker)
{
    if (!worker) return 1;
    int status = 0;
    SDL_WaitThread(worker->thread, &status);
    SDL_free(worker->source);
    SDL_free(worker->luaPath);
    SDL_free(worker);
    return status;
}
