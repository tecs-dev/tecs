---
description: "Type-safe Tecs event wrappers for Love2D callbacks (MousePressed, KeyPressed, Resize, JoystickAdded) observed at address 0"
outline: deep
---

# Love2D events

Tecs provides type-safe event wrappers for Love2D callbacks, allowing you to observe and react to window, input, and
system events through the [event system](../tecs/events.md). Love2D events are automatically captured and emitted
by Tecs when you use the framework. You can observe these events on the [world](../tecs/world.md) or use
traditional Love2D callbacks.

::: tip World-level events use address `0`
Love2D events are world-level events, so use address `0` when observing them.
See [Events](../tecs/events.md#address-types) for more on address types.
:::

::: tip Pass the event value, not the type
`require("tecs2d.events")` and pass the value (e.g. `events.MousePressed`) to
`observe`/`emit`. Passing `tecs2d.MousePressed` fails to type-check — that name
is the type, not the value.
:::

## Event flow

When an event is emitted from Love2D, Tecs emits the event to the Tecs event system and then emits the event to any
registered `love.*` function. This means you can use both approaches:

```teal
local events = require("tecs2d.events")

-- Tecs events work
world:observe(0, events.MousePressed, function(e: events.MousePressed)
    handleClick(e.x, e.y, e.button)
end)

-- Love2D callbacks work too
function love.mousepressed(x, y, button, istouch, presses)
    handleClick(x, y, button)
end
```

## Available events

### Window events

#### Focus

Triggered when the window gains or loses focus. *See [love.focus](https://love2d.org/wiki/love.focus)*

| Property    | Type        | Description                                |
| ----------- | ----------- | ------------------------------------------ |
| `visible`   | `boolean`   | `true` if the window has focus             |

```teal
world:observe(0, events.Focus, function(e: events.Focus)
    if e.visible then
        resumeGame()
    else
        pauseGame()
    end
end)
```

#### MouseFocus

Triggered when the window gains or loses mouse focus. *See [love.mousefocus](https://love2d.org/wiki/love.mousefocus)*

| Property   | Type        | Description                                |
| ---------- | ----------- | ------------------------------------------ |
| `focus`    | `boolean`   | `true` if the window has mouse focus       |

```teal
world:observe(0, events.MouseFocus, function(e: events.MouseFocus)
    if not e.focus then
        stopDragging()
    end
end)
```

#### Resize

Triggered when the window is resized. *See [love.resize](https://love2d.org/wiki/love.resize)*

| Property   | Type       | Description                |
| ---------- | ---------- | -------------------------- |
| `width`    | `number`   | New width of the window    |
| `height`   | `number`   | New height of the window   |

```teal
world:observe(0, events.Resize, function(e: events.Resize)
    camera:updateViewport(e.width, e.height)
end)
```

#### Visible

Triggered when the window is shown or hidden. *See [love.visible](https://love2d.org/wiki/love.visible)*

| Property    | Type        | Description                                |
| ----------- | ----------- | ------------------------------------------ |
| `visible`   | `boolean`   | `true` if the window is visible            |

```teal
world:observe(0, events.Visible, function(e: events.Visible)
    if not e.visible then
        audio:pauseMusic()
    else
        audio:resumeMusic()
    end
end)
```

#### Exposed

Triggered when the window is exposed and needs to be redrawn. *See [love.exposed](https://love2d.org/wiki/love.exposed)*

No properties.

#### Occluded

Triggered when the window is fully occluded by another window. *See
[love.occluded](https://love2d.org/wiki/love.occluded)*

No properties.

### Keyboard events

#### KeyPressed

Triggered when a key is pressed. *See [love.keypressed](https://love2d.org/wiki/love.keypressed)*

| Property     | Type                          | Description                                                                |
| ------------ | ----------------------------- | -------------------------------------------------------------------------- |
| `key`        | `love.keyboard.KeyConstant`   | The key that was pressed (e.g., `"space"`, `"a"`)                          |
| `scancode`   | `love.keyboard.Scancode`      | Hardware scancode for the key                                              |
| `isrepeat`   | `boolean`                     | Whether this is a repeat event. Delay depends on user's system settings.   |

```teal
world:observe(0, events.KeyPressed, function(e: events.KeyPressed)
    if e.key == "escape" then
        pauseGame()
    end
end)
```

#### KeyReleased

Triggered when a key is released. *See [love.keyreleased](https://love2d.org/wiki/love.keyreleased)*

| Property     | Type                         | Description                                      |
| ------------ | ---------------------------- | ------------------------------------------------ |
| `key`        | `love.keyboard.KeyConstant`  | The key that was released                        |
| `scancode`   | `love.keyboard.Scancode`     | Hardware scancode for the key                    |

```teal
world:observe(0, events.KeyReleased, function(e: events.KeyReleased)
    if e.key == "space" then
        endChargeAttack()
    end
end)
```

### Mouse events

#### MousePressed

Triggered when a mouse button is pressed. *See [love.mousepressed](https://love2d.org/wiki/love.mousepressed)*

| Property    | Type        | Description                                             |
| ----------- | ----------- | ------------------------------------------------------- |
| `x`         | `number`    | Mouse x position in pixels                              |
| `y`         | `number`    | Mouse y position in pixels                              |
| `button`    | `number`    | Button index (1 = left, 2 = right, 3 = middle)          |
| `istouch`   | `boolean`   | `true` if from a touchscreen                            |
| `presses`   | `number`    | Number of clicks for double/triple-click detection      |

```teal
world:observe(0, events.MousePressed, function(e: events.MousePressed)
    if e.button == 1 and e.presses == 2 then
        handleDoubleClick(e.x, e.y)
    end
end)
```

#### MouseReleased

Triggered when a mouse button is released. *See [love.mousereleased](https://love2d.org/wiki/love.mousereleased)*

| Property    | Type        | Description                                             |
| ----------- | ----------- | ------------------------------------------------------- |
| `x`         | `number`    | Mouse x position in pixels                              |
| `y`         | `number`    | Mouse y position in pixels                              |
| `button`    | `number`    | Button index (1 = left, 2 = right, 3 = middle)          |
| `istouch`   | `boolean`   | `true` if from a touchscreen                            |
| `presses`   | `number`    | Number of clicks                                        |

```teal
world:observe(0, events.MouseReleased, function(e: events.MouseReleased)
    if e.button == 1 then
        endDragOperation(e.x, e.y)
    end
end)
```

### Joystick events

#### JoystickAdded

Triggered when a joystick/gamepad is connected. *See [love.joystickadded](https://love2d.org/wiki/love.joystickadded)*

| Property     | Type                         | Description                    |
| ------------ | ---------------------------- | ------------------------------ |
| `joystick`   | `love.joystick.Joystick`     | The newly connected joystick   |

```teal
world:observe(0, events.JoystickAdded, function(e: events.JoystickAdded)
    if e.joystick:isGamepad() then
        setupGamepadMappings(e.joystick)
    end
end)
```

#### JoystickRemoved

Triggered when a joystick/gamepad is disconnected. *See
[love.joystickremoved](https://love2d.org/wiki/love.joystickremoved)*

| Property     | Type                         | Description                       |
| ------------ | ---------------------------- | --------------------------------- |
| `joystick`   | `love.joystick.Joystick`     | The now-disconnected joystick     |

```teal
world:observe(0, events.JoystickRemoved, function(e: events.JoystickRemoved)
    if love.joystick.getJoystickCount() == 0 then
        switchToKeyboardControls()
    end
end)
```

### File events

#### DirectoryDropped

Triggered when a directory is dragged and dropped onto the window. *See
[love.directorydropped](https://love2d.org/wiki/love.directorydropped)*

| Property   | Type       | Description                                |
| ---------- | ---------- | ------------------------------------------ |
| `path`     | `string`   | Full platform-dependent directory path     |
| `x`        | `number`   | X position where the directory was dropped |
| `y`        | `number`   | Y position where the directory was dropped |

```teal
world:observe(0, events.DirectoryDropped, function(e: events.DirectoryDropped)
    love.filesystem.mount(e.path, "dropped")
    loadImagesFromDirectory("dropped")
end)
```

#### FileDropped

Triggered when a file is dragged and dropped onto the window. *See
[love.filedropped](https://love2d.org/wiki/love.filedropped)*

| Property   | Type                            | Description                            |
| ---------- | ------------------------------- | -------------------------------------- |
| `file`     | `love.filesystem.DroppedFile`   | The unopened file that was dropped     |
| `x`        | `number`                        | X position where the file was dropped  |
| `y`        | `number`                        | Y position where the file was dropped  |

```teal
world:observe(0, events.FileDropped, function(e: events.FileDropped)
    local filename = e.file:getFilename()
    if filename:match("%.png$") or filename:match("%.jpg$") then
        loadDroppedImage(e.file)
    end
end)
```

### Application events

#### Quit

Triggered when the application is about to close. *See [love.quit](https://love2d.org/wiki/love.quit)*

| Property       | Type        | Description        |
| -------------- | ----------- | ------------------ |
| `exitstatus`   | `integer`   | The exit code      |

```teal
world:observe(0, events.Quit, function(e: events.Quit)
    saveGameState()
    cleanupResources()
end)
```

#### LocaleChanged

Triggered when the system locale changes. *See [love.localechanged](https://love2d.org/wiki/love.localechanged)*

No properties.

#### ThemeChanged

Triggered when the system theme changes. *See [love.themechanged](https://love2d.org/wiki/love.themechanged)*

| Property   | Type       | Description                           |
| ---------- | ---------- | ------------------------------------- |
| `theme`    | `string`   | The new theme (`"light"` or `"dark"`) |

```teal
world:observe(0, events.ThemeChanged, function(e: events.ThemeChanged)
    updateUITheme(e.theme)
end)
```

#### AudioDisconnected

Triggered when the audio device is disconnected. *See
[love.audiodisconnected](https://love2d.org/wiki/love.audiodisconnected)*

No properties.

### Touch events

#### TouchPressed

Triggered when a touch press is detected. *See [love.touchpressed](https://love2d.org/wiki/love.touchpressed)*

| Property       | Type                            | Description                           |
| -------------- | ------------------------------- | ------------------------------------- |
| `id`           | `any`                           | Identifier for the touch press        |
| `x`            | `number`                        | X position of the touch               |
| `y`            | `number`                        | Y position of the touch               |
| `pressure`     | `number`                        | Pressure being applied (0-1)          |
| `deviceType`   | `love.touch.TouchDeviceType`    | Type of touchscreen or touchpad       |
| `isMouse`      | `boolean`                       | `true` if from mouse emulation        |

```teal
world:observe(0, events.TouchPressed, function(e: events.TouchPressed)
    handleTouch(e.id, e.x, e.y)
end)
```

#### TouchMoved

Triggered when a touch point moves. *See [love.touchmoved](https://love2d.org/wiki/love.touchmoved)*

| Property       | Type                            | Description                           |
| -------------- | ------------------------------- | ------------------------------------- |
| `id`           | `any`                           | Identifier for the touch press        |
| `x`            | `number`                        | X position of the touch               |
| `y`            | `number`                        | Y position of the touch               |
| `dx`           | `number`                        | X component of movement delta         |
| `dy`           | `number`                        | Y component of movement delta         |
| `pressure`     | `number`                        | Pressure being applied (0-1)          |
| `deviceType`   | `love.touch.TouchDeviceType`    | Type of touchscreen or touchpad       |
| `isMouse`      | `boolean`                       | `true` if from mouse emulation        |

```teal
world:observe(0, events.TouchMoved, function(e: events.TouchMoved)
    handleTouchDrag(e.id, e.dx, e.dy)
end)
```

#### TouchReleased

Triggered when a touch point is released. *See [love.touchreleased](https://love2d.org/wiki/love.touchreleased)*

| Property       | Type                            | Description                           |
| -------------- | ------------------------------- | ------------------------------------- |
| `id`           | `any`                           | Identifier for the touch press        |
| `x`            | `number`                        | X position of the touch               |
| `y`            | `number`                        | Y position of the touch               |
| `pressure`     | `number`                        | Pressure being applied (0-1)          |
| `deviceType`   | `love.touch.TouchDeviceType`    | Type of touchscreen or touchpad       |
| `isMouse`      | `boolean`                       | `true` if from mouse emulation        |

```teal
world:observe(0, events.TouchReleased, function(e: events.TouchReleased)
    handleTouchRelease(e.id, e.x, e.y)
end)
```

### Sensor events

#### SensorUpdated

Triggered when a device sensor is updated. *See [love.sensorupdated](https://love2d.org/wiki/love.sensorupdated)*

| Property       | Type                         | Description                                         |
| -------------- | ---------------------------- | --------------------------------------------------- |
| `sensorType`   | `love.sensor.SensorType`     | Type of sensor (`"accelerometer"` or `"gyroscope"`) |
| `x`            | `number`                     | X component of sensor data                          |
| `y`            | `number`                     | Y component of sensor data                          |
| `z`            | `number`                     | Z component of sensor data                          |

```teal
world:observe(0, events.SensorUpdated, function(e: events.SensorUpdated)
    handleSensor(e.sensorType, e.x, e.y, e.z)
end)
```

#### JoystickSensorUpdated

Triggered when a joystick sensor is updated. *See
[love.joysticksensorupdated](https://love2d.org/wiki/love.joysticksensorupdated)*

| Property       | Type                            | Description                                         |
| -------------- | ------------------------------- | --------------------------------------------------- |
| `joystick`     | `love.joystick.Joystick`        | The joystick with the sensor                        |
| `sensorType`   | `love.joystick.SensorType`      | Type of sensor (`"accelerometer"` or `"gyroscope"`) |
| `x`            | `number`                        | X component of sensor data                          |
| `y`            | `number`                        | Y component of sensor data                          |
| `z`            | `number`                        | Z component of sensor data                          |

```teal
world:observe(0, events.JoystickSensorUpdated, function(e: events.JoystickSensorUpdated)
    handleJoystickSensor(e.joystick, e.sensorType, e.x, e.y, e.z)
end)
```

### Drag-and-drop lifecycle events

#### DropBegan

Triggered when a drag operation begins over the window.

| Property   | Type       | Description                      |
| ---------- | ---------- | -------------------------------- |
| `x`        | `number`   | X position where drag started    |
| `y`        | `number`   | Y position where drag started    |

```teal
world:observe(0, events.DropBegan, function(e: events.DropBegan)
    showDropZone()
end)
```

#### DropMoved

Triggered when a drag operation moves over the window.

| Property   | Type       | Description                |
| ---------- | ---------- | -------------------------- |
| `x`        | `number`   | Current drag x position    |
| `y`        | `number`   | Current drag y position    |

```teal
world:observe(0, events.DropMoved, function(e: events.DropMoved)
    updateDropHighlight(e.x, e.y)
end)
```

#### DropCompleted

Triggered when a drag operation is completed over the window.

| Property   | Type       | Description                            |
| ---------- | ---------- | -------------------------------------- |
| `x`        | `number`   | X position where drop completed        |
| `y`        | `number`   | Y position where drop completed        |

```teal
world:observe(0, events.DropCompleted, function(e: events.DropCompleted)
    hideDropZone()
end)
```
