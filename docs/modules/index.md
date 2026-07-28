---
description: "Every name on the public Tecs surface, spelled the way a game writes it, each linking to its page"
outline: [2, 2]
---

# The surface

`require("tecs")` is the whole of it. Every name below is a field on that one table, spelled here exactly as a
game writes it. `tecs` is also a global, so the require line is optional.

```teal
local tecs <const> = require("tecs")
```

This list is the index; the pages behind it are the reference. For signatures, parameters and returns of
everything at once, see [the generated surface](/modules/surface), which is rendered from `src/tecs/init.tl` and
checked against a fresh render so it cannot drift.

## Lifecycle and rendering

- [`tecs.Application`](/modules/Application) — the object an entry file returns and the host drives
- [`tecs.application`](/modules/Application) — builds that object
- [`tecs.Renderer`](/modules/Renderer) — a world to a frame, through an extractor and a backend
- [`tecs.Camera`](/modules/Camera) — the view a frame is drawn from
- [`tecs.layers`](/modules/layers) — z-ordering and per-layer behaviour
- [`tecs.materials`](/modules/materials) — the material a draw dispatches to
- [`tecs.sheet`](/modules/sheet) — sprite sheets: loading one, and what is in it
- [`tecs.animation`](/modules/animation) — sprite playback
- [`tecs.text`](/modules/text) — distance-field text, drawn through an instance producer
- [`tecs.particles`](/modules/particles) — emitters
- [`tecs.components`](/modules/components) — the engine's own components, the ones the renderer reads

## Platform

- [`tecs.Window`](/modules/Window) — the window, its size, its display and its mode
- [`tecs.Input`](/modules/Input) — gameplay input in three tiers, behind a layer stack
- [`tecs.Gamepad`](/modules/Gamepad) — a pad's identity, lifetime, metadata and outputs
- [`tecs.events`](/modules/events) — platform events, typed once and routed
- [`tecs.clock`](/modules/clock) — monotonic time
- [`tecs.clipboard`](/modules/clipboard) — reading and writing the system clipboard
- [`tecs.proc`](/modules/proc) — shelling out
- [`tecs.paths`](/modules/paths) — where a game may read from and write to
- [`tecs.filesystem`](/modules/filesystem) — touching the filesystem
- [`tecs.watch`](/modules/watch) — watching files for change
- [`tecs.capabilities`](/modules/capabilities) — what this machine and this build can do

## Simulation and content

- [`tecs.physics`](/modules/physics) — rigid-body simulation on Box2D 3
- [`tecs.Audio`](/modules/Audio) — clips, voices, groups, limits, and the `Sound` component
- [`tecs.sequence`](/modules/sequence) — the sequencer, with the tween runtime inside it
- [`tecs.assets`](/modules/assets) — loading content, cached and off the main thread
- [`tecs.workers`](/modules/workers) — typed background jobs
- [`tecs.Future`](/modules/Future) — a value that settles once

## Tooling and utilities

- [`tecs.log`](/modules/log) — SDL's logging, per platform, with a named logger as the unit of filtering
- [`tecs.mcp`](/modules/mcp) — the debug server: transport, tools, sandbox
- [`tecs.json`](/modules/json) — JSON, with the build's own copy of the C parser found
- [`tecs.hash`](/modules/hash) — hashing
- [`tecs.compress`](/modules/compress) — compression and decompression
- [`tecs.random`](/modules/random) — seeded random numbers

## Worlds, components and systems

These load with the surface rather than on first access. Most are documented in the [ECS section](/ecs/) rather
than under `/modules/`, because they are concepts as much as they are functions.

- [`tecs.newWorld`](/ecs/world) — create a world
- [`tecs.newComponent`](/ecs/components/table-components) — a table component
- [`tecs.newFFIComponent`](/ecs/components/ffi) — a component backed by an FFI struct
- [`tecs.newTagComponent`](/ecs/components/tag-components) — a component with no data, in bitset storage
- [`tecs.newScalarComponent`](/ecs/components/scalar-components) — a component that is one value
- [`tecs.newRelationship`](/ecs/relationships/) — a link from one entity to another
- [`tecs.newFFIRelationship`](/ecs/relationships/ffi) — the same, carrying data in an FFI struct
- [`tecs.newEvent`](/ecs/events) — give an event record its constructor
- [`tecs.newFFIEvent`](/ecs/events) — the same for an FFI-backed event
- [`tecs.newMessageBus`](/ecs/events) — an address-based bus, outside any world
- [`tecs.newKey`](/ecs/world) — a typed key for a resource
- [`tecs.findKey`](/ecs/world) — the key a name was created with, or nil
- [`tecs.listKeys`](/ecs/world) — every named key, as name to id
- [`tecs.newContext`](/ecs/world) — a resource container outside a world
- [`tecs.getComponentById`](/ecs/components/) — the component a numeric id names
- [`tecs.componentByName`](/ecs/components/) — the component a name names
- [`tecs.phases`](/ecs/phases) — the phases a system can be scheduled into
- [`tecs.builtins`](/ecs/builtins) — `Transform`, `ChildOf`, `TTL`, `Paused`, `Disabled` and the rest
- [`tecs.runif`](/ecs/systems) — composable run conditions
- [`tecs.MAX_ENTITIES`](/ecs/world) — the ceiling on a world's `maxEntities`, `2^22 - 1` usable slots
- [`tecs.DEFAULT_MAX_ENTITIES`](/ecs/world) — the default when a world names none, `2^20`
- [`tecs.version`](/modules/surface) — the version of this build, as a string

## Why there are two halves

The ECS half above loads eagerly, because it reaches nothing below Lua. The engine half is named in the surface
for its types but resolved on first field access, because each of those modules reaches SDL, Box2D or a worker
library through the FFI, and loading them up front would make a test, a server or a tool demand a graphics stack
it never asked for. Reading `tecs.Camera` loads it; requiring `tecs` does not.

Nothing else is supported, with one exception: the `tecs.utils.*` modules (`profile`, `pool`, `Bitset`) may be
required directly. `tecs.internal.*` modules are implementation details with no stability guarantee.

## The dependency rule

`require("tecs")` is what a game requires. Engine modules require `tecs.ecs` instead, because the surface exports
those modules and a module that also depended on the surface would be a cycle, which Teal rejects even through a
type-only require. So the graph runs one way: internal code depends on a half, only a game depends on the whole.

## Design record

- [The surface is a global](https://github.com/tecs-dev/tecs/blob/main/README.md#the-surface-is-a-global)
- [One way in](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
- [Layout](https://github.com/tecs-dev/tecs/blob/main/README.md#layout)
