--- A texture sampler.
---
--- Deferred passes read the previous pass's output one texel per fragment, so
--- the default is nearest with clamped edges. Filtering a G-buffer bleeds
--- neighbouring surfaces together, which shows up as haloed edges in lighting
--- rather than as anything that looks like a sampling problem.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

local record SamplerOptions
    --- "nearest" or "linear". Defaults to nearest, and applies to both
    --- minification and magnification: a sampler that filtered one and not the
    --- other has no use here.
    filter: string
    --- "clamp", "repeat", or "mirror". Defaults to clamp, and applies to all
    --- three axes. Clamp is what a texture array wants, where an image
    --- occupying part of a cell would otherwise sample its neighbour's padding.
    address: string
end

--- An immutable sampler, and the type `create` returns.
---
--- Filtering and addressing are fixed when it is made, so a second combination
--- is a second sampler. One may be paired with any number of textures; a bind
--- call carries one sampler for every texture it lists.
local record Sampler
    --- The `SDL_GPUSampler`. Nil once `destroy` has run.
    handle: loader.CPtr
    --- The `SDL_GPUDevice` it was created against, and the one `destroy`
    --- releases it from.
    _device: loader.CPtr
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local SamplerMT <const>: metatable<Sampler> = {__index = Sampler}

local FILTERS <const>: {string: integer} = {
    nearest = 0,
    linear = 1,
}

local ADDRESS_MODES <const>: {string: integer} = {
    ["repeat"] = 0,
    mirror = 1,
    clamp = 2,
}

--- Creates a sampler.
---
--- One mip level, no anisotropy and no comparison: nothing here generates
--- mips, so a sampler that could filter between them would be describing a
--- texture that does not exist.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param options Nil takes every default: nearest filtering, clamped edges.
---     An unknown filter or address mode raises rather than falling back.
function Sampler.create(device: loader.CPtr, options: SamplerOptions): Sampler
    options = options or {}

    local filter = FILTERS[options.filter or "nearest"]
    if filter == nil then
        error(("tecs: unknown filter '%s'"):format(tostring(options.filter)), 2)
    end
    local address = ADDRESS_MODES[options.address or "clamp"]
    if address == nil then
        error(("tecs: unknown address mode '%s'"):format(tostring(options.address)), 2)
    end

    local info = loader.newArray("SDL_GPUSamplerCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.min_filter = filter
    settings.mag_filter = filter
    settings.mipmap_mode = 0
    settings.address_mode_u = address
    settings.address_mode_v = address
    settings.address_mode_w = address
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
