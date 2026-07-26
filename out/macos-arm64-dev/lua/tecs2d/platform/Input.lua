



















local sdl = require("tecs2d.ffi.sdl3")
local eventStream = require("tecs2d.platform.events")

local C = sdl.C
local K = sdl.K
















local Input = {}
























local InputMT = { __index = Input }

local function newButtonState()
   return {
      down = {}, pressed = {}, released = {},
      latchedPressed = {}, latchedReleased = {},
   }
end

local function clear(set)
   for key in pairs(set) do set[key] = nil end
end


function Input.create()
   local self = setmetatable({}, InputMT)
   self._keys = newButtonState()
   self._mouse = newButtonState()
   self._pads = newButtonState()
   self._axes = {}
   self._scancodes = {}
   self._base = { name = "base", blocking = true, index = 1 }
   self._layers = { self._base }
   self._fixed = false
   self.mouseX, self.mouseY = 0.0, 0.0
   self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
   self.wheelX, self.wheelY = 0.0, 0.0
   self.text = ""
   return self
end









function Input:pushLayer(name, blocking)
   local layer = {
      name = name,
      blocking = blocking ~= false,
      index = #self._layers + 1,
   }
   self._layers[layer.index] = layer
   return layer
end


function Input:popLayer()
   if #self._layers <= 1 then return nil end
   local layer = self._layers[#self._layers]
   self._layers[#self._layers] = nil
   return layer
end


function Input:topLayer()
   return self._layers[#self._layers]
end


local function readableFrom(self)
   for index = #self._layers, 1, -1 do
      if self._layers[index].blocking then return index end
   end
   return 1
end


function Input:canRead(layer)
   local index = layer ~= nil and layer.index or 1
   return index >= readableFrom(self)
end






function Input:beginFrame()
   clear(self._keys.pressed)
   clear(self._keys.released)
   clear(self._mouse.pressed)
   clear(self._mouse.released)
   clear(self._pads.pressed)
   clear(self._pads.released)
   self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
   self.wheelX, self.wheelY = 0.0, 0.0
   self.text = ""
end


function Input:enterFixedPhase()
   self._fixed = true
end


function Input:exitFixedPhase()
   self._fixed = false
   clear(self._keys.latchedPressed)
   clear(self._keys.latchedReleased)
   clear(self._mouse.latchedPressed)
   clear(self._mouse.latchedReleased)
   clear(self._pads.latchedPressed)
   clear(self._pads.latchedReleased)
end





local function press(state, code)
   state.down[code] = true
   state.pressed[code] = true
   state.latchedPressed[code] = true
end

local function release(state, code)
   state.down[code] = nil
   state.released[code] = true
   state.latchedReleased[code] = true
end




function Input:handleEvent(event)
   local kind = event.kind

   if kind == "keyDown" then


      if not event.repeated then
         press(self._keys, event.scancode)
      end
   elseif kind == "keyUp" then
      release(self._keys, event.scancode)
   elseif kind == "mouseDown" then
      press(self._mouse, event.button)
   elseif kind == "mouseUp" then
      release(self._mouse, event.button)
   elseif kind == "mouseMotion" then
      self.mouseX = event.x
      self.mouseY = event.y
      self.mouseDeltaX = self.mouseDeltaX + event.dx
      self.mouseDeltaY = self.mouseDeltaY + event.dy
   elseif kind == "mouseWheel" then
      self.wheelX = self.wheelX + event.wheelX
      self.wheelY = self.wheelY + event.wheelY
   elseif kind == "controllerButtonDown" then
      press(self._pads, event.button)
   elseif kind == "controllerButtonUp" then
      release(self._pads, event.button)
   elseif kind == "controllerAxis" then
      self._axes[event.axis] = event.value
   end
end









function Input:scancode(name)
   local cached = self._scancodes[name]
   if cached ~= nil then return cached end

   local code = tonumber(C.SDL_GetScancodeFromName(name))
   if code == 0 then
      local titled = name:gsub("(%a)([%w']*)", function(head, tail)
         return head:upper() .. tail:lower()
      end)
      code = tonumber(C.SDL_GetScancodeFromName(titled))
   end
   if code == 0 then
      error(("tecs2d: no key named '%s'"):format(name), 2)
   end
   self._scancodes[name] = code
   return code
end

local function resolve(self, key)
   if type(key) == "string" then return self:scancode(key) end
   return key
end


local function eventSet(self, state, released)
   if self._fixed then
      return released and state.latchedReleased or state.latchedPressed
   end
   return released and state.released or state.pressed
end

function Input:isKeyDown(key, layer)
   if not self:canRead(layer) then return false end
   return self._keys.down[resolve(self, key)] == true
end

function Input:isKeyPressed(key, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._keys, false)[resolve(self, key)] == true
end

function Input:isKeyReleased(key, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._keys, true)[resolve(self, key)] == true
end

function Input:isMouseDown(button, layer)
   if not self:canRead(layer) then return false end
   return self._mouse.down[button] == true
end

function Input:isMousePressed(button, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._mouse, false)[button] == true
end

function Input:isMouseReleased(button, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._mouse, true)[button] == true
end

function Input:isPadDown(button, layer)
   if not self:canRead(layer) then return false end
   return self._pads.down[button] == true
end

function Input:isPadPressed(button, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._pads, false)[button] == true
end

function Input:isPadReleased(button, layer)
   if not self:canRead(layer) then return false end
   return eventSet(self, self._pads, true)[button] == true
end





function Input:axis(axis, deadzone, layer)
   if not self:canRead(layer) then return 0.0 end
   local value = self._axes[axis] or 0.0
   local limit = deadzone or 0.15
   if math.abs(value) < limit then return 0.0 end
   return value
end


function Input.buttons()
   return {
      left = K.SDL_BUTTON_LEFT,
      middle = K.SDL_BUTTON_MIDDLE,
      right = K.SDL_BUTTON_RIGHT,
   }
end

return Input
