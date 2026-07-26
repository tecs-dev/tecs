





local loader = require("tecs2d.ffi.loader")

loader.declare("shaderc")

local namespace, libraryPath =
loader.library("shaderc_shared", "shaderc", "TECS2D_SHADERC_PATH", "shaderc")

local shaderc = {}





shaderc.C = namespace
shaderc.K = loader.constants("shaderc")
shaderc.path = libraryPath

return shaderc
