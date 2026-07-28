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
--- the engine uses today is `adler32`, through `tecs.data`.
---
--- zlib names its functions after what they do rather than after itself, so
--- `C.inflate` and `C.compress` are zlib's, not something generic. That is the
--- library's own convention and is kept verbatim, as generated bindings are.

local loader <const> = require("tecs.ffi.loader")

loader.declare("zlib")

local namespace <const>, libraryPath <const> = loader.library("z", "zlib", "TECS_ZLIB_PATH", "zlib")

--- The zlib library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when zlib
--- cannot be found rather than answering a module whose calls fail later. No
--- version is enforced: `version` reports what loaded, and the caller decides
--- whether that is enough for the entry points it means to use.
local record zlib
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`.
    K: {string: integer}
    --- What satisfied the load: an absolute path, or the bare soname when the
    --- dynamic linker resolved it itself, or `"(registry)"` when the host
    --- linked the symbols in. Diagnostic, and not always openable.
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
---
--- @return The runtime library's own answer, so it reflects what is mapped
---     rather than what the cdef was generated from. Compares as a string
---     only: "1.3.10" sorts below "1.3.2" and is the newer of the two.
function zlib.version(): string
    return loader.toString(zlib.C.zlibVersion())
end

return zlib
