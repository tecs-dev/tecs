








local tecs = require("tecs")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local clock = require("tecs2d.platform.clock")
local events = require("tecs2d.platform.events")
local Input = require("tecs2d.platform.Input")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local Renderer = require("tecs2d.Renderer")
local tween = require("tecs2d.tween")
local sequence = require("tecs2d.sequence")
local paths = require("tecs2d.platform.paths")
local shaderpack = require("tecs2d.gpu.shaderpack")
local shadercompiler = require("tecs2d.gpu.shadercompiler")

local C = sdl.C
local K = sdl.K









local Application = { Config = {} }











































local ApplicationMT = { __index = Application }


function Application.create(config)
   local self = setmetatable({}, ApplicationMT)
   self._config = config or {}
   self._started = false
   self._shutdownDone = false
   self.quitRequested = false
   self.suspended = false
   self.elapsed = 0.0
   self.frame = 0
   return self
end






function Application:_init()
   local config = self._config

   sdl.check(C.SDL_Init(K.SDL_INIT_VIDEO + K.SDL_INIT_GAMEPAD),
   "SDL_Init")



   local packPath = paths.asset(config.shaderPack or "shaders.tsp")
   local pack = shaderpack.read(packPath)
   if pack ~= nil then
      shadercompiler.usePack(pack)
   elseif not shadercompiler.available() then
      error(("tecs2d: this build links no shader compiler and there is no " ..
      "pack at %s"):format(packPath))
   end

   local windowConfig = config.window or {}
   self.window = Window.create({
      title = windowConfig.title,
      width = windowConfig.width,
      height = windowConfig.height,
      resizable = windowConfig.resizable,
      highPixelDensity = windowConfig.highPixelDensity,
   })

   self.device = Device.create(self.window, { debug = config.debug })
   if config.framesInFlight ~= nil then
      self.device:setFramesInFlight(config.framesInFlight)
   end
   if config.presentMode ~= nil then
      self.device:setPresentMode(config.presentMode)
   end

   self.input = Input.create()
   self.world = tecs.newWorld({ maxEntities = config.maxEntities })
   self.renderer = Renderer.create(self.device.handle,
   self.device:getSwapchainFormat(), {
      ambient = config.ambient,
      capacity = config.capacity,
   })
   self.renderer:install(self.world)




   self.world:addPlugin(tween.plugin)
   self.world:addPlugin(sequence.plugin)



   local width, height = self.window:getPixelSize()
   events.setTouchScale(width, height)




   local input = self.input
   self.world:addSystem({
      name = "tecs2d.EnterFixedInput",
      phase = tecs.phases.FixedFirst,
      run = function() input:enterFixedPhase() end,
   })
   self.world:addSystem({
      name = "tecs2d.ExitFixedInput",
      phase = tecs.phases.FixedLast,
      run = function() input:exitFixedPhase() end,
   })

   if config.load ~= nil then config.load(self) end


   clock.reset()
   self._started = true
   return true
end






function Application:_receive(event)
   self.input:handleEvent(event)

   local kind = event.kind
   if kind == "quit" or kind == "windowCloseRequested" then
      self.quitRequested = true
   elseif kind == "appWillEnterBackground" then
      self.suspended = true
   elseif kind == "appDidEnterForeground" then
      self.suspended = false


      clock.reset()
   end

   local handler = self._config.event
   if handler ~= nil then handler(self, event) end
end


function Application:_iterate(queue, count)
   local dt = clock.step()

   self.input:beginFrame()
   events.drain(queue, count, function(event)
      self:_receive(event)
   end)

   if self.quitRequested then return false end

   if not self.suspended then
      self.elapsed = self.elapsed + dt
      if self._config.update ~= nil then self._config.update(self, dt) end

      self.world:update(dt)

      local frame = self.device:beginFrame()
      if frame ~= nil then
         self.renderer:render(frame)
         frame:submit()
      end
   end

   self.frame = self.frame + 1
   if self._config.maxFrames ~= nil and self.frame >= self._config.maxFrames then
      return false
   end
   return true
end


function Application:_shutdown()
   if self._shutdownDone then return true end
   self._shutdownDone = true

   if self._started and self._config.quit ~= nil then
      self._config.quit(self)
   end

   if self.device ~= nil then
      self.device:waitForIdle()
      if self.renderer ~= nil then self.renderer:destroy() end
      self.device:destroy()
   end
   if self.window ~= nil then self.window:destroy() end
   C.SDL_Quit()
   return true
end

return Application
