






local loader = require("tecs2d.ffi.loader")

loader.declare("box2d")

local namespace, libraryPath =
loader.library("box2d", "box2d", "TECS2D_BOX2D_PATH")

local box2d = {}








box2d.C = namespace
box2d.K = loader.constants("box2d")
box2d.path = libraryPath

return box2d
