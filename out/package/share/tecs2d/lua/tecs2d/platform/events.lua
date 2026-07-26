

















local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
















































local events = {}






local Cast = "SDL_Event *"








local KINDS = {}

local function map(name, kind)
   local value = C[name]
   if value == nil then return end
   KINDS[tonumber(value)] = kind
end

map("SDL_EVENT_QUIT", "quit")
map("SDL_EVENT_TERMINATING", "terminating")
map("SDL_EVENT_LOW_MEMORY", "lowMemory")
map("SDL_EVENT_WILL_ENTER_BACKGROUND", "appWillEnterBackground")
map("SDL_EVENT_DID_ENTER_BACKGROUND", "appDidEnterBackground")
map("SDL_EVENT_WILL_ENTER_FOREGROUND", "appWillEnterForeground")
map("SDL_EVENT_DID_ENTER_FOREGROUND", "appDidEnterForeground")
map("SDL_EVENT_LOCALE_CHANGED", "localeChanged")
map("SDL_EVENT_SYSTEM_THEME_CHANGED", "themeChanged")

map("SDL_EVENT_DISPLAY_ORIENTATION", "displayOrientation")
map("SDL_EVENT_DISPLAY_ADDED", "displayAdded")
map("SDL_EVENT_DISPLAY_REMOVED", "displayRemoved")
map("SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED", "displayScaleChanged")

map("SDL_EVENT_WINDOW_SHOWN", "windowShown")
map("SDL_EVENT_WINDOW_HIDDEN", "windowHidden")
map("SDL_EVENT_WINDOW_EXPOSED", "windowExposed")
map("SDL_EVENT_WINDOW_MOVED", "windowMoved")
map("SDL_EVENT_WINDOW_RESIZED", "windowResized")
map("SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED", "windowPixelSizeChanged")
map("SDL_EVENT_WINDOW_MINIMIZED", "windowMinimized")
map("SDL_EVENT_WINDOW_MAXIMIZED", "windowMaximized")
map("SDL_EVENT_WINDOW_RESTORED", "windowRestored")
map("SDL_EVENT_WINDOW_MOUSE_ENTER", "windowMouseEnter")
map("SDL_EVENT_WINDOW_MOUSE_LEAVE", "windowMouseLeave")
map("SDL_EVENT_WINDOW_FOCUS_GAINED", "windowFocusGained")
map("SDL_EVENT_WINDOW_FOCUS_LOST", "windowFocusLost")
map("SDL_EVENT_WINDOW_CLOSE_REQUESTED", "windowCloseRequested")
map("SDL_EVENT_WINDOW_DISPLAY_CHANGED", "windowDisplayChanged")

map("SDL_EVENT_KEY_DOWN", "keyDown")
map("SDL_EVENT_KEY_UP", "keyUp")
map("SDL_EVENT_TEXT_EDITING", "textEditing")
map("SDL_EVENT_TEXT_INPUT", "textInput")
map("SDL_EVENT_KEYMAP_CHANGED", "keymapChanged")

map("SDL_EVENT_MOUSE_MOTION", "mouseMotion")
map("SDL_EVENT_MOUSE_BUTTON_DOWN", "mouseDown")
map("SDL_EVENT_MOUSE_BUTTON_UP", "mouseUp")
map("SDL_EVENT_MOUSE_WHEEL", "mouseWheel")

map("SDL_EVENT_FINGER_DOWN", "fingerDown")
map("SDL_EVENT_FINGER_UP", "fingerUp")
map("SDL_EVENT_FINGER_MOTION", "fingerMotion")

map("SDL_EVENT_GAMEPAD_ADDED", "controllerAdded")
map("SDL_EVENT_GAMEPAD_REMOVED", "controllerRemoved")
map("SDL_EVENT_GAMEPAD_BUTTON_DOWN", "controllerButtonDown")
map("SDL_EVENT_GAMEPAD_BUTTON_UP", "controllerButtonUp")
map("SDL_EVENT_GAMEPAD_AXIS_MOTION", "controllerAxis")
map("SDL_EVENT_GAMEPAD_SENSOR_UPDATE", "controllerSensor")

map("SDL_EVENT_DROP_FILE", "dropFile")
map("SDL_EVENT_DROP_TEXT", "dropText")
map("SDL_EVENT_DROP_BEGIN", "dropBegin")
map("SDL_EVENT_DROP_COMPLETE", "dropComplete")

map("SDL_EVENT_CLIPBOARD_UPDATE", "clipboardUpdate")
map("SDL_EVENT_AUDIO_DEVICE_ADDED", "audioDeviceAdded")
map("SDL_EVENT_AUDIO_DEVICE_REMOVED", "audioDeviceRemoved")
map("SDL_EVENT_SENSOR_UPDATE", "sensorUpdate")
map("SDL_EVENT_USER", "user")


local AXIS_SCALE = 1.0 / 32767.0







local scratch = {}


local touchWidth = 1.0
local touchHeight = 1.0



