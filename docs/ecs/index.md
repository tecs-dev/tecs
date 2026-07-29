---
description: "Tour of the ECS half of Tecs: worlds, entities, components, systems, plugins, queries, archetypes, phases and resources"
outline: deep
---

# tecs.ecs

Tecs is a typed, archetype-based entity component system for [LuaJIT](https://luajit.org) and
[Teal](https://teal-language.org), and the game engine built around it. The two are one project, not a
renderer-agnostic core with a framework bolted on: the ECS knows what the GPU reads, and the engine's rendering,
audio, physics and sequencing are components and systems in the same worlds your game code writes to.

Entities are the interface. Anything that renders or updates per frame is an entity in a world, lights
included.

This page is the tour. [Getting started](/getting-started) covers building the engine and the shape of an entry
file, and does not repeat here.

::: warning Tecs is in preview
The API is not yet stable and may change as development progresses.
:::

## Reaching it

`tecs.ecs` is a module on `tecs`, so a game writes `tecs.ecs.newWorld()` with no require line: `tecs` is
ambient, loaded by the host before a game's first line. A headless tool or a spec does not go through the host
and writes `local tecs <const> = require("tecs")` first, and gets the same table.

It is also requirable on its own as `require("tecs.ecs")`, which is what every engine module does. `tecs` is the
aggregator that pulls every engine module in, so a module `tecs` exports cannot also depend on `tecs` without
making a cycle, which Teal rejects even through a type-only require. Both spellings reach one table, so there is
no half of the ECS that only one of them can see.

`tecs.ecs` is also the only module already loaded when `tecs` is. Every other one resolves on first field
access, so nothing here demands a graphics stack from a test, a tool or a server.

The `tecs.utils.*` modules, `profile`, `pool` and `Bitset`, are supported API and are required directly.
`tecs.internal.*` modules are implementation details with no stability guarantee.

## World

A `World` owns the entities, components, systems, plugins, resources, queries and state stack of a game.

```teal
local world = tecs.ecs.newWorld()
```

A game rarely calls this: `tecs.newApplication` builds the world and hands it to the entry plugin. Constructing one
directly is what a test, a tool or a headless server does.

> See the [World reference](/ecs/world).

## Entities

An entity is a unique id standing for an object in the world. Entities carry no data and no behavior of their
own; the components attached to them are what they are.

```teal
local Transform <const> = tecs.Transform

local entity = world:spawn(
    tecs.ecs.Name("cactus"),
    Transform(100, 100)
)
```

An id packs a slot and a generation into one number, 22 bits of slot and 31 of generation, so a handle to a
despawned entity is detectably stale rather than quietly aliasing whatever took its place.

`world:spawn` places one entity. For many at once, `world:batchSpawn(count, componentTypes, callback)` resolves
the archetype once and hands the callback contiguous rows to write into, which is the difference between a
fifth of a second and twenty at a million entities.

## Components

Components describe traits: a position, a color, a tint, a sound. They are the building blocks of game state.
Reading one back is typed, because you pass the component's type rather than a string:

```teal
local name = world:get(entity, tecs.ecs.Name)
print(name)
```

Three sets of components are already registered and ready to use.

**Builtins**, directly on `tecs.ecs`, are the ECS's own: `Name`, `EntityKey`, `TTL`, `ChildOf`,
`RelativeTransform`, `Paused` and `Disabled`.

**`tecs.Transform`** is at the root rather than on either, and it is the only component that is. It carries
`x`, `y`, `z`, `layer`, `rotation`, `scaleX` and `scaleY`, and the hierarchy, physics, the sequencer, animation
and the renderer all move the same one, so filing it under any of them would be wrong for the other four.

**Engine components**, on `tecs.gfx`, are what the renderer consumes. They are FFI components on purpose:
their columns are contiguous C memory, which is what lets the extractor walk rows straight into mapped GPU
staging instead of reading fields one entity at a time.

```teal
local gfx <const> = tecs.gfx

world:spawn(
    tecs.Transform(100, 100),
    gfx.Sprite(gfx.imageId("sprites/cactus.png"), 0.0, 0.0, 1.0, 1.0),
    gfx.Tint(1, 1, 1, 1),
    gfx.Renderable()
)
```

`Renderable` is the opt-in that marks an entity as contributing geometry. Without it a `Transform` is just a
position, which is what most entities in a world actually are. A light is an entity too:

```teal
world:spawn(
    tecs.Transform(640, 360),
    gfx.PointLight(120.0, 500.0, 1.0, 0.42, 0.35, 3.0)
)
```

**Your own**, registered with `tecs.ecs.newComponent`. Declare a Teal record, then wire it up:

```teal
local record Health is tecs.ecs.Component
    current: number
    max: number
    metamethod __call: function(self, current: number, max: number): Health
end

tecs.ecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"current", "max"},
    defaults = {100, 100},
})

world:set(entity, Health(80, 100))
```

`tecs.ecs.newFFIComponent` takes the same shape with `{name, ctype}` field pairs and backs the component with a C
struct, which is what you want for anything the GPU or a hot loop reads. There are also
`tecs.ecs.newTagComponent` for bitset-backed markers, `tecs.ecs.newScalarComponent` for a bare number, string or
boolean, and `tecs.ecs.newRelationship` for links between entities.

> See the [Components reference](/ecs/components/).

## Systems

A system is a function that runs game logic. Behavior is added by registering systems into
[phases](/ecs/phases), which is what decides when they run.

```teal
world:addSystem({
    name = "game.Tick",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        print("time since last frame: " .. dt)
    end,
})
```

Order is declared by the phase, not implied by where a loop happens to call it. `before` and `after` order
systems within one phase by name, and `runIf` gates a system on a predicate: `tecs.ecs.runif.after(5)` fires once
and removes itself, `tecs.ecs.runif.every(10)` fires on an interval, `tecs.ecs.runif.inState("menu")` gates on the
state stack.

> See the [Systems reference](/ecs/systems).

## Plugins

A plugin is a plain `function(world)`. It is how you configure a world: register components, create queries, add
systems, spawn entities, install observers.

```teal
world:addPlugin(function(world: tecs.World)
    -- register components, systems, entities, resources
end)
```

There is one composition mechanism rather than two. The entry plugin `tecs.newApplication` takes is the same shape
with the application passed alongside, and a game with several modules calls `world:addPlugin` from inside it.
The engine installs its own pieces the same way: `tecs.gfx.textPlugin({renderer = app.renderer})` is an ordinary
plugin.

> See the [Plugins reference](/ecs/plugins).

## Queries

A system is useful once it can find entities. Create queries during plugin setup, outside the system, and reuse
them for the world's lifetime; never build one inside `run`.

```teal
local Transform <const> = tecs.Transform
local Health <const> = ... -- registered above

local function healthPlugin(world: tecs.World)
    local dying = world:query({
        include = {Transform, Health},
    })

    world:addSystem({
        name = "game.Decay",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            for archetype, length in dying:iter() do
                local healths = archetype:getMut(Health)
                for row = 1, length do
                    healths[row].current = healths[row].current - dt
                end
            end
        end,
    })
end

world:addPlugin(healthPlugin)
```

A descriptor takes `include`, `includeAny` and `exclude`, plus optional entity-lifecycle callbacks and grouping.
`query:iter()` yields `(archetype, length, entities)` per matching archetype.

::: warning iter runs to exhaustion
`query:iter()` opens a deferred scope and closes it when the loop finishes. A loop that may `break` or return
early must use `query:cursor()` and call `cursor:close()`, or the world is left deferred and every later spawn
silently queues. See [the mutation model](/ecs/mutation-model).
:::

> See the [Query reference](/ecs/queries/).

## Archetypes

Every unique combination of components forms an _archetype_, and an entity belongs to exactly one. An archetype
stores its entity ids and its component columns contiguously, which is why query examples bind a column once per
archetype and index it by row instead of fetching component by component per entity.

```teal
-- Read with :get, write through :getMut.
local transforms = archetype:getMut(Transform)
local tints = archetype:get(gfx.Tint)

for row = 1, length do
    transforms[row].rotation = transforms[row].rotation + dt
end
```

`archetype:getMut` marks that component's column dirty on that archetype, which is what every dirty-gated
consumer downstream keys off, including the GPU sync. Reads take `:get`. Taking `getMut` in a loop that might
not write defeats the whole mechanism. Dirty bits clear at the end of each `world:update`.

> See the [Archetype reference](/ecs/archetype) and [the mutation model](/ecs/mutation-model).

## Phases

`world:update(dt)` runs every phase of the loop and every system registered in them. Under an application the
host drives this, along with `world:startup` and `world:shutdown` at either end. Phases run from `First` through
`PreUpdate`, the fixed-timestep group, `Update`, `PostUpdate`, the render group, and `Last`.

```teal
world:addSystem({
    phase = tecs.ecs.phases.Startup,
    run = function()
        print("the game is starting up")
    end,
})
```

> See the [Phases reference](/ecs/phases) for the full list.

## Resources

_Resources_ share values across a game without globals. Create a typed key first:

```teal
local record Score
    points: integer
end

local SCORE <const>: tecs.ecs.Key<Score> = tecs.ecs.newKey("game.score")
```

The key carries the type, so reads and writes through it are checked:

```teal
world.resources[SCORE] = {points = 0}

local score = world.resources[SCORE]
```

Always name a key. Named keys are discoverable at runtime through `tecs.ecs.findKey` and `tecs.ecs.listKeys` and the
tooling built on them, and a name is a stable identity: calling `tecs.ecs.newKey` again with the same name returns
the same key, so values keyed by it survive a hot reload. An unnamed key works, logs a warning, and stays
invisible to lookups.

::: tip Store keys in modules
Both sides have to refer to the same key, so declare it once on a module record and assign it there.
:::

Resources are runtime state outside the ECS, so a [snapshot](/ecs/save-games) does not capture them. Durable
state belongs in components, or in a snapshot handler.

## Where to go next

- [World](/ecs/world): spawning, mutation, resources and the state stack.
- [Components](/ecs/components/): the registration factories, FFI layout, serialization and bundles.
- [Queries](/ecs/queries/): descriptors, cursors, callbacks and grouping.
- [Systems](/ecs/systems) and [Phases](/ecs/phases): when work runs.
- [Relationships](/ecs/relationships/): links between entities, dense and sparse.
- [Events](/ecs/events) and [States](/ecs/states).
- [Builtins](/ecs/builtins): the components every world starts with.
- [Save games](/ecs/save-games) and [Profiling](/ecs/profiling).
- [The module reference](/modules/): one page per module a game can reach.
