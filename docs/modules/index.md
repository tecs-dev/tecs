---
description: "Every module a game can reach, spelled the way a game writes it, each linking to its page"
outline: [2, 2]
---

# Modules

The host loads `tecs` before a game's entry file. Headless tools and specs load
the same table explicitly:

```teal
local tecs <const> = require("tecs")
```

Modules own their classes and supporting records. For example,
`tecs.gfx.Camera` and `tecs.window.Options` live directly under their module.
A module may contain one level of subordinate modules, such as
`tecs.gfx.layers`.

## Top-level modules

| Module                                    | Description                                                 |
| ----------------------------------------- | ----------------------------------------------------------- |
| [`tecs.assets`](/modules/assets)          | cached background content loading                           |
| [`tecs.audio`](/modules/audio)            | clips, voices, groups, limits, components, and devices      |
| [`tecs.data`](/modules/data)              | JSON, DEFLATE, and byte-string hashes                       |
| [`tecs.ecs`](/ecs/)                       | worlds, components, queries, systems, events, and resources |
| [`tecs.events`](/modules/events)          | typed platform events                                       |
| [`tecs.filesystem`](/modules/filesystem/) | game paths and file access                                  |
| [`tecs.gfx`](/modules/gfx/)               | cameras, rendering, text, and graphics components           |
| [`tecs.input`](/modules/input)            | gameplay input, gamepads, and sensors                       |
| [`tecs.log`](/modules/log)                | named, leveled platform logging                             |
| [`tecs.math`](/modules/math)              | allocation-free 2D vector and angle math                    |
| [`tecs.mcp`](/modules/mcp)                | the debug server, tools, and sandbox                        |
| [`tecs.net`](/modules/net/)               | nonblocking TCP streams and UDP datagrams                   |
| [`tecs.physics`](/modules/physics)        | Rapier 2D rigid-body simulation                             |
| [`tecs.regex`](/modules/regex)            | compiled regular expressions over Lua byte strings          |
| [`tecs.sequence`](/modules/sequence)      | sequencing and tweening                                     |
| [`tecs.system`](/modules/system)          | capabilities, clipboard access, and child processes         |
| [`tecs.time`](/modules/time)              | monotonic time                                              |
| [`tecs.window`](/modules/window)          | window size, display, and mode                              |
| [`tecs.workers`](/modules/workers)        | typed background jobs                                       |

## Subordinate modules

Each subordinate module has its own page.

| Module                                               | What it is                                      |
| ---------------------------------------------------- | ----------------------------------------------- |
| [`tecs.filesystem.watch`](/modules/filesystem/watch) | watching files for change                       |
| [`tecs.gfx.animation`](/modules/gfx/animation)       | sprite sheets, and the playback that reads them |
| [`tecs.gfx.layers`](/modules/gfx/layers)             | z-ordering and per-layer behavior               |
| [`tecs.gfx.materials`](/modules/gfx/materials)       | the material a draw dispatches to               |
| [`tecs.gfx.particles`](/modules/gfx/particles)       | emitters                                        |
| [`tecs.net.http`](/modules/net/http)                 | fetching over HTTP without stopping the frame   |

## Root types and functions

These names cross subsystem boundaries:

| Module                                        | What it is                                                      |
| --------------------------------------------- | --------------------------------------------------------------- |
| [`tecs.Application`](/modules/Application)    | the object an entry file returns, and what the host drives      |
| [`tecs.Future`](/modules/Future)              | a value that settles once                                       |
| [`tecs.newApplication`](/modules/Application) | builds the application an entry file returns                    |
| [`tecs.Transform`](/ecs/builtins#transform)   | where an entity is, and the one component every subsystem moves |
| [`tecs.version`](/modules/)                   | the version of this build, as a string                          |

## ECS guides

Games use `tecs.ecs`. Engine modules use `require("tecs.ecs")` to avoid a
dependency cycle through the root aggregator. Both expressions return the
same table.

- [Overview](/ecs/) -- the model, in one page
- [Archetypes](/ecs/archetype) -- cache-friendly storage for millions of entities
- [Builtins](/ecs/builtins) -- names, transforms, hierarchy, TTL, pause, disable, state events
- [Bundles](/ecs/components/bundles) -- reusable entity templates and batch spawning
- [Components](/ecs/components/) -- table, tag, scalar and FFI data containers
- [Dirty tracking](/ecs/components/dirty-tracking) -- change-gated systems and GPU synchronization
- [Events](/ecs/events) -- type-safe pub/sub and entity lifecycle events
- [Mutation model](/ecs/mutation-model) -- the normative rules for reads, writes and dirty bits
- [Phases](/ecs/phases) -- ordered phase scheduling
- [Plugins](/ecs/plugins) -- modular, shareable game mechanics
- [Profiling](/ecs/profiling) -- where a frame went
- [Queries](/ecs/queries/) -- reusable filters with archetype iteration, callbacks and grouping
- [Random](/ecs/random) -- seeded generation, in named streams a snapshot carries
- [Relationships](/ecs/relationships/) -- links, hierarchies, relative transforms, cascade deletion
- [Save games](/ecs/save-games) -- snapshots, component codecs, migrations, resource handlers
- [States](/ecs/states) -- stack-based game states with transition events
- [Systems](/ecs/systems) -- phase scheduling, dependencies and run conditions
- [World](/ecs/world) -- entities, resources and the state stack

## Module loading

`tecs.ecs` loads with the root. The root resolves every engine module on first
field access, so a headless ECS tool does not initialize unrelated subsystems.
Reading `tecs.gfx` loads it; requiring `tecs` does not.

A name that is not a module answers nil rather than raising. For example,
`tecs.cmaera` answers nil at the misspelled field.

The `tecs.utils.*` modules (`profile`, `pool`, and `Bitset`) also support
direct imports. `tecs.internal.*` has no stability guarantee.
