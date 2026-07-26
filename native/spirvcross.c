/* Shared-object stub for SPIRV-Cross.
 *
 * SPIRV-Cross ships static archives, and the FFI can only load a shared
 * object. This file exists so there is something to link them into; the C API's
 * symbols come from the archives, pulled in whole because nothing here
 * references them and the linker would otherwise discard every one.
 */

#include <spirv_cross_c.h>

/* Reports the SPIRV-Cross C API version this object was built against, so a
 * mismatch is discoverable rather than a surprising crash. */
unsigned tecs2dSpirvCrossVersion(void)
{
    unsigned major = 0, minor = 0, patch = 0;
    spvc_get_version(&major, &minor, &patch);
    return major * 10000 + minor * 100 + patch;
}
