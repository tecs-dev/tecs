--- Box2D 3.x binding.
---
--- Box2D 3 is a plain C API whose handles (`b2BodyId`, `b2ShapeId`) are small
--- value structs rather than pointers to C++ objects. That is what makes them
--- storable directly in component columns: no userdata, no finalizers, and no
--- boundary crossing to read one back.

local loader <const> = require("tecs2d.ffi.loader")

loader.declare("box2d")

local namespace <const>, libraryPath <const> =
    loader.library("box2d", "box2d", "TECS2D_BOX2D_PATH")

local record box2d
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants.
    K: {string: integer}
    --- Absolute path of the library that satisfied the load.
    path: string
end

box2d.C = namespace
box2d.K = loader.constants("box2d")
box2d.path = libraryPath

return box2d
