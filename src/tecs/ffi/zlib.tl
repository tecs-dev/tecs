--- zlib binding.
---
--- zlib is in this process either way: SDL3_image reads PNG through it. What
--- changed is that it is now a dependency this tree names, pins and builds,
--- rather than one it inherits from whatever the machine had. libcurl needs it
--- to answer a `Content-Encoding`, and once it is pinned for that, everything
--- else it can do is reachable at no further cost.
---
--- The surface is the whole library, because zlib is small enough that
--- selecting from it would be more description than the thing described. What
--- the engine uses today is `adler32`, through `tecs.hash`.
---
--- zlib names its functions after what they do rather than after itself, so
--- `C.inflate` and `C.compress` are zlib's, not something generic. That is the
--- library's own convention and is kept verbatim, as generated bindings are.

local loader <const> = require("tecs.ffi.loader")

loader.declare("zlib")

local namespace <const>, libraryPath <const> = loader.library("z", "zlib", "TECS_ZLIB_PATH", "zlib")

local record zlib
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`.
    K: {string: integer}
    --- Absolute path of the library that satisfied the load.
    path: string
end

zlib.C = namespace
zlib.K = loader.constants("zlib")
zlib.path = libraryPath

--- The version of the library that was actually loaded, e.g. "1.3.2".
---
--- Worth asking rather than assuming: a development preset resolves zlib from
--- the system and a packaged one builds the pinned revision, so the two do not
--- have to agree and a bug report needs to say which was in the process.
function zlib.version(): string
    return loader.toString(zlib.C.zlibVersion())
end

return zlib
