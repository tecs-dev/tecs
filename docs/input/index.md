---
description: "Read physical input, route capture through layers, and map devices to rebindable player controls"
order: 35
---

# Input handling

An application owns one input state at `app.input`. It folds keyboard, mouse,
touch and gamepad events into held state, frame edges and fixed-step edges.
Use [logical controllers](controller/index.md) to map these devices to actions
such as jump, attack and movement, or read [](tecs.input) directly for a cursor,
text field or device-specific interaction.

## Logical player controls

The [controller guide](controller/index.md) restores the Baton-style workflow:
define named actions with several bindings, assign a gamepad to each player,
read button edges or analog movement, and rebind at runtime.

- [Bindings and movement pairs](controller/bindings.md) covers keyboard, mouse,
  buttons, raw axes and directional axes.
- [Gamepad assignment](controller/gamepad.md) covers multiple players, hot plug,
  callbacks and rumble.
- [API reference](controller/api.md) links to the contracts generated from the
  implementation.

## Physical state and edges

```nupp
if app.input:keyPressed("Space") then
    print("Space went down")
end
if app.input:mouseDown("left") then
    print(app.input.mouseX, app.input.mouseY)
end
const pad = app.input:gamepad(1)
if pad ~= nil then
    print(pad:axis("leftX"))
end
```

Held values survive frame boundaries. A press or release normally describes
the current frame. Inside fixed phases, the same query reads edges accumulated
since the previous fixed step: a short tap between two steps remains visible,
and additional catch-up steps do not repeat it. Queries do not consume edges;
several systems can observe the same press.

## Capture layers

A query with no explicit layer reads the base layer. A blocking layer above
it hides gameplay input from direct queries and logical controllers together.

```nupp
const menu = app.input:pushLayer("pauseMenu")
if app.input:keyPressed("Enter", menu) then
    print("Menu confirmation")
end
app.input:popLayer()
```

Changing the blocking owner clears pending frame and fixed edges. Physically
held controls remain held, so closing a menu resumes continuous movement
without replaying an old press or inventing a release. A nonblocking layer
does not suppress lower readers.

## Device vocabulary and backends

Binding values follow the public input vocabulary. The current keyboard names
include `Space`, `KeyA` and `ArrowLeft`; gamepad buttons use positions such as
`south`, and axes use names such as `leftX`. Numeric mouse buttons follow
Input's order: left, middle, right, back and forward.

Logical controller mapping uses the input contract and owns no native device
backend. Changing the window or gamepad backend does not change action names,
pairs or the controller API. If the input vocabulary changes, update the
physical binding strings in saved mappings as well as the game's defaults.

## Headless use

`tecs.input.newInput()` opens no hardware. Feed typed events to `handleEvent`,
bracket frames with `beginFrame`, and bracket simulated fixed steps with
`enterFixedPhase` and `exitFixedPhase`. A standalone
`tecs.controller.newManager(state)` reads that same state. Call its
`refreshDevices` after device changes to update automatic assignments.

An ECS world can install input and controllers explicitly; an application
already installs input before its plugin runs. The controller installer
requires that existing input state.
