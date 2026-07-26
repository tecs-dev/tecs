--- SPIRV-Cross binding: SPIR-V to Metal Shading Language.
---
--- The back half of the shader pipeline. Homebrew ships SPIRV-Cross as static
--- archives only, so `make spvc` links the shared object this loads.

local loader <const> = require("tecs.ffi.loader")

loader.declare("spvc")

local namespace <const>, libraryPath <const> =
    loader.library("spirvcrossc", "spirv-cross", "TECS_SPVC_PATH", "spvc")

local record spvc
    C: loader.CNamespace
    K: {string: integer}
    path: string
end

spvc.C = namespace
spvc.K = loader.constants("spvc")
spvc.path = libraryPath

return spvc
