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
- **Mutations inside a system are STAGED until the frame commits.** An entity spawned in this
  frame's system is not query-visible and not `getMut`-able until the commit drain — so never
  reconcile a variable-length render set by "query how many exist, spawn/despawn the
  difference" inside a system: the query undercounts every frame and you over-spawn unboundedly.
  Instead keep the authoritative id list in a named resource, spawn additions pre-positioned
  (constructor args, not post-spawn `getMut`), and reposition only committed entities.
- **Never build a query — or register an observer — inside `run`.** Create queries once in the plugin and reuse them; `world:observe` inside a per-frame system adds a NEW handler every tick (your callback fires N times per event and leaks). Register observers in plugin/Startup code.
- Optional record fields can't be marked `?` (only params can); document optionality and handle
  `nil` at each use site.
- **No anonymous record types in annotations.** `function f(c: {r: number, g: number})` is a
  syntax error (Teal reports only a bare `expected '}'`). Declare a named record
  (`local record RGBA r: number g: number end`) and annotate with it; `{K: V}` map and
  `{T}` array/tuple annotations are fine.

## Conventions

- **Naming:** camelCase for functions/fields/locals; PascalCase for types and system `name`s;
  `SCREAMING_SNAKE_CASE` only for tunables. Booleans read as predicates (`isRunning`).
- **Bindings:** every import/module-level binding is `local x <const> = ...`; alias types
  (`local type World = tecs.World`).
- **Typing:** `any` is a last resort (prefer unions/generics); type every public signature fully.
- **Components:** `newFFIComponent` for measured hot numeric data; `newComponent` (table) when a
  field holds a Lua table/string/object or is cold; tags for stable, queried flags. Give each a
  `name` matching its record. Keep components as data — behavior lives in systems.
