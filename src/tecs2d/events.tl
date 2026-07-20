local tecs <const> = require("tecs")

--- A module that contains Love2D events that can be emitted to observers of event inboxes in a tecs.World.
---
--- You can still listen for any event in love2d's built-in callback functions, but Tecs also provides a
--- more scalable way to observe events or to subscribe to them frame by frame in an event inbox.
---
--- @see https://love2d.org/wiki/love#Callbacks
local record events
    ---------------------------------------------------------------------------
    -- General events
    ---------------------------------------------------------------------------

    --- Event triggered when the game is closed.
    --- @see https://love2d.org/wiki/love.quit
    record Quit is tecs.Event
        exitstatus: integer

        metamethod __call: function(self, exitstatus: integer): Quit
    end

    ---------------------------------------------------------------------------
    -- Keyboard events
    ---------------------------------------------------------------------------

    --- Event triggered when a key is pressed.
    --- @see https://love2d.org/wiki/love.keypressed
    record KeyPressed is tecs.Event
        --- The key constant for the pressed key.
        key: love.keyboard.KeyConstant
        --- The scancode for the pressed key.
        scancode: love.keyboard.Scancode
        --- Whether this is a repeat event. The delay between repeats depends on the user's system settings.
        isrepeat: boolean

        metamethod __call: function(
            self, key: love.keyboard.KeyConstant, scancode: love.keyboard.Scancode, isrepeat: boolean
        ): KeyPressed
    end

    --- Event triggered when a key is released.
    --- @see https://love2d.org/wiki/love.keyreleased
    record KeyReleased is tecs.Event
        --- The key constant for the released key.
        key: love.keyboard.KeyConstant
        --- The scancode for the released key.
        scancode: love.keyboard.Scancode

        metamethod __call: function(
            self, key: love.keyboard.KeyConstant, scancode: love.keyboard.Scancode
        ): KeyReleased
    end

    --- Text entered through the active input target.
    record TextInput is tecs.Event
        text: string
        metamethod __call: function(self, text: string): TextInput
    end

    ---------------------------------------------------------------------------
    -- Mouse events
    ---------------------------------------------------------------------------

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

    --- Mouse motion routed through the active input target.
    record MouseMoved is tecs.Event
        x: number
        y: number
        dx: number
        dy: number
        istouch: boolean
        metamethod __call: function(
            self, x: number, y: number, dx: number, dy: number, istouch: boolean
        ): MouseMoved
    end

    --- Mouse wheel motion routed through the active input target.
    record WheelMoved is tecs.Event
        x: number
        y: number
        direction: love.mouse.WheelDirection
        metamethod __call: function(
            self, x: number, y: number, direction: love.mouse.WheelDirection
        ): WheelMoved
    end

    ---------------------------------------------------------------------------
    -- Joystick events
    ---------------------------------------------------------------------------

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

    --- Gamepad axis motion routed through the active input target.
    record GamepadAxis is tecs.Event
        joystick: love.joystick.Joystick
        axis: love.joystick.GamepadAxis
        value: number
        metamethod __call: function(
            self, joystick: love.joystick.Joystick, axis: love.joystick.GamepadAxis, value: number
        ): GamepadAxis
    end

    --- Gamepad button press routed through the active input target.
    record GamepadPressed is tecs.Event
        joystick: love.joystick.Joystick
        button: love.joystick.GamepadButton
        metamethod __call: function(
            self, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton
        ): GamepadPressed
    end

    --- Gamepad button release routed through the active input target.
    record GamepadReleased is tecs.Event
        joystick: love.joystick.Joystick
        button: love.joystick.GamepadButton
        metamethod __call: function(
            self, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton
        ): GamepadReleased
    end

    --- Raw joystick button press routed through the active input target.
    record JoystickPressed is tecs.Event
        joystick: love.joystick.Joystick
        button: number
        metamethod __call: function(self, joystick: love.joystick.Joystick, button: number): JoystickPressed
    end

    --- Raw joystick button release routed through the active input target.
    record JoystickReleased is tecs.Event
        joystick: love.joystick.Joystick
        button: number
        metamethod __call: function(self, joystick: love.joystick.Joystick, button: number): JoystickReleased
    end

    --- Joystick hat motion routed through the active input target.
    record JoystickHat is tecs.Event
        joystick: love.joystick.Joystick
        hat: number
        direction: love.joystick.JoystickHat
        metamethod __call: function(
            self, joystick: love.joystick.Joystick, hat: number, direction: love.joystick.JoystickHat
        ): JoystickHat
    end

    ---------------------------------------------------------------------------
    -- Window events
    ---------------------------------------------------------------------------

    --- Event triggered when a directory is dragged and dropped onto the window.
    --- @see https://love2d.org/wiki/love.directorydropped
    record DirectoryDropped is tecs.Event
        --- The full platform-dependent path to the directory. It can be used as an argument to love.filesystem.mount,
        --- in order to gain read access to the directory with love.filesystem.
        path: string
        --- X position where the directory was dropped.
        x: number
        --- Y position where the directory was dropped.
        y: number

        metamethod __call: function(self, path: string, x: number, y: number): DirectoryDropped
    end

    --- Event triggered when a file is dragged and dropped onto the window.
    --- @see https://love2d.org/wiki/love.filedropped
    record FileDropped is tecs.Event
        --- The unopened File object representing the file that was dropped.
        file: love.filesystem.DroppedFile
        --- X position where the file was dropped.
        x: number
        --- Y position where the file was dropped.
        y: number

        metamethod __call: function(self, file: love.filesystem.DroppedFile, x: number, y: number): FileDropped
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

    --- Event triggered when the window is exposed and needs to be redrawn.
    --- @see https://love2d.org/wiki/love.exposed
    record Exposed is tecs.Event
        metamethod __call: function(self): Exposed
    end

    --- Event triggered when the window is fully occluded by another window.
    --- @see https://love2d.org/wiki/love.occluded
    record Occluded is tecs.Event
        metamethod __call: function(self): Occluded
    end

    ---------------------------------------------------------------------------
    -- System events
    ---------------------------------------------------------------------------

    --- Sent directly to the target that is losing routed input ownership.
    record InputCaptureLost is tecs.Event
        from: string
        to: string
        metamethod __call: function(self, from: string, to: string): InputCaptureLost
    end

    --- Sent directly to the target that is gaining routed input ownership.
    record InputCaptureGained is tecs.Event
        from: string
        to: string
        metamethod __call: function(self, from: string, to: string): InputCaptureGained
    end

    --- Event triggered when the system locale changes.
    --- @see https://love2d.org/wiki/love.localechanged
    record LocaleChanged is tecs.Event
        metamethod __call: function(self): LocaleChanged
    end

    --- Event triggered when the system theme changes.
    --- @see https://love2d.org/wiki/love.themechanged
    record ThemeChanged is tecs.Event
        --- The new theme ("light" or "dark").
        theme: string

        metamethod __call: function(self, theme: string): ThemeChanged
    end

    ---------------------------------------------------------------------------
    -- Drag and Drop events
    ---------------------------------------------------------------------------

    --- Event triggered when a drag operation begins over the window.
    --- @see https://love2d.org/wiki/love.dropbegan
    record DropBegan is tecs.Event
        --- X position where the drag began.
        x: number
        --- Y position where the drag began.
        y: number

        metamethod __call: function(self, x: number, y: number): DropBegan
    end

    --- Event triggered when a drag operation moves over the window.
    --- @see https://love2d.org/wiki/love.dropmoved
    record DropMoved is tecs.Event
        --- X position of the drag.
        x: number
        --- Y position of the drag.
        y: number

        metamethod __call: function(self, x: number, y: number): DropMoved
    end

    --- Event triggered when a drag operation completes.
    --- @see https://love2d.org/wiki/love.dropcompleted
    record DropCompleted is tecs.Event
        --- X position where the drop completed.
        x: number
        --- Y position where the drop completed.
        y: number

        metamethod __call: function(self, x: number, y: number): DropCompleted
    end

    ---------------------------------------------------------------------------
    -- Audio events
    ---------------------------------------------------------------------------

    --- Event triggered when an audio device is disconnected.
    --- @see https://love2d.org/wiki/love.audiodisconnected
    record AudioDisconnected is tecs.Event
        metamethod __call: function(self): AudioDisconnected
    end

    ---------------------------------------------------------------------------
    -- Sensor events
    ---------------------------------------------------------------------------

    --- Event triggered when a device sensor is updated.
    --- @see https://love2d.org/wiki/love.sensorupdated
    record SensorUpdated is tecs.Event
        --- The type of sensor ("accelerometer" or "gyroscope").
        sensorType: love.sensor.SensorType
        --- X component of the sensor data.
        x: number
        --- Y component of the sensor data.
        y: number
        --- Z component of the sensor data.
        z: number

        metamethod __call: function(
            self, sensorType: love.sensor.SensorType, x: number, y: number, z: number
        ): SensorUpdated
    end

    --- Event triggered when a joystick sensor is updated.
    --- @see https://love2d.org/wiki/love.joysticksensorupdated
    record JoystickSensorUpdated is tecs.Event
        --- The joystick with the sensor.
        joystick: love.joystick.Joystick
        --- The type of sensor ("accelerometer" or "gyroscope").
        sensorType: love.joystick.SensorType
        --- X component of the sensor data.
        x: number
        --- Y component of the sensor data.
        y: number
        --- Z component of the sensor data.
        z: number

        metamethod __call: function(
            self,
            joystick: love.joystick.Joystick,
            sensorType: love.joystick.SensorType,
            x: number,
            y: number,
            z: number
        ): JoystickSensorUpdated
    end

    ---------------------------------------------------------------------------
    -- Touch events
    ---------------------------------------------------------------------------

    --- Event triggered when a touch press is detected.
    --- @see https://love2d.org/wiki/love.touchpressed
    record TouchPressed is tecs.Event
        --- The identifier for the touch press.
        id: any
        --- X position of the touch.
        x: number
        --- Y position of the touch.
        y: number
        --- Amount of pressure being applied (0-1).
        pressure: number
        --- The type of touchscreen or touchpad.
        deviceType: love.touch.TouchDeviceType
        --- True if the touch is a mouse event.
        isMouse: boolean

        metamethod __call: function(
            self,
            id: any,
            x: number,
            y: number,
            pressure: number,
            deviceType: love.touch.TouchDeviceType,
            isMouse: boolean
        ): TouchPressed
    end

    --- Event triggered when a touch is moved.
    --- @see https://love2d.org/wiki/love.touchmoved
    record TouchMoved is tecs.Event
        --- The identifier for the touch press.
        id: any
        --- X position of the touch.
        x: number
        --- Y position of the touch.
        y: number
        --- X component of movement delta.
        dx: number
        --- Y component of movement delta.
        dy: number
        --- Amount of pressure being applied (0-1).
        pressure: number
        --- The type of touchscreen or touchpad.
        deviceType: love.touch.TouchDeviceType
        --- True if the touch is a mouse event.
        isMouse: boolean

        metamethod __call: function(
            self,
            id: any,
            x: number,
            y: number,
            dx: number,
            dy: number,
            pressure: number,
            deviceType: love.touch.TouchDeviceType,
            isMouse: boolean
        ): TouchMoved
    end

    --- Event triggered when a touch is released.
    --- @see https://love2d.org/wiki/love.touchreleased
    record TouchReleased is tecs.Event
        --- The identifier for the touch press.
        id: any
        --- X position of the touch.
        x: number
        --- Y position of the touch.
        y: number
        --- Amount of pressure being applied (0-1).
        pressure: number
        --- The type of touchscreen or touchpad.
        deviceType: love.touch.TouchDeviceType
        --- True if the touch is a mouse event.
        isMouse: boolean

        metamethod __call: function(
            self,
            id: any,
            x: number,
            y: number,
            pressure: number,
            deviceType: love.touch.TouchDeviceType,
            isMouse: boolean
        ): TouchReleased
    end
