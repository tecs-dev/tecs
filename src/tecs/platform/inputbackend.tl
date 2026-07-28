--- The device half of the platform seam, in both directions.
---
--- The event stream carries input *in*. Rumble, LED, cursor modes and text
--- input go the other way: they are commands a game issues and the platform
--- carries out, and nothing in the typed event vocabulary can express them. So
--- the seam has a second face, and this is it.
---
--- `Input` and `Gamepad` hold a backend and never reach the FFI themselves. A
--- port supplies one of these and touches nothing above it; the SDL
--- implementation below is the worked example, and the only thing in the input
--- layer that names an SDL symbol.
---
--- Names are resolved here too. "south" and "leftShoulder" are the engine's
--- vocabulary, not SDL's, but the numbers behind them are the platform's, so a
--- port that numbers its buttons differently answers differently and every
--- query above keeps working.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- What a device reports about itself, read once when it is opened.
---
--- Read at open and on a remap, never per query: polling the device for
--- metadata every frame would be work nobody asked for, and the answers only
--- change when the device does.
local record GamepadInfo
    --- SDL instance id. Unique while the device is attached.
    id: number
    --- What the platform calls the device. For showing the player which pad is
    --- which, not for matching: `guid` is what survives a driver change.
    name: string
    --- Device family, as the platform recognises it: "xboxOne", "ps5",
    --- "switchPro", "standard", "unknown" and so on.
    kind: string
    --- Stable identity for the hardware, for matching saved bindings.
    guid: string
    --- Where the platform says the device is attached. Empty when it declines
    --- to say.
    path: string
    --- Player slot the platform assigned, or -1 for none.
    playerIndex: integer
    --- Touchpads the device carries.
    touchpads: integer
end