function events.setTouchScale(width, height)
   touchWidth = width
   touchHeight = height
end

local function convert(raw)
   local event = scratch
   local sdlType = tonumber(raw.type)

   event.kind = KINDS[sdlType] or "unknown"
   event.sdlType = sdlType
   event.repeated = false
   event.finger = nil

   local kind = event.kind

   if kind == "keyDown" or kind == "keyUp" then
      local key = raw.key
      event.timestamp = tonumber(key.timestamp)
      event.scancode = tonumber(key.scancode)
      event.repeated = key["repeat"]
   elseif kind == "mouseMotion" then
      local motion = raw.motion
      event.timestamp = tonumber(motion.timestamp)
      event.x = tonumber(motion.x)
      event.y = tonumber(motion.y)
      event.dx = tonumber(motion.xrel)
      event.dy = tonumber(motion.yrel)
   elseif kind == "mouseDown" or kind == "mouseUp" then
      local pressed = raw.button
      event.timestamp = tonumber(pressed.timestamp)
      event.button = tonumber(pressed.button)
      event.x = tonumber(pressed.x)
      event.y = tonumber(pressed.y)
   elseif kind == "mouseWheel" then
      local wheel = raw.wheel
      event.timestamp = tonumber(wheel.timestamp)
      event.wheelX = tonumber(wheel.x)
      event.wheelY = tonumber(wheel.y)
      event.x = tonumber(wheel.mouse_x)
      event.y = tonumber(wheel.mouse_y)
   elseif kind == "fingerDown" or kind == "fingerUp" or kind == "fingerMotion" then
      local touch = raw.tfinger
      event.timestamp = tonumber(touch.timestamp)


      event.finger = ("%s"):format(tostring(touch.fingerID))
      event.x = (tonumber(touch.x)) * touchWidth
      event.y = (tonumber(touch.y)) * touchHeight
      event.dx = (tonumber(touch.dx)) * touchWidth
      event.dy = (tonumber(touch.dy)) * touchHeight
      event.pressure = tonumber(touch.pressure)
   elseif kind == "controllerButtonDown" or kind == "controllerButtonUp" then
      local pad = raw.gbutton
      event.timestamp = tonumber(pad.timestamp)
      event.button = tonumber(pad.button)
      event.which = tonumber(pad.which)
   elseif kind == "controllerAxis" then
      local pad = raw.gaxis
      event.timestamp = tonumber(pad.timestamp)
      event.axis = tonumber(pad.axis)
      event.value = (tonumber(pad.value)) * AXIS_SCALE
      event.which = tonumber(pad.which)
   elseif kind == "controllerAdded" or kind == "controllerRemoved" then
      local device = raw.gdevice
      event.timestamp = tonumber(device.timestamp)
      event.which = tonumber(device.which)
   elseif kind:sub(1, 6) == "window" then
      local window = raw.window
      event.timestamp = tonumber(window.timestamp)
      event.data1 = tonumber(window.data1)
      event.data2 = tonumber(window.data2)
      event.which = tonumber(window.windowID)
   else
      event.timestamp = tonumber(raw.common.timestamp)
   end

   return event
end



function events.copy(event)
   local out = {}
   for key, value in pairs(event) do
      (out)[key] = value
   end
   return out
end










function events.drain(queue, count,
   handler)
   local replay = events.source
   if replay ~= nil then
      replay(handler)
      return
   end

   if count == 0 or queue == nil then return end

   local events_ = ffi.cast(Cast, queue)
   for index = 0, count - 1 do
      handler(convert(events_[index]))
   end
end






function events.push(kind, fields)
   local sdlType = nil
   for value, name in pairs(KINDS) do
      if name == kind then sdlType = value; break end
   end
   if sdlType == nil then
      error(("tecs2d: no event kind named '%s'"):format(tostring(kind)), 2)
   end

   local holder = loader.newArray("SDL_Event[1]")
   local raw = holder[0]
   raw.type = sdlType

   if fields ~= nil then
      if kind == "keyDown" or kind == "keyUp" then
         local key = (holder[0]).key
         key.scancode = fields.scancode or 0
         key["repeat"] = fields.repeated == true
         key.down = kind == "keyDown"
      elseif kind == "mouseDown" or kind == "mouseUp" then
         local button = (holder[0]).button
         button.button = fields.button or 1
         button.down = kind == "mouseDown"
         button.x = fields.x or 0.0
         button.y = fields.y or 0.0
      elseif kind == "mouseMotion" then
         local motion = (holder[0]).motion
         motion.x = fields.x or 0.0
         motion.y = fields.y or 0.0
         motion.xrel = fields.dx or 0.0
         motion.yrel = fields.dy or 0.0
      end
   end

   sdl.check(C.SDL_PushEvent(holder[0]), "SDL_PushEvent")
end


function events.kinds()
   local out = {}
   for _, name in pairs(KINDS) do out[#out + 1] = name end
   table.sort(out)
   return out
end

return events
