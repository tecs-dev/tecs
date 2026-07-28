/* Log sink: SDL's platform destination plus a JSON Lines file.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift.
 */

#ifndef TECS_LOGSINK_H
#define TECS_LOGSINK_H

#include <stdbool.h>

/* Starts writing to `path`, truncating it, and installs the sink in front of
 * SDL's own output function rather than instead of it. Called again with
 * another path, it closes the file it was writing to and moves to the new
 * one; a path it cannot open leaves the old one in place. */
bool tecsLogSinkOpen(const char *path);

/* Names a category so the sink can write it rather than a number. `base` is
 * where the caller's categories start. */
void tecsLogSinkCategory(int base, int category, const char *name);

/* Restores SDL's output function and closes the file. */
void tecsLogSinkClose(void);

#endif
