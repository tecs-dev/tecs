---
description: "Gameplay input in three tiers, behind a layer stack: live state, frame events, and latched events"
outline: deep
---

# Input

`tecs.Input` is gameplay input, in three tiers, behind a layer stack. SDL owns device mechanics; this owns
gameplay semantics. That split is why there is no `tecs.keyboard` beside it and no supported way to reach raw SDL:
a query answered by polling the device would bypass replay, layers, edge detection and latching, all of which live
here.

The three tiers answer three different questions.

- **Live state** answers "is it held".
- **Frame events** answer "did it change this frame".
- **Latched events** answer that same question for fixed-step systems, which is not the same question. A key
  pressed and released between two fixed steps is invisible to frame events, and dropping it produces input loss
  that is nondeterministic and so effectively unreproducible. Latched sets accumulate across every frame since the
  last fixed step and clear when it ends.

Queries are answered relative to a layer. A layer that blocks hides input from everything beneath it, so a menu
suppresses gameplay without gameplay code knowing a menu exists. Code that names no layer reads the base layer,
which is the safe default: it goes quiet when anything is pushed over it.

The state is fed typed events and holds no globals, so a recorded session replays by feeding the same events back.
It never sees an `SDL_Event`: the conversion happens once, in [`events`](/modules/events), and everything
downstream shares that one vocabulary.

::: warning This page is pending
Capture-boundary edge clearing is in flight, which moves exactly the part of the surface a reference would be
about. Writing the method reference today would mean writing it twice.

Read `src/tecs/platform/Input.tl` for the current surface.
:::

## Requiring it

```teal
local tecs <const> = require("tecs")
```

## Gamepads are not part of it

A gamepad has identity, a lifetime, metadata and outputs, so it is not a field on the input state. It is reached
through the input state's gamepad registry and answers for itself. See [`Gamepad`](/modules/Gamepad).

What `Input` holds is what the machine has one of: a keyboard, an aggregate mouse, the touch surface, the pen, and
the registry the pads live in.

## Design record

- [Input](https://github.com/tecs-dev/tecs/blob/main/README.md#input)
- [Events](https://github.com/tecs-dev/tecs/blob/main/README.md#events)
- [Measuring latency](https://github.com/tecs-dev/tecs/blob/main/README.md#measuring-latency)