local record Backend
    --- Name this backend reports as. For diagnostics; it is not matched
    --- against.
    name: string

    ---------------------------------------------------------------- devices

    --- Instance ids of every gamepad attached right now, in the platform's
    --- own order.
    attachedGamepads: function(): {number}
    --- Opens a gamepad by instance id. Nil when the device will not open.
    openGamepad: function(id: number): loader.CPtr
    --- Closes a handle `openGamepad` returned. Called exactly once per handle.
    closeGamepad: function(handle: loader.CPtr)
    --- Everything the device says about itself.
    gamepadInfo: function(handle: loader.CPtr, id: number): GamepadInfo
    --- Whether the device carries a control at all, which is what lets a
    --- prompt be omitted rather than shown for something the player does not
    --- have. Asked of the device, so a pad with no right stick says so.
    gamepadHasButton: function(handle: loader.CPtr, button: integer): boolean
    gamepadHasAxis: function(handle: loader.CPtr, axis: integer): boolean
    gamepadHasSensor: function(handle: loader.CPtr, sensor: integer): boolean
    --- The label printed on a button, for UI. Positional names identify a
    --- button; this is what the player sees on the hardware.
    gamepadButtonLabel: function(handle: loader.CPtr, button: integer): string
    --- Power state name and charge percentage, or -1 when unknown.
    gamepadPower: function(handle: loader.CPtr): string, integer
    --- Turns a sensor on or off. Off by default, because a sensor that is on
    --- delivers an event stream nobody asked for.
    setGamepadSensor: function(handle: loader.CPtr, sensor: integer, enabled: boolean): boolean
    gamepadSensorEnabled: function(handle: loader.CPtr, sensor: integer): boolean

    ---------------------------------------------------------------- outputs

    --- Rumble at `low` and `high` in 0..1 for `milliseconds`. Milliseconds
    --- rather than seconds because that is the resolution every platform takes
    --- it in, so the rounding happens once above rather than in each port.
    ---
    --- False rather than an error where the device has no motor. Every output
    --- here answers that way: they are garnish, and a game should not have to
    --- guard them.
    rumble: function(handle: loader.CPtr, low: number, high: number, milliseconds: integer): boolean
    --- The motors in the triggers, on the devices that have them, which is
    --- separate hardware from the body motors.
    rumbleTriggers: function(handle: loader.CPtr, left: number, right: number, milliseconds: integer): boolean
    --- Sets the device's light, in 0..1 per channel. The bar or ring, not the
    --- numbered player indicator.
    setLED: function(handle: loader.CPtr, red: number, green: number, blue: number): boolean
    --- Assigns the player slot, zero-based, or -1 for none. What lights the
    --- numbered indicator on a device that has one.
    setPlayerIndex: function(handle: loader.CPtr, index: integer): boolean

    ------------------------------------------------------------- text input

    --- Starts and stops composing. Off until asked for: a platform that is
    --- composing is one whose key events a game must not also read as
    --- bindings. False without a window, which is what a headless test gets.
    startTextInput: function(window: loader.CPtr): boolean
    stopTextInput: function(window: loader.CPtr): boolean
    --- Where the text being edited sits, so the platform can place its
    --- candidate window and its on-screen keyboard clear of it. Coordinates
    --- are window coordinates; `cursor` is the caret's offset from the left of
    --- the rectangle.
    setTextInputArea: function(
        window: loader.CPtr, x: integer, y: integer, width: integer, height: integer, cursor: integer
    ): boolean
    --- Whether the platform puts a keyboard on the screen for text input.
    screenKeyboardSupported: function(): boolean

    ----------------------------------------------------------------- cursor

    --- Hides the cursor and delivers motion as deltas only. Per window, as are
    --- the two below it; capture and visibility are per application, which is
    --- why those take no window.
    setRelativeMouseMode: function(window: loader.CPtr, enabled: boolean): boolean
    relativeMouseMode: function(window: loader.CPtr): boolean
    --- Moves the cursor, in window coordinates. Produces a motion event like
    --- any other, so a caller recentring the cursor sees its own warp.
    warpMouse: function(window: loader.CPtr, x: number, y: number)
    --- Keeps delivering mouse events while a button is held outside the
    --- window, which is what a drag that leaves the window needs.
    captureMouse: function(enabled: boolean): boolean
    showCursor: function(visible: boolean): boolean
    cursorVisible: function(): boolean

    ------------------------------------------------------------------ names
    --
    -- Everything below returns nil for a name it does not know, so a caller
    -- can say which name was wrong. The keyboard is the exception: the
    -- platform owns that table and reports its own miss.

    --- Physical key position from a name, or 0 when there is no such key. Zero
    --- rather than nil because the platform's own unknown scancode is zero,
    --- and translating it would lose nothing and cost a branch.
    scancodeFromName: function(name: string): integer
    --- Name of a physical key, for showing a binding. The position's name, not
    --- the character the player's layout produces there.
    scancodeName: function(scancode: integer): string
    --- "left", "middle", "right", "x1", "x2".
    mouseButtonFromName: function(name: string): integer
    --- A single modifier's mask, or a mask covering both sides for the unsided
    --- names: "shift" matches either, "leftShift" only one.
    modifierFromName: function(name: string): integer
    --- Positional button names, per `GAMEPAD_BUTTONS`.
    gamepadButtonFromName: function(name: string): integer
    --- "leftX", "rightY", "leftTrigger" and so on.
    gamepadAxisFromName: function(name: string): integer
    --- "pressure", "tiltX", "tiltY", "distance", "rotation", "slider",
    --- "tangentialPressure".
    penAxisFromName: function(name: string): integer
    --- "gyro", "accelerometer", and the per-side names a split device has.
    sensorFromName: function(name: string): integer
end

local record inputbackend
    --- What a device says about itself, as `Backend.gamepadInfo` returns it.
    GamepadInfo: GamepadInfo
    --- The seam a port implements. Every field is required: `Input` and
    --- `Gamepad` call them without checking, since a partial backend would
    --- fail at whichever command a game happened to reach first.
    Backend: Backend
    --- The SDL backend, and the default everywhere.
    sdl: Backend
end

-------------------------------------------------------------------------------
-- Name tables
-------------------------------------------------------------------------------

