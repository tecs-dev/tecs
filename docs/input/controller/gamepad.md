---
description: "Assign gamepads to logical players, handle hot plug and assignment changes, and identify devices with rumble"
---

# Gamepad support

A logical controller combines keyboard and mouse bindings with one optional
[](tecs.input.Gamepad). Its manager shares the application's input state and
does not enumerate or open native devices itself.

## Manual and automatic assignment

```nupp
const manager = tecs.controller.install(app.world)
const bindings: tecs.controller.Bindings = {
    controls = {
        jump = {"key:Space", "button:south"},
        aimX = {"axis:rightX"},
        aimY = {"axis:rightY"},
    },
}

const keyboardPlayer = manager:addController(bindings)
const automaticPlayer = manager:addController(bindings, {auto = true, deadzone = 0.25})
const pad = app.input:gamepad(1)
if pad ~= nil then
    keyboardPlayer:setGamepad(pad)
end
```

Automatic assignment is off by default. With `auto = true`, the manager picks
an unassigned pad, preferring one with a held button or axis magnitude above
0.5, then falling back to connection order. Players are filled in creation
order. Activity detection sees physical state even while a menu owns capture;
logical controls remain suppressed by that menu.

An explicit `gamepad` in the creation config overrides `auto`. Manual
assignment can share a device between players. Automatic assignment treats
every manually or automatically assigned device as occupied.

## Hot plug and removal

An installed manager refreshes device assignments in `Ingress`, after input
polls its gamepad source. A disconnected player's pad is cleared. An automatic
player receives another available pad; a manual player stays unassigned.
Keyboard and mouse bindings continue to work in both cases.

A retained disconnected gamepad object reads neutral values immediately,
even before the manager refreshes it. Reconnection creates a new gamepad
object. Do not identify a saved device by the current connection index; use
the input device's `guid` when selecting a persisted preference.

Removing a player with `manager:removeController(player)` clears its pad and
disables automatic assignment. The next manager refresh can give that pad to
another waiting player. `manager:get(index)` reads the current list position,
which changes when an earlier player is removed.

## Switching gamepads

```nupp
player:resetGamepad({auto = true})
player:resetGamepad({auto = false})
player:resetGamepad({gamepad = pad, deadzone = 0.3})
player:resetGamepad(nil)
```

`resetGamepad` clears the previous assignment, applies the new policy and
attempts automatic assignment immediately if enabled. Omitting `deadzone`
preserves its current value. Passing nil disables automatic assignment and
clears the pad.

`setGamepad(pad)` assigns a connected gamepad directly and disables automatic
assignment; `setGamepad(nil)` clears it. A device from another input state or
a disconnected reference raises at the call site.

## Assignment callbacks

```nupp
player.onGamepadChanged = function(
    changed: tecs.controller.Controller,
    current: tecs.input.Gamepad?,
    previous: tecs.input.Gamepad?
): nil
    if current ~= nil then
        print("Player gamepad: " .. current.name)
    else
        print("Player gamepad disconnected")
    end
end
```

The callback runs after a changed assignment is stored. Assigning the same
object again does not notify. A reset that clears a pad and then automatically
assigns one can notify twice. Rebinding actions leaves the assignment and
callback unchanged.

## Rumble

New assignments request a brief identification rumble at half strength for
0.2 seconds. Unsupported devices simply decline the effect.

```nupp
const identified = player:notifyWithRumble()
const current = player.gamepad
if current ~= nil then
    const started = current:rumble(0.8, 0.3, 0.15)
end
```

Use the gamepad's `rumble` method for separate motor strengths. Both methods
report whether the effect started; support depends on the input backend and
device. A disconnected or unassigned controller cannot rumble.

The controller layer uses only the public input contract. Native backend
changes, including an SDL3 backend, belong below that contract; bindings keep
following the device vocabulary Input publishes.