end

---------------------------------------------------------------------------
-- Event constructors
---------------------------------------------------------------------------

tecs.newFFIEvent(events.Quit, {
    {"exitstatus", "int32_t"}
}, "Love2D_Quit")

events.KeyPressed.init = function(
    e: events.KeyPressed,
    key: love.keyboard.KeyConstant,
    scancode: love.keyboard.Scancode,
    isrepeat: boolean
)
    e.key, e.scancode, e.isrepeat = key, scancode, isrepeat
end
tecs.newEvent(events.KeyPressed)

events.KeyReleased.init = function(e: events.KeyReleased, key: love.keyboard.KeyConstant, scancode: love.keyboard.Scancode)
    e.key, e.scancode = key, scancode
end
tecs.newEvent(events.KeyReleased)

events.TextInput.init = function(e: events.TextInput, text: string)
    e.text = text
end
tecs.newEvent(events.TextInput)

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

tecs.newFFIEvent(events.MouseMoved, {
    {"x", "float"},
    {"y", "float"},
    {"dx", "float"},
    {"dy", "float"},
    {"istouch", "bool"}
}, "Love2D_MouseMoved")

events.WheelMoved.init = function(
    e: events.WheelMoved, x: number, y: number, direction: love.mouse.WheelDirection
)
    e.x, e.y, e.direction = x, y, direction
