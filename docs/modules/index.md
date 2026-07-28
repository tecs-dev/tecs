---
description: "Every module a game can reach, spelled the way a game writes it, each linking to its page"
outline: [2, 2]
---

# Modules

Every name below is a field on `tecs`, spelled here exactly as a game writes it. `tecs` is ambient in a game:
the module installs itself as a global as it returns and the host has already loaded it by the time an entry
file runs, so no file in a game needs a require line. A headless tool or a spec does not go through the host
and writes `local tecs <const> = require("tecs")` first; it is the same table either way.

Each module is one namespace, and the thing inside it carries its own name: `tecs.camera.Camera` is the class,
`tecs.camera` is where it lives. So no name is a type and a namespace at once, and a satellite record sits
beside the class rather than under it -- `tecs.window.Options`, not `tecs.window.Window.Options`.

The list is alphabetical, ignoring case, because that is how a name is looked up. A reader arrives holding
`tecs.watch` and wants the line that says `tecs.watch`, not a category somebody else chose to file it under.

This list is the index; the pages behind it are the reference. For signatures, parameters and returns of
everything at once, see [the generated reference](/modules/), which is rendered from `src/tecs/init.tl`
and checked against a fresh render so it cannot drift.

## Every module

| Module                                       | What it is                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------- |
| [`tecs.animation`](/modules/animation)       | sprite playback                                                           |
| [`tecs.application`](/modules/application)   | the object an entry file returns, and what builds one                     |
| [`tecs.assets`](/modules/assets)             | loading content, cached and off the main thread                           |
| [`tecs.audio`](/modules/audio)               | clips, voices, groups, limits, the `Sound` component, and devices         |
| [`tecs.camera`](/modules/camera)             | the view a frame is drawn from                                            |
| [`tecs.capabilities`](/modules/capabilities) | what this machine and this build can do                                   |
| [`tecs.clipboard`](/modules/clipboard)       | reading and writing the system clipboard                                  |
| [`tecs.clock`](/modules/clock)               | monotonic time                                                            |
| [`tecs.components`](/modules/components)     | the engine's own components, the ones the renderer reads                  |
| [`tecs.compress`](/modules/compress)         | compression and decompression                                             |
| [`tecs.ecs`](/ecs/)                          | worlds, components, queries, systems, events and resources                |
| [`tecs.events`](/modules/events)             | platform events, typed once and routed                                    |
| [`tecs.filesystem`](/modules/filesystem)     | touching the filesystem                                                   |
| [`tecs.future`](/modules/future)             | a value that settles once                                                 |
| [`tecs.gamepad`](/modules/gamepad)           | a pad's identity, lifetime, metadata and outputs                          |
| [`tecs.hash`](/modules/hash)                 | hashing                                                                   |
| [`tecs.http`](/modules/http)                 | fetching over HTTP without stopping the frame                             |
| [`tecs.input`](/modules/input)               | gameplay input in three tiers, behind a layer stack                       |
| [`tecs.json`](/modules/json)                 | JSON, with the build's own copy of the C parser found                     |
| [`tecs.layers`](/modules/layers)             | z-ordering and per-layer behaviour                                        |
| [`tecs.log`](/modules/log)                   | SDL's logging, per platform, with a named logger as the unit of filtering |
| [`tecs.materials`](/modules/materials)       | the material a draw dispatches to                                         |
| [`tecs.mcp`](/modules/mcp)                   | the debug server: transport, tools, sandbox                               |
| [`tecs.net`](/modules/net)                   | nonblocking TCP streams and UDP datagrams                                 |
| [`tecs.particles`](/modules/particles)       | emitters                                                                  |
| [`tecs.paths`](/modules/paths)               | where a game may read from and write to                                   |
| [`tecs.physics`](/modules/physics)           | rigid-body simulation on Box2D 3                                          |
| [`tecs.proc`](/modules/proc)                 | shelling out                                                              |
| [`tecs.renderer`](/modules/renderer)         | a world to a frame, through an extractor and a backend                    |
| [`tecs.sensors`](/modules/sensors)           | standalone accelerometers and gyroscopes                                  |
| [`tecs.sequence`](/modules/sequence)         | the sequencer, with the tween runtime inside it                           |
| [`tecs.sheet`](/modules/sheet)               | sprite sheets: loading one, and what is in it                             |
| [`tecs.system`](/modules/system)             | URLs, locales, power, messages, and native file and folder dialogs        |
| [`tecs.text`](/modules/text)                 | distance-field text, drawn through an instance producer                   |
| [`tecs.version`](/modules/)                  | the version of this build, as a string                                    |
| [`tecs.watch`](/modules/watch)               | watching files for change                                                 |
| [`tecs.window`](/modules/window)             | the window, its size, its display and its mode                            |
| [`tecs.workers`](/modules/workers)           | typed background jobs                                                     |

## tecs.ecs

`tecs.ecs` is the ECS: `tecs.ecs.newWorld`, `tecs.ecs.phases`, `tecs.ecs.builtins`, `tecs.ecs.runif`,
`tecs.ecs.random` and the component constructors. It is one table with two ways in. A game reads it off `tecs`
like any other module; an engine module writes `require("tecs.ecs")`, because `tecs` is the aggregator that
pulls every engine module in and a module `tecs` exports cannot also depend on `tecs` without making a cycle,
which Teal rejects even through a type-only require. Both spellings reach the same table.

What follows are the concepts behind those names, which are pages rather than names.

- [Overview](/ecs/) -- the model, in one page
- [Archetypes](/ecs/archetype) -- cache-friendly storage for millions of entities
- [Builtins](/ecs/builtins) -- names, transforms, hierarchy, TTL, pause, disable, state events
- [Bundles](/ecs/components/bundles) -- reusable entity templates and batch spawning
- [Components](/ecs/components/) -- table, tag, scalar and FFI data containers
- [Dirty tracking](/ecs/components/dirty-tracking) -- change-gated systems and GPU synchronisation
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

## What loads when

`tecs.ecs` loads with `tecs`, because it reaches nothing below Lua. Every other module is named on `tecs` for
its types and resolved on first field access, because each of them reaches SDL, Box2D or a worker library
through the FFI, and loading them up front would make a test, a server or a tool demand a graphics stack it
never asked for. Reading `tecs.camera` loads it; requiring `tecs` does not.

A name that is not a module answers nil rather than raising, and the modules are written out in `init.tl`
rather than derived from a module path, so `tecs.cmaera` is nil where it is written instead of an error out of
`require` about a module nobody meant to ask for.

Nothing else is supported, with one exception: the `tecs.utils.*` modules (`profile`, `pool`, `Bitset`) may be
required directly. `tecs.internal.*` modules are implementation details with no stability guarantee.
