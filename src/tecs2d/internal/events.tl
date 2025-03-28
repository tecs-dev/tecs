local tecs <const> = require("tecs")

--- A module that contains Love2D events that can be emitted to observers of event inboxes in a tecs.World.
---
--- You can still listen for any event in love2d's built-in callback functions, but Tecs also provides a
--- more scalable way to observe events or to subscribe to them frame by frame in an event inbox.
---
--- @see https://love2d.org/wiki/love#Callbacks
local record events
    -------------------------------------------------------------------------------
    -- General events
    -------------------------------------------------------------------------------

    --- Event triggered when the game is closed.
    --- @see https://love2d.org/wiki/love.quit
    record Quit is tecs.Event
        exitstatus: integer

        metamethod __call: function(self, exitstatus: integer): Quit
    end

    -------------------------------------------------------------------------------
    -- Mouse events
    -------------------------------------------------------------------------------

    --- Event triggered when a mouse button is pressed.
    --- @see https://love2d.org/wiki/love.mousepressed
    record MousePressed is tecs.Event
        --- Mouse x position, in pixels.
        x: number
        --- Mouse y position, in pixels.
        y: number
        --- The button index that was pressed. 1 is the primary mouse button, 2 is the secondary mouse
        --- button and 3 is the middle button. Further buttons are mouse dependent.
        button: number
        --- True if the mouse button press originated from a touchscreen touch-press.
        istouch: boolean
        --- The number of presses in a short time frame and small area, used to simulate double, triple clicks
        presses: number

        metamethod __call: function(
            self,
            x: number,
            y: number,
            button: number,
            istouch: boolean,
            presses: number
        ): MousePressed
    end

    --- Event triggered when a mouse button is released.
    --- @see https://love2d.org/wiki/love.mousereleased
    record MouseReleased is tecs.Event
        --- Mouse x position, in pixels.
        x: number
        --- Mouse y position, in pixels.
        y: number
        --- The button index that was released. 1 is the primary mouse button, 2 is the secondary mouse
        --- button and 3 is the middle button. Further buttons are mouse dependent.
        button: number
        --- True if the mouse button release originated from a touchscreen touch-release.
        istouch: boolean
        --- The number of presses in a short time frame and small area, used to simulate double, triple clicks
        presses: number

        metamethod __call: function(
            self,
            x: number,
            y: number,
            button: number,
            istouch: boolean,
            presses: number
        ): MouseReleased
    end

    -------------------------------------------------------------------------------
    -- Joystick events
    -------------------------------------------------------------------------------

    --- Event triggered when a joystick is connected.
    --- @see https://love2d.org/wiki/love.joystickadded
    record JoystickAdded is tecs.Event
        --- The newly connected Joystick object.
        joystick: love.joystick.Joystick

        metamethod __call: function(self, joystick: love.joystick.Joystick): JoystickAdded
    end

    --- Event triggered when a joystick is disconnected.
    --- @see https://love2d.org/wiki/love.joystickremoved
    record JoystickRemoved is tecs.Event
        --- The now-disconnected Joystick object.
        joystick: love.joystick.Joystick

        metamethod __call: function(self, joystick: love.joystick.Joystick): JoystickRemoved
    end

    -------------------------------------------------------------------------------
    -- Window events
    -------------------------------------------------------------------------------

    --- Event triggered when a directory is dragged and dropped onto the window.
    --- @see https://love2d.org/wiki/love.directorydropped
    record DirectoryDropped is tecs.Event
        --- The full platform-dependent path to the directory. It can be used as an argument to love.filesystem.mount,
        --- in order to gain read access to the directory with love.filesystem.
        path: string

        metamethod __call: function(self, path: string): DirectoryDropped
    end

    --- Event triggered when a file is dragged and dropped onto the window.
    --- @see https://love2d.org/wiki/love.filedropped
    record FileDropped is tecs.Event
        --- The unopened File object representing the file that was dropped.
        file: love.filesystem.DroppedFile

        metamethod __call: function(self, file: love.filesystem.DroppedFile): FileDropped
    end

    --- Event triggered when window receives or loses focus.
    --- @see https://love2d.org/wiki/love.focus
    record Focus is tecs.Event
        --- True if the window has focus, false if it doesn't.
        visible: boolean

        metamethod __call: function(self, visible: boolean): Focus
    end

    --- Event triggered when window receives or loses mouse focus.
    --- @see https://love2d.org/wiki/love.mousefocus
    record MouseFocus is tecs.Event
        --- Whether the window has mouse focus or not.
        focus: boolean

        metamethod __call: function(self, focus: boolean): MouseFocus
    end

    --- Event triggered when the window is resized.
    --- @see https://love2d.org/wiki/love.resize
    record Resize is tecs.Event
        --- The new width of the window.
        width: number
        --- The new height of the window.
        height: number

        metamethod __call: function(self, width: number, height: number): Resize
    end

    --- Event triggered when window is shown or hidden.
    --- @see https://love2d.org/wiki/love.visible
    record Visible is tecs.Event
        --- True if the window is visible, false if it isn't.
        visible: boolean

        metamethod __call: function(self, visible: boolean): Visible
    end
end

-------------------------------------------------------------------------------
-- Event constructors
-------------------------------------------------------------------------------

tecs.newFFIEvent(events.Quit, {
    {"exitstatus", "int32_t"}
}, "Love2D_Quit")

tecs.newFFIEvent(events.MousePressed, {
    {"x", "float"},
    {"y", "float"},
    {"button", "int32_t"},
    {"istouch", "bool"},
    {"presses", "int32_t"}
}, "Love2D_MousePressed")

tecs.newFFIEvent(events.MouseReleased, {
    {"x", "float"},
    {"y", "float"},
    {"button", "int32_t"},
    {"istouch", "bool"},
    {"presses", "int32_t"}
}, "Love2D_MouseReleased")

tecs.newFFIEvent(events.Focus, {
    {"visible", "bool"}
}, "Love2D_Focus")

tecs.newFFIEvent(events.MouseFocus, {
    {"focus", "bool"}
}, "Love2D_MouseFocus")

tecs.newFFIEvent(events.Resize, {
    {"width", "float"},
    {"height", "float"}
}, "Love2D_Resize")

tecs.newFFIEvent(events.Visible, {
    {"visible", "bool"}
}, "Love2D_Visible")

tecs.newEvent(events.JoystickAdded, function(joystick: love.joystick.Joystick): events.JoystickAdded
    return {joystick = joystick}
end)

tecs.newEvent(events.JoystickRemoved, function(joystick: love.joystick.Joystick): events.JoystickRemoved
    return {joystick = joystick}
end)

tecs.newEvent(events.DirectoryDropped, function(path: string): events.DirectoryDropped
    return {path = path}
end)

tecs.newEvent(events.FileDropped, function(file: love.filesystem.DroppedFile): events.FileDropped
    return {file = file}
end)

return events