end
tecs.newEvent(events.WheelMoved)

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

events.JoystickAdded.init = function(e: events.JoystickAdded, joystick: love.joystick.Joystick)
    e.joystick = joystick
end
tecs.newEvent(events.JoystickAdded)

events.JoystickRemoved.init = function(e: events.JoystickRemoved, joystick: love.joystick.Joystick)
    e.joystick = joystick
end
tecs.newEvent(events.JoystickRemoved)

events.GamepadAxis.init = function(
    e: events.GamepadAxis,
    joystick: love.joystick.Joystick,
    axis: love.joystick.GamepadAxis,
    value: number
)
    e.joystick, e.axis, e.value = joystick, axis, value
end
tecs.newEvent(events.GamepadAxis)

events.GamepadPressed.init = function(
    e: events.GamepadPressed, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton
)
    e.joystick, e.button = joystick, button
end
tecs.newEvent(events.GamepadPressed)

events.GamepadReleased.init = function(
    e: events.GamepadReleased, joystick: love.joystick.Joystick, button: love.joystick.GamepadButton
)
    e.joystick, e.button = joystick, button
end
tecs.newEvent(events.GamepadReleased)

events.JoystickPressed.init = function(
    e: events.JoystickPressed, joystick: love.joystick.Joystick, button: number
)
    e.joystick, e.button = joystick, button
