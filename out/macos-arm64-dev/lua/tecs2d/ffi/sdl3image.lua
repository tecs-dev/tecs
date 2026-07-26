





local loader = require("tecs2d.ffi.loader")

loader.declare("sdl3image")

local namespace, libraryPath =
loader.library("SDL3_image", "sdl3_image", "TECS2D_SDL3IMAGE_PATH")

local sdl3image = {}





sdl3image.C = namespace
sdl3image.K = loader.constants("sdl3image")
sdl3image.path = libraryPath

return sdl3image
