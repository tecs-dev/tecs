







local sdl = require("tecs2d.ffi.sdl3")

local C = sdl.C

local clock = {}













clock.nominal = 1.0 / 60.0
clock.maxDelta = 0.25

local frequency = 0.0
local last = 0.0


function clock.now()
   if frequency == 0.0 then
      frequency = tonumber(C.SDL_GetPerformanceFrequency())
   end
   return (tonumber(C.SDL_GetPerformanceCounter())) / frequency
end



function clock.reset()
   last = clock.now()
end




function clock.step()
   local now = clock.now()
   if last == 0.0 then last = now end
   local dt = now - last
   last = now

   if dt > clock.maxDelta then dt = clock.maxDelta end

   local p = clock.provider
   if p ~= nil then
      local override = p(dt)
      if override ~= nil then return override end
   end
   return dt
end

return clock