end
tecs.newEvent(events.JoystickPressed)

events.JoystickReleased.init = function(
    e: events.JoystickReleased, joystick: love.joystick.Joystick, button: number
)
    e.joystick, e.button = joystick, button
end
tecs.newEvent(events.JoystickReleased)

events.JoystickHat.init = function(
    e: events.JoystickHat,
    joystick: love.joystick.Joystick,
    hat: number,
    direction: love.joystick.JoystickHat
)
    e.joystick, e.hat, e.direction = joystick, hat, direction
end
tecs.newEvent(events.JoystickHat)

events.DirectoryDropped.init = function(e: events.DirectoryDropped, path: string, x: number, y: number)
    e.path, e.x, e.y = path, x, y
end
tecs.newEvent(events.DirectoryDropped)

events.FileDropped.init = function(e: events.FileDropped, file: love.filesystem.DroppedFile, x: number, y: number)
    e.file, e.x, e.y = file, x, y
end
tecs.newEvent(events.FileDropped)

tecs.newFFIEvent(events.Exposed, {}, "Love2D_Exposed")

tecs.newFFIEvent(events.Occluded, {}, "Love2D_Occluded")

tecs.newFFIEvent(events.LocaleChanged, {}, "Love2D_LocaleChanged")

events.ThemeChanged.init = function(e: events.ThemeChanged, theme: string)
    e.theme = theme
end
tecs.newEvent(events.ThemeChanged)

tecs.newFFIEvent(events.DropBegan, {
    {"x", "float"},
    {"y", "float"}
}, "Love2D_DropBegan")

tecs.newFFIEvent(events.DropMoved, {
    {"x", "float"},
    {"y", "float"}
}, "Love2D_DropMoved")

tecs.newFFIEvent(events.DropCompleted, {
    {"x", "float"},
    {"y", "float"}
}, "Love2D_DropCompleted")

tecs.newFFIEvent(events.AudioDisconnected, {}, "Love2D_AudioDisconnected")

events.InputCaptureLost.init = function(e: events.InputCaptureLost, from: string, to: string)
    e.from, e.to = from, to
end
tecs.newEvent(events.InputCaptureLost)

events.InputCaptureGained.init = function(e: events.InputCaptureGained, from: string, to: string)
    e.from, e.to = from, to
end
tecs.newEvent(events.InputCaptureGained)

events.SensorUpdated.init = function(
    e: events.SensorUpdated, sensorType: love.sensor.SensorType, x: number, y: number, z: number
)
    e.sensorType, e.x, e.y, e.z = sensorType, x, y, z
end
tecs.newEvent(events.SensorUpdated)

events.JoystickSensorUpdated.init = function(
    e: events.JoystickSensorUpdated,
    joystick: love.joystick.Joystick,
    sensorType: love.joystick.SensorType,
    x: number,
    y: number,
    z: number
)
    e.joystick, e.sensorType, e.x, e.y, e.z = joystick, sensorType, x, y, z
end
tecs.newEvent(events.JoystickSensorUpdated)

events.TouchPressed.init = function(
    e: events.TouchPressed,
    id: any,
    x: number,
    y: number,
    pressure: number,
    deviceType: love.touch.TouchDeviceType,
    isMouse: boolean
)
    e.id, e.x, e.y, e.pressure, e.deviceType, e.isMouse = id, x, y, pressure, deviceType, isMouse
end
tecs.newEvent(events.TouchPressed)

events.TouchMoved.init = function(
    e: events.TouchMoved,
    id: any,
    x: number,
    y: number,
    dx: number,
    dy: number,
    pressure: number,
    deviceType: love.touch.TouchDeviceType,
    isMouse: boolean
)
    e.id, e.x, e.y, e.dx, e.dy, e.pressure, e.deviceType, e.isMouse = id, x, y, dx, dy, pressure, deviceType, isMouse
end
tecs.newEvent(events.TouchMoved)

events.TouchReleased.init = function(
    e: events.TouchReleased,
    id: any,
    x: number,
    y: number,
    pressure: number,
    deviceType: love.touch.TouchDeviceType,
    isMouse: boolean
)
    e.id, e.x, e.y, e.pressure, e.deviceType, e.isMouse = id, x, y, pressure, deviceType, isMouse
end
tecs.newEvent(events.TouchReleased)

return events
