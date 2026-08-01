---
description: "Tecs home: a typed entity component system for LuaJIT and the GPU-driven game engine built around it"
layout: home

hero:
  name: "Build 2D games with LuaJIT"
  text: "Typed. GPU-driven. One data model."
  image:
    src: /images/tecs.png
    alt: Tecs
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: Modules
      link: /modules/

features:
  - title: Live inspection
    details: Inspect, freeze, and edit a running game through the <a href="/modules/io/mcp">built-in MCP server</a>.
    icon: 🤖
  - title: ECS built for LuaJIT
    details: >-
      An <a href="/modules/ecs/archetype">archetype-based ECS</a> with FFI components,
      contiguous columns, and a dirty model the GPU reads.
    icon: ⚡
  - title: Batteries included
    details: >-
      <a href="/modules/physics">Physics</a>,
      <a href="/modules/audio">audio</a>,
      <a href="/modules/gfx/particles">particles</a>,
      <a href="/modules/gfx/">text</a>,
      <a href="/ui/">retained UI</a>,
      <a href="/modules/sequence">sequences</a>,
      <a href="/modules/gfx/animation">sprite sheets</a>, and hot reload share
      the ECS.
    icon: 🔋
  - title: Static typing
    details: >-
      <a href="https://github.com/teal-language/tl"><u>Teal</u></a> checks
      component, query, system, and engine APIs before the game runs.
    icon:
      src: /images/teal.svg
---

## Install

The `tecs` command carries the compiler, engine, type definitions, and project template. It needs no separate Lua,
LuaRocks, Teal, or C compiler installation.

::: code-group

```bash [macOS]
brew install tecs-dev/tap/tecs
```

```powershell [Windows]
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

```bash [Linux]
brew install tecs-dev/tap/tecs
```

:::

Create a game and run it:

```bash
tecs new my-game && cd my-game && tecs run
```

The [Tecs CLI](/cli/) carries the project toolchain in one file. Contributors can build this repository through
Cargo; [getting started](/getting-started) covers that workflow.

## Entities are the interface

Anything that renders or updates per frame is an entity in a world. The host
owns the loop: an entry file returns an application, so game code registers
work instead of driving frames itself.

```teal
local Transform <const> = tecs.Transform

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers = world:newQuery({ include = { Transform } })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in movers:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        transforms[row].rotation = transforms[row].rotation + dt
                    end
                end
            end,
        })

        world:spawn(Transform(100, 100))
    end,
})
```

## ECS examples

::: code-group

```teal [Components]
local world = tecs.ecs.newWorld()

-- Define typed components with Teal
local record Position is tecs.ecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Position
end

tecs.ecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {{"x", "float"}, {"y", "float"}},
})

local record Velocity is tecs.ecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Velocity
end

tecs.ecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {{"x", "float"}, {"y", "float"}},
})

-- Query and update entities
local query = world:newQuery({include = {Position, Velocity}})

world:addSystem({
    phase = tecs.ecs.phases.Update,
    run = function(dt: number, _world: tecs.World)
        for archetype, len in query:iter() do
            local positions = archetype:getMut(Position)
            local velocities = archetype:get(Velocity)
            for row = 1, len do
                positions[row].x = positions[row].x + velocities[row].x * dt
            end
        end
    end
})

world:spawn(Position(100, 100), Velocity(10, 0))
```

```teal [Relationships]
local world = tecs.ecs.newWorld()
local ChildOf = tecs.ecs.ChildOf

-- Create a parent entity
local parent: integer = world:spawn(
    tecs.ecs.Name("parent"),
    tecs.Transform(100, 100)
)

-- ChildOf has cascadeDelete; despawning parent despawns children too.
local child1: integer = world:spawn(
    ChildOf(parent),
    tecs.ecs.RelativeTransform(20, 0)
)

local child2: integer = world:spawn(
    ChildOf(parent),
    tecs.ecs.RelativeTransform(-20, 0)
)

-- Walk children of a specific parent
world:targets(parent, ChildOf, function(childId: integer)
    print("child:", childId)
end)

-- Despawning parent cascades to child1 and child2
world:despawn(parent)
```

```teal [Events]
local world = tecs.ecs.newWorld()

-- Define a custom event
local record DamageEvent is tecs.events.Event
    target: integer
    amount: number
    metamethod __call: function(self, target: integer, amount: number): DamageEvent
end

-- Wire up the event init hook (it mutates a pre-allocated instance)
DamageEvent.init = function(e: DamageEvent, target: integer, amount: number)
    e.target = target
    e.amount = amount
end
tecs.events.newEvent(DamageEvent)

-- Observe events anywhere in your game (0 = world-level)
world:observe(0, DamageEvent, function(e: DamageEvent)
    local health: Health = world:get(e.target, Health)
    if health then
        health.current = health.current - e.amount
        if health.current <= 0 then
            world:despawn(e.target)
        end
    end
end)

