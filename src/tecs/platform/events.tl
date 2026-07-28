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
--- Events reach a game through the world's message bus, one ECS event type per
--- kind at address zero, so `world:observe(0, events.on.dropFile, handler)` is
--- how a drop is handled. See `KindTypes` for why the vocabulary is a type per
--- kind rather than one type carrying the kind.
---
--- Unrecognised SDL events arrive as `unknown` with their numeric type rather
--- than being dropped, so upgrading SDL surfaces new input instead of silently
--- losing it.
---
--- A recognised kind means usable fields. An event whose kind is named here
--- and whose payload was left unread would be worse than an unknown one: the
--- caller has every reason to trust it. Text, composition, drops and the
--- clipboard carry pointers, and SDL recycles what they point at as soon as
--- the callback returns, so the host copies those bytes into the queue it owns
--- and the conversion reads them from there.

local ffi <const> = require("ffi")
local ecs <const> = require("tecs.ecs")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

--- An event is also an ECS event, so the record a handler receives is the
--- record the message bus routes. `eventId` is the only field the bus reads,
--- and it is stamped just before an emit, which is what makes delivery to an
--- observer copy nothing.
local record Event is ecs.Event
    --- What happened. Determines which other fields mean anything.
    kind: string
    --- Nanoseconds since SDL started, as SDL reported it. That is the
    --- `SDL_GetTicksNS` epoch, which is not the clock `clock.now` reads, so it
    --- orders events against each other and against nothing else.
    timestamp: number
    --- Monotonic seconds on the clock `clock.now` reads, converted by the host
    --- from the stamp SDL put on the event when it produced it. Nil for an
    --- event that did not come through the host's queue, such as a replayed
    --- one.
    ---
    --- Not where the host was handed the event, which is a different and much
    --- kinder number: SDL only hands events over while the main thread is
    --- pumping, and most of what a player waits through is time the thread was
    --- doing something else. Dating an event from delivery would leave the
    --- measurement least trustworthy in exactly the frames worth catching.
    arrival: number

    --- Physical key position, which is what a movement binding wants: WASD
    --- stays in the same place on every layout.
    scancode: integer
    --- The key the layout produces, which is what a text binding and a prompt
    --- want. Both are carried, because neither answers the other's question.
    keycode: integer
    --- Modifier keys held when the key event was produced, as a mask.
    modifiers: integer
    --- True when the platform is repeating a held key rather than reporting a
    --- new press.
    repeated: boolean
    --- Whether the button or key this event describes went down.
    down: boolean

    --- Text committed by an input method, or being composed by one, or dropped
    --- onto the window.
    text: string
    --- Cursor position and selection length within composing text.
    start: integer
    length: integer
    --- Candidates an input method is offering, and which is selected. Nil when
    --- the platform offers none.
    candidates: {string}
    selected: integer
    --- Whether the platform lays its candidates out horizontally.
    horizontal: boolean

    --- Pointer position, in window coordinates.
    x: number
    y: number
    --- Movement since the previous event of this kind.
    dx: number
    dy: number
    --- Pointer position as the platform reported it, in 0..1 across the
    --- window. Touch is normalised at source, so it is carried through
    --- unscaled as well as converted: a normalised position survives a resize
    --- and a window coordinate does not.
    normalX: number
    normalY: number
    --- Mouse, gamepad or pen button.
    button: integer
    --- How many times this button was pressed in quick succession, as the
    --- platform counts it against its own double-click interval. One for a
    --- single click, two for a double, and up from there.
    clicks: integer
    --- Wheel movement, with one meaning whatever the platform is set to:
    --- positive `wheelY` is a scroll away from the player and positive
    --- `wheelX` is a scroll to the right. A platform reporting natural
    --- scrolling sends the opposite pair and flags it, and the conversion
    --- undoes that, so nothing above binds a sign twice.
    wheelX: number
    wheelY: number
    --- The same movement accumulated to whole notches by the platform, on the
    --- same sign convention. What a menu stepping one item per notch reads,
    --- rather than deciding for itself where a fraction of a notch becomes a
    --- step.
    wheelTicksX: integer
    wheelTicksY: integer
    --- Whether the wheel event being handed to `push` is one a platform with
    --- natural scrolling would send, which is what SDL's direction flag says
    --- and what the conversion undoes. Read only there: an event coming out
    --- of the conversion has had that applied already, so nothing above it
    --- has a flag to check.
    flipped: boolean
    --- Zoom factor a pinch gesture reports since the previous event in it.
    --- Below one is a pinch closed, above one is a pinch opened.
    scale: number
    --- Gamepad or pen axis, and its value in -1..1.
    axis: integer
    value: number
    --- How hard a finger is pressing, in 0..1, on a touch surface or a gamepad
    --- touchpad. A pen reports its pressure as an axis instead, so a pen event
    --- leaves this holding whatever the last touch put there.
    pressure: number
    --- Whether the pen's eraser end is in use.
    eraser: boolean
    --- Everything the pen was doing at the instant of the event, as a mask:
    --- the tip down, the eraser end in use, whether it is in proximity, and
    --- each barrel button. `eraser` and `down` answer for one stroke; this
    --- answers which barrel button is held right now. The bits are the
    --- platform's `SDL_PEN_INPUT_*` values. Not carried on the proximity
    --- events, which report no state.
    penState: integer

    --- Device that produced the event: a gamepad, a keyboard, a mouse, a pen,
    --- a sensor, a display, or a window. These identifiers are 32 bits and fit
    --- a Lua number exactly.
    which: number
    --- True when the platform produced this mouse event from a touch or a pen
    --- rather than from a mouse. A game that also handles touch would
    --- otherwise act on the same gesture twice.
    synthetic: boolean
    --- Touch finger identity, and the device it belongs to. Both are 64 bits
    --- and do not fit a double, so they are carried as opaque strings rather
    --- than numbers that might silently round.
    finger: string
    touchDevice: string
    --- Gamepad touchpad index and the finger's slot on it. A touchpad finger
    --- is identified by position on the device, not by a 64-bit id.
    touchpad: integer
    fingerIndex: integer

    --- Sensor identity and its most recent reading. A gamepad sensor reports
    --- three components; a standalone sensor reports up to six, and the rest
    --- arrive in `sensorData`.
    sensor: integer
    sensorX: number
    sensorY: number
    sensorZ: number
    sensorData: {number}
    --- When the hardware took the reading, in nanoseconds on the sensor's own
    --- clock. Like `timestamp` it orders readings against each other and
    --- against nothing else, which is what integrating a rotation over them
    --- needs and is all it is for.
    sensorTimestamp: number

    --- Where a dropped file or text came from, when the platform says.
    source: string
    --- Clipboard formats on offer.
    mimeTypes: {string}
    --- Whether the clipboard's new contents are this application's own.
    owner: boolean
    --- Whether an audio device is a recording device.
    recording: boolean

    --- Window, display and user payloads, as SDL reports them. A user event's
    --- code arrives in `data1`; the two data pointers beside it do not cross,
    --- since a pointer is not a value this vocabulary can carry.
    data1: integer
    data2: integer

    --- Numeric SDL type, set on every event and the only useful field on
    --- `unknown`.
    sdlType: integer
