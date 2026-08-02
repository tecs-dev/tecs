--[=[
A texture sampler.

Deferred passes read the previous pass's output one texel per fragment, so
the default is nearest with clamped edges. Filtering a G-buffer bleeds
neighboring surfaces together, which shows up as haloed edges in lighting
rather than as anything that looks like a sampling problem.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

local record SamplerOptions
    --- One of the module's `FILTER_*` constants. Defaults to `FILTER_NEAREST`, and applies to both
    --- minification and magnification: a sampler that filtered one and not the
    --- other has no use here.
    filter: integer
    --- One of the module's `ADDRESS_*` constants. Defaults to `ADDRESS_CLAMP`, and applies to all
    --- three axes. Clamp is what a texture array wants, where an image
    --- occupying part of a cell would otherwise sample its neighbor's padding.
    address: integer
    --- Uses linear filtering between mip levels and defaults to false.
    mipmaps: boolean
end

--- An immutable sampler, and the type `create` returns.
---
--- Filtering and addressing are fixed when it is made, so a second combination
--- is a second sampler. One may be paired with any number of textures; a bind
--- call carries one sampler for every texture it lists.
local record Sampler
    --- Selects nearest-neighbor filtering.
    FILTER_NEAREST: integer
    --- Selects linear filtering.
    FILTER_LINEAR: integer
    --- Repeats texture coordinates outside zero through one.
    ADDRESS_REPEAT: integer
    --- Mirrors repeated texture coordinates outside zero through one.
    ADDRESS_MIRROR: integer
    --- Clamps texture coordinates to the nearest edge.
    ADDRESS_CLAMP: integer

    --- The `SDL_GPUSampler`. Nil once `destroy` has run.
    handle: loader.CPtr
    --- The `SDL_GPUDevice` it was created against, and the one `destroy`
    --- releases it from.
    _device: loader.CPtr
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local SamplerMT <const>: metatable<Sampler> = {__index = Sampler}

Sampler.FILTER_NEAREST = tonumber(C.SDL_GPU_FILTER_NEAREST) as integer
Sampler.FILTER_LINEAR = tonumber(C.SDL_GPU_FILTER_LINEAR) as integer
Sampler.ADDRESS_REPEAT = tonumber(C.SDL_GPU_SAMPLERADDRESSMODE_REPEAT) as integer
Sampler.ADDRESS_MIRROR = tonumber(C.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT) as integer
Sampler.ADDRESS_CLAMP = tonumber(C.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE) as integer

--- Creates a sampler.
---
--- Mipmap filtering is independently enabled because the paired texture must
--- own the matching levels. Anisotropy and comparison remain disabled.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param options Nil takes every default: nearest filtering, clamped edges.
---     An invalid filter or address mode raises rather than falling back.
function Sampler.create(device: loader.CPtr, options: SamplerOptions): Sampler
    options = options or {}

    local filter = options.filter or Sampler.FILTER_NEAREST
    if filter < Sampler.FILTER_NEAREST or filter > Sampler.FILTER_LINEAR then
        error(("tecs: invalid sampler filter %s"):format(tostring(options.filter)), 2)
    end
    local address = options.address or Sampler.ADDRESS_CLAMP
    if address < Sampler.ADDRESS_REPEAT or address > Sampler.ADDRESS_CLAMP then
        error(("tecs: invalid sampler address mode %s"):format(tostring(options.address)), 2)
    end

    local info = loader.newArray("SDL_GPUSamplerCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.min_filter = filter
    settings.mag_filter = filter
    settings.mipmap_mode = options.mipmaps and C.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR or C.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST
    settings.address_mode_u = address
    settings.address_mode_v = address
    settings.address_mode_w = address
    settings.min_lod = 0.0
    settings.max_lod = options.mipmaps and 1000.0 or 0.0
    settings.enable_anisotropy = false
    settings.enable_compare = false
    settings.props = 0

    local handle = C.SDL_CreateGPUSampler(device, info)
    if handle == nil then
        sdl.fail("SDL_CreateGPUSampler")
    end

    local self = setmetatable({} as Sampler, SamplerMT)
    self.handle = handle
    self._device = device
    self._destroyed = false
    return self
end

--- Releases the sampler. Safe to call more than once.
function Sampler:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.SDL_ReleaseGPUSampler(self._device, self.handle)
    self.handle = nil
end

return Sampler
