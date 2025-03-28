local tecs <const> = require("tecs")
local events <const> = require("tecs2d.internal.events")
local input <const> = require("tecs2d.internal.input")

local rawget <const> = rawget
local love_poll <const> = love.event.poll
local love_handlers <const> = love.handlers
local LOGGER <const> = tecs.logging.getLogger("tecs2d.inputHandlers")

--- Handles Love2D input events and updates the Input resource.
local record inputHandlers
    handlers: {string: function(...: any)}

    pollEvents: function(world: tecs.World): tecs.System
end

-------------------------------------------------------------------------------
-- Event handlers that register events with Love2D
-------------------------------------------------------------------------------

inputHandlers.handlers = {
    keypressed = function(_world: tecs.World, key: love.keyboard.KeyConstant, _scancode: love.keyboard.Scancode, isrepeat: boolean)
        if not isrepeat then
            input.keys[key] = true
            input.keysPressed[key] = true
            input.keysLatchedPressed[key] = true
            input.markLatchedDirty()
        end
    end,
    keyreleased = function(_world: tecs.World, key: love.keyboard.KeyConstant, _scancode: love.keyboard.Scancode)
        input.keys[key] = nil
        input.keysReleased[key] = true
        input.keysLatchedReleased[key] = true
        input.markLatchedDirty()
    end,
    textinput = function(_world: tecs.World, text: string)
        input.textInput = text
    end,
    wheelmoved = function(_world: tecs.World, x: number, y: number)
        local moved = input.mouseWheelMoved
        moved[1], moved[2] = x, y
    end,
    mousemoved = function(_world: tecs.World, x: number, y: number, _dx: number, _dy: number, _istouch: boolean)
        input.mouseX, input.mouseY = x, y
    end,
    mousepressed = function(w: tecs.World, x: number, y: number, button: integer, istouch: boolean, presses: number)
        input.mouseButtons[button] = true
        input.mousePressed[button] = true
        input.mouseLatchedPressed[button] = true
        input.markLatchedDirty()
        if w:hasObservers(events.MousePressed) then
            w:emit(events.MousePressed(x, y, button, istouch, presses))
        end
    end,
    mousereleased = function(w: tecs.World, x: number, y: number, button: integer, istouch: boolean, presses: number)
        input.mouseButtons[button] = nil
        input.mouseReleased[button] = true
        input.mouseLatchedReleased[button] = true
        input.markLatchedDirty()
        if w:hasObservers(events.MouseReleased) then
            w:emit(events.MouseReleased(x, y, button, istouch, presses))
        end
    end,
    mousefocus = function(w: tecs.World, focus: boolean)
        LOGGER:info("Mouse focus: %s", focus)
        if w:hasObservers(events.MouseFocus) then
            w:emit(events.MouseFocus(focus))
        end
    end,
    joystickadded = function(w: tecs.World, joystick: love.joystick.Joystick)
        LOGGER:info("Joystick added: %s", joystick)
        input.getJoystick(joystick) -- triggers the creation and registration of a new JoystickInput.
        if w:hasObservers(events.JoystickAdded) then
            w:emit(events.JoystickAdded(joystick))
        end
    end,
    joystickremoved = function(w: tecs.World, joystick: love.joystick.Joystick)
        LOGGER:info("Joystick removed: %s", joystick)
        if w:hasObservers(events.JoystickRemoved) then
            w:emit(events.JoystickRemoved(joystick))
        end
        input.joysticks[joystick] = nil -- remove *after* emitting the event.
    end,
    gamepadaxis = function(_world: tecs.World, joystick: love.joystick.Joystick, axis: love.joystick.GamepadAxis, value: number)
        input.getJoystick(joystick).gamepadAxis[axis] = value
    end,
    gamepadpressed = function(_world: tecs.World, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton)
        local js = input.getJoystick(joystick)
        js.gamepadButtons[button] = true
        js.gamepadPressed[button] = true
        js.gamepadLatchedPressed[button] = true
        input.markLatchedDirty()
    end,
    gamepadreleased = function(_world: tecs.World, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton)
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
    joystickhat = function(_world: tecs.World, joystick: love.joystick.Joystick, hat: number, direction: love.joystick.JoystickHat)
        input.getJoystick(joystick).joystickHat[hat] = direction
    end,
    directorydropped = function(w: tecs.World, path: string)
        LOGGER:info("Directory dropped: %s", path)
        if w:hasObservers(events.DirectoryDropped) then
            w:emit(events.DirectoryDropped(path))
        end
    end,
    filedropped = function(w: tecs.World, file: love.filesystem.DroppedFile)
        LOGGER:info("File dropped: %s", file)
        if w:hasObservers(events.FileDropped) then
            w:emit(events.FileDropped(file))
        end
    end,
    focus = function(w: tecs.World, visible: boolean)
        LOGGER:info("Window focus: %s", visible)
        if w:hasObservers(events.Focus) then
            w:emit(events.Focus(visible))
        end
    end,
    resize = function(w: tecs.World, width: number, height: number)
        LOGGER:info("Window resized: %d x %d", width, height)
        if w:hasObservers(events.Resize) then
            w:emit(events.Resize(width, height))
        end
    end,
    visible = function(w: tecs.World, visible: boolean)
        LOGGER:info("Window visible: %s", visible)
        if w:hasObservers(events.Visible) then
            w:emit(events.Visible(visible))
        end
    end,
}

function inputHandlers.pollEvents(w: tecs.World): tecs.System
    local handlers <const> = inputHandlers.handlers
    local quit_func <const> = love.quit

    return function()
        input.update()
        love.event.pump()
        for name, a, b, c, d, e, f in love_poll() do
            if name == "quit" then
                LOGGER:info("Quit event: %s", a)
                if not quit_func or not quit_func() then
                    LOGGER:info("FPS: %d", love.timer.getFPS())
                    w:emit(events.Quit(a as integer or 0))
                end
            else
                -- Call callbacks registered with `love`.
                local loveHandler <const> = rawget(love_handlers, name)
                if loveHandler then
                    loveHandler(a, b, c, d, e, f)
                end

                -- Call input handlers of the love2d plugin.
                local inputHandler <const> = rawget(handlers, name)
                if inputHandler then
                    inputHandler(w, a, b, c, d, e, f)
                end
            end
        end
    end
end

return inputHandlers