end

--- One ECS event type per kind, to observe at address zero.
---
--- A game asks for the kinds it wants rather than for the stream:
--- `world:observe(0, events.on.dropFile, handler)` is called for dropped files
--- and for nothing else. That is what a type per kind buys over one type
--- carrying the kind, where every subscriber is handed every kind and filters
--- it back out again.
---
--- Written as a record rather than looked up by name, so a misspelled kind is
--- a compile error on the key instead of an observer that is never called.
--- `events.typeOf` is the same table for code holding a kind as a string.
---
--- The record an observer receives is the reused one, so the borrow rule is
--- the one this module states everywhere: read it, or copy it with
--- `events.copy`, but do not keep it.
local record KindTypes
    quit: Event
    terminating: Event
    lowMemory: Event
    appWillEnterBackground: Event
    appDidEnterBackground: Event
    appWillEnterForeground: Event
    appDidEnterForeground: Event
    localeChanged: Event
    themeChanged: Event
    displayOrientation: Event
    displayAdded: Event
    displayRemoved: Event
    displayMoved: Event
    displayScaleChanged: Event
    displayDesktopModeChanged: Event
    displayCurrentModeChanged: Event
    displayUsableBoundsChanged: Event
    windowShown: Event
    windowHidden: Event
    windowExposed: Event
    windowMoved: Event
    windowResized: Event
    windowPixelSizeChanged: Event
    windowMinimized: Event
    windowMaximized: Event
    windowRestored: Event
    windowMouseEnter: Event
    windowMouseLeave: Event
    windowFocusGained: Event
    windowFocusLost: Event
    windowCloseRequested: Event
    windowDisplayChanged: Event
    windowDisplayScaleChanged: Event
    windowSafeAreaChanged: Event
    windowOccluded: Event
    windowEnterFullscreen: Event
    windowLeaveFullscreen: Event
    keyDown: Event
    keyUp: Event
    textEditing: Event
    textCandidates: Event
    textInput: Event
    keymapChanged: Event
    keyboardAdded: Event
    keyboardRemoved: Event
    screenKeyboardShown: Event
    screenKeyboardHidden: Event
    mouseMotion: Event
    mouseDown: Event
    mouseUp: Event
    mouseWheel: Event
    mouseAdded: Event
    mouseRemoved: Event
    fingerDown: Event
    fingerUp: Event
    fingerMotion: Event
    fingerCanceled: Event
    pinchBegin: Event
    pinchUpdate: Event
    pinchEnd: Event
    penProximityIn: Event
    penProximityOut: Event
    penDown: Event
    penUp: Event
    penMotion: Event
    penButtonDown: Event
    penButtonUp: Event
    penAxis: Event
    gamepadAdded: Event
    gamepadRemoved: Event
    gamepadRemapped: Event
    gamepadButtonDown: Event
    gamepadButtonUp: Event
    gamepadAxis: Event
    gamepadSensor: Event
    gamepadTouchpadDown: Event
    gamepadTouchpadUp: Event
    gamepadTouchpadMotion: Event
    dropFile: Event
    dropText: Event
    dropBegin: Event
    dropComplete: Event
    dropPosition: Event
    clipboardUpdate: Event
    audioDeviceAdded: Event
    audioDeviceRemoved: Event
    audioDeviceFormatChanged: Event
    sensorUpdate: Event
    user: Event
    --- An SDL event this build has no name for. Carries `sdlType` and nothing
    --- else worth reading.
    unknown: Event
