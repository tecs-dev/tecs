






local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C








local Sampler = {}





local SamplerMT = { __index = Sampler }

local FILTERS = {
   nearest = 0,
   linear = 1,
}

local ADDRESS_MODES = {
   ["repeat"] = 0,
   mirror = 1,
   clamp = 2,
}


function Sampler.create(device, options)
   options = options or {}

   local filter = FILTERS[options.filter or "nearest"]
   if filter == nil then
      error(("tecs2d: unknown filter '%s'"):format(tostring(options.filter)), 2)
   end
   local address = ADDRESS_MODES[options.address or "clamp"]
   if address == nil then
      error(("tecs2d: unknown address mode '%s'"):format(tostring(options.address)), 2)
   end

   local info = loader.newArray("SDL_GPUSamplerCreateInfo[1]")
   local settings = info[0]
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
   if handle == nil then sdl.fail("SDL_CreateGPUSampler") end

   local self = setmetatable({}, SamplerMT)
   self.handle = handle
   self._device = device
   self._destroyed = false
   return self
end


function Sampler:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.SDL_ReleaseGPUSampler(self._device, self.handle)
   self.handle = nil
end

return Sampler