-- Emit events from systems
world:emit(0, DamageEvent, enemyId, 25)
```

:::

## Reference

The host loads `tecs` before the entry file. A game can use these names without a `require`:

::: module-columns

- [`tecs.assets`](/modules/assets) - loading bytes, images and sounds off the main thread
- [`tecs.audio`](/modules/audio) - voices, groups, keyed limits, fades, pitch, loop points, streaming, devices
- [`tecs.data`](/modules/data) - typed stores, JSON, byte encodings, DEFLATE, transcoding, UTF-8, UUIDs, hashes and checksums
- [`tecs.ecs`](/modules/ecs/) - worlds, components, queries, systems, events and resources
- [`tecs.events`](/modules/events) - typed events and address-based message buses
- [`tecs.gfx`](/modules/gfx/) - the camera, the components, the renderer, text, and the vocabularies below
- [`tecs.input`](/modules/input) - gameplay input, gamepads and standalone sensors
- [`tecs.io`](/modules/io/) - binary I/O, nonblocking sockets, HTTP, and external tools
- [`tecs.log`](/modules/log) - named, leveled platform logging
- [`tecs.math`](/modules/math) - angle math and two-dimensional geometry
- [`tecs.physics`](/modules/physics) - Rapier 2D, solved across a shared thread pool
- [`tecs.platform`](/modules/platform/) - platform events, operating-system services, time, and windows
- [`tecs.regex`](/modules/regex) - compiled regular expressions over Lua byte strings
- [`tecs.runtime`](/modules/runtime) - process-wide polling for asynchronous work
- [`tecs.sequence`](/modules/sequence) - timelines with the tween runtime inside them
- [`tecs.ui`](/modules/ui) - retained layout, scrolling, clipping, and interaction over existing drawing components
- [`tecs.workers`](/modules/workers) - typed background jobs

Inside one of those, one level and no deeper:

- [`tecs.data.utf8`](/modules/data/utf8) - UTF-8 codepoint decoding, encoding, validation and truncation
- [`tecs.ecs.random`](/modules/ecs/random) - seeded named streams and standalone generators
- [`tecs.gfx.animation`](/modules/gfx/animation) - sprite sheets, and the playback that reads them
- [`tecs.gfx.layers`](/modules/gfx/layers) - z-ordering and per-layer behavior
- [`tecs.gfx.materials`](/modules/gfx/materials) - one fragment shader, compiled from the material set
- [`tecs.gfx.particles`](/modules/gfx/particles) - emitters
- [`tecs.io.files`](/modules/io/files) - where a game may read and write, and what to do with a path
- [`tecs.io.http`](/modules/io/http) - fetching over HTTP without stopping the frame
- [`tecs.io.mcp`](/modules/io/mcp) - the debug server agents and humans drive a running game through
- [`tecs.io.watcher`](/modules/io/watcher) - watching files for change
- [`tecs.math.vec2`](/modules/math/vec2) - allocation-free two-dimensional vector and point math
- [`tecs.platform.events`](/modules/platform/events) - typed platform events routed through the world
- [`tecs.platform.os`](/modules/platform/os) - capabilities, process signals, the clipboard, and desktop services
- [`tecs.platform.time`](/modules/platform/time) - clocks, calendar time, delays and frame timing
- [`tecs.platform.window`](/modules/platform/window) - the window, its size, its display and its mode

On `tecs` itself, because no one module owns them:

- [`tecs.Application`](/modules/Application) - the object an entry file returns, and what the host drives
- [`tecs.Future`](/modules/Future) - a value that settles once
- [`tecs.newApplication`](/modules/Application) - builds the application an entry file returns
- [`tecs.scoped`](/modules/#tecs.scoped) - closes explicitly owned resources when one callback ends
- [`tecs.Transform`](/modules/ecs/builtins#transform) - where an entity is, and the one component every subsystem moves
- [`tecs.version`](/modules/) - the version of this build, as a string

:::

## tecs.ecs

Worlds, components, queries, systems, events and resources. One table with two ways in: a game reads it off
`tecs` like any other module, and an engine module writes `require("tecs.ecs")`, because `tecs` is the
aggregator that pulls every engine module in and a module `tecs` exports cannot also depend on `tecs`. These
are the concepts behind the names.

::: module-columns

- [Overview](/modules/ecs/) - the model, in one page
- [Archetypes](/modules/ecs/archetype) - cache-friendly storage for millions of entities
- [Builtins](/modules/ecs/builtins) - names, transforms, hierarchy, TTL, pause, disable, state events
- [Bundles](/modules/ecs/components/bundles) - reusable entity templates and batch spawning
- [Components](/modules/ecs/components/) - table, tag, scalar and FFI data containers
- [Dirty tracking](/modules/ecs/components/dirty-tracking) - change-gated systems and GPU synchronization
- [Events](/modules/ecs/events) - type-safe pub/sub and entity lifecycle events
- [Mutation model](/modules/ecs/mutation-model) - the normative rules for reads, writes and dirty bits
- [Phases](/modules/ecs/phases) - ordered phase scheduling
- [Plugins](/modules/ecs/plugins) - modular, shareable game mechanics
- [Profiling](/modules/ecs/profiling) - where a frame went
- [Queries](/modules/ecs/queries/) - reusable filters with archetype iteration, callbacks and grouping
- [Relationships](/modules/ecs/relationships/) - links, hierarchies, relative transforms, cascade deletion
- [Save games](/modules/ecs/save-games) - snapshots, component codecs, migrations, resource handlers
- [States](/modules/ecs/states) - stack-based game states with transition events
- [Systems](/modules/ecs/systems) - phase scheduling, dependencies and run conditions
- [World](/modules/ecs/world) - entities, resources and the state stack

:::