--- Enum value by name, as a plain number, or nil when this SDL does not have
--- it. Read through the namespace rather than written as literals, so a value
--- SDL renumbers cannot silently point at the wrong button.
local function enumValue(name: string): integer
    local value = C[name]
    if value == nil then
        return nil
    end
    return tonumber(value) as integer
end

--- Positional button names.
---
--- Positional, not Xbox-only: "south" is the button nearest the player on
--- every pad, where "a" is the one nearest the player on some pads and the one
--- to its right on others. The label printed on the hardware is a separate
--- question, answered by `gamepadButtonLabel`.
local GAMEPAD_BUTTONS <const>: {string: integer} = {
    south = enumValue("SDL_GAMEPAD_BUTTON_SOUTH"),
    east = enumValue("SDL_GAMEPAD_BUTTON_EAST"),
    west = enumValue("SDL_GAMEPAD_BUTTON_WEST"),
    north = enumValue("SDL_GAMEPAD_BUTTON_NORTH"),
    back = enumValue("SDL_GAMEPAD_BUTTON_BACK"),
    guide = enumValue("SDL_GAMEPAD_BUTTON_GUIDE"),
    start = enumValue("SDL_GAMEPAD_BUTTON_START"),
    leftStick = enumValue("SDL_GAMEPAD_BUTTON_LEFT_STICK"),
    rightStick = enumValue("SDL_GAMEPAD_BUTTON_RIGHT_STICK"),
    leftShoulder = enumValue("SDL_GAMEPAD_BUTTON_LEFT_SHOULDER"),
    rightShoulder = enumValue("SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER"),
    dpadUp = enumValue("SDL_GAMEPAD_BUTTON_DPAD_UP"),
    dpadDown = enumValue("SDL_GAMEPAD_BUTTON_DPAD_DOWN"),
    dpadLeft = enumValue("SDL_GAMEPAD_BUTTON_DPAD_LEFT"),
    dpadRight = enumValue("SDL_GAMEPAD_BUTTON_DPAD_RIGHT"),
    misc1 = enumValue("SDL_GAMEPAD_BUTTON_MISC1"),
    misc2 = enumValue("SDL_GAMEPAD_BUTTON_MISC2"),
    misc3 = enumValue("SDL_GAMEPAD_BUTTON_MISC3"),
    misc4 = enumValue("SDL_GAMEPAD_BUTTON_MISC4"),
    misc5 = enumValue("SDL_GAMEPAD_BUTTON_MISC5"),
    misc6 = enumValue("SDL_GAMEPAD_BUTTON_MISC6"),
    rightPaddle1 = enumValue("SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1"),
    rightPaddle2 = enumValue("SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2"),
    leftPaddle1 = enumValue("SDL_GAMEPAD_BUTTON_LEFT_PADDLE1"),
    leftPaddle2 = enumValue("SDL_GAMEPAD_BUTTON_LEFT_PADDLE2"),
    touchpad = enumValue("SDL_GAMEPAD_BUTTON_TOUCHPAD"),
}

local GAMEPAD_AXES <const>: {string: integer} = {
    leftX = enumValue("SDL_GAMEPAD_AXIS_LEFTX"),
    leftY = enumValue("SDL_GAMEPAD_AXIS_LEFTY"),
    rightX = enumValue("SDL_GAMEPAD_AXIS_RIGHTX"),
    rightY = enumValue("SDL_GAMEPAD_AXIS_RIGHTY"),
    leftTrigger = enumValue("SDL_GAMEPAD_AXIS_LEFT_TRIGGER"),
    rightTrigger = enumValue("SDL_GAMEPAD_AXIS_RIGHT_TRIGGER"),
}

