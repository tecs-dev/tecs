--- SPIRV-Cross binding: SPIR-V to Metal Shading Language.
---
--- The back half of the shader pipeline. Homebrew ships SPIRV-Cross as static
--- archives only, so `make spvc` links the shared object this loads.

local loader <const> = require("tecs.ffi.loader")

loader.declare("spvc")

local namespace <const>, libraryPath <const> = loader.library("spirvcrossc", "spirv-cross", "TECS_SPVC_PATH", "spvc")

--- The SPIRV-Cross C library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when the
--- shared object cannot be found rather than answering a module whose calls
--- fail later. It is not a library a package manager installs under this name:
--- `make spvc` produces it, and a tree that has not run that fails here. No
--- version is checked.
local record spvc
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

spvc.C = namespace
spvc.K = loader.constants("spvc")
spvc.path = libraryPath

return spvc
