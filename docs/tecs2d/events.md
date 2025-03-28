---
outline: deep
---

# Love2D events

Tecs2D provides type-safe event wrappers for Love2D callbacks, allowing you to observe and react to window, input, and
system events through the [event system](../reference/events.md). Love2D events are automatically captured and emitted
by Tecs2D when you use the framework. You can observe these events on the [world](../reference/world.md) or use
traditional Love2D callbacks.

## Event flow

When an input event occurs: (1) **Tecs2D handler** captures it first, (2) event is **emitted to world observers**
(if any exist), (3) traditional **love.* callbacks** are also called (if defined).

```
Love2D Events ⌨️🕹️🎮🖱️
        │
        │ Enqueues
        ▼
Tecs2D Handler 🌵
        │
        ├─── Emits ────────► Tecs Observers 📬
        │
        └─── Delegates ────► love.* callbacks ❤️
```

This means you can use both approaches:

```lua
local tecs2d = require("tecs2d")

-- Tecs2D event observation (recommended)
world:observe(tecs2d.events.MousePressed, function(e: tecs2d.events.MousePressed)
    handleClick(e.x, e.y, e.button)
end)

-- Traditional Love2D callback (still works)
function love.mousepressed(x, y, button, istouch, presses)
    -- This will also be called
end
```

## Available events

### Window events

#### Focus

Triggered when the window gains or loses focus.

```lua
local tecs2d = require("tecs2d")

world:observe(tecs2d.events.Focus, function(e: tecs2d.events.Focus)
    if e.visible then
        resumeGame()
    else
        pauseGame()
    end
end)
```

*See [love.focus](https://love2d.org/wiki/love.focus)*

#### MouseFocus

Triggered when the window gains or loses mouse focus.

```lua
world:observe(events.MouseFocus, function(e: events.MouseFocus)
    if not e.focus then
        -- Mouse left the window, stop dragging
        stopDragging()
    end
end)
```

*See [love.mousefocus](https://love2d.org/wiki/love.mousefocus)*

#### Resize

Triggered when the window is resized.

```lua
world:observe(events.Resize, function(e: events.Resize)
    print("Window resized to", e.width, "x", e.height)
    -- Update camera viewport
    camera:updateViewport(e.width, e.height)
end)
```

*See [love.resize](https://love2d.org/wiki/love.resize)*

#### Visible

Triggered when the window is shown or hidden.

```lua
world:observe(events.Visible, function(e: events.Visible)
    if not e.visible then
        -- Window minimized, pause music
        audio:pauseMusic()
    else
        audio:resumeMusic()
    end
end)
```

*See [love.visible](https://love2d.org/wiki/love.visible)*

### Mouse events

#### MousePressed

Triggered when a mouse button is pressed.

```lua
world:observe(events.MousePressed, function(e: events.MousePressed)
    -- e.x, e.y: Mouse position
    -- e.button: Button number (1=left, 2=right, 3=middle)
    -- e.istouch: True if from touchscreen
    -- e.presses: Number of clicks (for double-click detection)

    if e.button == 1 and e.presses == 2 then
        handleDoubleClick(e.x, e.y)
    end
end)
```

*See [love.mousepressed](https://love2d.org/wiki/love.mousepressed)*

#### MouseReleased

Triggered when a mouse button is released.

```lua
world:observe(events.MouseReleased, function(e: events.MouseReleased)
    if e.button == 1 then
        endDragOperation(e.x, e.y)
    end
end)
```

*See [love.mousereleased](https://love2d.org/wiki/love.mousereleased)*

### Joystick events

#### JoystickAdded

Triggered when a joystick/gamepad is connected.

```lua
world:observe(events.JoystickAdded, function(e: events.JoystickAdded)
    local name = e.joystick:getName()
    print("Controller connected:", name)

    -- Configure the new joystick
    if e.joystick:isGamepad() then
        setupGamepadMappings(e.joystick)
    end
end)
```

*See [love.joystickadded](https://love2d.org/wiki/love.joystickadded)*

#### JoystickRemoved

Triggered when a joystick/gamepad is disconnected.

```lua
world:observe(events.JoystickRemoved, function(e: events.JoystickRemoved)
    print("Controller disconnected")

    -- Switch to keyboard controls if no controllers left
    if love.joystick.getJoystickCount() == 0 then
        switchToKeyboardControls()
    end
end)
```

*See [love.joystickremoved](https://love2d.org/wiki/love.joystickremoved)*

### File events

#### DirectoryDropped

Triggered when a directory is dragged and dropped onto the window.

```lua
world:observe(events.DirectoryDropped, function(e: events.DirectoryDropped)
    print("Directory dropped:", e.path)

    -- Mount the directory for reading
    love.filesystem.mount(e.path, "dropped")

    -- Load all images from the directory
    loadImagesFromDirectory("dropped")
end)
```

*See [love.directorydropped](https://love2d.org/wiki/love.directorydropped)*

#### FileDropped

Triggered when a file is dragged and dropped onto the window.

```lua
world:observe(events.FileDropped, function(e: events.FileDropped)
    local file = e.file
    local filename = file:getFilename()

    print("File dropped:", filename)

    -- Check file extension and handle accordingly
    if filename:match("%.png$") or filename:match("%.jpg$") then
        loadDroppedImage(file)
    elseif filename:match("%.lua$") or filename:match("%.tl$") then
        loadDroppedScript(file)
    end
end)
```

*See [love.filedropped](https://love2d.org/wiki/love.filedropped)*

### Application events

#### Quit

Triggered when the application is about to close.

```lua
world:observe(events.Quit, function(e: events.Quit)
    print("Quitting with status:", e.exitstatus)

    -- Save game state
    saveGameState()

    -- Cleanup resources
    cleanupResources()

    -- The quit event is handled automatically by Tecs2D
    -- Return false from love.quit() to prevent quitting
end)
```

*See [love.quit](https://love2d.org/wiki/love.quit)*

## Integration with systems

Use events within your [systems](../reference/systems.md) for reactive gameplay:

```lua
world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        -- React to window resize by updating UI
        world:observe(events.Resize, function(e: events.Resize)
            local uiEntities = world:query({ UIElement })
            for _, entity in ipairs(uiEntities) do
                local ui = entity[UIElement]
                ui:updateLayout(e.width, e.height)
            end
        end)

        -- Handle file drops for level editor
        world:observe(events.FileDropped, function(e: events.FileDropped)
            if levelEditor.active then
                levelEditor:importAsset(e.file)
            end
        end)
    end
})
```

*See [Queries](../reference/queries.md) for entity queries and [Phases](../reference/phases.md) for execution phases*

## Best practices

1. **Use events for decoupling**: React to events instead of checking states
2. **Prefer Tecs2D events**: Use the event system over Love2D callbacks for consistency
3. **Check for observers**: Only emit custom events if there are listeners
4. **Clean up observers**: Remove observers when entities are destroyed
5. **Use appropriate phases**: Set up observers in Startup phase