--- Pen axis names.
---
--- A pen reports every one of these the way a pad reports a stick: as an axis
--- event carrying a number and a value. The whole set is named here because
--- this table is the vocabulary; which of them the input state folds into a
--- field is a separate question, answered in `Input`.
local PEN_AXES <const>: {string: integer} = {
    pressure = enumValue("SDL_PEN_AXIS_PRESSURE"),
    tiltX = enumValue("SDL_PEN_AXIS_XTILT"),
    tiltY = enumValue("SDL_PEN_AXIS_YTILT"),
    distance = enumValue("SDL_PEN_AXIS_DISTANCE"),
    rotation = enumValue("SDL_PEN_AXIS_ROTATION"),
    slider = enumValue("SDL_PEN_AXIS_SLIDER"),
    tangentialPressure = enumValue("SDL_PEN_AXIS_TANGENTIAL_PRESSURE"),
}

local SENSORS <const>: {string: integer} = {
    gyro = enumValue("SDL_SENSOR_GYRO"),
    accelerometer = enumValue("SDL_SENSOR_ACCEL"),
    leftGyro = enumValue("SDL_SENSOR_GYRO_L"),
    rightGyro = enumValue("SDL_SENSOR_GYRO_R"),
    leftAccelerometer = enumValue("SDL_SENSOR_ACCEL_L"),
    rightAccelerometer = enumValue("SDL_SENSOR_ACCEL_R"),
}

local MOUSE_BUTTONS <const>: {string: integer} = {
    left = K.SDL_BUTTON_LEFT,
    middle = K.SDL_BUTTON_MIDDLE,
    right = K.SDL_BUTTON_RIGHT,
    x1 = K.SDL_BUTTON_X1,
    x2 = K.SDL_BUTTON_X2,
}

local MODIFIERS <const>: {string: integer} = {
    shift = K.SDL_KMOD_SHIFT,
    leftShift = K.SDL_KMOD_LSHIFT,
    rightShift = K.SDL_KMOD_RSHIFT,
    ctrl = K.SDL_KMOD_CTRL,
    leftCtrl = K.SDL_KMOD_LCTRL,
    rightCtrl = K.SDL_KMOD_RCTRL,
    alt = K.SDL_KMOD_ALT,
    leftAlt = K.SDL_KMOD_LALT,
    rightAlt = K.SDL_KMOD_RALT,
    gui = K.SDL_KMOD_GUI,
    leftGui = K.SDL_KMOD_LGUI,
    rightGui = K.SDL_KMOD_RGUI,
    capsLock = K.SDL_KMOD_CAPS,
    numLock = K.SDL_KMOD_NUM,
    scrollLock = K.SDL_KMOD_SCROLL,
    mode = K.SDL_KMOD_MODE,
}

--- Device family names, by SDL's type value.
local GAMEPAD_TYPES <const>: {integer: string} = {}
for name, kind in pairs({
    SDL_GAMEPAD_TYPE_STANDARD = "standard",
    SDL_GAMEPAD_TYPE_XBOX360 = "xbox360",
    SDL_GAMEPAD_TYPE_XBOXONE = "xboxOne",
    SDL_GAMEPAD_TYPE_PS3 = "ps3",
    SDL_GAMEPAD_TYPE_PS4 = "ps4",
    SDL_GAMEPAD_TYPE_PS5 = "ps5",
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO = "switchPro",
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT = "joyconLeft",
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT = "joyconRight",
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR = "joyconPair",
    SDL_GAMEPAD_TYPE_GAMECUBE = "gamecube",
} as {string: string}) do
    local value = enumValue(name)
    if value ~= nil then
        GAMEPAD_TYPES[value] = kind
    end
end

local POWER_STATES <const>: {integer: string} = {}
for name, state in pairs({
    SDL_POWERSTATE_ERROR = "error",
    SDL_POWERSTATE_UNKNOWN = "unknown",
    SDL_POWERSTATE_ON_BATTERY = "onBattery",
    SDL_POWERSTATE_NO_BATTERY = "noBattery",
    SDL_POWERSTATE_CHARGING = "charging",
    SDL_POWERSTATE_CHARGED = "charged",
} as {string: string}) do
    local value = enumValue(name)
    if value ~= nil then
        POWER_STATES[value] = state
    end
end

