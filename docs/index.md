---
description: "Tecs home: a typed entity component system for LuaJIT and the GPU-driven game engine built around it"
layout: home

hero:
  name: "Build games with LuaJIT"
  text: "Typed. GPU-driven. Designed for humans and AI."
  image:
    src: /images/tecs.png
    alt: Tecs
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: The surface
      link: /modules/
    - theme: alt
      text: The ECS
      link: /ecs/

features:
  - title: Build with AI
    details: A <a href="/modules/mcp">built-in MCP server</a> lets humans and agents inspect, freeze and edit a running game.
    icon: 🤖
  - title: ECS built for LuaJIT
    details: An <a href="/ecs/archetype">archetype-based ECS</a> with FFI components, contiguous columns, and a dirty model the GPU reads.
    icon: ⚡
  - title: Batteries included
    details: <a href="/modules/physics">Physics</a>, <a href="/modules/Audio">audio</a>, <a href="/modules/particles">particles</a>, <a href="/modules/text">text</a>, <a href="/modules/sequence">sequencing</a>, <a href="/modules/sheet">sprite sheets</a> and hot reload ship in the box, sharing one data model.
    icon: 🔋
  - title: Static typing
    details: Catch errors at compile time, not runtime. Tecs is designed from the ground up for static typing with <a href="https://github.com/teal-language/tl"><u>Teal</u></a>.
    icon:
      src: /images/teal.svg
---

## Install

The `tecs` command carries the compiler, the engine, the type definitions and a project template. Nothing else
has to be on the machine: no Lua, no LuaRocks, no Teal, no C compiler.

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

The command is not on this branch yet. [The CLI](/cli/) records the shape it is taking, and
[getting started](/getting-started) is how to build and run through `make` in the meantime.

## Entities are the interface

Anything that renders or updates per frame is an entity in a world. SDL owns the loop: an entry file returns an
application and a C host drives it, so nothing in a game blocks and nothing drives frames itself.

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.builtins.Transform

