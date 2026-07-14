# Tecs2D input

Read keyboard, mouse, and gamepad state through `require("tecs2d.input")` — held state plus per-frame press/release edges.

## Keyboard

```teal
input.isKeyDown("left")      -- held this frame
input.isKeyPressed("space")  -- edge: went down this frame
input.isKeyReleased("space") -- edge: came up this frame
```

Key names are LÖVE keyconstants: `"up"`, `"down"`, `"left"`, `"right"`, `"space"`, `"return"`,
`"escape"`, `"a"`..`"z"`, etc.

## Mouse

```teal
input.mouseX, input.mouseY
input.isMouseDown(1)      -- 1 = left, 2 = right, 3 = middle
input.isMousePressed(1)
input.isMouseReleased(1)
local dx, dy, dir = input.getMouseWheelMovement()
```

## Gamepad

```teal
for joystick, pad in pairs(input.joysticks) do
    if pad:isGamepadButtonPressed("a") then ... end
    local x = pad.gamepadAxis["leftx"]
end
```

For higher-level bindings/deadzones use `require("tecs2d.controller")`.

## Frame vs fixed phases

`isKeyPressed`/`isKeyReleased` automatically read **frame** edges in normal phases and **latched**
edges inside `FixedUpdate`, so a press is never missed by a fixed tick that runs zero or multiple
times in a frame. Read input in `Update` (or `FixedUpdate`) systems — both work correctly.

## Pattern: buffered direction (from the snake example)

```teal
world:addSystem({
    name = "Steer", phase = tecs.phases.Update,
    run = function()
        if input.isKeyPressed("up")    or input.isKeyPressed("w") then queueDir(0, -1) end
        if input.isKeyPressed("down")  or input.isKeyPressed("s") then queueDir(0,  1) end
        if input.isKeyPressed("left")  or input.isKeyPressed("a") then queueDir(-1, 0) end
        if input.isKeyPressed("right") or input.isKeyPressed("d") then queueDir(1,  0) end
    end,
})
```

See also: `tecs docs tecs-ecs`, `tecs docs tecs2d-quickstart`.
