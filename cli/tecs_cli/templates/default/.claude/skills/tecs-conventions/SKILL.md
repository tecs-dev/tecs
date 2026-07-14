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
