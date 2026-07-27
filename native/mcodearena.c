#include "mcodearena.h"

#include <dlfcn.h>
#include <stdint.h>
#include <sys/mman.h>

#include <lua.h>

/* How much to hold, and how little is still worth holding.
 *
 * Twenty-four megabytes is what fits. Measured across eight launches each, a
 * block of that size places every time and thirty-two places never: the loader
 * has already stacked the dylibs by the time the process reaches its first
 * instruction, and the longest free run left between them lands between the
 * two. Halving on failure is for a layout where it does not, since a smaller
 * block in reach beats none.
 *
 * It also has to be that large to be enough. Eight megabytes places just as
 * reliably and is not sufficient: releasing it hands the space back to whatever
 * asks next, and the driver's first-frame mappings ask for most of it before
 * any worker compiles a trace. At eight the worker still ran interpreted in
 * three launches out of four, at sixteen in one, and at twenty-four in none of
 * eight. */
#define TECS_MCODE_ARENA_BYTES (24u << 20)
#define TECS_MCODE_ARENA_MIN (4u << 20)

/* Half of arm64's branch reach, less a margin, exactly as lj_mcode.c computes
 * it. Straying from LuaJIT's own arithmetic would reserve a window that is not
 * the one it allocates from. */
#define TECS_MCODE_RANGE (((uintptr_t)1 << 26) - ((uintptr_t)1 << 21))

/* Where a probe starts and how far each miss advances it. The kernel returns
 * the lowest free span at or above a hint, so the first probe usually answers;
 * the rest are for a window whose low end is already taken. */
#define TECS_MCODE_ATTEMPTS 64
#define TECS_MCODE_STEP (1u << 20)

static void *arena;
static size_t arenaSize;

/* Where the interpreter's code sits.
 *
 * LuaJIT anchors on `lj_vm_exit_handler`, which is not an exported symbol, so
 * the image holding the interpreter stands in for it. The image is under a
 * megabyte and the window is a hundred and twenty-four, so the two anchors
 * describe the same window. */
static uintptr_t interpreterAnchor(void)
{
    Dl_info info;
    if (!dladdr((const void *)(uintptr_t)&lua_newstate, &info)) return 0;
    if (!info.dli_fbase) return 0;
    return (uintptr_t)info.dli_fbase & ~(uintptr_t)0xffff;
}

/* Holds `size` bytes somewhere between `low` and `high`, or returns NULL. */
static void *reserveWithin(size_t size, uintptr_t low, uintptr_t high)
{
    uintptr_t hint = low;
    for (int attempt = 0; attempt < TECS_MCODE_ATTEMPTS; attempt++) {
        void *p = mmap((void *)hint, size, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return NULL;

        uintptr_t got = (uintptr_t)p;
        if (got >= low && got + size <= high) return p;

        /* Placed outside the window, so give it back and look above whatever
         * the kernel found rather than asking for the same span again. */
        munmap(p, size);
        hint = (got > hint ? got : hint) + TECS_MCODE_STEP;
        if (hint >= high) return NULL;
    }
    return NULL;
}

bool tecsMcodeArenaReserve(void)
{
    if (arena) return true;

    uintptr_t target = interpreterAnchor();
    if (!target) return false;
    uintptr_t low = target - TECS_MCODE_RANGE;
    uintptr_t high = target + TECS_MCODE_RANGE;

    for (size_t size = TECS_MCODE_ARENA_BYTES; size >= TECS_MCODE_ARENA_MIN;
         size /= 2) {
        void *p = reserveWithin(size, low, high);
        if (p) {
            arena = p;
            arenaSize = size;
            return true;
        }
    }
    return false;
}

void tecsMcodeArenaRelease(void)
{
    if (!arena) return;
    munmap(arena, arenaSize);
    arena = NULL;
    arenaSize = 0;
}
