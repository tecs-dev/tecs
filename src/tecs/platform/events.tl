--- One typed event stream, derived from SDL.
---
--- Every platform delivers the same vocabulary: desktop, mobile, replay, and
--- tests. Game code never sees an `SDL_Event`, both because the union is a
--- poor thing to program against and because its pointer is only valid inside
--- the callback that produced it.
---
--- `Event` is one wide record discriminated by `kind` rather than a union of
--- per-kind records. Teal can express the union, but not a union that pools,
--- and an event stream that allocates per event is not one this engine can
--- use. The kind determines which fields are meaningful; the rest are stale.
--- Records handed to a handler are reused, so anything retaining one must
--- take a copy.
---
--- Unrecognised SDL events arrive as `unknown` with their numeric type rather
--- than being dropped, so upgrading SDL surfaces new input instead of silently
--- losing it.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

local record Event
    --- What happened. Determines which other fields mean anything.
    kind: string
    --- Milliseconds since SDL started, as SDL reported it.
    timestamp: number

    --- Keyboard.
    scancode: integer
    --- True when the platform is repeating a held key rather than reporting a
    --- new press.
    repeated: boolean

    --- Pointer position, in window coordinates. Touch positions are
    --- normalised by SDL, so they are scaled to the window here.
    x: number
    y: number
    --- Movement since the previous event of this kind.
    dx: number
    dy: number
    --- Mouse or gamepad button.
    button: integer
    --- Wheel movement.
    wheelX: number
    wheelY: number
    --- Gamepad axis and its value in -1..1.
    axis: integer
    value: number
    --- Touch pressure in 0..1.
    pressure: number

    --- Device that produced the event: a gamepad, a display, or a window.
    --- Gamepad and display identifiers fit a Lua number exactly.
    which: number
    --- Touch finger identity. A finger id is 64 bits and does not fit a
    --- double, so it is carried as an opaque string rather than a number that
    --- might silently round.
    finger: string

    --- Window and display payloads, as SDL reports them.
    data1: integer
    data2: integer

    --- Numeric SDL type, set on every event and the only useful field on
    --- `unknown`.
    sdlType: integer
end

local record events
    Event: Event
    --- Installed by a replay driver. Called instead of draining the host
    --- queue, and expected to invoke the handler for each recorded event.
    source: function(handler: function(Event))
end

local Cast <const> = "SDL_Event *"

-------------------------------------------------------------------------------
-- Kind mapping
-------------------------------------------------------------------------------

--- SDL event type to kind name. Built once from the enum rather than written
--- as literals, so a value that SDL renumbers cannot silently point at the
--- wrong kind.
local KINDS <const>: {integer: string} = {}

local function map(name: string, kind: string)
    local value = C[name]
    if value == nil then return end
    KINDS[tonumber(value) as integer] = kind
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

--- Axis values arrive as signed 16-bit and are reported as -1..1.
local AXIS_SCALE <const> = 1.0 / 32767.0

-------------------------------------------------------------------------------
-- Conversion
-------------------------------------------------------------------------------

-- One record for the whole process. Handlers are called with it and must copy
-- anything they retain.
local scratch: Event = {} as Event

--- Window size, needed to scale SDL's normalised touch coordinates.
local touchWidth = 1.0
local touchHeight = 1.0

--- Tells the converter how large the window is, so touch positions arrive in
--- the same units as mouse positions rather than in SDL's 0..1.
function events.setTouchScale(width: number, height: number)
    touchWidth = width
    touchHeight = height
end