end

local record events
    --- One event, discriminated by `kind`. The record handed to a handler is
    --- reused, so anything retaining one takes a copy through `events.copy`.
    Event: Event
    --- Installed by a replay driver. Called instead of draining the host
    --- queue, and expected to invoke the handler for each recorded event.
    source: function(handler: function(Event))

    --- One ECS event type per kind, to observe at address zero. See
    --- `KindTypes`.
    on: KindTypes
    --- The event type for a kind, or nil for a name this build does not know.
    ---
    --- What `on` is for code holding a kind it cannot spell in source, which
    --- is the conversion itself and the debug tools.
    typeOf: function(kind: string): Event
end

local Cast <const> = "SDL_Event *"
local StampCast <const> = "uint64_t *"

-------------------------------------------------------------------------------
-- Kind mapping
-------------------------------------------------------------------------------

--- SDL event type to kind name. Built once from the enum rather than written
--- as literals, so a value that SDL renumbers cannot silently point at the
--- wrong kind.
local KINDS <const>: {integer: string} = {}

--- Kind name to the ECS event type it is observed through. The same tables
--- `events.on` names, reachable by a name that is only known at run time.
local TYPES <const>: {string: Event} = {}

--- Registers the event type for a kind.
---
--- One per kind rather than one for the stream, because a subscription is
--- worth no more than what it excludes. The type is a table with an id on it
--- and nothing else: the payload stays the one wide record above, so a hundred
--- types cost a hundred integers and no per-event work.
local function declare(kind: string): Event
    local eventType = {} as Event
    ecs.newEvent(eventType)
    TYPES[kind] = eventType
    return eventType
end

local function map(name: string, kind: string)
    local value = C[name]
    if value == nil then
        return
    end
    KINDS[tonumber(value) as integer] = kind
    declare(kind)
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
map("SDL_EVENT_DISPLAY_MOVED", "displayMoved")
map("SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED", "displayScaleChanged")
map("SDL_EVENT_DISPLAY_DESKTOP_MODE_CHANGED", "displayDesktopModeChanged")
map("SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED", "displayCurrentModeChanged")
map("SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED", "displayUsableBoundsChanged")

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
map("SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED", "windowDisplayScaleChanged")
map("SDL_EVENT_WINDOW_SAFE_AREA_CHANGED", "windowSafeAreaChanged")
map("SDL_EVENT_WINDOW_OCCLUDED", "windowOccluded")
map("SDL_EVENT_WINDOW_ENTER_FULLSCREEN", "windowEnterFullscreen")
map("SDL_EVENT_WINDOW_LEAVE_FULLSCREEN", "windowLeaveFullscreen")

map("SDL_EVENT_KEY_DOWN", "keyDown")
map("SDL_EVENT_KEY_UP", "keyUp")
map("SDL_EVENT_TEXT_EDITING", "textEditing")
map("SDL_EVENT_TEXT_EDITING_CANDIDATES", "textCandidates")
map("SDL_EVENT_TEXT_INPUT", "textInput")
map("SDL_EVENT_KEYMAP_CHANGED", "keymapChanged")
map("SDL_EVENT_KEYBOARD_ADDED", "keyboardAdded")
map("SDL_EVENT_KEYBOARD_REMOVED", "keyboardRemoved")
map("SDL_EVENT_SCREEN_KEYBOARD_SHOWN", "screenKeyboardShown")
map("SDL_EVENT_SCREEN_KEYBOARD_HIDDEN", "screenKeyboardHidden")

map("SDL_EVENT_MOUSE_MOTION", "mouseMotion")
map("SDL_EVENT_MOUSE_BUTTON_DOWN", "mouseDown")
map("SDL_EVENT_MOUSE_BUTTON_UP", "mouseUp")
map("SDL_EVENT_MOUSE_WHEEL", "mouseWheel")
map("SDL_EVENT_MOUSE_ADDED", "mouseAdded")
map("SDL_EVENT_MOUSE_REMOVED", "mouseRemoved")

map("SDL_EVENT_FINGER_DOWN", "fingerDown")
map("SDL_EVENT_FINGER_UP", "fingerUp")
map("SDL_EVENT_FINGER_MOTION", "fingerMotion")
map("SDL_EVENT_FINGER_CANCELED", "fingerCanceled")

map("SDL_EVENT_PINCH_BEGIN", "pinchBegin")
map("SDL_EVENT_PINCH_UPDATE", "pinchUpdate")
map("SDL_EVENT_PINCH_END", "pinchEnd")

map("SDL_EVENT_PEN_PROXIMITY_IN", "penProximityIn")
map("SDL_EVENT_PEN_PROXIMITY_OUT", "penProximityOut")
map("SDL_EVENT_PEN_DOWN", "penDown")
map("SDL_EVENT_PEN_UP", "penUp")
map("SDL_EVENT_PEN_MOTION", "penMotion")
map("SDL_EVENT_PEN_BUTTON_DOWN", "penButtonDown")
map("SDL_EVENT_PEN_BUTTON_UP", "penButtonUp")
map("SDL_EVENT_PEN_AXIS", "penAxis")

