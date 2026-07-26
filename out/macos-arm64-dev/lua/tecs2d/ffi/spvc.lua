




local loader = require("tecs2d.ffi.loader")

loader.declare("spvc")

local namespace, libraryPath =
loader.library("spirvcrossc", "spirv-cross", "TECS2D_SPVC_PATH")

local spvc = {}





spvc.C = namespace
spvc.K = loader.constants("spvc")
spvc.path = libraryPath

return spvc
