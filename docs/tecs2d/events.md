---
description: "Type-safe LÖVE event wrappers, routed interaction ownership, input capture events, and global lifecycle delivery"
outline: deep
---

# Love2D events

Tecs provides type-safe event wrappers for Love2D callbacks, allowing you to observe and react to window, input, and
system events through the [event system](../tecs/events.md). Love2D events are automatically captured and emitted
by Tecs when you use the framework. You can observe these events on the [world](../tecs/world.md) or use
traditional Love2D callbacks.

::: tip Address `0` is the base input target
Address-0 observers receive routed interaction events only when delivery reaches `input.base`. Window, lifecycle, and
device-connection events remain globally delivered at address `0`. See [Input layers](/tecs2d/input/#input-layers)
and [Events](../tecs/events.md#address-types).
:::

## Event flow

When an interaction arrives from Love2D, Tecs updates polling state, notifies `input.raw`, and emits the event to the
current top input target. A layer may handle it or explicitly continue with `layer.parent:emit(event)`. With no pushed
layer, the base target emits to address-0 world observers. Tecs then invokes any registered `love.*` callback.

```text
physical interaction
├─ input.raw (always notified when it observes this type)
└─ current top target
   └─ parent only after parent:emit(event)
      └─ ...
         └─ input.base → world address 0
```

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

Window and device-topology events such as `Resize`, `Focus`, `JoystickAdded`, and `JoystickRemoved` do not participate
in the input stack. They always reach address-0 observers. `input.raw` is the explicit always-on stream for routed
interaction events.

Direct `love.*` callbacks are invoked after this flow but remain outside it: an input layer cannot suppress them. Use
routed Tecs observers for gameplay and modal UI, and direct callbacks only when intentionally global behavior is
appropriate.

### Routed event families

The routed stream covers:

- `KeyPressed`, `KeyReleased`, and `TextInput`.
- `MousePressed`, `MouseReleased`, `MouseMoved`, and `WheelMoved`.
- `TouchPressed`, `TouchMoved`, and `TouchReleased`.
- `GamepadAxis`, `GamepadPressed`, and `GamepadReleased`.
- `JoystickPressed`, `JoystickReleased`, and `JoystickHat`.
- `SensorUpdated`, `JoystickSensorUpdated`, directory/file drops, and drop gestures.
- `InputCaptureLost` and `InputCaptureGained`, delivered directly to affected targets rather than forwarded.

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

#### TextInput

Triggered when LÖVE produces text according to the active keyboard layout. Use this for text fields rather than
converting `KeyPressed` values yourself. This is a routed interaction event.

| Property | Type | Description |
| --- | --- | --- |
| `text` | `string` | Text entered by the user. |

```teal
world:observe(0, events.TextInput, function(e: events.TextInput)
    nameField = nameField .. e.text
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

#### MouseMoved

Triggered when the pointer moves. This is a routed interaction event.

| Property | Type | Description |
| --- | --- | --- |
| `x` | `number` | Current mouse x position in pixels. |
| `y` | `number` | Current mouse y position in pixels. |
| `dx` | `number` | Horizontal movement since the previous mouse event. |
| `dy` | `number` | Vertical movement since the previous mouse event. |
| `istouch` | `boolean` | Whether the motion originated from a touchscreen. |

```teal
world:observe(0, events.MouseMoved, function(e: events.MouseMoved)
    updatePointer(e.x, e.y)
end)
```

#### WheelMoved

Triggered when the mouse wheel moves. This is a routed interaction event.

| Property | Type | Description |
| --- | --- | --- |
| `x` | `number` | Horizontal wheel movement. |
| `y` | `number` | Vertical wheel movement. |
| `direction` | `love.mouse.WheelDirection` | LÖVE 12 wheel direction, such as `"standard"` or `"flick"`. |

```teal
world:observe(0, events.WheelMoved, function(e: events.WheelMoved)
    zoomBy(e.y)
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

`JoystickAdded` and `JoystickRemoved` describe device topology and always reach address-0 observers. The interaction
events below are routed through the active input target.

#### GamepadAxis

Triggered when a standardized gamepad axis changes.

| Property | Type | Description |
| --- | --- | --- |
| `joystick` | `love.joystick.Joystick` | Device that produced the input. |
| `axis` | `love.joystick.GamepadAxis` | Standardized axis name. |
| `value` | `number` | Current axis value. |

```teal
world:observe(0, events.GamepadAxis, function(e: events.GamepadAxis)
    if e.axis == "leftx" then
        aimX = e.value
    end
end)
```

#### GamepadPressed

Triggered when a standardized gamepad button is pressed.

| Property | Type | Description |
| --- | --- | --- |
| `joystick` | `love.joystick.Joystick` | Device that produced the input. |
| `button` | `love.joystick.GamepadButton` | Standardized button name. |

#### GamepadReleased

Triggered when a standardized gamepad button is released. It has the same `joystick` and `button` properties as
`GamepadPressed`.

```teal
world:observe(0, events.GamepadPressed, function(e: events.GamepadPressed)
    if e.button == "a" then
        jump()
    end
end)
```

#### JoystickPressed

Triggered when a raw joystick button is pressed.

| Property | Type | Description |
| --- | --- | --- |
| `joystick` | `love.joystick.Joystick` | Device that produced the input. |
| `button` | `number` | Device-specific button index. |

#### JoystickReleased

Triggered when a raw joystick button is released. It has the same `joystick` and numeric `button` properties as
`JoystickPressed`.

#### JoystickHat

Triggered when a raw joystick hat changes direction.

| Property | Type | Description |
| --- | --- | --- |
| `joystick` | `love.joystick.Joystick` | Device that produced the input. |
| `hat` | `number` | Device-specific hat index. |
| `direction` | `love.joystick.JoystickHat` | Current direction, such as `"u"`, `"ld"`, or centered `"c"`. |

```teal
world:observe(0, events.JoystickHat, function(e: events.JoystickHat)
    updateHat(e.hat, e.direction)
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

### Input ownership events

Input ownership can change in the middle of an interaction. For example, gameplay may receive a mouse press that
starts a drag, then lose input to a pause menu or debugger before the matching release arrives. Because the new top
layer intercepts that release, gameplay cannot finish the drag normally and may remain stuck in a transient state.

Capture events give each owner a reliable boundary for that cleanup and restoration:

- On `InputCaptureLost`, cancel partial gestures, drag state, key repeat, text-editing state, hover effects, or pointer
  capture that should not survive behind a modal.
- On `InputCaptureGained`, recompute hover and focus, refresh cursor behavior, or restore other UI state that depends on
  being the active input owner.

Tecs automatically clears pending press/release edges, text, wheel movement, and fixed-step latches when the top owner
changes. Capture events exist for higher-level state that only the game or UI feature understands.

They are generated by [`input.pushLayer` and `input.popLayer`](/tecs2d/input/#capture-lifecycle), and by restoring the
snapshot-managed input topology, not by a LÖVE callback. Each event is sent directly to the target losing or gaining
ownership and is never forwarded through the stack. A runtime-only overlay remains the owner while game layers are
restored beneath it, so that restore emits no capture change until the overlay closes.

#### InputCaptureLost

Sent to the outgoing top target before capture changes. Use it to abandon interactions that will no longer receive
their normal completion event.

| Property | Type | Description |
| --- | --- | --- |
| `from` | `string` | Name of the target losing capture. |
| `to` | `string` | Name of the target gaining capture. |

#### InputCaptureGained

Sent to the incoming top target after capture changes. It has the same `from` and `to` properties. Use it to initialize
or refresh state that should reflect the newly active owner.

```teal
local input = require("tecs2d.input")
local pause = input.newLayer("pause")

world:observe(0, events.InputCaptureLost, function(_event: events.InputCaptureLost)
    dragging = false -- gameplay will not receive the release while covered
end)

pause:observe(events.InputCaptureGained, function(_event: events.InputCaptureGained)
    refreshHoveredControl()
end)
```

Popping a middle layer emits neither capture event because the top owner remains unchanged.

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