map("SDL_EVENT_GAMEPAD_ADDED", "gamepadAdded")
map("SDL_EVENT_GAMEPAD_REMOVED", "gamepadRemoved")
map("SDL_EVENT_GAMEPAD_REMAPPED", "gamepadRemapped")
map("SDL_EVENT_GAMEPAD_BUTTON_DOWN", "gamepadButtonDown")
map("SDL_EVENT_GAMEPAD_BUTTON_UP", "gamepadButtonUp")
map("SDL_EVENT_GAMEPAD_AXIS_MOTION", "gamepadAxis")
map("SDL_EVENT_GAMEPAD_SENSOR_UPDATE", "gamepadSensor")
map("SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN", "gamepadTouchpadDown")
map("SDL_EVENT_GAMEPAD_TOUCHPAD_UP", "gamepadTouchpadUp")
map("SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION", "gamepadTouchpadMotion")

map("SDL_EVENT_DROP_FILE", "dropFile")
map("SDL_EVENT_DROP_TEXT", "dropText")
map("SDL_EVENT_DROP_BEGIN", "dropBegin")
map("SDL_EVENT_DROP_COMPLETE", "dropComplete")
map("SDL_EVENT_DROP_POSITION", "dropPosition")

map("SDL_EVENT_CLIPBOARD_UPDATE", "clipboardUpdate")
map("SDL_EVENT_AUDIO_DEVICE_ADDED", "audioDeviceAdded")
map("SDL_EVENT_AUDIO_DEVICE_REMOVED", "audioDeviceRemoved")
map("SDL_EVENT_AUDIO_DEVICE_FORMAT_CHANGED", "audioDeviceFormatChanged")
map("SDL_EVENT_SENSOR_UPDATE", "sensorUpdate")
map("SDL_EVENT_USER", "user")

-- Not in the table above, since nothing maps to it: it is what a kind becomes
-- when this build has no name for the SDL type.
declare("unknown")

events.on = TYPES as KindTypes

--- The event type for a kind, or nil for a name this build does not know.
function events.typeOf(kind: string): Event
    return TYPES[kind]
end

--- Axis values arrive as signed 16-bit and are reported as -1..1.
local AXIS_SCALE <const> = 1.0 / 32767.0

--- The direction a wheel event carries when the platform has natural
--- scrolling on, which means both of its axes are the opposite of what they
--- read as, and the direction it carries otherwise.
local WHEEL_FLIPPED <const> = tonumber(C.SDL_MOUSEWHEEL_FLIPPED) as integer
local WHEEL_NORMAL <const> = tonumber(C.SDL_MOUSEWHEEL_NORMAL) as integer

--- Kinds a player produces, as against ones the platform reports about
--- itself. Latency is only meaningful for these: nobody is waiting on a
--- window expose.
local INPUT <const>: {string: boolean} = {
    keyDown = true,
    keyUp = true,
    textInput = true,
    textEditing = true,
    mouseMotion = true,
    mouseDown = true,
    mouseUp = true,
    mouseWheel = true,
    fingerDown = true,
    fingerUp = true,
    fingerMotion = true,
    pinchBegin = true,
    pinchUpdate = true,
    pinchEnd = true,
    penDown = true,
    penUp = true,
    penMotion = true,
    penButtonDown = true,
    penButtonUp = true,
    penAxis = true,
    gamepadButtonDown = true,
    gamepadButtonUp = true,
    gamepadAxis = true,
    gamepadTouchpadDown = true,
    gamepadTouchpadUp = true,
    gamepadTouchpadMotion = true,
}

--- Whether a kind carries player input rather than describing the platform.
function events.isInput(kind: string): boolean
    return INPUT[kind] == true
end

-------------------------------------------------------------------------------
-- Conversion
-------------------------------------------------------------------------------

-- One record for the whole process. Handlers are called with it and must copy
-- anything they retain.
local scratch: Event = {} as Event

--- Window size in the units mouse positions arrive in, needed to convert SDL's
--- normalised touch coordinates.
---
--- Logical window size, not pixels: a mouse position is in window coordinates,
--- and scaling touch by the pixel size would put the two pointers in different
--- units on every high-density display.
local touchWidth = 1.0
local touchHeight = 1.0

--- Ticks per second on the counter the host stamps arrivals with. Read once,
--- since it is fixed for the life of the process.
local counterFrequency = 0.0

--- Mouse identifiers the platform uses for events it generated from something
--- that is not a mouse. Read once, since they are compile-time constants.
local TOUCH_MOUSE <const> = sdl.K.SDL_TOUCH_MOUSEID
local PEN_MOUSE <const> = sdl.K.SDL_PEN_MOUSEID

--- Tells the converter how large the window is, so touch positions arrive in
--- the same units as mouse positions as well as in the platform's own 0..1.
function events.setTouchScale(width: number, height: number)
    touchWidth = width
    touchHeight = height
end