- **System `run` is `function(dt, world)` — dt FIRST.** A swapped `(world, dt)` still
  typechecks (callback params are bivariant), so this is a silent runtime bug; get it right
  at write time. Inside a plugin whose param is `world`, name the run param `w` (or take only
  `dt` and use the plugin's `world` upvalue) — re-naming it `world` shadows the upvalue and
  earns a warning per system.
- **Resources are index access:** `world.resources[KEY]` to read and assign — there is no
  `getResource`/`setResource` method.
- **Systems:** every persistent system gets a `name`; pick the right `phase` (game logic in
  `Update`/`FixedUpdate`, never render work there); gate with `runIf`; use `dt`, never wall clocks.
  Don't add `love.update`/`love.draw` — `tecs2d.run` owns the loop.
- **Queries:** iterate archetype-wise, binding columns once; prefer numeric `for row = 1, len`;
  use `batchDespawn`/`batchSet`/`batchRemove` over per-entity loops.
- **Render with gfx components first — UI/HUD included.** `gfx.Rectangle`/`Text`/`Circle`
  entities get layering, lighting, and GPU batching for free; score displays and labels are
  `gfx.Text` entities (anchor screen-space UI with `tecs2d.ui`), NOT `love.graphics.print`
  in a draw system — hand-drawn UI is an anti-pattern that bypasses the batched glyph
  system, layer sorting, and anchoring. The immediate-mode escape hatch
  (`pipeline:worldShader():at(layer):attach()` around raw `love.graphics` calls, detach after)
  is for effects components can't express — not the default way to draw a board or a HUD.
- **Model with builtins first.** For a small entity game, builtin `Transform` + gfx shapes + a
  named-key state resource is often the whole model — no custom components needed. Custom
  components buy two specific things: **querying by trait** (`world:query{include={Enemy}}`)
  and **serialization** — component state rides snapshots/rewind/replay for free, while
  resource state survives time travel only if you register a `World.SnapshotHandler`. Choose
  by which of those you need, not by ceremony.
- **Plugins/state:** plugins are the unit of composition; share globals via `world.resources[...]`
  keyed by a typed key (no Lua globals); use `world:observe` for lifecycle instead of polling.
  Always name keys — `tecs.newKey("game.state")`, not `tecs.newKey()` — so the resource is
  readable by name (`cmd_resources`, `tecs.findKey`) and keeps its identity across hot reloads;
  unnamed keys log a warning. Declare a typed key as
  `local STATE_KEY <const> = tecs.newKey("game.state") as tecs.Key<GameState>` —
  `local STATE_KEY: tecs.Key<GameState> <const> = …` is a **syntax error** (Teal cannot parse
  `<const>` after a generic annotation, and the bare "syntax error" message won't tell you why).
- **Errors:** `error(msg, 0)` for user-actionable failures; validate options at construction, not
  on the first frame; log through `tecs.utils.logging`, not `print`.

## Gameplay & rendering pitfalls

These cost iterations because the fix lives in a page you read *before* you hit the problem. Run
`tecs docs <page>` for detail.

- **Gameplay input is a poll, not an event subscription.** `tecs2d.input` already latches and
  phase-schedules every edge — poll `input.isKeyPressed` in the system that consumes it instead
  of wiring a `KeyPressed` observer plus your own pressed-keys bookkeeping (that rebuilds what
  the input module does, worse). Observers are for discrete one-shots outside the gameplay loop
  (pause toggle, menu confirm). **Edge reads are phase-aware — read them in the consuming
  phase**: `input.isKeyPressed` in Update reliably reports this frame's press; in FixedUpdate
  it reports a latched edge that only the FIRST fixed tick of a frame sees (latches clear per
  tick). Don't shuttle edge state between phases by hand. If input "silently doesn't work",
  verify the read actually fires — tape a press via `cmd_step` events, assert — before
  rearchitecting. (`tecs docs tecs2d/input`, "Latch-based input")
- **Transform args:** `Transform(x, y, z, layer, rotation?, scaleX?, scaleY?)` — the 4th arg is the
  **layer**, not scale. (`tecs docs tecs/builtins`)
- **Draw order:** the rule is *one overlapping visual per layer*. Higher layer = strictly on
  top; **within** a layer, order follows its `sortMode` (e.g. `topdown` y-sort), **not spawn
  order** — so ANY two overlapping full-area visuals on the same layer can occlude each other
  (backdrop + board, board + panel, ...), even on a "background" layer. Give each stacked
  visual its own layer, or order within a layer with `Transform.z`. And one entry per index:
  a duplicate key in the `layers` table (`[2] = {...}, [2] = {...}`) silently drops the
  earlier layer — Lua table literals last-win without warning.
  (`tecs docs tecs2d/rendering/layers`, `tecs docs tecs2d/rendering/styling`)
- **Text/shapes are centered by default:** `gfx.Text`, `gfx.Rectangle`, etc. default to
  `Pivot(0.5, 0.5)`, so the `Transform` position is their **center**, not their top-left. Add
  `gfx.Pivot(0, 0)` for a top-left anchor (e.g. a HUD label at a corner).
  (`tecs docs tecs2d/rendering/styling`, `tecs docs tecs2d/rendering/text`)
- **Observing events needs the VALUE, not the type:** `local events = require("tecs2d.events");
  world:observe(0, events.MousePressed, ...)`. `tecs2d.MousePressed` resolves to a *type* and won't
  type-check. (`tecs docs tecs2d/events`)
- **Gameplay belongs on world-space layers, viewed by the camera.** Layers without
  `space = "virtual"` are world space by default — keep game entities there so camera
  follow/zoom/shake work and coordinates aren't welded to the window. Reserve
  `space = "virtual"` for screen-fixed chrome (backdrop, HUD). A game whose every layer is
  virtual has opted out of the camera entirely — treat that as a design smell.
- **Pointer → game coordinates:** put gameplay on a **world-space** layer and convert with
  `camera:toWorld(x, y)`; use `tecs2d.ui.Anchor` for HUD (it resolves the layer's coordinate space).
  Don't hand-roll screen→virtual math. (`tecs docs tecs2d/input`, `tecs docs tecs2d/rendering/camera`)
- **Hot reload restores the world from a snapshot, so `Startup` systems do not re-run.** A change
  that only runs at `Startup` (spawning an entity, setting a pivot) won't appear after a rebuild —
  it's overwritten by the restored state; do a clean `restart_game` to see it. State in
  `world.resources[...]` or closures likewise needs a snapshot handler to survive. A frozen-looking
  frame after reload is often a leftover debugger freeze, not a broken reload.
  (`tecs docs tecs/save-games`)
