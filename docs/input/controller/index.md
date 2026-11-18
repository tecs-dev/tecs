---
description: "Build rebindable logical player controls with Baton-style actions, analog pairs and per-player gamepads"
---

# Tecs Controller

Tecs Controller maps physical inputs to logical actions such as `jump` and
`attack`. Its binding model is based on Baton, with raw signed axes in addition
to directional axes. The same player can use keyboard, mouse and a gamepad.
Mappings are copied and compiled when created or rebound, so gameplay queries
do not parse strings.

## Quick start

Install [](tecs.controller) from your application plugin. The application has
already installed [](tecs.input). This complete component prints logical jumps
and movement from either WASD or the assigned gamepad:

```nupp
module controllergame

local function game(exclusive app: tecs.application.Application): nil
    const manager = tecs.controller.install(app.world)
    const player = manager:addController({
        controls = {
            jump = {"key:Space", "button:south"},
            attack = {"key:KeyZ", "mouse:left", "button:west"},
            left = {"key:KeyA", "key:ArrowLeft", "axis:leftX-"},
            right = {"key:KeyD", "key:ArrowRight", "axis:leftX+"},
            up = {"key:KeyW", "key:ArrowUp", "axis:leftY-"},
            down = {"key:KeyS", "key:ArrowDown", "axis:leftY+"},
        },
        pairs = {move = {"left", "right", "up", "down"}},
    }, {auto = true, deadzone = 0.15})

    app.world:addSystem({
        name = "game.PlayerInput",
        phase = tecs.ecs.phases.FixedUpdate,
        run = function(): nil
            if player:isPressed("jump") then
                print("Jump")
            end
            const moveX, moveY = player:getPairNormalized("move")
            if moveX ~= 0 or moveY ~= 0 then
                print(moveX, moveY)
            end
        end,
    })
end

export function create(
    title: string?, width: integer?, height: integer?,
    debug: boolean?, maxFrames: integer?
): tecs.host.Session
    return tecs.host.createWithPlugin(game, title or "Controller", width, height, debug, maxFrames)
end
```

The [getting-started workflow](../../getting-started.md) explains registering
and building a component target. The generated
[controller reference](tecs.controller) owns the public signatures and errors.

## Input ownership and timing

Controllers read Input's base capture layer. A blocking menu or debugger layer
makes digital queries false and analog values zero. Closing it restores held
values without replaying old edges. Gamepad discovery and assignment still
work while a menu owns capture.

`isPressed` and `isReleased` report a physical edge from any bound key, mouse
button or gamepad button. Releasing one binding can report a release while
another binding keeps the action down. Axes provide continuous values and do
not produce press or release edges.

In fixed phases, digital queries inherit Input's accumulated edges. A tap
between steps reaches the next step once, even when the final held state is
up. Multiple reads during that step see the same edge. See
[physical input timing](../index.md#physical-state-and-edges).

## Rebinding

Replace the complete mapping at runtime:

```nupp
player:rebind({
    controls = {
        jump = {"key:KeyJ", "button:south"},
        attack = {"mouse:left", "button:west"},
    },
})
```

The controller copies the replacement and preserves its gamepad assignment,
deadzone and change callback. An invalid mapping raises at `rebind` and leaves
the previous mapping intact. Rebinding reads the current physical state; it
does not synthesize new presses for held inputs.

## Multiple players

Each controller has its own mapping and optional gamepad. Give players
different keyboard bindings when they share a keyboard:

```nupp
const player1 = manager:addController({
    controls = {jump = {"key:KeyW", "button:south"}},
}, {auto = true})
const player2 = manager:addController({
    controls = {jump = {"key:ArrowUp", "button:south"}},
}, {auto = true})
```

Automatic assignment never gives one pad to two players. Manual assignment can
share a pad deliberately. See [gamepad assignment](gamepad.md).

## Custom managers

`tecs.controller.newManager(state)` creates a standalone manager over an
existing input state, without opening hardware or registering a world system.
Call `refreshDevices` after hot-plug changes. An installed manager refreshes
after `tecs.PollGamepads` in `Ingress` and is available through
`tecs.controller.of(world)`.