--- Copies a C array of strings out, so nothing above holds a pointer.
local function strings(array: loader.CValue, count: integer): {string}
    if array == nil or count == nil or count <= 0 then
        return nil
    end
    local out: {string} = {}
    local items = array as loader.CArray
    for index = 0, count - 1 do
        out[index + 1] = loader.toString(items[index] as loader.CValue)
    end
    return out
end

--- Fields the reused record must not carry over.
---
--- The kind decides which fields mean anything, and a stale number is only
--- read by code that ignored that. A stale string, table or flag is different:
--- it reads as present, and a handler that checks `event.text ~= nil` or
--- `event.eraser` would act on the previous event's payload. So the fields
--- that answer a question by existing are cleared every time.
local function reset(event: Event)
    event.repeated = false
    event.synthetic = false
    event.down = false
    event.eraser = false
    event.arrival = nil
    event.finger = nil
    event.touchDevice = nil
    event.text = nil
    event.source = nil
    event.candidates = nil
    event.mimeTypes = nil
    event.sensorData = nil
end

local function convert(raw: loader.CValue): Event
    local event = scratch
    local sdlType = tonumber(raw.type) as integer

    event.kind = KINDS[sdlType] or "unknown"
    event.sdlType = sdlType
    reset(event)

    local kind = event.kind

    if kind == "keyDown" or kind == "keyUp" then
        local key = raw.key
        event.timestamp = tonumber(key.timestamp) as number
        event.scancode = tonumber(key.scancode) as integer
        event.keycode = tonumber(key.key) as integer
        event.modifiers = tonumber(key.mod) as integer
        event.repeated = key["repeat"] as boolean
        event.down = key.down as boolean
        event.which = tonumber(key.which) as number
    elseif kind == "mouseMotion" then
        local motion = raw.motion
        event.timestamp = tonumber(motion.timestamp) as number
        event.x = tonumber(motion.x) as number
        event.y = tonumber(motion.y) as number
        event.dx = tonumber(motion.xrel) as number
        event.dy = tonumber(motion.yrel) as number
        event.which = tonumber(motion.which) as number
        event.synthetic = event.which == TOUCH_MOUSE or event.which == PEN_MOUSE
    elseif kind == "mouseDown" or kind == "mouseUp" then
        local pressed = raw.button
        event.timestamp = tonumber(pressed.timestamp) as number
        event.button = tonumber(pressed.button) as integer
        -- The platform already counted the run against its own double-click
        -- interval, which is the interval the player set and the one every
        -- other application on the machine uses.
        event.clicks = tonumber(pressed.clicks) as integer
        event.x = tonumber(pressed.x) as number
        event.y = tonumber(pressed.y) as number
        event.down = pressed.down as boolean
        event.which = tonumber(pressed.which) as number
        event.synthetic = event.which == TOUCH_MOUSE or event.which == PEN_MOUSE
    elseif kind == "mouseWheel" then
        local wheel = raw.wheel
        event.timestamp = tonumber(wheel.timestamp) as number
        -- Natural scrolling is reported rather than applied: the platform
        -- sends both axes negated and sets the flag. Undoing it here is what
        -- lets everything above mean one thing by a positive scroll, instead
        -- of each reader learning that the flag exists and half of them not.
        local flipped = (tonumber(wheel.direction) as integer) == WHEEL_FLIPPED
        local wheelX = tonumber(wheel.x) as number
        local wheelY = tonumber(wheel.y) as number
        local ticksX = tonumber(wheel.integer_x) as integer
        local ticksY = tonumber(wheel.integer_y) as integer
        if flipped then
            wheelX, wheelY = -wheelX, -wheelY
            ticksX, ticksY = -ticksX, -ticksY
        end
        event.wheelX = wheelX
        event.wheelY = wheelY
        event.wheelTicksX = ticksX
        event.wheelTicksY = ticksY
        event.x = tonumber(wheel.mouse_x) as number
        event.y = tonumber(wheel.mouse_y) as number
        event.which = tonumber(wheel.which) as number
        event.synthetic = event.which == TOUCH_MOUSE or event.which == PEN_MOUSE
    elseif kind == "mouseAdded" or kind == "mouseRemoved" then
        local device = raw.mdevice
        event.timestamp = tonumber(device.timestamp) as number
        event.which = tonumber(device.which) as number
    elseif kind == "keyboardAdded" or kind == "keyboardRemoved" then
        local device = raw.kdevice
        event.timestamp = tonumber(device.timestamp) as number
        event.which = tonumber(device.which) as number
    elseif kind == "fingerDown" or kind == "fingerUp" or kind == "fingerMotion" or kind == "fingerCanceled" then
        local touch = raw.tfinger
        event.timestamp = tonumber(touch.timestamp) as number
        -- A finger id and a touch device id are both 64 bits. Formatting them
        -- keeps each identity exact, where a Lua number would round and merge
        -- two fingers into one.
        event.finger = ("%s"):format(tostring(touch.fingerID))
        event.touchDevice = ("%s"):format(tostring(touch.touchID))
        event.normalX = tonumber(touch.x) as number
        event.normalY = tonumber(touch.y) as number
        event.x = event.normalX * touchWidth
        event.y = event.normalY * touchHeight
        event.dx = (tonumber(touch.dx) as number) * touchWidth
        event.dy = (tonumber(touch.dy) as number) * touchHeight
        event.pressure = tonumber(touch.pressure) as number
        event.down = kind == "fingerDown"
    elseif kind:sub(1, 5) == "pinch" then
        local gesture = raw.pinch
        event.timestamp = tonumber(gesture.timestamp) as number
        event.which = tonumber(gesture.windowID) as number
        event.scale = tonumber(gesture.scale) as number
    elseif kind == "textInput" then
        local typed = raw.text
        event.timestamp = tonumber(typed.timestamp) as number
        event.text = loader.toString(typed.text)
        event.which = tonumber(typed.windowID) as number
    elseif kind == "textEditing" then
        local editing = raw.edit
        event.timestamp = tonumber(editing.timestamp) as number
        event.text = loader.toString(editing.text)
        event.start = tonumber(editing.start) as integer
        event.length = tonumber(editing.length) as integer
        event.which = tonumber(editing.windowID) as number
    elseif kind == "textCandidates" then
        local offered = raw.edit_candidates
        event.timestamp = tonumber(offered.timestamp) as number
        event.candidates = strings(offered.candidates as loader.CValue, tonumber(offered.num_candidates) as integer)
        event.selected = tonumber(offered.selected_candidate) as integer
        event.horizontal = offered.horizontal as boolean
        event.which = tonumber(offered.windowID) as number
    elseif kind:sub(1, 3) == "pen" then
        -- Every pen event shares a prefix, so the position and the device are
        -- read once and only the tail differs.
        local pen = raw.pmotion
        event.timestamp = tonumber(pen.timestamp) as number
        event.which = tonumber(pen.which) as number
        if kind ~= "penProximityIn" and kind ~= "penProximityOut" then
            event.x = tonumber(pen.x) as number
            event.y = tonumber(pen.y) as number
            -- The whole of what the pen was doing when this happened, which
            -- is the only field that answers which barrel button is held.
            -- A proximity event carries no state, hence the guard.
            event.penState = tonumber(pen.pen_state) as integer
        end
        if kind == "penDown" or kind == "penUp" then
            event.eraser = raw.ptouch.eraser as boolean
            event.down = raw.ptouch.down as boolean
        elseif kind == "penButtonDown" or kind == "penButtonUp" then
            event.button = tonumber(raw.pbutton.button) as integer
            event.down = raw.pbutton.down as boolean
        elseif kind == "penAxis" then
            event.axis = tonumber(raw.paxis.axis) as integer
            event.value = tonumber(raw.paxis.value) as number
        end
    elseif kind == "gamepadButtonDown" or kind == "gamepadButtonUp" then
        local pad = raw.gbutton
        event.timestamp = tonumber(pad.timestamp) as number
        event.button = tonumber(pad.button) as integer
        event.which = tonumber(pad.which) as number
        event.down = pad.down as boolean
    elseif kind == "gamepadAxis" then
        local pad = raw.gaxis
        event.timestamp = tonumber(pad.timestamp) as number
        event.axis = tonumber(pad.axis) as integer
        event.value = (tonumber(pad.value) as number) * AXIS_SCALE
        event.which = tonumber(pad.which) as number
    elseif kind == "gamepadSensor" then
        local reading = raw.gsensor
        event.timestamp = tonumber(reading.timestamp) as number
        event.which = tonumber(reading.which) as number
        event.sensor = tonumber(reading.sensor) as integer
        event.sensorTimestamp = tonumber(reading.sensor_timestamp) as number
        local data = reading.data as loader.CArray
        event.sensorX = tonumber(data[0]) as number
        event.sensorY = tonumber(data[1]) as number
        event.sensorZ = tonumber(data[2]) as number
    elseif kind == "gamepadTouchpadDown" or kind == "gamepadTouchpadUp" or kind == "gamepadTouchpadMotion" then
        local pad = raw.gtouchpad
        event.timestamp = tonumber(pad.timestamp) as number
        event.which = tonumber(pad.which) as number
        event.touchpad = tonumber(pad.touchpad) as integer
        event.fingerIndex = tonumber(pad.finger) as integer
        event.normalX = tonumber(pad.x) as number
        event.normalY = tonumber(pad.y) as number
        event.pressure = tonumber(pad.pressure) as number
        event.down = kind ~= "gamepadTouchpadUp"
    elseif kind == "gamepadAdded" or kind == "gamepadRemoved" or kind == "gamepadRemapped" then
        local device = raw.gdevice
        event.timestamp = tonumber(device.timestamp) as number
        event.which = tonumber(device.which) as number
    elseif kind == "sensorUpdate" then
        local reading = raw.sensor
        event.timestamp = tonumber(reading.timestamp) as number
        event.which = tonumber(reading.which) as number
        event.sensorTimestamp = tonumber(reading.sensor_timestamp) as number
        local data = reading.data as loader.CArray
        event.sensorX = tonumber(data[0]) as number
        event.sensorY = tonumber(data[1]) as number
        event.sensorZ = tonumber(data[2]) as number
        -- A standalone sensor reports six components where a gamepad reports
        -- three, so the whole reading is carried as well as the first three.
        event.sensorData = {
            event.sensorX,
            event.sensorY,
            event.sensorZ,
            tonumber(data[3]) as number,
            tonumber(data[4]) as number,
            tonumber(data[5]) as number,
        }
    elseif kind:sub(1, 4) == "drop" then
        local dropped = raw.drop
        event.timestamp = tonumber(dropped.timestamp) as number
        event.text = loader.toString(dropped.data)
        event.source = loader.toString(dropped.source)
        event.x = tonumber(dropped.x) as number
        event.y = tonumber(dropped.y) as number
        event.which = tonumber(dropped.windowID) as number
    elseif kind == "clipboardUpdate" then
        local clipboard = raw.clipboard
        event.timestamp = tonumber(clipboard.timestamp) as number
        event.owner = clipboard.owner as boolean
        event.mimeTypes = strings(clipboard.mime_types as loader.CValue, tonumber(clipboard.num_mime_types) as integer)
    elseif kind:sub(1, 11) == "audioDevice" then
        local device = raw.adevice
        event.timestamp = tonumber(device.timestamp) as number
        event.which = tonumber(device.which) as number
        event.recording = device.recording as boolean
    elseif kind:sub(1, 6) == "window" then
        local window = raw.window
        event.timestamp = tonumber(window.timestamp) as number
        event.data1 = tonumber(window.data1) as integer
        event.data2 = tonumber(window.data2) as integer
        event.which = tonumber(window.windowID) as number
    elseif kind:sub(1, 7) == "display" then
        -- The display an event is about is its whole subject, so a display
        -- event that did not carry one would name a change on a machine with
        -- two monitors without saying which of them changed.
        local display = raw.display
        event.timestamp = tonumber(display.timestamp) as number
        event.data1 = tonumber(display.data1) as integer
        event.data2 = tonumber(display.data2) as integer
        event.which = tonumber(display.displayID) as number
    elseif kind == "user" then
        local pushed = raw.user
        event.timestamp = tonumber(pushed.timestamp) as number
        event.data1 = tonumber(pushed.code) as integer
        event.which = tonumber(pushed.windowID) as number
    else
        event.timestamp = tonumber(raw.common.timestamp) as number
    end

    return event
