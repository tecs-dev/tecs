/* Log sink: SDL's platform destination plus a JSON Lines file.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift.
 */

#ifndef TECS2D_LOGSINK_H
#define TECS2D_LOGSINK_H

#include <stdbool.h>

/* Starts writing to `path`, truncating it, and installs the sink in front of
 * SDL's own output function rather than instead of it. */
bool tecs2dLogSinkOpen(const char *path);

/* Names a category so the sink can write it rather than a number. `base` is
 * where the caller's categories start. */
void tecs2dLogSinkCategory(int base, int category, const char *name);

/* Restores SDL's output function and closes the file. */
void tecs2dLogSinkClose(void);

#endif
