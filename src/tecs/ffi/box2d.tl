--- Box2D 3.x binding.
---
--- Box2D 3 is a plain C API whose handles (`b2BodyId`, `b2ShapeId`) are small
--- value structs rather than pointers to C++ objects. That is what makes them
--- storable directly in component columns: no userdata, no finalizers, and no
--- boundary crossing to read one back.

local loader <const> = require("tecs.ffi.loader")

loader.declare("box2d")

local namespace <const>, libraryPath <const> = loader.library("box2d", "box2d", "TECS_BOX2D_PATH", "box2d")

--- The Box2D library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when Box2D
--- cannot be found rather than answering a module whose calls fail later. No
--- version is checked, and Box2D 3 broke its API from Box2D 2: a 2.x library
--- resolves almost none of these symbols and raises at the first access.
local record box2d
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants.
    K: {string: integer}
    --- What satisfied the load: an absolute path, or the bare soname when the
    --- dynamic linker resolved it itself, or `"(registry)"` when the host
    --- linked the symbols in. Diagnostic, and not always openable.
    path: string
end

box2d.C = namespace
box2d.K = loader.constants("box2d")
box2d.path = libraryPath

return box2d
