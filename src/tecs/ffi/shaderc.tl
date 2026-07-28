--- shaderc binding: GLSL source to SPIR-V.
---
--- This is the front half of the shader pipeline. Runtime compilation is a
--- requirement rather than a convenience: material variants are assembled from
--- source at load time, so an offline-only bake would not serve them.

local loader <const> = require("tecs.ffi.loader")

loader.declare("shaderc")

local namespace <const>, libraryPath <const> = loader.library(
    "shaderc_shared", "shaderc", "TECS_SHADERC_PATH", "shaderc"
)

--- The shaderc library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when
--- shaderc cannot be found rather than answering a module whose calls fail
--- later. That makes the require itself the thing a target without a compiler
--- must not reach: such a build consumes a prebuilt shader pack and never
--- requires this. No version is checked.
local record shaderc
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

shaderc.C = namespace
shaderc.K = loader.constants("shaderc")
shaderc.path = libraryPath

return shaderc