--- Button labels, by SDL's label value. What is printed on the hardware, which
--- is what a prompt has to show and what a positional name deliberately is
--- not.
local BUTTON_LABELS <const>: {integer: string} = {}
for name, label in pairs({
    SDL_GAMEPAD_BUTTON_LABEL_A = "a",
    SDL_GAMEPAD_BUTTON_LABEL_B = "b",
    SDL_GAMEPAD_BUTTON_LABEL_X = "x",
    SDL_GAMEPAD_BUTTON_LABEL_Y = "y",
    SDL_GAMEPAD_BUTTON_LABEL_CROSS = "cross",
    SDL_GAMEPAD_BUTTON_LABEL_CIRCLE = "circle",
    SDL_GAMEPAD_BUTTON_LABEL_SQUARE = "square",
    SDL_GAMEPAD_BUTTON_LABEL_TRIANGLE = "triangle",
} as {string: string}) do
    local value = enumValue(name)
    if value ~= nil then
        BUTTON_LABELS[value] = label
    end
end

-------------------------------------------------------------------------------
-- The SDL backend
-------------------------------------------------------------------------------

--- Rumble and LED take 0..1 and SDL takes fixed-point, so the conversion is
--- here rather than in every caller.
local function clamped(value: number, scale: number): integer
    if value == nil or value < 0.0 then
        return 0
    end
    if value > 1.0 then
        return math.floor(scale)
    end
    return math.floor(value * scale + 0.5)
end

--- Reusable out-parameters. Device metadata is read on connection, not per
--- frame, but there is no reason to allocate for it either.
local countOut <const> = loader.newArray("int[1]")
local percentOut <const> = loader.newArray("int[1]")
local guidText <const> = loader.newArray("char[33]")
local textArea <const> = loader.newStruct("SDL_Rect")

