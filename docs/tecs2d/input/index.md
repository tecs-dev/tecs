---
description: "Polling, routed events, input layers, capture ownership, and latch-based keyboard, mouse, and gamepad input"
outline: deep
---

# Input Handling

The input module provides low-level access to keyboard, mouse, and gamepad state. Use this for direct device queries
like "is spacebar down?" or "where is the mouse?".

For rebindable game controls (jump, attack, move), see [Controller](/tecs2d/input/controller/).

## Getting Started

The input module is globally available and automatically managed by Tecs:

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

love.run = tecs2d.run({
    fps = 60,
    game = function(world)
        -- Use input directly in your systems
        if input.isKeyPressed("space") then
            -- Handle input
        end
    end
})
```

## Keyboard input

Check keyboard state using the input module:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Check if a key is currently down (pressed or held)
if input.isKeyDown("space") then
    player:jump()
end

-- Check if a key was just pressed this frame
if input.isKeyPressed("escape") then
    pauseGame()
end

-- Check if a key was just released this frame
if input.isKeyReleased("e") then
    interact()
end
```

*See [love.keypressed](https://love2d.org/wiki/love.keypressed) and
[love.keyreleased](https://love2d.org/wiki/love.keyreleased) for keyboard events*

### Text input

For text entry (chat boxes, name fields, etc.), use `getTextInput`, which captures actual typed characters with
proper keyboard layout handling:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Get text typed this frame
local text = input.getTextInput()
if text ~= "" then
    chatBox:appendText(text)
end

-- Example text input field system
world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        if activeTextField then
            -- Append typed text
            activeTextField.text = activeTextField.text .. input.getTextInput()

            -- Handle backspace
            if input.isKeyPressed("backspace") then
                activeTextField.text = activeTextField.text:sub(1, -2)
            end
        end
    end
})
```

*See [love.textinput](https://love2d.org/wiki/love.textinput) for more about text input handling*

## Mouse input

You can get the current mouse X and Y position using `input`:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

local x, y = input.getMousePosition()
```

You can check if the mouse wheel was moved using `getMouseWheelMovement()`:

```teal
local dx, dy = input.getMouseWheelMovement()
if dy ~= 0 then
    zoom = zoom + dy * 0.1
end
```

You can check mouse button states:

```teal
if input.isMouseDown(1) then
    -- Button held
end

if input.isMousePressed(1) then
    -- Just pressed
end

if input.isMouseReleased(1) then
    -- Just released
end
```

### Mouse button reference
* **1**: Primary button (usually left)
* **2**: Secondary button (usually right)
* **3**: Middle button (wheel click)
* **4+**: Additional buttons (mouse-dependent)

