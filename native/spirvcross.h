/* Shared-object stub for SPIRV-Cross. See spirvcross.c for why it exists.
 *
 * The one thing the stub declares of its own. Every other native module has a
 * header for the same reason: a definition checked against nothing is a
 * signature free to drift from what a caller was told.
 */

#ifndef TECS_SPIRVCROSS_H
#define TECS_SPIRVCROSS_H

/* The SPIRV-Cross C API version this object was built against, as
 * major * 10000 + minor * 100 + patch, so a mismatch between the archives
 * linked here and the cdef generated from their headers can be read rather
 * than inferred from a crash. */
unsigned tecsSpirvCrossVersion(void);

#endif
