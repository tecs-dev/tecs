---
description: "Every module a game can reach, spelled the way a game writes it, each linking to its page"
outline: [2, 2]
---

# Modules

`require("tecs")` is the whole of it. Every name below is a field on that one table, spelled here exactly as a
game writes it. `tecs` is also a global, so the require line is optional.

```teal
local tecs <const> = require("tecs")
```

The list is alphabetical, ignoring case, because that is how a name is looked up. A reader arrives holding
`tecs.watch` and wants the line that says `tecs.watch`, not a category somebody else chose to file it under.
Where two names differ only in case, the capitalised one comes first: `tecs.Application` is the type,
`tecs.application` is the function that builds one.

This list is the index; the pages behind it are the reference. For signatures, parameters and returns of
everything at once, see [every signature at once](/modules/surface), which is rendered from `src/tecs/init.tl` and
checked against a fresh render so it cannot drift.

## Engine and ECS

| Module                                                                 | What it is                                                                |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| [`tecs.animation`](/modules/animation)                                 | sprite playback                                                           |
| [`tecs.Application`](/modules/Application)                             | the object an entry file returns and the host drives                      |
| [`tecs.application`](/modules/Application)                             | builds that object                                                        |
| [`tecs.assets`](/modules/assets)                                       | loading content, cached and off the main thread                           |
| [`tecs.Audio`](/modules/Audio)                                         | clips, voices, groups, limits, and the `Sound` component                  |
| [`tecs.audio`](/modules/Audio#physical-devices-and-microphone-capture) | physical audio devices and microphone capture                             |
| [`tecs.builtins`](/ecs/builtins)                                       | `Transform`, `ChildOf`, `TTL`, `Paused`, `Disabled` and the rest          |
| [`tecs.Camera`](/modules/Camera)                                       | the view a frame is drawn from                                            |
| [`tecs.capabilities`](/modules/capabilities)                           | what this machine and this build can do                                   |
| [`tecs.clipboard`](/modules/clipboard)                                 | reading and writing the system clipboard                                  |
| [`tecs.clock`](/modules/clock)                                         | monotonic time                                                            |
| [`tecs.componentByName`](/ecs/components/)                             | the component a name names                                                |
| [`tecs.components`](/modules/components)                               | the engine's own components, the ones the renderer reads                  |
| [`tecs.compress`](/modules/compress)                                   | compression and decompression                                             |
| [`tecs.DEFAULT_MAX_ENTITIES`](/ecs/world)                              | the default `maxEntities` when a world names none, `2^20`                 |
| [`tecs.events`](/modules/events)                                       | platform events, typed once and routed                                    |
| [`tecs.filesystem`](/modules/filesystem)                               | touching the filesystem                                                   |
| [`tecs.findKey`](/ecs/world)                                           | the key a name was created with, or nil                                   |
| [`tecs.Future`](/modules/Future)                                       | a value that settles once                                                 |
| [`tecs.Gamepad`](/modules/Gamepad)                                     | a pad's identity, lifetime, metadata and outputs                          |
| [`tecs.getComponentById`](/ecs/components/)                            | the component a numeric id names                                          |
| [`tecs.hash`](/modules/hash)                                           | hashing                                                                   |
| [`tecs.http`](/modules/http)                                           | fetching over HTTP without stopping the frame                             |
| [`tecs.Input`](/modules/Input)                                         | gameplay input in three tiers, behind a layer stack                       |
| [`tecs.json`](/modules/json)                                           | JSON, with the build's own copy of the C parser found                     |
| [`tecs.layers`](/modules/layers)                                       | z-ordering and per-layer behaviour                                        |
| [`tecs.listKeys`](/ecs/world)                                          | every named key, as name to id                                            |
| [`tecs.log`](/modules/log)                                             | SDL's logging, per platform, with a named logger as the unit of filtering |
| [`tecs.materials`](/modules/materials)                                 | the material a draw dispatches to                                         |
| [`tecs.MAX_ENTITIES`](/ecs/world)                                      | the ceiling on a world's `maxEntities`, `2^22 - 1` usable slots           |
| [`tecs.mcp`](/modules/mcp)                                             | the debug server: transport, tools, sandbox                               |
| [`tecs.net`](/modules/net)                                             | nonblocking TCP streams and UDP datagrams                                 |
| [`tecs.newComponent`](/ecs/components/table-components)                | a table component                                                         |
| [`tecs.newContext`](/ecs/world)                                        | a resource container outside a world                                      |
| [`tecs.newEvent`](/ecs/events)                                         | give an event record its constructor                                      |
| [`tecs.newFFIComponent`](/ecs/components/ffi)                          | a component backed by an FFI struct                                       |
| [`tecs.newFFIEvent`](/ecs/events)                                      | the same for an FFI-backed event                                          |
| [`tecs.newFFIRelationship`](/ecs/relationships/ffi)                    | a relationship carrying data in an FFI struct                             |
| [`tecs.newKey`](/ecs/world)                                            | a typed key for a resource                                                |
| [`tecs.newMessageBus`](/ecs/events)                                    | an address-based bus, outside any world                                   |
| [`tecs.newRelationship`](/ecs/relationships/)                          | a link from one entity to another                                         |
| [`tecs.newScalarComponent`](/ecs/components/scalar-components)         | a component that is one value                                             |
| [`tecs.newTagComponent`](/ecs/components/tag-components)               | a component with no data, in bitset storage                               |
| [`tecs.newWorld`](/ecs/world)                                          | create a world                                                            |
| [`tecs.particles`](/modules/particles)                                 | emitters                                                                  |
| [`tecs.paths`](/modules/paths)                                         | where a game may read from and write to                                   |
| [`tecs.phases`](/ecs/phases)                                           | the phases a system can be scheduled into                                 |
| [`tecs.physics`](/modules/physics)                                     | rigid-body simulation on Box2D 3                                          |
| [`tecs.proc`](/modules/proc)                                           | shelling out                                                              |
| [`tecs.random`](/modules/random)                                       | seeded random numbers                                                     |
| [`tecs.Renderer`](/modules/Renderer)                                   | a world to a frame, through an extractor and a backend                    |
| [`tecs.runif`](/ecs/systems)                                           | composable run conditions                                                 |
| [`tecs.sensors`](/modules/sensors)                                     | standalone accelerometers and gyroscopes                                  |
| [`tecs.sequence`](/modules/sequence)                                   | the sequencer, with the tween runtime inside it                           |
| [`tecs.sheet`](/modules/sheet)                                         | sprite sheets: loading one, and what is in it                             |
| [`tecs.system`](/modules/system)                                       | URLs, locales, power, messages, and native file and folder dialogs        |
| [`tecs.text`](/modules/text)                                           | distance-field text, drawn through an instance producer                   |
| [`tecs.version`](/modules/surface)                                     | the version of this build, as a string                                    |
| [`tecs.watch`](/modules/watch)                                         | watching files for change                                                 |
| [`tecs.Window`](/modules/Window)                                       | the window, its size, its display and its mode                            |
| [`tecs.workers`](/modules/workers)                                     | typed background jobs                                                     |

## tecs.ecs

**A game does not require this.** `tecs.ecs` is the ECS half on its own, and it exists for engine code: `tecs` is
the aggregator that pulls every engine module in, so a module `tecs` exports cannot also depend on `tecs`
without making a cycle, which Teal rejects even through a type-only require. Engine modules therefore
require `tecs.ecs`, and only a game requires the whole of `tecs`.

Everything it carries is on `tecs` too, and that is where a game reads it: `tecs.newWorld`, `tecs.phases`,
`tecs.builtins`, `tecs.runif`, `tecs.random` and the component constructors are all in the list above. What
follows are the concepts behind them, which are pages rather than names.

- [Overview](/ecs/) — the model, in one page
- [Archetypes](/ecs/archetype) — cache-friendly storage for millions of entities
- [Builtins](/ecs/builtins) — names, transforms, hierarchy, TTL, pause, disable, state events
- [Bundles](/ecs/components/bundles) — reusable entity templates and batch spawning
- [Components](/ecs/components/) — table, tag, scalar and FFI data containers
- [Dirty tracking](/ecs/components/dirty-tracking) — change-gated systems and GPU synchronisation
- [Events](/ecs/events) — type-safe pub/sub and entity lifecycle events
- [Mutation model](/ecs/mutation-model) — the normative rules for reads, writes and dirty bits
- [Phases](/ecs/phases) — ordered phase scheduling
- [Plugins](/ecs/plugins) — modular, shareable game mechanics
- [Profiling](/ecs/profiling) — where a frame went
- [Queries](/ecs/queries/) — reusable filters with archetype iteration, callbacks and grouping
- [Relationships](/ecs/relationships/) — links, hierarchies, relative transforms, cascade deletion
- [Save games](/ecs/save-games) — snapshots, component codecs, migrations, resource handlers
- [States](/ecs/states) — stack-based game states with transition events
- [Systems](/ecs/systems) — phase scheduling, dependencies and run conditions
- [World](/ecs/world) — entities, resources and the state stack

## Why there are two halves

The ECS half loads eagerly, because it reaches nothing below Lua. The engine half is named on `tecs` for its
types but resolved on first field access, because each of those modules reaches SDL, Box2D or a worker library
through the FFI, and loading them up front would make a test, a server or a tool demand a graphics stack it never
asked for. Reading `tecs.Camera` loads it; requiring `tecs` does not.

Nothing else is supported, with one exception: the `tecs.utils.*` modules (`profile`, `pool`, `Bitset`) may be
required directly. `tecs.internal.*` modules are implementation details with no stability guarantee.

## Design record

- [The surface is a global](https://github.com/tecs-dev/tecs/blob/main/README.md#the-surface-is-a-global)
- [One way in](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
- [Layout](https://github.com/tecs-dev/tecs/blob/main/README.md#layout)
