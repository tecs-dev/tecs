---
description: "Configure keyboard, mouse, gamepad button and axis bindings, movement pairs and analog magnitude"
---

# Bindings

A mapping contains a `controls` table and an optional `pairs` table. Every
action has an ordered list of `source:value` strings. The first nonzero binding
supplies its raw value, so a keyboard binding before an axis gives the keyboard
priority while its key is held.

## Binding sources

| Source         | Examples                                    | Value                                                |
| -------------- | ------------------------------------------- | ---------------------------------------------------- |
| Keyboard       | `key:Space`, `key:KeyW`, `key:ArrowLeft`    | Zero or one.                                         |
| Mouse          | `mouse:left`, `mouse:right`, `mouse:1`      | Zero or one.                                         |
| Gamepad button | `button:south`, `button:dpadUp`, `button:1` | Zero or one.                                         |
| Raw axis       | `axis:leftX`, `axis:rightY`, `axis:1`       | Signed axis value after filtering.                   |
| Positive axis  | `axis:leftX+`, `axis:rightTrigger+`         | Positive half of the axis, from zero to one.         |
| Negative axis  | `axis:leftX-`, `axis:rightY-`               | Negative half converted to a positive magnitude.     |
| Joystick hat   | `hat:1u`, `hat:1lu`, `hat:1c`               | Raises when evaluated until backend support returns. |

The formats follow Baton-style bindings, extended with signed raw axes.
Keyboard bindings use Input's physical key names; there is no separate
scancode source. The mapper reads [](tecs.input) and has no native backend
dependency.

## Keyboard and mouse

```nupp
const bindings: tecs.controller.Bindings = {
    controls = {
        jump = {"key:Space", "key:KeyW"},
        attack = {"key:KeyZ", "mouse:left"},
        menu = {"key:Escape"},
    },
}
```

Key names are case-sensitive and follow Input's physical-key vocabulary.
Mouse names are `left`, `middle`, `right`, `back` and `forward`. Numeric mouse
buttons follow the same order, starting at one; named bindings avoid depending
on that numbering.

## Positional gamepad buttons

Gamepad bindings read only the player's assigned pad. Without a pad, keyboard
and mouse bindings continue to work.

| Group        | Names                                         |
| ------------ | --------------------------------------------- |
| Face         | `south`, `east`, `west`, `north`              |
| System       | `back`, `guide`, `start`                      |
| Stick clicks | `leftStick`, `rightStick`                     |
| Shoulders    | `leftShoulder`, `rightShoulder`               |
| D-pad        | `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight` |

Use `button:dpadUp` and the other D-pad buttons for directional controls.
Positive numeric button and axis codes are accepted for backend-specific controls;
positional names are the portable choice.

## Joystick hats

Legacy hat bindings remain part of the mapping API. A binding names a positive,
one-based hat index followed by its direction:

| Direction                                | Value                  |
| ---------------------------------------- | ---------------------- |
| Centered                                 | `c`                    |
| Up, right, down, left                    | `u`, `r`, `d`, `l`     |
| Up-right, down-right, down-left, up-left | `ru`, `rd`, `ld`, `lu` |

```nupp
const player = manager:addController({
    controls = {
        left = {"hat:1l"}, right = {"hat:1r"},
        up = {"hat:1u"}, down = {"hat:1d"},
    },
    pairs = {move = {"left", "right", "up", "down"}},
})
```

Creating, retaining and rebinding this mapping works. Input does not currently
expose raw joystick hats, so evaluating one through any controller query raises
`joystick hat bindings are unavailable in the current input backend`. This
keeps configurations usable while backend support is restored, without
silently reporting a neutral input for an unavailable feature. Malformed hat
indices or directions still raise when the mapping is created or rebound.

A blocked capture layer returns neutral without evaluating bindings. An
earlier binding that answers the query also avoids evaluating a later hat
binding: for example, a held `key:Space` before `hat:1u` supplies a raw value
of one. When a query reaches the hat binding, it raises.

## Raw and directional axes

Stick axes are `leftX`, `leftY`, `rightX` and `rightY`, with values from minus
one to one and positive Y pointing down. Trigger axes are `leftTrigger` and
`rightTrigger`, with values from zero to one.

```nupp
const player = manager:addController({
    controls = {
        aimX = {"axis:rightX"},
        aimY = {"axis:rightY"},
        accelerate = {"key:ArrowUp", "axis:rightTrigger+"},
        brake = {"key:ArrowDown", "axis:leftTrigger+"},
    },
}, {auto = true, deadzone = 0.15})

const aimX = player:getRaw("aimX")
const aimY = player:getRaw("aimY")
const throttle = player:getRaw("accelerate")
```

Values below the configured deadzone magnitude become zero. Values at or
above it keep their original magnitude; the remaining range is not rescaled.
The controller's default deadzone is 0.5; set it explicitly for a more
sensitive stick or trigger. Axis bindings answer through `getRaw`, `isDown`
and movement pairs, and never produce digital press or release edges.

## Movement pairs

A pair names exactly four existing controls, ordered left, right, up, down:

```nupp
const player = manager:addController({
    controls = {
        left = {"key:KeyA", "axis:leftX-"},
        right = {"key:KeyD", "axis:leftX+"},
        up = {"key:KeyW", "axis:leftY-"},
        down = {"key:KeyS", "axis:leftY+"},
    },
    pairs = {move = {"left", "right", "up", "down"}},
}, {auto = true, deadzone = 0.15})

const moveX, moveY = player:getPairNormalized("move")
```

`getPair` subtracts left from right and up from down, clamping each coordinate
to minus one through one. Equal opposite directions cancel. A half-deflected
stick still contributes half a unit.

`getPairNormalized` additionally limits the vector to unit length. Digital
diagonals become approximately `(0.707, 0.707)`, while `(0.3, 0.4)` stays
`(0.3, 0.4)`. Partial stick input therefore stays slow instead of becoming
full-speed movement. A zero vector stays zero.

Define more pairs using the same format for movement, aiming or a camera.
Unknown action names return false or zero; an unknown pair returns two zeroes.
Malformed bindings and pairs that reference missing actions raise when the
mapping is created or rebound.
