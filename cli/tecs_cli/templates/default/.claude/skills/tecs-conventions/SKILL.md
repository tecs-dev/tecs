---
name: tecs-conventions
description: Idiomatic, strictly-typed Tecs/Teal conventions and the pitfalls that break `tecs check` or cause silent runtime bugs. Use when writing or editing any Teal source in this project.
---

# Tecs conventions and pitfalls

Apply these while writing Tecs code so it reads like the framework and passes `tecs check` the
first time. For the full API, run `tecs docs <page>` (offline mirror of the docs).

## Pitfalls that bite

- **`love.math.random` returns `number`, not `integer`.** Wrap it for integer fields/keys:
  `math.floor(love.math.random(0, n))`.
- **No `//` operator** on the 5.1 gen target — use `math.floor(a / b)`.
- **Dirty tracking:** `world:get` / `archetype:get` are read-only; writing through them silently
  skips dirty tracking so renders/reactive systems miss the change. Use `getMut` at every write
  site.
- **Tags** are added by passing the container (`world:spawn(t, Dead)`); other components must be
  constructed (`gfx.Color(1,0,0,1)`).
- **Never build a query inside `run`** — create it once in the plugin and reuse it.
- Optional record fields can't be marked `?` (only params can); document optionality and handle
  `nil` at each use site.

## Conventions

- **Naming:** camelCase for functions/fields/locals; PascalCase for types and system `name`s;
  `SCREAMING_SNAKE_CASE` only for tunables. Booleans read as predicates (`isRunning`).
- **Bindings:** every import/module-level binding is `local x <const> = ...`; alias types
  (`local type World = tecs.World`).
- **Typing:** `any` is a last resort (prefer unions/generics); type every public signature fully.
- **Components:** `newFFIComponent` for measured hot numeric data; `newComponent` (table) when a
  field holds a Lua table/string/object or is cold; tags for stable, queried flags. Give each a
  `name` matching its record. Keep components as data — behavior lives in systems.
- **Systems:** every persistent system gets a `name`; pick the right `phase` (game logic in
  `Update`/`FixedUpdate`, never render work there); gate with `runIf`; use `dt`, never wall clocks.
  Don't add `love.update`/`love.draw` — `tecs2d.run` owns the loop.
- **Queries:** iterate archetype-wise, binding columns once; prefer numeric `for row = 1, len`;
  use `batchDespawn`/`batchSet`/`batchRemove` over per-entity loops.
- **Plugins/state:** plugins are the unit of composition; share globals via `world.resources[...]`
  keyed by a typed key (no Lua globals); use `world:observe` for lifecycle instead of polling.
- **Errors:** `error(msg, 0)` for user-actionable failures; validate options at construction, not
  on the first frame; log through `tecs.utils.logging`, not `print`.

## Gameplay & rendering pitfalls

These cost iterations because the fix lives in a page you read *before* you hit the problem. Run
`tecs docs <page>` for detail.

- **Transform args:** `Transform(x, y, z, layer, rotation?, scaleX?, scaleY?)` — the 4th arg is the
  **layer**, not scale. (`tecs docs tecs/builtins`)
- **Draw order:** within one layer, order follows that layer's `sortMode` (e.g. `topdown` y-sort),
  **not spawn order** — a full-bleed background on a gameplay layer can draw over things above it.
  Put backgrounds on their own lower layer, or order within a layer with `Transform.z`.
  (`tecs docs tecs2d/rendering/layers`, `tecs docs tecs2d/rendering/styling`)
- **Observing events needs the VALUE, not the type:** `local events = require("tecs2d.events");
  world:observe(0, events.MousePressed, ...)`. `tecs2d.MousePressed` resolves to a *type* and won't
  type-check. (`tecs docs tecs2d/events`)
- **Pointer → game coordinates:** put gameplay on a **world-space** layer and convert with
  `camera:toWorld(x, y)`; use `tecs2d.ui.Anchor` for HUD (it resolves the layer's coordinate space).
  Don't hand-roll screen→virtual math. (`tecs docs tecs2d/input`, `tecs docs tecs2d/rendering/camera`)
- **Hot reload restores ECS state via snapshots.** State kept in `world.resources[...]` or closures
  needs a snapshot handler to survive a reload; changing render/layer topology needs a full
  `restart_game`, not just a rebuild. A frozen-looking frame after reload is often a leftover
  debugger freeze, not a broken reload. (`tecs docs tecs/save-games`)
