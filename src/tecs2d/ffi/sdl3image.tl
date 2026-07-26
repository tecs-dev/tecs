--- SDL3_image binding: file bytes to pixels.
---
--- Decoding happens on a worker, so this is loaded in the worker's state as
--- well as the main one. `ffi.load` resolves to the same already-mapped
--- library in both, so there is one copy of the decoder in the process.

local loader <const> = require("tecs2d.ffi.loader")

loader.declare("sdl3image")

local namespace <const>, libraryPath <const> =
    loader.library("SDL3_image", "sdl3_image", "TECS2D_SDL3IMAGE_PATH", "sdl3image")

local record sdl3image
    C: loader.CNamespace
    K: {string: integer}
    path: string
end

sdl3image.C = namespace
sdl3image.K = loader.constants("sdl3image")
sdl3image.path = libraryPath

return sdl3image