end

--- Returns an independent copy, for code that must retain an event past the
--- handler that received it.
---
--- Shallow, which is enough because every field is a number, a string or a
--- boolean except the three lists, and those are freshly built per event
--- rather than reused. Allocates, so this is for the events a recorder or a
--- tool keeps and not for the stream.
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
---
--- `arrivals` is the host's parallel array of performance counter readings,
--- one per event, converted there from the stamp SDL put on each event as it
--- was produced. Given it, every converted event carries `arrival` in the
--- units `clock.now` reports.
function events.drain(queue: loader.CValue, count: integer, handler: function(Event), arrivals?: loader.CValue)
    local replay = events.source
    if replay ~= nil then
        replay(handler)
        return
    end

    if count == 0 or queue == nil then
        return
    end

    local stamps: loader.CArray = nil
    if arrivals ~= nil then
        if counterFrequency == 0.0 then
            counterFrequency = tonumber(C.SDL_GetPerformanceFrequency()) as number
        end
        stamps = ffi.cast(StampCast, arrivals) as loader.CArray
    end

    local queued = ffi.cast(Cast, queue) as loader.CArray
    for index = 0, count - 1 do
        local event = convert(queued[index] as loader.CValue)
        if stamps ~= nil then
            event.arrival = (tonumber(stamps[index]) as number) / counterFrequency
        end
        handler(event)
    end
