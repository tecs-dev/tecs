/*
 * Log sink: the platform destination plus a file.
 *
 * SDL has no file sink, and MCP needs one: with a file, `get_logs` is a seek
 * and a read, the cursor is a byte offset, and a co-located agent can grep it
 * directly. This writes JSON Lines, because the callback is handed category,
 * priority and message as separate arguments and there is no reason to format
 * them into one string only to parse them apart again.
 *
 * It lives in C rather than Lua because SDL logs from threads it created: the
 * audio device thread, the async IO pool. An FFI callback entered from a
 * thread the VM never saw is the unsafe case, so the VM is never involved.
 */

#include <stdio.h>
#include <string.h>

#include <SDL3/SDL.h>

static SDL_LogOutputFunction previousFunction = NULL;
static void *previousUserdata = NULL;
static SDL_Mutex *sinkLock = NULL;
static SDL_IOStream *sinkFile = NULL;

/* Category names are owned by Lua, which registers them as it creates them. */
#define TECS_MAX_CATEGORIES 128
static char categoryNames[TECS_MAX_CATEGORIES][64];
static int categoryBase = 0;

static const char *priorityName(SDL_LogPriority priority)
{
    switch (priority) {
    case SDL_LOG_PRIORITY_TRACE: return "TRACE";
    case SDL_LOG_PRIORITY_VERBOSE: return "VERBOSE";
    case SDL_LOG_PRIORITY_DEBUG: return "DEBUG";
    case SDL_LOG_PRIORITY_INFO: return "INFO";
    case SDL_LOG_PRIORITY_WARN: return "WARN";
    case SDL_LOG_PRIORITY_ERROR: return "ERROR";
    case SDL_LOG_PRIORITY_CRITICAL: return "CRITICAL";
    default: return "UNKNOWN";
    }
}

static const char *categoryName(int category)
{
    int index = category - categoryBase;
    if (categoryBase > 0 && index >= 0 && index < TECS_MAX_CATEGORIES && categoryNames[index][0] != '\0') {
        return categoryNames[index];
    }
    switch (category) {
    case SDL_LOG_CATEGORY_APPLICATION: return "sdl.application";
    case SDL_LOG_CATEGORY_ERROR: return "sdl.error";
    case SDL_LOG_CATEGORY_ASSERT: return "sdl.assert";
    case SDL_LOG_CATEGORY_SYSTEM: return "sdl.system";
    case SDL_LOG_CATEGORY_AUDIO: return "sdl.audio";
    case SDL_LOG_CATEGORY_VIDEO: return "sdl.video";
    case SDL_LOG_CATEGORY_RENDER: return "sdl.render";
    case SDL_LOG_CATEGORY_INPUT: return "sdl.input";
    case SDL_LOG_CATEGORY_GPU: return "sdl.gpu";
    default: return "sdl";
    }
}

/* Escapes into `out`, returning how many bytes were written. */
static size_t writeEscaped(char *out, size_t limit, const char *text)
{
    size_t used = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (used + 8 >= limit) break;
        switch (*p) {
        case '"':
            out[used++] = '\\';
            out[used++] = '"';
            break;
        case '\\':
            out[used++] = '\\';
            out[used++] = '\\';
            break;
        case '\n':
            out[used++] = '\\';
            out[used++] = 'n';
            break;
        case '\r':
            out[used++] = '\\';
            out[used++] = 'r';
            break;
        case '\t':
            out[used++] = '\\';
            out[used++] = 't';
            break;
        default:
            if (*p < 0x20) {
                used += (size_t)SDL_snprintf(out + used, limit - used, "\\u%04x", *p);
            } else {
                out[used++] = (char)*p;
            }
        }
    }
    return used;
}

static void SDLCALL sink(void *userdata, int category, SDL_LogPriority priority, const char *message)
{
    /* The platform destination first, so a crash between here and the file
     * still leaves the message somewhere. */
    if (previousFunction) {
        previousFunction(previousUserdata, category, priority, message);
    }
    /* Read without the lock only to skip formatting a line nothing will take.
     * The pointer is not dereferenced until it has been read again under the
     * lock below, so a file being swapped or closed underneath this cannot
     * turn into a write to a stream that has gone. */
    if (!sinkFile) return;

    char line[2048];
    int head = SDL_snprintf(line, sizeof(line), "{\"time\":%.3f,\"level\":\"%s\",\"logger\":\"",
                            (double)SDL_GetTicks() / 1000.0, priorityName(priority));
    if (head < 0) return;

    size_t used = (size_t)head;
    used += writeEscaped(line + used, sizeof(line) - used - 16, categoryName(category));
    used += (size_t)SDL_snprintf(line + used, sizeof(line) - used, "\",\"message\":\"");
    used += writeEscaped(line + used, sizeof(line) - used - 8, message);
    used += (size_t)SDL_snprintf(line + used, sizeof(line) - used, "\"}\n");

    SDL_LockMutex(sinkLock);
    if (sinkFile) {
        /* One write per line, under the lock, so a line is never split across
         * two files when `tecsLogSinkOpen` swaps one for another. */
        SDL_WriteIO(sinkFile, line, used);
        SDL_FlushIO(sinkFile);
    }
    SDL_UnlockMutex(sinkLock);
}

/* Starts writing to `path`, truncating it, and stops writing to whatever file
 * was open before. Returns false on failure, in which case the previous file
 * keeps receiving lines. */
bool tecsLogSinkOpen(const char *path)
{
    if (!sinkLock) {
        sinkLock = SDL_CreateMutex();
        if (!sinkLock) return false;
    }

    /* The new file is opened before the old one is given up, so a path that
     * cannot be created leaves the sink exactly as it was. */
    SDL_IOStream *opened = SDL_IOFromFile(path, "w");
    if (!opened) return false;

    SDL_LockMutex(sinkLock);
    SDL_IOStream *replaced = sinkFile;
    sinkFile = opened;
    SDL_UnlockMutex(sinkLock);

    if (replaced) {
        /* Past the unlock nothing can reach `replaced`: a thread already
         * inside `sink` finished its line before the swap took the lock, and
         * one arriving after reads the new file under it. */
        SDL_CloseIO(replaced);
        return true;
    }

    /* Only on the way in from nothing. Asking SDL for its output function
     * while this one is already installed would answer with `sink` itself,
     * and the restore in `tecsLogSinkClose` would then recurse forever. */
    SDL_GetLogOutputFunction(&previousFunction, &previousUserdata);
    SDL_SetLogOutputFunction(sink, NULL);
    return true;
}

/* Tells the sink where Lua's categories start and what they are called. */
void tecsLogSinkCategory(int base, int category, const char *name)
{
    categoryBase = base;
    int index = category - base;
    if (index < 0 || index >= TECS_MAX_CATEGORIES) return;
    SDL_strlcpy(categoryNames[index], name, sizeof(categoryNames[index]));
}

void tecsLogSinkClose(void)
{
    if (!sinkFile) return;
    SDL_SetLogOutputFunction(previousFunction, previousUserdata);
    SDL_LockMutex(sinkLock);
    SDL_CloseIO(sinkFile);
    sinkFile = NULL;
    SDL_UnlockMutex(sinkLock);
}