*See [love.mousepressed](https://love2d.org/wiki/love.mousepressed) for more about mouse buttons*

## Gamepad and joystick input

Handle gamepad and joystick input for each connected device:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Iterate through connected joysticks
for joystick in pairs(input.joysticks) do
    local joystickInput = input.getJoystick(joystick)
    -- Check gamepad buttons (using standard names)
    if joystickInput:isGamepadButtonPressed("a") then
        player:jump()
    end

    if joystickInput:isGamepadButtonDown("x") then
        player:attack()
    end

    -- Read analog stick values
    local leftStickX = joystickInput.gamepadAxis["leftx"] or 0
    local leftStickY = joystickInput.gamepadAxis["lefty"] or 0
    player:move(leftStickX, leftStickY)

    -- Check joystick buttons by number
    if joystickInput:isJoystickButtonPressed(1) then
        handleButtonPress(1)
    end

    -- Read joystick hat positions
    local hatDirection = joystickInput.joystickHat[1]
    if hatDirection == "u" then
        navigateMenu("up")
    end
end
```

## Input layers

Input layers decide who owns physical interaction without changing the world's
[game-state stack](/tecs/states). The implicit `input.base` target represents normal gameplay. A pushed layer receives
polling and routed events while the base and lower layers are suppressed:

```teal
local input = require("tecs2d.input")

local pause = input.newLayer("pause")
input.pushLayer(pause)

if pause.view.isKeyPressed("escape") then
    input.popLayer(pause)
end
```

The module-level polling functions (`input.isKeyPressed`, `input.getMousePosition`, `input.getJoystick`, and the other
queries above) read `input.base.view`. Existing gameplay therefore participates in routing without being rewritten.
Code owned by a pushed layer reads that layer's `view` instead.

Only the current top target has a live view. Suppressed views report no keys or buttons, empty text, zero wheel motion,
mouse position `(0, 0)`, and an empty joystick state. Physical state is still recorded internally, so the correct held
state becomes visible to whichever target owns input after a capture change.

### Targets

| Target | Purpose | Polling | Routed events |
| --- | --- | --- | --- |
| `input.base` | Implicit bottom target for ordinary gameplay | Live only when it is top | Delegates to world observers at address `0` |
| `input.newLayer(name)` | Stable, snapshot-managed target for a game menu or modal | Live only while it is top | Uses observers registered directly on the layer |
| `input.newLayer(name, {snapshot = false})` | Runtime-only target for a debugger or development tool | Live only while it is top | Uses observers registered directly on the layer |
| `input.raw` | Always-on target for framework shortcuts, recording, and diagnostics | Always live | Runs before the routed top target and cannot be intercepted |

`input.base` and `input.raw` are permanent targets; do not push or pop them.

### Polling view API

`input.View` exposes the same routed polling surface for every target:

| Method | Live result |
| --- | --- |
| `view.isKeyDown(key)` | Whether the key is physically held. |
| `view.isKeyPressed(key)` | Whether the key gained its pressed edge this frame or fixed-step latch. |
| `view.isKeyReleased(key)` | Whether the key gained its released edge this frame or fixed-step latch. |
| `view.getTextInput()` | Text entered this frame. |
| `view.getMousePosition()` | Current mouse `x, y`. |
| `view.isMouseDown(button)` | Whether the mouse button is physically held. |
| `view.isMousePressed(button)` | Whether the mouse button gained its pressed edge. |
| `view.isMouseReleased(button)` | Whether the mouse button gained its released edge. |
| `view.getMouseWheelMovement()` | Wheel `dx, dy, direction` accumulated for this frame or fixed-step latch. |
| `view.getJoystick(joystick)` | Routed `JoystickInput` for gamepad axes, hats, and button queries. |

The module-level keyboard, mouse, wheel, text, and joystick functions have the same signatures and delegate to
`input.base.view`. `input.joysticks` is the current device-to-state map; iterate its keys for connected devices and use
`input.getJoystick(joystick)` to read routed gameplay state.

### Stack API

#### `input.newLayer`

Creates and registers an inactive, reusable layer. Its name is required, non-empty, and unique within the current
world because snapshots use it as the layer's stable identity.

```teal
function input.newLayer(name: string, options?: input.LayerOptions): input.Layer
```

Creating a layer does not activate it or change input ownership. Register observers once and reuse the same handle
across repeated opens and closes. Popping a layer does not remove its observers; use `stopObserving` when the
subscription itself should end.

Layers participate in snapshots by default. Runtime tools that must remain open independently of the loaded game
state opt out explicitly:

```teal
local debuggerInput = input.newLayer("debugger", {snapshot = false})
```

#### `input.pushLayer`

Pushes an inactive user layer into its configured lane.

```teal
function input.pushLayer(layer: input.Layer)
```

Pushing an already-active layer, `input.base`, or `input.raw` is an error. A normal snapshot-managed layer is pushed
above other game layers. A runtime-only layer is pushed above both lanes. If no runtime layer is open, the old top
loses capture, pending edge state is cleared, and the new game layer gains capture. Pushing a game layer while a
runtime overlay is open changes the saved game topology beneath it without disturbing the current input owner.

#### `input.popLayer`

Pops a specific layer by handle, including a layer below the current top.

```teal
function input.popLayer(layer: input.Layer): boolean
```

It returns `true` when an active user layer was popped and `false` for an inactive layer, `input.base`, or `input.raw`.
Popping the top transfers capture to its parent. Popping a middle layer rewires its child directly to its parent without
disturbing the current owner or emitting capture events. This lets an external command close a pause menu safely while
the debugger remains above it.

#### Inspecting the stack

```teal
local owner = input.topLayer()   -- input.base when no user layer is active
local count = input.layerCount() -- excludes input.base and input.raw
```

Use `layer:isActive()` when cleanup may run more than once, and `layer:isTop()` when behavior depends on current
ownership. Prefer keeping the stable layer handle over searching by its diagnostic `name`.

### Layer API

| Member | Description |
| --- | --- |
| `layer.name` | Required unique name supplied to `newLayer`; also the layer's snapshot identity. |
| `layer.snapshot` | `true` for a snapshot-managed game layer; `false` for a runtime-only overlay. |
| `layer.view` | Polling view for this owner; live only while the layer is top. |
| `layer.parent` | Next lower routed target while the layer is active. Use it for explicit forwarding. |
| `layer:observe(Event, callback, id?)` | Subscribe without changing the `function(event)` observer signature. The optional ID supports named removal. |
| `layer:stopObserving(Event, callbackOrId)` | Unsubscribe the callback or named observer. |
| `layer:hasObservers(Event)` | Report whether this target listens for the event type. |
| `layer:emit(event)` | Forward the event currently being routed to this target. It cannot emit an unrelated or newly constructed event. |
| `layer:isActive()` | Whether the user layer is currently in the stack. `input.base` and `input.raw` are always active. |
| `layer:isTop()` | Whether this target currently owns routed and polled input. |

The router checks only `input.raw` and the current top target before constructing an event. With no relevant observers,
it returns without allocating an event or walking lower layers. Parents are reached only when an observer explicitly
forwards.

### Event interception and forwarding

Physical input is emitted only to the top target. An observer consumes an event by handling it and doing nothing else.
To pass the same event down, explicitly emit it to the layer's current parent:

```teal
local events = require("tecs2d.events")
local hud = input.newLayer("hud")

hud:observe(events.MousePressed, function(event: events.MousePressed)
    if hitHud(event.x, event.y) then
        activateHud(event.x, event.y)
        return -- consumed
    end

    hud.parent:emit(event) -- offer the same event to the next target
end)

input.pushLayer(hud)
```

Forwarding is explicit: there is no automatic bubbling and observer signatures remain `function(event)`. A routing
observer should forward at most once and should forward complete press/move/release sequences when a parent owns a
gesture. Each target is protected against receiving the same physical event twice.

An observer may also close its own layer and continue the same event. Capture the parent first because the layer is no
longer active after `popLayer`:

```teal
hud:observe(events.KeyPressed, function(event: events.KeyPressed)
    if event.key == "escape" then
        local parent = hud.parent
        input.popLayer(hud)
        parent:emit(event)
    end
end)
```

`emit` is synchronous and accepts only the exact event currently being routed. A target receives a physical event at
most once even if more than one observer tries to forward it.

### Capture lifecycle

`InputCaptureLost` and `InputCaptureGained` are sent directly to the affected targets rather than routed through the
stack:

```teal
pause:observe(events.InputCaptureLost, function(event: events.InputCaptureLost)
    cancelPendingGesture(event.to)
end)
```

Both events contain `from` and `to` layer names. A top push sends `Lost` to the outgoing target before `Gained` to the
incoming target. A top pop does the same in reverse. A middle pop emits neither event because the top owner did not
change.

Pending press/release edges, text, wheel movement, and their fixed-step latches are cleared at a top-owner boundary so
input intended for one owner does not leak into the next. Physically held keyboard, mouse, and joystick state remains
current.

### Input layers and game states

The two stacks are deliberately independent:

- `world:pushState` and `world:popState` manage ECS ownership and entity lifecycle; they do not change input capture.
- `input.pushLayer` and `input.popLayer` manage physical input ownership; they do not pause systems, tag entities, or
  create a game state.
- A pause screen normally uses both stacks, while a transient confirmation dialog may need only an input layer.
- The runtime debugger pushes its own input layer and separately holds the freeze controller. It does not push a game
  state, so it can open above any game's state model.

When a feature uses both, retain and pop its exact input-layer handle during the same lifecycle that pushes and pops
the game state:

```teal
local pauseInput = input.newLayer("pause")

local function openPause()
    world:pushState("pause")
    input.pushLayer(pauseInput)
end

local function closePause()
    input.popLayer(pauseInput)
    world:popState()
end
```

The stacks are independent in operation, but both have built-in snapshot behavior. Tecs2D saves the names and
bottom-to-top order of active snapshot-managed input layers. On load it restores that topology automatically. Layer
handles, observers, and callbacks are runtime objects and are not serialized; create each named layer and register its
observers during normal plugin setup, before a snapshot can load.

Runtime-only layers remain above the restored game topology and are never opened or closed by a load. This is what
allows an open debugger to load a paused-game snapshot without losing debugger input:

```text
runtime-only layers (snapshot = false)  debugger, development tools
snapshot-managed layers (default)      pause menu, inventory, game modal
input.base                              ordinary gameplay
```

Loading establishes a fresh capture boundary: pending press/release edges, text, wheel motion, and fixed-step latches
are cleared. Physical held state stays live. If a load is requested from inside a routed input or capture-lifecycle
observer, the topology change is deferred until the current event or push/pop transition finishes. A snapshot that
names a layer not registered in the new world fails clearly instead of silently restoring the wrong owner. `input.raw`
remains a separate always-on stream and is not snapshot data.

### Raw input

Framework tooling and diagnostics that must ignore the stack use `input.raw`:

```teal
if input.raw.view.isKeyPressed("f12") then
    toggleDeveloperOverlay()
end

input.raw:observe(events.KeyPressed, function(event: events.KeyPressed)
    recordPhysicalKey(event.key)
end)
```

Raw observers run before the routed top target and cannot be intercepted. Ordinary game code should use module-level
polling or address-0 world observers so menus and the debugger can suppress it.

Do not use `input.raw` merely to make a shortcut convenient: it is appropriate only when the action must remain live
through every game modal and tool overlay. Raw observers cannot prevent the top target from receiving the same event.

*See [love.gamepadpressed](https://love2d.org/wiki/love.gamepadpressed) for gamepad buttons and
[love.joystickpressed](https://love2d.org/wiki/love.joystickpressed) for joystick buttons*

## Joystick connection events

You can also react to joystick connection/disconnection events:

```teal
local tecs = require("tecs")
local events = require("tecs2d.events")

world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        world:observe(0, events.JoystickAdded, function(e: events.JoystickAdded)
            local name = e.joystick:getName()
            print("Controller connected: " .. name)
        end)

        world:observe(0, events.JoystickRemoved, function(e: events.JoystickRemoved)
            print("Controller disconnected")
        end)
    end
})
```

## Latch-based input

Tecs takes a different approach to input than most Love2D libraries. The goal is to make input reliable and
simple in both variable-rate Update and fixed-rate FixedUpdate phases.

### How Love2D usually does it

- Love2D polls input once per render frame
- Libraries like Baton give you helpers like `pressed`, `released`, `down`, but these values are _frame-scoped_
- That works fine if your gameplay only runs once per frame in `love.update`

::: warning Problem: Fixed phases
If you run multiple fixed steps per frame, or sometimes zero (at very high FPS), quick taps can get lost
or duplicated.
:::

### Tecs's model

Tecs separates how input is captured from how it's consumed:

* Events are polled once per frame in the main loop before world:update()
* In **FixedUpdate**, input "edges" (like `isKeyPressed` and `isKeyReleased`) are _latched_:
  - They report their value since the last FixedUpdate tick
  - If a key was pressed and released between FixedUpdate ticks, the key is both pressed and released
  - Queries like `isKeyDown` always reflect the most up to date state from Love2D.
  - Latches are cleared after each FixedUpdate tick. So only the first FixedUpdate tick sees the latched state.

So no matter what phase you handle input in, whether it's Update or FixedUpdate, "down", "released", and "pressed"
states will return fresh values you'd expect.

## Input events

While `isKeyPressed` and `isKeyReleased` use a latching model to ensure inputs are never dropped, they do not preserve
the exact sequence or timing of multiple inputs within a single render frame. If your game requires frame-perfect
combos or input sequences (e.g., a fighting game), implement a custom input buffer from the routed
[Tecs event stream](/tecs2d/events), or use `input.raw` when the buffer must operate regardless of input ownership.

```teal
local events = require("tecs2d.events")

world:observe(0, events.KeyPressed, function(e: events.KeyPressed)
    addToComboBuffer(e.key, love.timer.getTime())
end)
```