end

--- Pushes a synthetic event onto SDL's own queue.
---
--- Takes the engine's vocabulary rather than an SDL union, so a test or a tool
--- can inject input without knowing SDL's layout. Only the fields a kind uses
--- are read.
---
--- Payloads are filled for the key, mouse, wheel, pen, gamepad, device, pinch,
--- window and display kinds. Any other recognised kind is pushed carrying its
--- type and nothing else, which is what a kind whose payload nobody injects
--- needs and is not what a caller expecting a full event would assume.
---
--- A wheel payload is written the way the platform writes one, so `flipped`
--- sets the direction and the axes beside it are left as given. The conversion
--- then negates them, which is what a caller asking for a flipped scroll is
--- asking to see: the round trip is the normalisation, not the identity.
---
--- SDL stamps the timestamp, so a pushed event arrives ordered against real
--- ones rather than ahead of them.
--- @param kind One of `events.kinds()`. An unrecognised name raises.
function events.push(kind: string, fields: Event)
    local sdlType: integer = nil
    for value, name in pairs(KINDS) do
        if name == kind then
            sdlType = value
            break
        end
    end
    if sdlType == nil then
        error(("tecs: no event kind named '%s'"):format(tostring(kind)), 2)
    end

    local holder = loader.newArray("SDL_Event[1]")
    local raw = holder[0] as loader.CStruct
    raw.type = sdlType

    if fields ~= nil then
        if kind == "keyDown" or kind == "keyUp" then
            local key = (holder[0] as loader.CValue).key as loader.CStruct
            key.scancode = fields.scancode or 0
            key.key = fields.keycode or 0
            key.mod = fields.modifiers or 0
            key["repeat"] = fields.repeated == true
            key.down = kind == "keyDown"
        elseif kind == "mouseDown" or kind == "mouseUp" then
            local button = (holder[0] as loader.CValue).button as loader.CStruct
            button.button = fields.button or 1
            button.down = kind == "mouseDown"
            -- A press nobody counted is still one press. Zero would say the
            -- platform saw the button go down and counted no click.
            button.clicks = fields.clicks or 1
            button.x = fields.x or 0.0
            button.y = fields.y or 0.0
            button.which = fields.which or 0
        elseif kind == "mouseMotion" then
            local motion = (holder[0] as loader.CValue).motion as loader.CStruct
            motion.x = fields.x or 0.0
            motion.y = fields.y or 0.0
            motion.xrel = fields.dx or 0.0
            motion.yrel = fields.dy or 0.0
            motion.which = fields.which or 0
        elseif kind == "mouseWheel" then
            local wheel = (holder[0] as loader.CValue).wheel as loader.CStruct
            -- Written unnegated whichever direction this carries, because
            -- that is what the platform sends and the conversion is what
            -- reads the flag. A scroll pushed without one is an ordinary one.
            local direction = WHEEL_NORMAL
            if fields.flipped == true then
                direction = WHEEL_FLIPPED
            end
            wheel.direction = direction
            wheel.x = fields.wheelX or 0.0
            wheel.y = fields.wheelY or 0.0
            wheel.integer_x = fields.wheelTicksX or 0
            wheel.integer_y = fields.wheelTicksY or 0
            wheel.mouse_x = fields.x or 0.0
            wheel.mouse_y = fields.y or 0.0
            wheel.which = fields.which or 0
        elseif kind:sub(1, 3) == "pen" then
            -- Every pen event shares a prefix, so the position and the state
            -- are written once and only the tail differs. A proximity event
            -- has neither, which is why the guard matches the conversion's.
            local union = holder[0] as loader.CValue
            local pen = union.pmotion as loader.CStruct
            pen.which = fields.which or 0
            if kind ~= "penProximityIn" and kind ~= "penProximityOut" then
                pen.x = fields.x or 0.0
                pen.y = fields.y or 0.0
                pen.pen_state = fields.penState or 0
            end
            if kind == "penDown" or kind == "penUp" then
                local touch = union.ptouch as loader.CStruct
                touch.eraser = fields.eraser == true
                touch.down = kind == "penDown"
            elseif kind == "penButtonDown" or kind == "penButtonUp" then
                local pressed = union.pbutton as loader.CStruct
                pressed.button = fields.button or 0
                pressed.down = kind == "penButtonDown"
            elseif kind == "penAxis" then
                local axis = union.paxis as loader.CStruct
                axis.axis = fields.axis or 0
                axis.value = fields.value or 0.0
            end
        elseif kind == "gamepadButtonDown" or kind == "gamepadButtonUp" then
            local pad = (holder[0] as loader.CValue).gbutton as loader.CStruct
            pad.button = fields.button or 0
            pad.which = fields.which or 0
            pad.down = kind == "gamepadButtonDown"
        elseif kind == "gamepadAxis" then
            local pad = (holder[0] as loader.CValue).gaxis as loader.CStruct
            pad.axis = fields.axis or 0
            pad.which = fields.which or 0
            pad.value = math.floor((fields.value or 0.0) * 32767.0 + 0.5)
        elseif kind == "mouseAdded" or kind == "mouseRemoved" then
            local device = (holder[0] as loader.CValue).mdevice as loader.CStruct
            device.which = fields.which or 0
        elseif kind == "keyboardAdded" or kind == "keyboardRemoved" then
            local device = (holder[0] as loader.CValue).kdevice as loader.CStruct
            device.which = fields.which or 0
        elseif kind:sub(1, 11) == "audioDevice" then
            local device = (holder[0] as loader.CValue).adevice as loader.CStruct
            device.which = fields.which or 0
            device.recording = fields.recording == true
        elseif kind:sub(1, 5) == "pinch" then
            local gesture = (holder[0] as loader.CValue).pinch as loader.CStruct
            gesture.windowID = fields.which or 0
            -- One is the neutral factor, so a pinch pushed without a scale
            -- reads as a gesture that has not moved rather than as one that
            -- collapsed the view to nothing.
            gesture.scale = fields.scale or 1.0
        elseif kind:sub(1, 6) == "window" then
            local window = (holder[0] as loader.CValue).window as loader.CStruct
            window.windowID = fields.which or 0
            window.data1 = fields.data1 or 0
            window.data2 = fields.data2 or 0
        elseif kind:sub(1, 7) == "display" then
            local display = (holder[0] as loader.CValue).display as loader.CStruct
            display.displayID = fields.which or 0
            display.data1 = fields.data1 or 0
            display.data2 = fields.data2 or 0
        end
    end

    sdl.check(C.SDL_PushEvent(holder[0]) as boolean, "SDL_PushEvent")
end

--- Every kind this build recognises, for tooling that enumerates them.
function events.kinds(): {string}
    local out: {string} = {}
    for _, name in pairs(KINDS) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

return events
