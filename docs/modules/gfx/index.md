---
description: "Drawing, and the modules a scene is described in: what sits under tecs.gfx and how each of them is reached"
---

# tecs.gfx

`tecs.gfx` is where drawing lives. It is a namespace rather than a module: nothing is read off `tecs.gfx`
itself, and every name it carries is a module one level below it with a page of its own.

## What is under it

| Module                                   | What it is                         |
| ---------------------------------------- | ---------------------------------- |
| [`tecs.gfx.layers`](/modules/gfx/layers) | z-ordering and per-layer behaviour |

## One level, and no deeper

A public name goes at most one module below the root. `tecs.gfx.layers.configure` is a function on a
module inside a namespace; there is no third namespace under it, and a type a module owns sits on that
module's page rather than getting a level of its own. So a name a game writes is read left to right with
no guessing about where the module stops and the value starts.

## Reading one costs only that one

Each name under `tecs.gfx` resolves the first time it is read, and reading one does not resolve its
siblings. `tecs.gfx` on its own resolves nothing at all: it answers with a table whose members are filled
in one at a time.

That is what keeps `require("tecs")` usable with no graphics stack present. A resource pipeline, a
simulation server or a spec that names `tecs.gfx.layers` loads `src/tecs/gfx/layers.tl` and stops there,
and one that names nothing under `tecs.gfx` loads nothing under it. `spec/headless_spec.lua` is where that
is held to.

The module a name resolves to is the module itself and not a copy of it, so
`tecs.gfx.layers` and `require("tecs.gfx.layers")` are one table. A value written through one is read back
through the other, which matters for `layers.maxY` and `layers.maxZ`, the two module values a game is
expected to assign.
