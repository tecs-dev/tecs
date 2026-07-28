---
description: "Index of every module and value on the public Tecs surface, with a page for each"
outline: deep
---

# Module reference

`require("tecs")` is the whole surface. Everything below is a field on it, and `tecs` is also a global, so a
require line is optional.

```teal
local tecs <const> = require("tecs")
```

The surface has two halves. The **ECS half** loads eagerly, because it reaches nothing below Lua. The **engine
half** is named here for its types but resolved on first field access, because each of those modules reaches SDL,
Box2D or a worker library through the FFI, and loading them up front would make a test, a server or a tool demand
a graphics stack it never asked for. Reading `tecs.Camera` loads it; requiring `tecs` does not.

`tecs.internal.*` modules are implementation details with no stability guarantee.

## The engine half

### Lifecycle and rendering

| Module                                | What it is for                                           |
| ------------------------------------- | -------------------------------------------------------- |
| [`Application`](/modules/Application) | The object an entry file returns and the host drives     |
| [`Renderer`](/modules/Renderer)       | A world to a frame, through an extractor and a backend   |
| [`Camera`](/modules/Camera)           | The view a frame is drawn from                           |
| [`layers`](/modules/layers)           | Z-ordering and per-layer behaviour                       |
| [`materials`](/modules/materials)     | The material a draw dispatches to                        |
| [`sheet`](/modules/sheet)             | Sprite sheets: loading one and describing what is in it  |
| [`animation`](/modules/animation)     | Sprite playback                                          |
| [`text`](/modules/text)               | Distance-field text, drawn through an instance producer  |
| [`particles`](/modules/particles)     | Emitters                                                 |
| [`components`](/modules/components)   | The engine's own components, the ones the renderer reads |

### Platform

| Module                                  | What it is for                                      |
| --------------------------------------- | --------------------------------------------------- |
| [`Window`](/modules/Window)             | The window, its size, its display and its mode      |
| [`Input`](/modules/Input)               | Gameplay input in three tiers, behind a layer stack |
| [`Gamepad`](/modules/Gamepad)           | A pad's identity, lifetime, metadata and outputs    |
| [`events`](/modules/events)             | Platform events, typed once and routed              |
| [`clock`](/modules/clock)               | Monotonic time                                      |
| [`clipboard`](/modules/clipboard)       | Reading and writing the system clipboard            |
| [`proc`](/modules/proc)                 | Shelling out                                        |
| [`paths`](/modules/paths)               | Where a game may read from and write to             |
| [`filesystem`](/modules/filesystem)     | Touching the filesystem                             |
| [`watch`](/modules/watch)               | Watching files for change                           |
| [`capabilities`](/modules/capabilities) | What this machine and this build can do             |

### Simulation and content

| Module                          | What it is for                                           |
| ------------------------------- | -------------------------------------------------------- |
| [`physics`](/modules/physics)   | Rigid-body simulation on Box2D 3                         |
| [`Audio`](/modules/Audio)       | Clips, voices, groups, limits, and the `Sound` component |
| [`sequence`](/modules/sequence) | The sequencer, with the tween runtime inside it          |
| [`assets`](/modules/assets)     | Loading content, cached and off the main thread          |
| [`workers`](/modules/workers)   | Typed background jobs                                    |
| [`Future`](/modules/Future)     | A value that settles once                                |

### Tooling and utilities

| Module                          | What it is for                                                            |
| ------------------------------- | ------------------------------------------------------------------------- |
| [`log`](/modules/log)           | SDL's logging, per platform, with a named logger as the unit of filtering |
| [`mcp`](/modules/mcp)           | The debug server: transport, tools, sandbox                               |
| [`json`](/modules/json)         | JSON, with the build's own copy of the C parser found                     |
| [`hash`](/modules/hash)         | Hashing                                                                   |
| [`compress`](/modules/compress) | Compression and decompression                                             |

## The ECS half

These load with the surface. Most have a page in the [ECS section](/ecs/) rather than here, because they are
concepts as much as they are modules.

| Surface entry                                                              | Page                                    |
| -------------------------------------------------------------------------- | --------------------------------------- |
| `newWorld`                                                                 | [World](/ecs/world)                     |
| `newComponent`, `newFFIComponent`, `newTagComponent`, `newScalarComponent` | [Components](/ecs/components/)          |
| `newRelationship`, `newFFIRelationship`                                    | [Relationships](/ecs/relationships/)    |
| `newEvent`, `newFFIEvent`, `newMessageBus`                                 | [Events](/ecs/events)                   |
| `newKey`, `findKey`, `listKeys`, `newContext`                              | [World: resources](/ecs/world)          |
| `phases`                                                                   | [Phases](/ecs/phases)                   |
| `builtins`                                                                 | [Builtins](/ecs/builtins)               |
| `runif`                                                                    | [Systems: run conditions](/ecs/systems) |
| `getComponentById`, `componentByName`                                      | [Components](/ecs/components/)          |
| [`random`](/modules/random)                                                | Seeded random numbers                   |

### Values

| Value                  | What it is                                                                              |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `version`              | The version of this build, as a string                                                  |
| `MAX_ENTITIES`         | The absolute ceiling for a world's `maxEntities`, `2^22 - 1` usable slots               |
| `DEFAULT_MAX_ENTITIES` | The default `maxEntities` when a world names none, `2^20`                               |
| `application`          | Builds the application an entry file returns; see [`Application`](/modules/Application) |

## The dependency rule

`require("tecs")` is what a game requires. Engine modules require `tecs.ecs` instead, because the surface exports
those modules and a module that also depended on the surface would be a cycle, which Teal rejects even through a
type-only require. So the graph runs one way: internal code depends on a half, only a game depends on the whole.

## Design record

- [The surface is a global](https://github.com/tecs-dev/tecs/blob/main/README.md#the-surface-is-a-global)
- [One way in](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
- [Layout](https://github.com/tecs-dev/tecs/blob/main/README.md#layout)
