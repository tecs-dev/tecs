
local types = require("tecs.types")

local random = math.random






local runIf = {}




























































function runIf.after(delay)
   local elapsed = 0
   local hasFired = false

   return function(dt, world, systemName)
      if hasFired then
         return false
      end

      elapsed = elapsed + dt
      if elapsed >= delay then
         hasFired = true

         world:removeSystem(systemName)
         return true
      end

      return false
   end
end

function runIf.every(interval, jitter)
   local elapsed = 0
   local currentInterval = interval
   jitter = jitter or 0


   if jitter == 0 then
      return function(dt, _world, _systemName)
         elapsed = elapsed + dt
         if elapsed >= interval then
            elapsed = elapsed - interval
            return true
         end
         return false
      end
   end

   return function(dt, _world, _systemName)
      elapsed = elapsed + dt
      if elapsed >= currentInterval then
         elapsed = elapsed - currentInterval



         local variance = (random() * 2 - 1) * jitter
         currentInterval = interval + variance
         if currentInterval < interval * 0.01 then
            currentInterval = interval * 0.01
         end
         return true
      end
      return false
   end
end

function runIf.cooldown(duration)
   local elapsed = duration

   return function(dt, _world, _systemName)
      elapsed = elapsed + dt

      if elapsed >= duration then
         elapsed = 0
         return true
      end

      return false
   end
end

function runIf.inState(name)
   return function(_dt, world, _systemName)
      return world:peekState() == name
   end
end












function runIf.both(lhs, rhs)
   return function(dt, world, systemName)
      return lhs(dt, world, systemName) and rhs(dt, world, systemName)
   end
end

function runIf.either(lhs, rhs)
   return function(dt, world, systemName)
      return lhs(dt, world, systemName) or rhs(dt, world, systemName)
   end
end

function runIf.negate(predicate)
   return function(dt, world, systemName)
      return not predicate(dt, world, systemName)
   end
end

return runIf
