--- shaderc binding: GLSL source to SPIR-V.
---
--- This is the front half of the shader pipeline. Runtime compilation is a
--- requirement rather than a convenience: material variants are assembled from
--- source at load time, so an offline-only bake would not serve them.

local loader <const> = require("tecs2d.ffi.loader")

loader.declare("shaderc")

local namespace <const>, libraryPath <const> =
    loader.library("shaderc_shared", "shaderc", "TECS2D_SHADERC_PATH", "shaderc")

local record shaderc
    C: loader.CNamespace
    K: {string: integer}
    path: string
end

shaderc.C = namespace
shaderc.K = loader.constants("shaderc")
shaderc.path = libraryPath

return shaderc
