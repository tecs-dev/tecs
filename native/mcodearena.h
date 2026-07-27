/* Address space held open for the machine code every Lua state compiles into.
 *
 * A LuaJIT trace reaches the interpreter with a single immediate branch, so its
 * machine code has to sit within that branch's reach: 128MB on arm64, which
 * LuaJIT halves to 62MB either side of the interpreter's own code so that mcode
 * can reach mcode as well. It places an area by asking the kernel for one near
 * that anchor and rejecting whatever lands outside; there is no way to hand it
 * memory, and there is nowhere else a trace can go.
 *
 * That window is a fixed 124MB of the process, and this process fills it. Below
 * the anchor is __PAGEZERO, which on arm64 macOS is a four gigabyte reservation
 * the kernel refuses to shrink and no mapping may enter. Above it is where the
 * loader stacks every dylib and where the graphics driver maps. Measured by
 * mmapping every 64KB-aligned address in the window, all 1984 land before the
 * engine boots and none do once a window and a device exist. So a state created
 * after that point, which is every worker `tecs.workers` spawns, never gets an
 * area and runs entirely interpreted. `jit.status()` still answers true, and
 * nothing else reports it either.
 *
 * Holding a block of the window from the first instruction of the process is
 * what keeps that from happening. Everything mapped afterwards goes somewhere
 * else, because this is already there; releasing the block once the device
 * exists leaves free address space in reach that nothing else is competing for,
 * and every state in the process allocates its areas out of it for the rest of
 * the run.
 *
 * Reserving costs no memory. The block is mapped unreadable and never touched,
 * so it is address space and nothing more.
 *
 * What it does not cover is a bound worth knowing. Twenty-four megabytes is
 * held and not all of it reaches a Lua state: releasing hands the space back to
 * whatever asks next, and the driver's first-frame mappings take most of it.
 * Sweeping the window a few frames in leaves about six megabytes free. LuaJIT's
 * default budget is 512KB of machine code per state, so that is on the order of
 * a dozen states compiling everything they are allowed to, and many more than
 * that compiling a few hot loops each: forty-eight workers running the same
 * loop at once were measured with none of them interpreted, because one loop is
 * one 32KB area and a state takes no more than it fills.
 *
 * A game past that bound competes for whatever the loader left over, exactly as
 * it did before, and the only symptom is a worker that runs slowly. Setting
 * `TECS_TRACEPROF` makes a worker report its trace aborts when it stops, which
 * is how that is told apart from a worker that is merely busy.
 */

#ifndef TECS_MCODEARENA_H
#define TECS_MCODEARENA_H

#include <stdbool.h>

/* Holds a block of address space within reach of the interpreter. Call before
 * anything else in the process: the value is in being first.
 *
 * Returns false when no block could be placed in reach, which is not fatal and
 * not worth failing a launch over. It means traces compete for whatever the
 * loader left. */
bool tecsMcodeArenaReserve(void);

/* Gives the block back, leaving free address space where the loader and the
 * driver can no longer take it. Call once everything that maps at startup has
 * mapped. Does nothing when nothing was reserved, and nothing when called
 * again. */
void tecsMcodeArenaRelease(void);

#endif
