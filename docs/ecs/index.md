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

## Where it lives

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

A game rarely calls this: `tecs.application.create` builds the world and hands it to the entry plugin. Constructing one
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
local record Health is tecs.Component
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

There is one composition mechanism rather than two. The entry plugin `tecs.application.create` takes is the same shape
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

local SCORE <const>: tecs.Key<Score> = tecs.ecs.newKey("game.score")
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

<!-- @generated by docs/scripts/reference.py from src/tecs/ecs.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/ecs.tl`.

<a id="tecs.ecs.Archetype"></a>

### tecs.ecs.Archetype

<pre><code v-pre>type <a href="#tecs.ecs.Archetype">tecs.ecs.Archetype</a> = types.Archetype
</code></pre>

<a id="tecs.ecs.ArchetypeCreated"></a>

### tecs.ecs.ArchetypeCreated

<pre><code v-pre><a href="#tecs.ecs.ArchetypeCreated">tecs.ecs.ArchetypeCreated</a>: builtins.ArchetypeCreated
</code></pre>

Emitted at entity 0 when a new archetype is created.
<a id="tecs.ecs.ArchetypeEntityObserver"></a>

### tecs.ecs.ArchetypeEntityObserver

<pre><code v-pre>type <a href="#tecs.ecs.ArchetypeEntityObserver">tecs.ecs.ArchetypeEntityObserver</a> = types.ArchetypeEntityObserver
</code></pre>

<a id="tecs.ecs.Bundle"></a>

### tecs.ecs.Bundle

<pre><code v-pre>type <a href="#tecs.ecs.Bundle">tecs.ecs.Bundle</a> = types.Bundle
</code></pre>

<a id="tecs.ecs.BundleDef"></a>

### tecs.ecs.BundleDef

<pre><code v-pre>type <a href="#tecs.ecs.BundleDef">tecs.ecs.BundleDef</a> = types.Bundle.Definition
</code></pre>

<a id="tecs.ecs.ChildOf"></a>

### tecs.ecs.ChildOf

<pre><code v-pre><a href="#tecs.ecs.ChildOf">tecs.ecs.ChildOf</a>: <a href="#tecs.ecs.Relationship">Relationship</a>
</code></pre>

Parent and child. Sparse, so adding one does not split archetypes, and
cascade-deleting, so despawning a parent takes its children.
<a id="tecs.ecs.Component"></a>

### tecs.ecs.Component

<pre><code v-pre>type <a href="#tecs.ecs.Component">tecs.ecs.Component</a> = types.components.Component
</code></pre>

<a id="tecs.ecs.ComponentOptions"></a>

### tecs.ecs.ComponentOptions

<pre><code v-pre>type <a href="#tecs.ecs.ComponentOptions">tecs.ecs.ComponentOptions</a> = generic&lt;C is <a href="#tecs.ecs.Component">Component</a>&gt; types.components.ComponentOptions&lt;C&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint                                                     | Description |
| -------------------- | -------------------------------------------------------------- | ----------- |
| <code v-pre>C</code> | <code v-pre><a href="#tecs.ecs.Component">Component</a></code> |             |

<a id="tecs.ecs.Context"></a>

### tecs.ecs.Context

<pre><code v-pre>type <a href="#tecs.ecs.Context">tecs.ecs.Context</a> = types.Context
</code></pre>

<a id="tecs.ecs.DEFAULT_MAX_ENTITIES"></a>

### tecs.ecs.DEFAULT_MAX_ENTITIES

<pre><code v-pre><a href="#tecs.ecs.DEFAULT_MAX_ENTITIES">tecs.ecs.DEFAULT_MAX_ENTITIES</a>: integer
</code></pre>

Default `World.Config.maxEntities` when none is given (2^20).
<a id="tecs.ecs.Disabled"></a>

### tecs.ecs.Disabled

<pre><code v-pre><a href="#tecs.ecs.Disabled">tecs.ecs.Disabled</a>: <a href="#tecs.ecs.Component">Component</a>
</code></pre>

Excluded from every query that does not ask for it.
<a id="tecs.ecs.DoubleArray"></a>

### tecs.ecs.DoubleArray

<pre><code v-pre>type <a href="#tecs.ecs.DoubleArray">tecs.ecs.DoubleArray</a> = types.DoubleArray
</code></pre>

<a id="tecs.ecs.EntityKey"></a>

### tecs.ecs.EntityKey

<pre><code v-pre><a href="#tecs.ecs.EntityKey">tecs.ecs.EntityKey</a>: <a href="#tecs.ecs.ScalarComponent">ScalarComponent</a>&lt;string&gt;
</code></pre>

A durable, unique lookup key, read back with `world:byKey`. For hot
reload, authored references, tooling and save-compatible lookup, where
an entity id is meaningless across runs.

Spelled `EntityKey` here and registered as `"Key"`, because `Key` on
this module is the typed `world.resources` key `newKey` hands out, and
Teal refuses the second declaration outright. The registered name is a
save format and does not move; this one is the surface.
<a id="tecs.ecs.Event"></a>

### tecs.ecs.Event

<pre><code v-pre>type <a href="#tecs.ecs.Event">tecs.ecs.Event</a> = types.events.Event
</code></pre>

<a id="tecs.ecs.EventInit"></a>

### tecs.ecs.EventInit

<pre><code v-pre>type <a href="#tecs.ecs.EventInit">tecs.ecs.EventInit</a> = types.events.EventInit
</code></pre>

<a id="tecs.ecs.EventListener"></a>

### tecs.ecs.EventListener

<pre><code v-pre>type <a href="#tecs.ecs.EventListener">tecs.ecs.EventListener</a> = types.events.EventListener
</code></pre>

<a id="tecs.ecs.FFIComponentOptions"></a>

### tecs.ecs.FFIComponentOptions

<pre><code v-pre>type <a href="#tecs.ecs.FFIComponentOptions">tecs.ecs.FFIComponentOptions</a> = generic&lt;C is <a href="#tecs.ecs.Component">Component</a>&gt; types.components.FFIComponentOptions&lt;C&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint                                                     | Description |
| -------------------- | -------------------------------------------------------------- | ----------- |
| <code v-pre>C</code> | <code v-pre><a href="#tecs.ecs.Component">Component</a></code> |             |

<a id="tecs.ecs.FFIRelationshipOptions"></a>

### tecs.ecs.FFIRelationshipOptions

<pre><code v-pre>type <a href="#tecs.ecs.FFIRelationshipOptions">tecs.ecs.FFIRelationshipOptions</a> = generic&lt;R is <a href="#tecs.ecs.Relationship">Relationship</a>&gt; types.components.FFIRelationshipOptions&lt;R&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint                                                           | Description |
| -------------------- | -------------------------------------------------------------------- | ----------- |
| <code v-pre>R</code> | <code v-pre><a href="#tecs.ecs.Relationship">Relationship</a></code> |             |

<a id="tecs.ecs.FinishSnapshotLoad"></a>

### tecs.ecs.FinishSnapshotLoad

<pre><code v-pre><a href="#tecs.ecs.FinishSnapshotLoad">tecs.ecs.FinishSnapshotLoad</a>: builtins.FinishSnapshotLoad
</code></pre>

Emitted at entity 0 once every entity is restored and every data
callback has run.
<a id="tecs.ecs.FixedOverload"></a>

### tecs.ecs.FixedOverload

<pre><code v-pre>type <a href="#tecs.ecs.FixedOverload">tecs.ecs.FixedOverload</a> = types.FixedOverload
</code></pre>

<a id="tecs.ecs.Key"></a>

### tecs.ecs.Key

<pre><code v-pre>type <a href="#tecs.ecs.Key">tecs.ecs.Key</a> = generic&lt;T&gt; types.Context.Key&lt;T&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

<a id="tecs.ecs.MAX_ENTITIES"></a>

### tecs.ecs.MAX_ENTITIES

<pre><code v-pre><a href="#tecs.ecs.MAX_ENTITIES">tecs.ecs.MAX_ENTITIES</a>: integer
</code></pre>

Absolute ceiling for `World.Config.maxEntities` (2^22 - 1 usable
slots; slot 0 is reserved by the entity-id format).
<a id="tecs.ecs.MessageBus"></a>

### tecs.ecs.MessageBus

<pre><code v-pre>type <a href="#tecs.ecs.MessageBus">tecs.ecs.MessageBus</a> = types.events.MessageBus
</code></pre>

<a id="tecs.ecs.Name"></a>

### tecs.ecs.Name

<pre><code v-pre><a href="#tecs.ecs.Name">tecs.ecs.Name</a>: <a href="#tecs.ecs.ScalarComponent">ScalarComponent</a>&lt;string&gt;
</code></pre>

A label for an entity, stored as the raw string. Not unique: use
`EntityKey` where something has to find one entity again.
<a id="tecs.ecs.OnDespawn"></a>

### tecs.ecs.OnDespawn

<pre><code v-pre><a href="#tecs.ecs.OnDespawn">tecs.ecs.OnDespawn</a>: builtins.OnDespawn
</code></pre>

Emitted at the entity when it is despawned.
<a id="tecs.ecs.OnSnapshotSave"></a>

### tecs.ecs.OnSnapshotSave

<pre><code v-pre><a href="#tecs.ecs.OnSnapshotSave">tecs.ecs.OnSnapshotSave</a>: builtins.OnSnapshotSave
</code></pre>

Emitted at entity 0 before a snapshot's archetypes are written, which
is where a plugin attaches keyed data or excludes what it re-derives.
<a id="tecs.ecs.OnSpawn"></a>

### tecs.ecs.OnSpawn

<pre><code v-pre><a href="#tecs.ecs.OnSpawn">tecs.ecs.OnSpawn</a>: builtins.OnSpawn
</code></pre>

Emitted at the entity when it is spawned.
<a id="tecs.ecs.Paused"></a>

### tecs.ecs.Paused

<pre><code v-pre><a href="#tecs.ecs.Paused">tecs.ecs.Paused</a>: <a href="#tecs.ecs.Component">Component</a>
</code></pre>

Excluded from logic queries and still drawn, which is the difference
from `Disabled`: a paused world is one that renders and does not think.
<a id="tecs.ecs.Phase"></a>

### tecs.ecs.Phase

<pre><code v-pre>type <a href="#tecs.ecs.Phase">tecs.ecs.Phase</a> = types.Phase
</code></pre>

<a id="tecs.ecs.Pipeline"></a>

### tecs.ecs.Pipeline

<pre><code v-pre>type <a href="#tecs.ecs.Pipeline">tecs.ecs.Pipeline</a> = types.Pipeline
</code></pre>

<a id="tecs.ecs.Plugin"></a>

### tecs.ecs.Plugin

<pre><code v-pre>type <a href="#tecs.ecs.Plugin">tecs.ecs.Plugin</a> = types.Plugin
</code></pre>

<a id="tecs.ecs.Query"></a>

### tecs.ecs.Query

<pre><code v-pre>type <a href="#tecs.ecs.Query">tecs.ecs.Query</a> = types.Query
</code></pre>

<a id="tecs.ecs.QueryCursor"></a>

### tecs.ecs.QueryCursor

<pre><code v-pre>type <a href="#tecs.ecs.QueryCursor">tecs.ecs.QueryCursor</a> = types.Query.Cursor
</code></pre>

<a id="tecs.ecs.QueryDescriptor"></a>

### tecs.ecs.QueryDescriptor

<pre><code v-pre>type <a href="#tecs.ecs.QueryDescriptor">tecs.ecs.QueryDescriptor</a> = types.Query.Descriptor
</code></pre>

<a id="tecs.ecs.Relationship"></a>

### tecs.ecs.Relationship

<pre><code v-pre>type <a href="#tecs.ecs.Relationship">tecs.ecs.Relationship</a> = types.components.Relationship
</code></pre>

<a id="tecs.ecs.RelationshipOptions"></a>

### tecs.ecs.RelationshipOptions

<pre><code v-pre>type <a href="#tecs.ecs.RelationshipOptions">tecs.ecs.RelationshipOptions</a> = generic&lt;R is <a href="#tecs.ecs.Relationship">Relationship</a>&gt; types.components.RelationshipOptions&lt;R&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint                                                           | Description |
| -------------------- | -------------------------------------------------------------------- | ----------- |
| <code v-pre>R</code> | <code v-pre><a href="#tecs.ecs.Relationship">Relationship</a></code> |             |

<a id="tecs.ecs.RelativeTransform"></a>

### tecs.ecs.RelativeTransform

<pre><code v-pre><a href="#tecs.ecs.RelativeTransform">tecs.ecs.RelativeTransform</a>: builtins.RelativeTransform
</code></pre>

A transform expressed relative to a `ChildOf` parent. The builtin
hierarchy system composes it with the parent's `Transform` into the
child's world-space one, so a game writes this and reads `Transform`.
<a id="tecs.ecs.ScalarComponent"></a>

### tecs.ecs.ScalarComponent

<pre><code v-pre>type <a href="#tecs.ecs.ScalarComponent">tecs.ecs.ScalarComponent</a> = generic&lt;T&gt; types.components.ScalarComponent&lt;T&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

<a id="tecs.ecs.ScalarComponentOptions"></a>

### tecs.ecs.ScalarComponentOptions

<pre><code v-pre>type <a href="#tecs.ecs.ScalarComponentOptions">tecs.ecs.ScalarComponentOptions</a> = generic&lt;T&gt; types.components.ScalarComponentOptions&lt;T&gt;
</code></pre>

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

<a id="tecs.ecs.Snapshot"></a>

### tecs.ecs.Snapshot

<pre><code v-pre>type <a href="#tecs.ecs.Snapshot">tecs.ecs.Snapshot</a> = types.World.Snapshot
</code></pre>

<a id="tecs.ecs.SnapshotComponentTableEntry"></a>

### tecs.ecs.SnapshotComponentTableEntry

<pre><code v-pre>type <a href="#tecs.ecs.SnapshotComponentTableEntry">tecs.ecs.SnapshotComponentTableEntry</a> = types.World.SnapshotComponentTableEntry
</code></pre>

<a id="tecs.ecs.SnapshotHandler"></a>

### tecs.ecs.SnapshotHandler

<pre><code v-pre>type <a href="#tecs.ecs.SnapshotHandler">tecs.ecs.SnapshotHandler</a> = types.World.SnapshotHandler
</code></pre>

<a id="tecs.ecs.SnapshotOptions"></a>

### tecs.ecs.SnapshotOptions

<pre><code v-pre>type <a href="#tecs.ecs.SnapshotOptions">tecs.ecs.SnapshotOptions</a> = types.World.SnapshotOptions
</code></pre>

<a id="tecs.ecs.SnapshotOutput"></a>

### tecs.ecs.SnapshotOutput

<pre><code v-pre>type <a href="#tecs.ecs.SnapshotOutput">tecs.ecs.SnapshotOutput</a> = types.World.SnapshotOutput
</code></pre>

<a id="tecs.ecs.SnapshotPrelude"></a>

### tecs.ecs.SnapshotPrelude

<pre><code v-pre>type <a href="#tecs.ecs.SnapshotPrelude">tecs.ecs.SnapshotPrelude</a> = types.World.SnapshotPrelude
</code></pre>

<a id="tecs.ecs.StartSnapshotLoad"></a>

### tecs.ecs.StartSnapshotLoad

<pre><code v-pre><a href="#tecs.ecs.StartSnapshotLoad">tecs.ecs.StartSnapshotLoad</a>: builtins.StartSnapshotLoad
</code></pre>

Emitted at entity 0 after a snapshot's world is restored and before its
data section is dispatched, which is where a plugin registers what to
do with each key it wrote.
<a id="tecs.ecs.StateBlur"></a>

### tecs.ecs.StateBlur

<pre><code v-pre><a href="#tecs.ecs.StateBlur">tecs.ecs.StateBlur</a>: builtins.StateBlur
</code></pre>

Emitted at the state losing focus when another is pushed above it.
<a id="tecs.ecs.StateEnter"></a>

### tecs.ecs.StateEnter

<pre><code v-pre><a href="#tecs.ecs.StateEnter">tecs.ecs.StateEnter</a>: builtins.StateEnter
</code></pre>

Emitted when a state is pushed onto the stack.
<a id="tecs.ecs.StateExit"></a>

### tecs.ecs.StateExit

<pre><code v-pre><a href="#tecs.ecs.StateExit">tecs.ecs.StateExit</a>: builtins.StateExit
</code></pre>

Emitted when a state is popped off it.
<a id="tecs.ecs.StateFocus"></a>

### tecs.ecs.StateFocus

<pre><code v-pre><a href="#tecs.ecs.StateFocus">tecs.ecs.StateFocus</a>: builtins.StateFocus
</code></pre>

Emitted at the state regaining focus when the one above it is popped.
<a id="tecs.ecs.StatePolicy"></a>

### tecs.ecs.StatePolicy

<pre><code v-pre>type <a href="#tecs.ecs.StatePolicy">tecs.ecs.StatePolicy</a> = types.StatePolicy
</code></pre>

<a id="tecs.ecs.Stats"></a>

### tecs.ecs.Stats

<pre><code v-pre>type <a href="#tecs.ecs.Stats">tecs.ecs.Stats</a> = types.World.Stats
</code></pre>

<a id="tecs.ecs.System"></a>

### tecs.ecs.System

<pre><code v-pre>type <a href="#tecs.ecs.System">tecs.ecs.System</a> = types.System
</code></pre>

<a id="tecs.ecs.SystemConfig"></a>

### tecs.ecs.SystemConfig

<pre><code v-pre>type <a href="#tecs.ecs.SystemConfig">tecs.ecs.SystemConfig</a> = types.SystemConfig
</code></pre>

<a id="tecs.ecs.TTL"></a>

### tecs.ecs.TTL

<pre><code v-pre><a href="#tecs.ecs.TTL">tecs.ecs.TTL</a>: builtins.TTL
</code></pre>

Despawns an entity once its time to live reaches zero, counted down in
`FixedUpdate` by a query declared `type = "logic"`, so a `Paused`
entity does not burn through it.
<a id="tecs.ecs.TagComponentOptions"></a>

### tecs.ecs.TagComponentOptions

<pre><code v-pre>type <a href="#tecs.ecs.TagComponentOptions">tecs.ecs.TagComponentOptions</a> = types.components.TagComponentOptions
</code></pre>

<a id="tecs.ecs.Transform"></a>

### tecs.ecs.Transform

<pre><code v-pre><a href="#tecs.ecs.Transform">tecs.ecs.Transform</a>: builtins.Transform
</code></pre>

Positions everything a world holds: the hierarchy, physics, the
sequencer and the renderer all move the same one. Not a drawing
component, which is why it is here and not on `tecs.gfx`, and why a
headless world has it.
<a id="tecs.ecs.World"></a>

### tecs.ecs.World

<pre><code v-pre>type <a href="#tecs.ecs.World">tecs.ecs.World</a> = types.World
</code></pre>

<a id="tecs.ecs.componentByName"></a>

### tecs.ecs.componentByName

<pre><code v-pre>function <a href="#tecs.ecs.componentByName">tecs.ecs.componentByName</a>(name: string): <a href="#tecs.ecs.Component">Component</a>
</code></pre>

The component registered under `name`, or nil.

The registry is process-wide, because a component's id is allocated
once at registration and every world that carries one agrees on it. So
this answers what can be named, and a world answers what is present.

Finds a dense relationship instance by its stamped name as well, which
`declaredComponents` leaves out.

#### Parameters

| Type                      | Name                    | Description                                                                                  |
| ------------------------- | ----------------------- | -------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | The `name` the component was registered under, which is the record's own name by convention. |

#### Returns

| Type                                                           | Description                                                                                                                                                                           |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.Component">Component</a></code> | The component, or nil when nothing has registered that name yet. Nil is a question of whether the declaring module has been required, not of whether any world carries the component. |

<a id="tecs.ecs.declaredComponents"></a>

### tecs.ecs.declaredComponents

<pre><code v-pre>function <a href="#tecs.ecs.declaredComponents">tecs.ecs.declaredComponents</a>(): {string : <a href="#tecs.ecs.Component">Component</a>}
</code></pre>

Every component declared in this process, name to component.

A fresh table per call, so the registry itself stays unwritable from
outside registration.

Dense relationship instances are left out. One is registered per target
under a stamped `Rel->42` name, so a world with many edges has many of
them, and none of them is a component anybody declared.

#### Returns

| Type                                                                      | Description                                                                                                                                                                                                |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string : <a href="#tecs.ecs.Component">Component</a>}</code> | A fresh table each call, built by walking the whole registry, so this is for tooling rather than for a per-frame path. What is declared in the process, which is a superset of what any one world carries. |

<a id="tecs.ecs.findKey"></a>

### tecs.ecs.findKey

<pre><code v-pre>function <a href="#tecs.ecs.findKey">tecs.ecs.findKey</a>&lt;T&gt;(name: string): <a href="#tecs.ecs.Key">Key</a>&lt;T&gt; | nil
</code></pre>

Find a named key created by `newKey`. Returns nil when unknown.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

#### Parameters

| Type                      | Name                    | Description                                                                                                          |
| ------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | The name the key was created with. Unnamed keys are unreachable here, which is the reason `newKey` warns about them. |

#### Returns

| Type                                                               | Description                                                                                                                                                                                                                                         |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.Key">Key</a>&lt;T&gt; \| nil</code> | The existing key, so a value stored under it is readable without the module that created it. Nil when no key of that name has been created yet, which is a question of load order rather than of spelling: the key appears once its module has run. |

<a id="tecs.ecs.getComponentById"></a>

### tecs.ecs.getComponentById

<pre><code v-pre>function <a href="#tecs.ecs.getComponentById">tecs.ecs.getComponentById</a>(id: integer): <a href="#tecs.ecs.Component">Component</a>
</code></pre>

Look up a registered component by numeric ID.

#### Parameters

| Type                       | Name                  | Description                                                                                            |
| -------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------ |
| <code v-pre>integer</code> | <code v-pre>id</code> | A component id, which is allocated once at registration and is the same in every world in the process. |

#### Returns

| Type                                                           | Description                                                                                                                                                                               |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.Component">Component</a></code> | The component, or nil for an id that was never allocated. Ids are not stable across runs: registration order decides them, so a saved id is only meaningful within the run that wrote it. |

<a id="tecs.ecs.listKeys"></a>

### tecs.ecs.listKeys

<pre><code v-pre>function <a href="#tecs.ecs.listKeys">tecs.ecs.listKeys</a>(): {string : integer}
</code></pre>

All named keys, as a fresh name -> numeric key id table.

#### Returns

| Type                                  | Description                                                                                                                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string : integer}</code> | A fresh table each call, so the caller may keep it and the registry stays unwritable from outside `newKey`. Names span the process rather than one world, so a key here is not evidence that any world has a value under it. |

<a id="tecs.ecs.newComponent"></a>

### tecs.ecs.newComponent

<pre><code v-pre>function <a href="#tecs.ecs.newComponent">tecs.ecs.newComponent</a>&lt;C is <a href="#tecs.ecs.Component">Component</a>&gt;(options: <a href="#tecs.ecs.ComponentOptions">ComponentOptions</a>&lt;C&gt;): C
</code></pre>

Creates and registers a new table component. See `ecs.ComponentOptions`
and the component docs for the shared `fields` / `defaults` / `init` /
`.new` model.

#### Type Parameters

| Name                 | Constraint                                                     | Description |
| -------------------- | -------------------------------------------------------------- | ----------- |
| <code v-pre>C</code> | <code v-pre><a href="#tecs.ecs.Component">Component</a></code> |             |

#### Parameters

| Type                                                                                  | Name                       | Description                                                                                                                                      |
| ------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.ecs.ComponentOptions">ComponentOptions</a>&lt;C&gt;</code> | <code v-pre>options</code> | Its `name` is the registry key, so it has to be unique in the process and is what queries, snapshots and the MCP tools address the component by. |

#### Returns

| Type                 | Description                                                                                                                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>C</code> | The same `container` record passed in, now registered and callable as a constructor. Registration is process-wide and permanent, so this belongs at module scope rather than in a plugin that may be added to two worlds. |

<a id="tecs.ecs.newContext"></a>

### tecs.ecs.newContext

<pre><code v-pre>function <a href="#tecs.ecs.newContext">tecs.ecs.newContext</a>(): <a href="#tecs.ecs.Context">Context</a>
</code></pre>

Create a new Context instance.

#### Returns

| Type                                                       | Description                                                                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.Context">Context</a></code> | An empty context, which is the keyed store `world.resources` is one of. For something wanting that store without a world. |

<a id="tecs.ecs.newEvent"></a>

### tecs.ecs.newEvent

<pre><code v-pre>function <a href="#tecs.ecs.newEvent">tecs.ecs.newEvent</a>&lt;E is <a href="#tecs.ecs.Event">Event</a>&gt;(event: E)
</code></pre>

Configure an event to have an appropriate __call based constructor.

#### Type Parameters

| Name                 | Constraint                                             | Description |
| -------------------- | ------------------------------------------------------ | ----------- |
| <code v-pre>E</code> | <code v-pre><a href="#tecs.ecs.Event">Event</a></code> |             |

#### Parameters

| Type                 | Name                     | Description                                                                                                                                                                                                                             |
| -------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>E</code> | <code v-pre>event</code> | Mutated in place rather than copied, so the record the caller declared is the one that becomes callable. Its `init`, where it has one, is what the constructor's arguments are handed to, so `init` is what decides the call signature. |

<a id="tecs.ecs.newFFIComponent"></a>

### tecs.ecs.newFFIComponent

<pre><code v-pre>function <a href="#tecs.ecs.newFFIComponent">tecs.ecs.newFFIComponent</a>&lt;C is <a href="#tecs.ecs.Component">Component</a>&gt;(options: <a href="#tecs.ecs.FFIComponentOptions">FFIComponentOptions</a>&lt;C&gt;): C
</code></pre>

Creates and registers an FFI-based component. Same constructor model
as `newComponent`, but the base instance is an FFI struct.

#### Type Parameters

| Name                 | Constraint                                                     | Description |
| -------------------- | -------------------------------------------------------------- | ----------- |
| <code v-pre>C</code> | <code v-pre><a href="#tecs.ecs.Component">Component</a></code> |             |

#### Parameters

| Type                                                                                        | Name                       | Description                                                                                                                                                         |
| ------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.FFIComponentOptions">FFIComponentOptions</a>&lt;C&gt;</code> | <code v-pre>options</code> | Its `fields` have to map to a C struct, so numbers, booleans and fixed-size arrays only. One field needing a Lua table makes the whole component a table component. |

#### Returns

| Type                 | Description                                                                                                                                                                                                           |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>C</code> | The registered component. Its columns are contiguous cdata, so writing a row through `world:get` bypasses dirty tracking and needs an explicit `world:markComponentDirty`, and `world:batchSpawn` skips its defaults. |

<a id="tecs.ecs.newFFIEvent"></a>

### tecs.ecs.newFFIEvent

<pre><code v-pre>function <a href="#tecs.ecs.newFFIEvent">tecs.ecs.newFFIEvent</a>&lt;E is <a href="#tecs.ecs.Event">Event</a>&gt;(event: E, fields: <span v-pre>{{</span>string, string}}, structName: string)
</code></pre>

Configure an FFI event to have an appropriate __call based constructor.

#### Type Parameters

| Name                 | Constraint                                             | Description |
| -------------------- | ------------------------------------------------------ | ----------- |
| <code v-pre>E</code> | <code v-pre><a href="#tecs.ecs.Event">Event</a></code> |             |

#### Parameters

| Type                                                     | Name                          | Description                                                                                                                                                          |
| -------------------------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>E</code>                                     | <code v-pre>event</code>      | Mutated in place, as `newEvent` does it.                                                                                                                             |
| <code v-pre><span v-pre>{{</span>string, string}}</code> | <code v-pre>fields</code>     | Name and C type per field, in declaration order, which is also the order the constructor takes them in. The same C-struct restriction `newFFIComponent` has applies. |
| <code v-pre>string</code>                                | <code v-pre>structName</code> | Optional. One is generated when it is left out, and it only needs naming when something else has to name the same struct.                                            |

<a id="tecs.ecs.newFFIRelationship"></a>

### tecs.ecs.newFFIRelationship

<pre><code v-pre>function <a href="#tecs.ecs.newFFIRelationship">tecs.ecs.newFFIRelationship</a>&lt;R is <a href="#tecs.ecs.Relationship">Relationship</a>&gt;(config: <a href="#tecs.ecs.FFIRelationshipOptions">FFIRelationshipOptions</a>&lt;R&gt;): R
</code></pre>

Create an FFI-backed relationship with data fields.

#### Type Parameters

| Name                 | Constraint                                                           | Description |
| -------------------- | -------------------------------------------------------------------- | ----------- |
| <code v-pre>R</code> | <code v-pre><a href="#tecs.ecs.Relationship">Relationship</a></code> |             |

#### Parameters

| Type                                                                                              | Name                      | Description                                                                                                                 |
| ------------------------------------------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.FFIRelationshipOptions">FFIRelationshipOptions</a>&lt;R&gt;</code> | <code v-pre>config</code> | As `newRelationship`, plus the `fields` the edge itself carries, under the same C-struct restriction `newFFIComponent` has. |

#### Returns

| Type                 | Description                  |
| -------------------- | ---------------------------- |
| <code v-pre>R</code> | The registered relationship. |

<a id="tecs.ecs.newKey"></a>

### tecs.ecs.newKey

<pre><code v-pre>function <a href="#tecs.ecs.newKey">tecs.ecs.newKey</a>&lt;T&gt;(name: string, forType: T): <a href="#tecs.ecs.Key">Key</a>&lt;T&gt;
</code></pre>

A typed key for `world.resources`, and the way an engine module stores
something scoped to one world.

Always pass a name: named keys are discoverable at runtime through
`findKey`/`listKeys` and the tooling built on them (the MCP `inspect`
tool, `tecs info --keys`), and a named key is a stable identity --
calling `newKey` again with the same name returns the same key, so
values keyed by it survive hot reload. An unnamed key works but logs a
warning and stays invisible to name-based lookups.

`forType` carries the phantom type, because Teal has no explicit type
argument at a call site: pass `nil as T` for `world.resources[key]` to
read as a `T` rather than as `any`.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

#### Parameters

| Type                      | Name                       | Description                                                                                                                                                  |
| ------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code> | <code v-pre>name</code>    | Namespaced, like "game.state". Omitting it is what triggers the warning above, and the key it returns is still usable, just anonymous and new on every call. |
| <code v-pre>T</code>      | <code v-pre>forType</code> | Never read. It exists so the call site can say what `T` is, since Teal has no explicit type argument; pass `nil as T`.                                       |

#### Returns

| Type                                                        | Description                                                                                                                                                                                        |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.Key">Key</a>&lt;T&gt;</code> | The key for that name, which is the same one every later call with the same name gets rather than a fresh one. That is what makes values keyed by it survive a module re-running under hot reload. |

<a id="tecs.ecs.newMessageBus"></a>

### tecs.ecs.newMessageBus

<pre><code v-pre>function <a href="#tecs.ecs.newMessageBus">tecs.ecs.newMessageBus</a>(): <a href="#tecs.ecs.MessageBus">MessageBus</a>
</code></pre>

Create a new address-based event message bus.

#### Returns

| Type                                                             | Description                                                                                                                                                                                   |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.MessageBus">MessageBus</a></code> | A bus of its own, unconnected to any world's. A world already carries one, which `world:emit` and `world:observe` reach, so this is for messaging that should outlive or sit outside a world. |

<a id="tecs.ecs.newRelationship"></a>

### tecs.ecs.newRelationship

<pre><code v-pre>function <a href="#tecs.ecs.newRelationship">tecs.ecs.newRelationship</a>&lt;R is <a href="#tecs.ecs.Relationship">Relationship</a>&gt;(config: <a href="#tecs.ecs.RelationshipOptions">RelationshipOptions</a>&lt;R&gt;): R
</code></pre>

Creates and registers a new relationship component. See the relationship
docs for target/exclusive/sparse semantics. A target-only relationship
(name plus flags, no `container`/`fields`) is backed by a compact FFI
struct automatically; add `container`/`fields` for relationships that
carry data.

#### Type Parameters

| Name                 | Constraint                                                           | Description |
| -------------------- | -------------------------------------------------------------------- | ----------- |
| <code v-pre>R</code> | <code v-pre><a href="#tecs.ecs.Relationship">Relationship</a></code> |             |

#### Parameters

| Type                                                                                        | Name                      | Description                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.RelationshipOptions">RelationshipOptions</a>&lt;R&gt;</code> | <code v-pre>config</code> | `exclusive` keeps one target per entity, replacing rather than adding. `sparse` keeps edges out of the archetype key, so adding one does not split archetypes. `cascadeDelete` despawns the sources when the target goes, and raises here unless `exclusive` and `reverseIndex` are both set, since finding the sources is what the reverse index is for. |

#### Returns

| Type                 | Description                                                                                                                                                                                              |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>R</code> | The registered relationship, called with a target to make an instance. A dense relationship registers one component per target under a stamped name, which is why `declaredComponents` leaves those out. |

<a id="tecs.ecs.newScalarComponent"></a>

### tecs.ecs.newScalarComponent

<pre><code v-pre>function <a href="#tecs.ecs.newScalarComponent">tecs.ecs.newScalarComponent</a>&lt;T&gt;(options: <a href="#tecs.ecs.ScalarComponentOptions">ScalarComponentOptions</a>&lt;T&gt;): <a href="#tecs.ecs.ScalarComponent">ScalarComponent</a>&lt;T&gt;
</code></pre>

Creates and registers a new scalar component.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

#### Parameters

| Type                                                                                              | Name                       | Description                                                                                                      |
| ------------------------------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.ScalarComponentOptions">ScalarComponentOptions</a>&lt;T&gt;</code> | <code v-pre>options</code> | Describes a component that is one value rather than a record of fields, so its column holds that value directly. |

#### Returns

| Type                                                                                | Description                                                                                           |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.ScalarComponent">ScalarComponent</a>&lt;T&gt;</code> | The registered component, whose rows are read and written as bare values rather than through a field. |

<a id="tecs.ecs.newTagComponent"></a>

### tecs.ecs.newTagComponent

<pre><code v-pre>function <a href="#tecs.ecs.newTagComponent">tecs.ecs.newTagComponent</a>(options: <a href="#tecs.ecs.TagComponentOptions">TagComponentOptions</a>): <a href="#tecs.ecs.Component">Component</a>
</code></pre>

Creates and registers a new tag component that uses bitset storage for efficiency.

#### Parameters

| Type                                                                               | Name                       | Description                                                                     |
| ---------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.TagComponentOptions">TagComponentOptions</a></code> | <code v-pre>options</code> | Name only: a tag carries no fields, which is what lets it be stored as one bit. |

#### Returns

| Type                                                           | Description                                                                                                                                                                                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.ecs.Component">Component</a></code> | The registered tag. Queries match it by archetype rather than by scanning, so a stable flag is cheaper as a tag than as a boolean field, while one toggled often is not: every flip moves the entity between archetypes. |

<a id="tecs.ecs.newWorld"></a>

### tecs.ecs.newWorld

<pre><code v-pre>function <a href="#tecs.ecs.newWorld">tecs.ecs.newWorld</a>(config: types.World.Config): <a href="#tecs.ecs.World">World</a>
</code></pre>

Create a new World.

#### Parameters

| Type                                  | Name                      | Description                                                                                                                                                                                                                                                             |
| ------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World.Config</code> | <code v-pre>config</code> | May be nil, which takes `DEFAULT_MAX_ENTITIES` slots and the default pipeline. `maxEntities` is the one field worth deciding up front: it sizes the entity index at creation and is not grown later, so a world that runs out of slots raises rather than reallocating. |

#### Returns

| Type                                                   | Description                                                                                                                                                                                                                                  |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.ecs.World">World</a></code> | A world with the builtin components already registered and no systems. Worlds are independent: an entity id is meaningful only in the world that issued it, while a component id is process-wide and shared by every world that carries one. |

<a id="tecs.ecs.phases"></a>

### tecs.ecs.phases

<pre><code v-pre><a href="#tecs.ecs.phases">tecs.ecs.phases</a>: phases
</code></pre>

The phases a system can be scheduled into.
<a id="tecs.ecs.random"></a>

### tecs.ecs.random

<pre><code v-pre><a href="#tecs.ecs.random">tecs.ecs.random</a>: random
</code></pre>

Seeded generation, in named streams a snapshot carries.
<a id="tecs.ecs.runif"></a>

### tecs.ecs.runif

<pre><code v-pre><a href="#tecs.ecs.runif">tecs.ecs.runif</a>: runIfHelpers
</code></pre>

Composable run conditions, for `SystemConfig.runIf`.