return tecs.application({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers = world:query({ include = { Transform } })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.phases.Update,
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

## Example code

::: code-group

```teal [Components]
local tecs = require("tecs")
local world = tecs.newWorld()

-- Define typed components with Teal
local record Position is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Position
end

tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {{"x", "float"}, {"y", "float"}},
})

local record Velocity is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Velocity
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {{"x", "float"}, {"y", "float"}},
})

-- Query and update entities
local query = world:query({include = {Position, Velocity}})

world:addSystem({
    phase = tecs.phases.Update,
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
local tecs = require("tecs")
local world = tecs.newWorld()
local ChildOf = tecs.builtins.ChildOf

-- Create a parent entity
local parent: integer = world:spawn(
    tecs.builtins.Name("parent"),
    tecs.builtins.Transform(100, 100)
)

-- ChildOf has cascadeDelete; despawning parent despawns children too.
local child1: integer = world:spawn(
    ChildOf(parent),
    tecs.builtins.RelativeTransform(20, 0)
)

local child2: integer = world:spawn(
    ChildOf(parent),
    tecs.builtins.RelativeTransform(-20, 0)
)

-- Walk children of a specific parent
world:targets(parent, ChildOf, function(childId: integer)
    print("child:", childId)
end)

-- Despawning parent cascades to child1 and child2
world:despawn(parent)
```

```teal [Events]
local tecs = require("tecs")
local world = tecs.newWorld()

-- Define a custom event
local record DamageEvent is tecs.Event
    target: integer
    amount: number
    metamethod __call: function(self, target: integer, amount: number): DamageEvent
end

-- Wire up the event init hook (it mutates a pre-allocated instance)
DamageEvent.init = function(e: DamageEvent, target: integer, amount: number)
    e.target = target
    e.amount = amount
end
tecs.newEvent(DamageEvent)

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

## Features

Everything a game reaches is a field on `require("tecs")`, spelled below the way it is written.

<div class="feature-grid">
<div class="feature-group">

**The engine**

- [`tecs.Application`](/modules/Application) - the object an entry file returns and the host drives
- [`tecs.Renderer`](/modules/Renderer) - deferred and GPU-driven, with compute culling and one indirect draw
- [`tecs.Camera`](/modules/Camera) - the view a frame is drawn from
- [`tecs.layers`](/modules/layers) - z-ordering and per-layer behaviour
- [`tecs.materials`](/modules/materials) - one fragment shader, compiled from the material set
- [`tecs.sheet`](/modules/sheet) - sprite sheets, frame tags, pivots
- [`tecs.animation`](/modules/animation) - sprite playback
- [`tecs.text`](/modules/text) - distance-field glyphs, drawn through an instance producer
- [`tecs.particles`](/modules/particles) - emitters
- [`tecs.components`](/modules/components) - the components the renderer reads
- [`tecs.Window`](/modules/Window) - the window, its size, its display and its mode
- [`tecs.Input`](/modules/Input) - three tiers behind a layer stack
- [`tecs.Gamepad`](/modules/Gamepad) - identity, lifetime, metadata and outputs
- [`tecs.events`](/modules/events) - typed once, routed, never an SDL union downstream
- [`tecs.clock`](/modules/clock) - monotonic time
- [`tecs.clipboard`](/modules/clipboard) - the system clipboard
- [`tecs.proc`](/modules/proc) - shelling out
- [`tecs.paths`](/modules/paths) - where a game may read and write
- [`tecs.filesystem`](/modules/filesystem) - touching the filesystem
- [`tecs.watch`](/modules/watch) - watching files for change
- [`tecs.capabilities`](/modules/capabilities) - what this machine and this build can do
- [`tecs.physics`](/modules/physics) - Box2D 3, solved across a shared thread pool
- [`tecs.Audio`](/modules/Audio) - voices, groups, keyed limits, fades, pitch, loop points, streaming
- [`tecs.sequence`](/modules/sequence) - timelines with the tween runtime inside them
- [`tecs.assets`](/modules/assets) - loading content, cached and off the main thread
- [`tecs.workers`](/modules/workers) - typed background jobs
- [`tecs.Future`](/modules/Future) - a value that settles once
- [`tecs.log`](/modules/log) - SDL's logging, per platform
- [`tecs.mcp`](/modules/mcp) - the debug server agents and humans drive a running game through
- [`tecs.json`](/modules/json) - JSON, with the build's own copy of the C parser found
- [`tecs.hash`](/modules/hash) - hashing
- [`tecs.compress`](/modules/compress) - compression and decompression
- [`tecs.random`](/modules/random) - seeded random numbers

</div>
<div class="feature-group">

**The ECS**

- [`tecs.newWorld`](/ecs/world) - worlds, resources and the state stack
- [`tecs.newComponent`](/ecs/components/table-components) - table components
- [`tecs.newFFIComponent`](/ecs/components/ffi) - components backed by FFI structs
- [`tecs.newTagComponent`](/ecs/components/tag-components) - data-free components in bitset storage
- [`tecs.newScalarComponent`](/ecs/components/scalar-components) - components that are one value
- [`tecs.newRelationship`](/ecs/relationships/) - links, hierarchies, cascade deletion
- [`tecs.newEvent`](/ecs/events) - type-safe pub/sub and entity lifecycle events
- [`tecs.phases`](/ecs/phases) - ordered phase scheduling
- [`tecs.runif`](/ecs/systems) - composable run conditions
- [`tecs.builtins`](/ecs/builtins) - names, transforms, hierarchy, TTL, pause, disable, state events
- [The whole surface](/modules/) - every name, and [its signatures](/modules/surface)

**Concepts**

- [Archetypes](/ecs/archetype) - cache-friendly storage for millions of entities
- [Queries](/ecs/queries/) - reusable filters with archetype iteration, callbacks and grouping
- [Systems](/ecs/systems) - phase scheduling and dependencies
- [Plugins](/ecs/plugins) - modular, shareable game mechanics
- [Bundles](/ecs/components/bundles) - reusable entity templates and batch spawning
- [Dirty tracking](/ecs/components/dirty-tracking) - change-gated systems and GPU synchronisation
- [States](/ecs/states) - stack-based game states with transition events
- [Save games](/ecs/save-games) - snapshots, component codecs, migrations, resource handlers
- [Profiling](/ecs/profiling) - where a frame went
- [The mutation model](/ecs/mutation-model) - the normative rules for reads, writes and dirty bits

</div>
</div>

<style>
.feature-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0 3rem;
  margin-top: 1.5rem;
}

.feature-group strong {
  display: block;
  margin: 1.5rem 0 0.5rem;
  font-size: 1.1rem;
}

.feature-group strong:first-child {
  margin-top: 0;
}

.feature-group ul {
  margin: 0;
  padding-left: 1.25rem;
}

.feature-group li {
  margin: 0.25rem 0;
  line-height: 1.5;
}

@media (max-width: 640px) {
  .feature-grid {
    grid-template-columns: 1fr;
  }
}
</style>
