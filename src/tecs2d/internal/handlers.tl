local tecs <const> = require("tecs")
local events <const> = require("tecs2d.events")
local input <const> = require("tecs2d.input")

local rawget <const> = rawget
local love_poll <const> = love.event.poll
local love_handlers <const> = love.handlers
local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.inputHandlers")

--- Handles Love2D input events and updates the Input resource.
local record inputHandlers
    handlers: {string: function(...: any)}
    restartRequested: boolean
    -- Set to the exit code (0 by default) when a quit event was polled
    -- and not vetoed by `love.quit`. Consumed by the main loop, which
    -- returns it from love.run so LÖVE exits cleanly. `false` means no
    -- quit is pending. Stored here (not on the bus) so the path from
    -- poll → exit is a direct boolean check rather than an event dispatch
    -- that depends on observer wiring surviving plugin init ordering.
    quitRequested: integer | boolean

    pollEvents: function(world: tecs.World): tecs.System

    --- Dispatch one LÖVE event through the same path pollEvents uses for
    --- real events: the Tecs input handler first (so the input snapshot is
    --- updated), then any user-defined love.* callback. Used by the debug
    --- input tape to inject scheduled events indistinguishably from real
    --- ones. `quit` is not dispatchable here.
    dispatch: function(w: tecs.World, name: string, ...: any)

    --- Optional single listener invoked for every dispatched event, real or
    --- taped (the debugger's replay recorder). nil when nothing records.
    onDispatch: function(name: string, ...: any)
end

-------------------------------------------------------------------------------
-- Event handlers that register events with Love2D
-------------------------------------------------------------------------------

inputHandlers.handlers = {
    keypressed = function(
        w: tecs.World, key: love.keyboard.KeyConstant, scancode: love.keyboard.Scancode, isrepeat: boolean
    )
        if not isrepeat then
            input.keys[key] = true
            input.keysPressed[key] = true
            input.keysLatchedPressed[key] = true
            input.markLatchedDirty()
        end
        w:emit(0, events.KeyPressed, key, scancode, isrepeat)
    end,
    keyreleased = function(w: tecs.World, key: love.keyboard.KeyConstant, scancode: love.keyboard.Scancode)
        input.keys[key] = nil
        input.keysReleased[key] = true
        input.keysLatchedReleased[key] = true
        input.markLatchedDirty()
        w:emit(0, events.KeyReleased, key, scancode)
    end,
    textinput = function(_world: tecs.World, text: string)
        input.textInput = text
    end,
    wheelmoved = function(_world: tecs.World, x: number, y: number, direction: love.mouse.WheelDirection)
        local moved = input.mouseWheelMoved
        moved[1], moved[2] = moved[1] + x, moved[2] + y
        input.mouseWheelDirection = direction
        local latchedMoved = input.mouseWheelLatchedMoved
        latchedMoved[1], latchedMoved[2] = latchedMoved[1] + x, latchedMoved[2] + y
        input.mouseWheelLatchedDirection = direction
        input.markLatchedDirty()
    end,
    mousemoved = function(_world: tecs.World, x: number, y: number, _dx: number, _dy: number, _istouch: boolean)
        input.mouseX, input.mouseY = x, y
    end,
    mousepressed = function(w: tecs.World, x: number, y: number, button: integer, istouch: boolean, presses: number)
        input.mouseButtons[button] = true
        input.mousePressed[button] = true
        input.mouseLatchedPressed[button] = true
        input.markLatchedDirty()
        w:emit(0, events.MousePressed, x, y, button, istouch, presses)
    end,
    mousereleased = function(w: tecs.World, x: number, y: number, button: integer, istouch: boolean, presses: number)
        input.mouseButtons[button] = nil
        input.mouseReleased[button] = true
        input.mouseLatchedReleased[button] = true
        input.markLatchedDirty()
        w:emit(0, events.MouseReleased, x, y, button, istouch, presses)
    end,
    mousefocus = function(w: tecs.World, focus: boolean)
        w:emit(0, events.MouseFocus, focus)
    end,
    joystickadded = function(w: tecs.World, joystick: love.joystick.Joystick)
        LOGGER:debug("Joystick added: %s", joystick)
        input.getJoystick(joystick) -- triggers the creation and registration of a new JoystickInput.
        w:emit(0, events.JoystickAdded, joystick)
    end,
    joystickremoved = function(w: tecs.World, joystick: love.joystick.Joystick)
        LOGGER:debug("Joystick removed: %s", joystick)
        w:emit(0, events.JoystickRemoved, joystick)
        input.joysticks[joystick] = nil -- remove *after* emitting the event.
    end,
    gamepadaxis = function(
        _world: tecs.World, joystick: love.joystick.Joystick, axis: love.joystick.GamepadAxis, value: number
    )
        input.getJoystick(joystick).gamepadAxis[axis] = value
    end,
    gamepadpressed = function(_world: tecs.World, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton)
        local js = input.getJoystick(joystick)
        js.gamepadButtons[button] = true
        js.gamepadPressed[button] = true
        js.gamepadLatchedPressed[button] = true
        input.markLatchedDirty()
    end,
    gamepadreleased = function(
        _world: tecs.World, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton
    )
        local js = input.getJoystick(joystick)
        js.gamepadButtons[button] = nil
        js.gamepadReleased[button] = true
        js.gamepadLatchedReleased[button] = true
        input.markLatchedDirty()
    end,
    joystickpressed = function(_world: tecs.World, joystick: love.joystick.Joystick, button: number)
        local js = input.getJoystick(joystick)
        js.joystickButtons[button] = true
        js.joystickPressed[button] = true
        js.joystickLatchedPressed[button] = true
        input.markLatchedDirty()
    end,
    joystickreleased = function(_world: tecs.World, joystick: love.joystick.Joystick, button: number)
        local js = input.getJoystick(joystick)
        js.joystickButtons[button] = nil
        js.joystickReleased[button] = true
        js.joystickLatchedReleased[button] = true
        input.markLatchedDirty()
    end,
    joystickhat = function(
        _world: tecs.World, joystick: love.joystick.Joystick, hat: number, direction: love.joystick.JoystickHat
    )
        input.getJoystick(joystick).joystickHat[hat] = direction
    end,
    directorydropped = function(w: tecs.World, path: string, x: number, y: number)
        LOGGER:info("Directory dropped: %s at (%d, %d)", path, x, y)
        w:emit(0, events.DirectoryDropped, path, x, y)
    end,
    filedropped = function(w: tecs.World, file: love.filesystem.DroppedFile, x: number, y: number)
        LOGGER:debug("File dropped: %s at (%d, %d)", file, x, y)
        w:emit(0, events.FileDropped, file, x, y)
    end,
    focus = function(w: tecs.World, visible: boolean)
        w:emit(0, events.Focus, visible)
    end,
    resize = function(w: tecs.World, width: number, height: number)
        LOGGER:debug("Window resized: %d x %d", width, height)
        w:emit(0, events.Resize, width, height)
    end,
    visible = function(w: tecs.World, visible: boolean)
        w:emit(0, events.Visible, visible)
    end,
    exposed = function(w: tecs.World)
        w:emit(0, events.Exposed)
    end,
    occluded = function(w: tecs.World)
        w:emit(0, events.Occluded)
    end,
    localechanged = function(w: tecs.World)
        LOGGER:debug("Locale changed")
        w:emit(0, events.LocaleChanged)
    end,
    themechanged = function(w: tecs.World, theme: string)
        LOGGER:debug("Theme changed: %s", theme)
        w:emit(0, events.ThemeChanged, theme)
    end,
    dropbegan = function(w: tecs.World, x: number, y: number)
        w:emit(0, events.DropBegan, x, y)
    end,
    dropmoved = function(w: tecs.World, x: number, y: number)
        w:emit(0, events.DropMoved, x, y)
    end,
    dropcompleted = function(w: tecs.World, x: number, y: number)
        w:emit(0, events.DropCompleted, x, y)
    end,
    audiodisconnected = function(w: tecs.World)
        LOGGER:debug("Audio device disconnected")
        w:emit(0, events.AudioDisconnected)
    end,
    sensorupdated = function(w: tecs.World, sensorType: love.sensor.SensorType, x: number, y: number, z: number)
        w:emit(0, events.SensorUpdated, sensorType, x, y, z)
    end,
    joysticksensorupdated = function(
        w: tecs.World,
        joystick: love.joystick.Joystick,
        sensorType: love.joystick.SensorType,
        x: number,
        y: number,
        z: number
    )
        w:emit(0, events.JoystickSensorUpdated, joystick, sensorType, x, y, z)
    end,
    touchpressed = function(
        w: tecs.World,
        id: any,
        x: number,
        y: number,
        _dx: number,
        _dy: number,
        pressure: number,
        deviceType: love.touch.TouchDeviceType,
        isMouse: boolean
    )
        w:emit(0, events.TouchPressed, id, x, y, pressure, deviceType, isMouse)
    end,
    touchmoved = function(
        w: tecs.World,
        id: any,
        x: number,
        y: number,
        dx: number,
        dy: number,
        pressure: number,
        deviceType: love.touch.TouchDeviceType,
        isMouse: boolean
    )
        w:emit(0, events.TouchMoved, id, x, y, dx, dy, pressure, deviceType, isMouse)
    end,
    touchreleased = function(
        w: tecs.World,
        id: any,
        x: number,
        y: number,
        _dx: number,
        _dy: number,
        pressure: number,
        deviceType: love.touch.TouchDeviceType,
        isMouse: boolean
    )
        w:emit(0, events.TouchReleased, id, x, y, pressure, deviceType, isMouse)
    end,
}

-- Restart request flag (set by event handler, checked by main loop)
inputHandlers.restartRequested = false
inputHandlers.quitRequested = false

function inputHandlers.pollEvents(w: tecs.World): tecs.System
    local quit_func <const> = love.quit

    return function()
        input.update()
        love.event.pump()
        -- Capture up to 8 payload slots: LÖVE 12 touchmoved/pressed/released
        -- events carry (id, x, y, dx, dy, pressure, deviceType, isMouse).
        -- Stopping at 6 would silently drop deviceType and isMouse and leave
        -- TouchPressed/TouchMoved/TouchReleased event fields as nil.
        for name, a, b, c, d, e, f, g, h in love_poll() do
            if name == "quit" then
                LOGGER:info("Quit event: %s", a)
                if a == "restart" then
                    -- Love2D restart - signal to main loop via flag
                    inputHandlers.restartRequested = true
                    return
                end
                if not quit_func or not quit_func() then
                    LOGGER:debug("FPS: %d", love.timer.getFPS())
                    local exitCode = (type(a) == "number") and (a as integer) or 0
                    -- Emit the Tecs event for game code that wants to observe
                    -- quit (save-on-exit, etc.) and ALSO set the direct flag
                    -- so the main loop exits on the next frame. The flag is
                    -- the authoritative signal: it doesn't rely on observer
                    -- registration order, event-id pairing, or any other
                    -- plugin state that could silently drift.
                    w:emit(0, events.Quit, exitCode)
                    inputHandlers.quitRequested = exitCode
                end
            else
                inputHandlers.dispatch(w, name, a, b, c, d, e, f, g, h)
            end
        end
    end
end

-- Run the Tecs input handler BEFORE user-defined love.* callbacks so that
-- anything reading tecs2d.input (keysPressed, mouseButtons, etc.) from inside
-- a love.keypressed / love.mousepressed override sees the current event
-- already applied to the input snapshot.
function inputHandlers.dispatch(w: tecs.World, name: string, ...: any)
    local listener <const> = inputHandlers.onDispatch
    if listener then
        listener(name, ...)
    end

    local inputHandler <const> = rawget(inputHandlers.handlers, name)
    if inputHandler then
        inputHandler(w, ...)
    end

    local loveHandler <const> = rawget(love_handlers, name)
    if loveHandler then
        loveHandler(...)
    end
end

return inputHandlers
