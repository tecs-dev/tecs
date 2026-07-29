---
description: "Every module a game can reach, spelled the way a game writes it, each linking to its page"
outline: [2, 2]
---

# Modules

Every name below is a field on `tecs`, spelled here exactly as a game writes it. `tecs` is ambient in a game:
the module installs itself as a global as it returns and the host has already loaded it by the time an entry
file runs, so no file in a game needs a require line. A headless tool or a spec does not go through the host
and writes `local tecs <const> = require("tecs")` first; it is the same table either way.

Each module is one namespace, and the thing inside it carries its own name: `tecs.gfx.Camera` is the class,
`tecs.gfx` is where it lives. So no name is a type and a namespace at once, and a satellite record sits
beside the class rather than under it -- `tecs.window.Options`, not `tecs.window.Window.Options`.

A module may also sit inside another module, one level and no deeper: `tecs.gfx.layers` is a module, and there
is no third namespace under it. A subordinate module is listed here under its own full name and has a page of
its own, because it is a module rather than a section of its parent; a type its parent owns stays on the
parent's page.

The list is alphabetical, ignoring case, because that is how a name is looked up. A reader arrives holding
`tecs.filesystem.watch` and wants the line that says `tecs.filesystem.watch`, not a category somebody else chose to file it under.
A subordinate module sorts directly after its parent, since that is where its full name puts it.

This list is the index; the pages behind it are the reference. For signatures, parameters and returns of
everything at once, see [the generated reference](/modules/), which is rendered from `src/tecs/init.tl`
and checked against a fresh render so it cannot drift.

## Every module

| Module                                    | What it is                                                                 |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| [`tecs.assets`](/modules/assets)          | loading content, cached and off the main thread                            |
| [`tecs.audio`](/modules/audio)            | clips, voices, groups, limits, the `Sound` component, and devices          |
| [`tecs.data`](/modules/data)              | JSON, DEFLATE and hashes over byte strings                                 |
| [`tecs.ecs`](/ecs/)                       | worlds, components, queries, systems, events and resources                 |
| [`tecs.events`](/modules/events)          | platform events, typed once and routed                                     |
| [`tecs.filesystem`](/modules/filesystem/) | where a game may read and write, and what to do with a path                |
| [`tecs.gfx`](/modules/gfx/)               | the camera, the components, the renderer, text, and the vocabularies below |
| [`tecs.input`](/modules/input)            | gameplay input, the gamepads on it, and standalone sensors                 |
| [`tecs.log`](/modules/log)                | SDL's logging, per platform, with a named logger as the unit of filtering  |
| [`tecs.mcp`](/modules/mcp)                | the debug server: transport, tools, sandbox                                |
| [`tecs.net`](/modules/net/)               | nonblocking TCP streams and UDP datagrams                                  |
| [`tecs.physics`](/modules/physics)        | rigid-body simulation on Rapier 2D                                         |
| [`tecs.sequence`](/modules/sequence)      | the sequencer, with the tween runtime inside it                            |
| [`tecs.system`](/modules/system)          | capabilities, the clipboard, child processes, and what the desktop offers  |
| [`tecs.time`](/modules/time)              | monotonic time                                                             |
| [`tecs.window`](/modules/window)          | the window, its size, its display and its mode                             |
| [`tecs.workers`](/modules/workers)        | typed background jobs                                                      |

## Modules inside a module

One level and no deeper. Each is a module in its own right with a page of its
own, listed here under the full name a game writes.

| Module                                               | What it is                                      |
| ---------------------------------------------------- | ----------------------------------------------- |
| [`tecs.filesystem.watch`](/modules/filesystem/watch) | watching files for change                       |
| [`tecs.gfx.animation`](/modules/gfx/animation)       | sprite sheets, and the playback that reads them |
| [`tecs.gfx.layers`](/modules/gfx/layers)             | z-ordering and per-layer behavior               |
| [`tecs.gfx.materials`](/modules/gfx/materials)       | the material a draw dispatches to               |
| [`tecs.gfx.particles`](/modules/gfx/particles)       | emitters                                        |
| [`tecs.net.http`](/modules/net/http)                 | fetching over HTTP without stopping the frame   |

## On `tecs` itself

Types and functions that cross subsystems, so no one module owns them.

| Module                                        | What it is                                                      |
| --------------------------------------------- | --------------------------------------------------------------- |
| [`tecs.Application`](/modules/Application)    | the object an entry file returns, and what the host drives      |
| [`tecs.Future`](/modules/Future)              | a value that settles once                                       |
| [`tecs.newApplication`](/modules/Application) | builds the application an entry file returns                    |
| [`tecs.Transform`](/ecs/builtins#transform)   | where an entity is, and the one component every subsystem moves |
| [`tecs.version`](/modules/)                   | the version of this build, as a string                          |

## tecs.ecs

`tecs.ecs` is the ECS: `tecs.ecs.newWorld`, `tecs.Transform`, `tecs.ecs.phases`, `tecs.ecs.runif`,
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

## What loads when

`tecs.ecs` loads with `tecs`, because it reaches nothing below Lua. Every other module is named on `tecs` for
its types and resolved on first field access, because each is engine functionality a headless ECS-only tool may
not need, and many reach SDL, a Rust native service or a worker through the FFI. Loading them up front would make
a test, a server or a tool demand a graphics stack it never asked for. Reading `tecs.gfx` loads it; requiring
`tecs` does not.

A name that is not a module answers nil rather than raising, and the modules are written out in `init.tl`
rather than derived from a module path, so `tecs.cmaera` is nil where it is written instead of an error out of
`require` about a module nobody meant to ask for.

Nothing else is supported, with one exception: the `tecs.utils.*` modules (`profile`, `pool`, `Bitset`) may be
required directly. `tecs.internal.*` modules are implementation details with no stability guarantee.