local function convert(raw: loader.CValue): Event
    local event = scratch
    local sdlType = tonumber(raw.type) as integer

    event.kind = KINDS[sdlType] or "unknown"
    event.sdlType = sdlType
    event.repeated = false
    event.finger = nil

    local kind = event.kind

    if kind == "keyDown" or kind == "keyUp" then
        local key = raw.key
        event.timestamp = tonumber(key.timestamp) as number
        event.scancode = tonumber(key.scancode) as integer
        event.repeated = key["repeat"] as boolean
    elseif kind == "mouseMotion" then
        local motion = raw.motion
        event.timestamp = tonumber(motion.timestamp) as number
        event.x = tonumber(motion.x) as number
        event.y = tonumber(motion.y) as number
        event.dx = tonumber(motion.xrel) as number
        event.dy = tonumber(motion.yrel) as number
    elseif kind == "mouseDown" or kind == "mouseUp" then
        local pressed = raw.button
        event.timestamp = tonumber(pressed.timestamp) as number
        event.button = tonumber(pressed.button) as integer
        event.x = tonumber(pressed.x) as number
        event.y = tonumber(pressed.y) as number
    elseif kind == "mouseWheel" then
        local wheel = raw.wheel
        event.timestamp = tonumber(wheel.timestamp) as number
        event.wheelX = tonumber(wheel.x) as number
        event.wheelY = tonumber(wheel.y) as number
        event.x = tonumber(wheel.mouse_x) as number
        event.y = tonumber(wheel.mouse_y) as number
    elseif kind == "fingerDown" or kind == "fingerUp" or kind == "fingerMotion" then
        local touch = raw.tfinger
        event.timestamp = tonumber(touch.timestamp) as number
        -- A finger id is 64 bits. Formatting it keeps the identity exact,
        -- where a Lua number would round and merge two fingers into one.
        event.finger = ("%s"):format(tostring(touch.fingerID))
        event.x = (tonumber(touch.x) as number) * touchWidth
        event.y = (tonumber(touch.y) as number) * touchHeight
        event.dx = (tonumber(touch.dx) as number) * touchWidth
        event.dy = (tonumber(touch.dy) as number) * touchHeight
        event.pressure = tonumber(touch.pressure) as number
    elseif kind == "controllerButtonDown" or kind == "controllerButtonUp" then
        local pad = raw.gbutton
        event.timestamp = tonumber(pad.timestamp) as number
        event.button = tonumber(pad.button) as integer
        event.which = tonumber(pad.which) as number
    elseif kind == "controllerAxis" then
        local pad = raw.gaxis
        event.timestamp = tonumber(pad.timestamp) as number
        event.axis = tonumber(pad.axis) as integer
        event.value = (tonumber(pad.value) as number) * AXIS_SCALE
        event.which = tonumber(pad.which) as number
    elseif kind == "controllerAdded" or kind == "controllerRemoved" then
        local device = raw.gdevice
        event.timestamp = tonumber(device.timestamp) as number
        event.which = tonumber(device.which) as number
    elseif kind:sub(1, 6) == "window" then
        local window = raw.window
        event.timestamp = tonumber(window.timestamp) as number
        event.data1 = tonumber(window.data1) as integer
        event.data2 = tonumber(window.data2) as integer
        event.which = tonumber(window.windowID) as number
    else
        event.timestamp = tonumber(raw.common.timestamp) as number
    end

    return event
end

--- Returns an independent copy, for code that must retain an event past the
--- handler that received it.
function events.copy(event: Event): Event
    local out: Event = {}
    for key, value in pairs(event as {string: any}) do
        (out as {string: any})[key] = value
    end
    return out
end

-------------------------------------------------------------------------------
-- Draining
-------------------------------------------------------------------------------

--- Converts and dispatches a queue of SDL events, in arrival order.
---
--- The host owns the queue and clears it; this only reads. A replay driver
--- installs `source` instead, which is handed the same handler and calls it
--- with recorded events.
function events.drain(queue: loader.CValue, count: integer,
                      handler: function(Event))
    local replay = events.source
    if replay ~= nil then
        replay(handler)
        return
    end

    if count == 0 or queue == nil then return end

    local events_ = ffi.cast(Cast, queue) as loader.CArray
    for index = 0, count - 1 do
        handler(convert(events_[index] as loader.CValue))
    end
end

--- Pushes a synthetic event onto SDL's own queue.
---
--- Takes the engine's vocabulary rather than an SDL union, so a test or a tool
--- can inject input without knowing SDL's layout. Only the fields a kind uses
--- are read.
function events.push(kind: string, fields: Event)
    local sdlType: integer = nil
    for value, name in pairs(KINDS) do
        if name == kind then sdlType = value break end
    end
    if sdlType == nil then
        error(("tecs2d: no event kind named '%s'"):format(tostring(kind)), 2)
    end

    local holder = loader.newArray("SDL_Event[1]")
    local raw = holder[0] as loader.CStruct
    raw.type = sdlType

    if fields ~= nil then
        if kind == "keyDown" or kind == "keyUp" then
            local key = (holder[0] as loader.CValue).key as loader.CStruct
            key.scancode = fields.scancode or 0
            key["repeat"] = fields.repeated == true
            key.down = kind == "keyDown"
        elseif kind == "mouseDown" or kind == "mouseUp" then
            local button = (holder[0] as loader.CValue).button as loader.CStruct
            button.button = fields.button or 1
            button.down = kind == "mouseDown"
            button.x = fields.x or 0.0
            button.y = fields.y or 0.0
        elseif kind == "mouseMotion" then
            local motion = (holder[0] as loader.CValue).motion as loader.CStruct
            motion.x = fields.x or 0.0
            motion.y = fields.y or 0.0
            motion.xrel = fields.dx or 0.0
            motion.yrel = fields.dy or 0.0
        end
    end

    sdl.check(C.SDL_PushEvent(holder[0]) as boolean, "SDL_PushEvent")
end

--- Every kind this build recognises, for tooling that enumerates them.
function events.kinds(): {string}
    local out: {string} = {}
    for _, name in pairs(KINDS) do out[#out + 1] = name end
    table.sort(out)
    return out
end

return events