local sdlBackend <const>: Backend = {
    name = "sdl",

    attachedGamepads = function(): {number}
        local ids: {number} = {}
        local list = C.SDL_GetGamepads(countOut)
        if list == nil then
            return ids
        end
        local total = countOut[0] as integer
        local array = list as loader.CArray
        for index = 0, total - 1 do
            ids[#ids + 1] = tonumber(array[index]) as number
        end
        C.SDL_free(list)
        return ids
    end,

    openGamepad = function(id: number): loader.CPtr
        local handle = C.SDL_OpenGamepad(id)
        if handle == nil then
            return nil
        end
        return handle
    end,

    closeGamepad = function(handle: loader.CPtr) C.SDL_CloseGamepad(handle) end,

    gamepadInfo = function(handle: loader.CPtr, id: number): GamepadInfo
        C.SDL_GUIDToString(C.SDL_GetGamepadGUIDForID(id), guidText, 33)
        return {
            id = id,
            name = loader.toString(C.SDL_GetGamepadName(handle)),
            kind = GAMEPAD_TYPES[tonumber(C.SDL_GetGamepadType(handle)) as integer] or "unknown",
            guid = loader.toString(guidText as loader.CValue),
            path = loader.toString(C.SDL_GetGamepadPath(handle)),
            playerIndex = tonumber(C.SDL_GetGamepadPlayerIndex(handle)) as integer,
            touchpads = tonumber(C.SDL_GetNumGamepadTouchpads(handle)) as integer,
        }
    end,

    gamepadHasButton = function(handle: loader.CPtr, button: integer): boolean
        return C.SDL_GamepadHasButton(handle, button) as boolean
    end,

    gamepadHasAxis = function(handle: loader.CPtr, axis: integer): boolean
        return C.SDL_GamepadHasAxis(handle, axis) as boolean
    end,

    gamepadHasSensor = function(handle: loader.CPtr, sensor: integer): boolean
        return C.SDL_GamepadHasSensor(handle, sensor) as boolean
    end,

    gamepadButtonLabel = function(handle: loader.CPtr, button: integer): string
        local label = tonumber(C.SDL_GetGamepadButtonLabel(handle, button)) as integer
        return BUTTON_LABELS[label] or "unknown"
    end,

    gamepadPower = function(handle: loader.CPtr): string, integer
        local state = tonumber(C.SDL_GetGamepadPowerInfo(handle, percentOut)) as integer
        return POWER_STATES[state] or "unknown", percentOut[0] as integer
    end,

    setGamepadSensor = function(handle: loader.CPtr, sensor: integer, enabled: boolean): boolean
        return C.SDL_SetGamepadSensorEnabled(handle, sensor, enabled) as boolean
    end,

    gamepadSensorEnabled = function(handle: loader.CPtr, sensor: integer): boolean
        return C.SDL_GamepadSensorEnabled(handle, sensor) as boolean
    end,

    rumble = function(handle: loader.CPtr, low: number, high: number, milliseconds: integer): boolean
        return C.SDL_RumbleGamepad(handle, clamped(low, 65535), clamped(high, 65535), milliseconds) as boolean
    end,

    rumbleTriggers = function(handle: loader.CPtr, left: number, right: number, milliseconds: integer): boolean
        return C.SDL_RumbleGamepadTriggers(handle, clamped(left, 65535), clamped(right, 65535), milliseconds) as boolean
    end,

    setLED = function(handle: loader.CPtr, red: number, green: number, blue: number): boolean
        return C.SDL_SetGamepadLED(handle, clamped(red, 255), clamped(green, 255), clamped(blue, 255)) as boolean
    end,

    setPlayerIndex = function(handle: loader.CPtr, index: integer): boolean
        return C.SDL_SetGamepadPlayerIndex(handle, index) as boolean
    end,

    startTextInput = function(window: loader.CPtr): boolean
        if window == nil then
            return false
        end
        return C.SDL_StartTextInput(window) as boolean
    end,

    stopTextInput = function(window: loader.CPtr): boolean
        if window == nil then
            return false
        end
        return C.SDL_StopTextInput(window) as boolean
    end,

    setTextInputArea = function(
        window: loader.CPtr, x: integer, y: integer, width: integer, height: integer, cursor: integer
    ): boolean
        if window == nil then
            return false
        end
        local rect = textArea as loader.CStruct
        rect.x, rect.y, rect.w, rect.h = x, y, width, height
        return C.SDL_SetTextInputArea(window, textArea, cursor) as boolean
    end,

    screenKeyboardSupported = function(): boolean return C.SDL_HasScreenKeyboardSupport() as boolean end,

    setRelativeMouseMode = function(window: loader.CPtr, enabled: boolean): boolean
        if window == nil then
            return false
        end
        return C.SDL_SetWindowRelativeMouseMode(window, enabled) as boolean
    end,

    relativeMouseMode = function(window: loader.CPtr): boolean
        if window == nil then
            return false
        end
        return C.SDL_GetWindowRelativeMouseMode(window) as boolean
    end,

    warpMouse = function(window: loader.CPtr, x: number, y: number)
        if window == nil then
            return
        end
        C.SDL_WarpMouseInWindow(window, x, y)
    end,

    captureMouse = function(enabled: boolean): boolean return C.SDL_CaptureMouse(enabled) as boolean end,

    showCursor = function(visible: boolean): boolean
        if visible then
            return C.SDL_ShowCursor() as boolean
        end
        return C.SDL_HideCursor() as boolean
    end,

    cursorVisible = function(): boolean return C.SDL_CursorVisible() as boolean end,

    scancodeFromName = function(name: string): integer return tonumber(C.SDL_GetScancodeFromName(name)) as integer end,

    scancodeName = function(scancode: integer): string return loader.toString(C.SDL_GetScancodeName(scancode)) end,

    mouseButtonFromName = function(name: string): integer return MOUSE_BUTTONS[name] end,

    modifierFromName = function(name: string): integer return MODIFIERS[name] end,

    gamepadButtonFromName = function(name: string): integer return GAMEPAD_BUTTONS[name] end,

    gamepadAxisFromName = function(name: string): integer return GAMEPAD_AXES[name] end,

    penAxisFromName = function(name: string): integer return PEN_AXES[name] end,

    sensorFromName = function(name: string): integer return SENSORS[name] end,
}

inputbackend.sdl = sdlBackend

return inputbackend
