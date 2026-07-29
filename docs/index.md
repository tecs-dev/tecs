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
      text: Modules
      link: /modules/
    - theme: alt
      text: tecs.ecs
      link: /ecs/

features:
  - title: Build with AI
    details: A <a href="/modules/mcp">built-in MCP server</a> lets humans and agents inspect, freeze and edit a running game.
    icon: 🤖
  - title: ECS built for LuaJIT
    details: An <a href="/ecs/archetype">archetype-based ECS</a> with FFI components, contiguous columns, and a dirty model the GPU reads.
    icon: ⚡
  - title: Batteries included
    details: <a href="/modules/physics">Physics</a>, <a href="/modules/audio">audio</a>, <a href="/modules/gfx/particles">particles</a>, <a href="/modules/gfx/">text</a>, <a href="/modules/sequence">sequencing</a>, <a href="/modules/gfx/animation">sprite sheets</a> and hot reload ship in the box, sharing one data model.
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

The command is not on this branch yet. [Tecs CLI](/cli/) records the shape it is taking, and
[getting started](/getting-started) is how to build and run through `make` in the meantime.

## Entities are the interface

Anything that renders or updates per frame is an entity in a world. SDL owns the loop: an entry file returns an
application and a Rust host drives it, so nothing in a game blocks and nothing drives frames itself.

```teal
local Transform <const> = tecs.Transform

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers = world:query({ include = { Transform } })

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

## Example code

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
local query = world:query({include = {Position, Velocity}})

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
local record DamageEvent is tecs.ecs.Event
    target: integer
    amount: number
    metamethod __call: function(self, target: integer, amount: number): DamageEvent
end

-- Wire up the event init hook (it mutates a pre-allocated instance)
DamageEvent.init = function(e: DamageEvent, target: integer, amount: number)
    e.target = target
    e.amount = amount
end
tecs.ecs.newEvent(DamageEvent)

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

## Modules

Everything a game reaches is a field on `tecs`, which is ambient in a game: it is already loaded by the time an
entry file runs, so no require line. Alphabetical, ignoring case, because that is how a name is looked up.
[Modules](/modules/) carries the same list, and [the generated reference](/modules/) carries what is
behind each one.

<div class="module-columns">

- [`tecs.assets`](/modules/assets) - loading content, cached and off the main thread
- [`tecs.audio`](/modules/audio) - voices, groups, keyed limits, fades, pitch, loop points, streaming, devices
- [`tecs.data`](/modules/data) - JSON, DEFLATE and hashes over byte strings
- [`tecs.ecs`](/ecs/) - worlds, components, queries, systems, events and resources
- [`tecs.events`](/modules/events) - typed once, routed, never an SDL union downstream
- [`tecs.filesystem`](/modules/filesystem/) - where a game may read and write, and what to do with a path
- [`tecs.gfx`](/modules/gfx/) - the camera, the components, the renderer, text, and the vocabularies below
- [`tecs.input`](/modules/input) - gameplay input, gamepads and standalone sensors
- [`tecs.log`](/modules/log) - SDL's logging, per platform
- [`tecs.mcp`](/modules/mcp) - the debug server agents and humans drive a running game through
- [`tecs.net`](/modules/net/) - nonblocking TCP streams and UDP datagrams
- [`tecs.physics`](/modules/physics) - Rapier 2D, solved across a shared thread pool
- [`tecs.sequence`](/modules/sequence) - timelines with the tween runtime inside them
- [`tecs.system`](/modules/system) - capabilities, the clipboard, child processes, and what the desktop offers
- [`tecs.time`](/modules/time) - monotonic time
- [`tecs.window`](/modules/window) - the window, its size, its display and its mode
- [`tecs.workers`](/modules/workers) - typed background jobs

Inside one of those, one level and no deeper:

- [`tecs.filesystem.watch`](/modules/filesystem/watch) - watching files for change
- [`tecs.gfx.animation`](/modules/gfx/animation) - sprite sheets, and the playback that reads them
- [`tecs.gfx.layers`](/modules/gfx/layers) - z-ordering and per-layer behavior
- [`tecs.gfx.materials`](/modules/gfx/materials) - one fragment shader, compiled from the material set
- [`tecs.gfx.particles`](/modules/gfx/particles) - emitters
- [`tecs.net.http`](/modules/net/http) - fetching over HTTP without stopping the frame

On `tecs` itself, because no one module owns them:

- [`tecs.Application`](/modules/Application) - the object an entry file returns, and what the host drives
- [`tecs.Future`](/modules/Future) - a value that settles once
- [`tecs.newApplication`](/modules/Application) - builds the application an entry file returns
- [`tecs.Transform`](/ecs/builtins#transform) - where an entity is, and the one component every subsystem moves
- [`tecs.version`](/modules/) - the version of this build, as a string

</div>

## tecs.ecs

Worlds, components, queries, systems, events and resources. One table with two ways in: a game reads it off
`tecs` like any other module, and an engine module writes `require("tecs.ecs")`, because `tecs` is the
aggregator that pulls every engine module in and a module `tecs` exports cannot also depend on `tecs`. These
are the concepts behind the names.

<div class="module-columns">

- [Overview](/ecs/) - the model, in one page
- [Archetypes](/ecs/archetype) - cache-friendly storage for millions of entities
- [Builtins](/ecs/builtins) - names, transforms, hierarchy, TTL, pause, disable, state events
- [Bundles](/ecs/components/bundles) - reusable entity templates and batch spawning
- [Components](/ecs/components/) - table, tag, scalar and FFI data containers
- [Dirty tracking](/ecs/components/dirty-tracking) - change-gated systems and GPU synchronization
- [Events](/ecs/events) - type-safe pub/sub and entity lifecycle events
- [Mutation model](/ecs/mutation-model) - the normative rules for reads, writes and dirty bits
- [Phases](/ecs/phases) - ordered phase scheduling
- [Plugins](/ecs/plugins) - modular, shareable game mechanics
- [Profiling](/ecs/profiling) - where a frame went
- [Queries](/ecs/queries/) - reusable filters with archetype iteration, callbacks and grouping
- [Random](/ecs/random) - seeded generation, in named streams a snapshot carries
- [Relationships](/ecs/relationships/) - links, hierarchies, relative transforms, cascade deletion
- [Save games](/ecs/save-games) - snapshots, component codecs, migrations, resource handlers
- [States](/ecs/states) - stack-based game states with transition events
- [Systems](/ecs/systems) - phase scheduling, dependencies and run conditions
- [World](/ecs/world) - entities, resources and the state stack

</div>

<style>
.module-columns {
  margin-top: 1.5rem;
}

.module-columns ul {
  columns: 2;
  column-gap: 3rem;
  margin: 0;
  padding-left: 1.25rem;
}

.module-columns li {
  break-inside: avoid;
  margin: 0.25rem 0;
  line-height: 1.5;
}

@media (max-width: 640px) {
  .module-columns ul {
    columns: 1;
  }
}
</style>
