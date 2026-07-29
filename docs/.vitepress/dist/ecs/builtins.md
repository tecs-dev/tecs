---
url: /ecs/builtins.md
description: >-
  The components, relationship, events and systems every world registers
  automatically, all on tecs.ecs
---

# Builtins

These are the components, the one relationship, and the events that Tecs registers itself. Every world creates
them, and the builtin plugin that owns the `TTL` and `RelativeTransform` systems is installed when the world is
constructed, so nothing here has to be added by hand.

They sit directly on `tecs.ecs`: `tecs.ecs.ChildOf`, `tecs.ecs.TTL`, `tecs.ecs.Paused`. Where they came from
is a fact about this implementation rather than something a game asking for a parent link should have to know,
so there is no namespace between the module and the name.

[`Transform`](#transform) is the exception and sits at the root, as `tecs.Transform`. It is the one component
every subsystem moves, so it belongs to none of them.

One more name differs, and that one is a collision rather than a decision. The durable lookup key is registered
as `"Key"` and
is reached as [`tecs.ecs.EntityKey`](#entitykey), because `tecs.ecs.Key` is the typed `world.resources` key
that [`newKey`](/ecs/#tecs.ecs.newKey) hands out. The registered name is what a snapshot writes and does not
move.

## Components

| Component                                 | Storage             | Description                                 |
| ----------------------------------------- | ------------------- | ------------------------------------------- |
| [`Name`](#name)                           | scalar, `string`    | A label for an entity                       |
| [`EntityKey`](#entitykey)                 | scalar, `string`    | A durable, unique lookup key                |
| [`ChildOf`](#childof)                     | sparse relationship | Parent and child, with cascade delete       |
| [`Transform`](#transform)                 | FFI struct          | Position, rotation, scale and layer         |
| [`RelativeTransform`](#relativetransform) | FFI struct          | A transform expressed relative to a parent  |
| [`TTL`](#ttl)                             | table               | Despawns the entity when its time runs out  |
| [`Disabled`](#disabled)                   | tag                 | Excluded from queries by default            |
| [`Paused`](#paused)                       | tag                 | Excluded from logic queries, still rendered |

### Name {#name}

A label for an entity. It is a scalar component of kind `string`, so the column holds the raw string and
`world:get(id, Name)` returns a string rather than a wrapper.

`Name` is not unique. Use [`EntityKey`](#entitykey) when runtime code or tooling needs a durable address for an
entity.

**Teal type:**

```teal
Name: tecs.ScalarComponent<string>
```

**Example:**

```teal
local entity <const> = world:spawn(
    tecs.ecs.Name("Phreddy")
)

local name <const> = world:get(entity, tecs.ecs.Name) -- "Phreddy"
```

To change an existing entity's name, use the three-argument form of `world:set`:

```teal
world:set(entity, tecs.ecs.Name, "Greg")
```

### EntityKey {#entitykey}

A durable, developer-assigned lookup key, registered as `"Key"`. Keys are unique within a world: spawning or
setting one that another live entity already holds raises an error naming the entity that holds it. When an
entity despawns, or the component is removed, the key leaves the index and can be claimed again.

**Teal type:**

```teal
EntityKey: tecs.ScalarComponent<string>
```

**Example:**

```teal
local player <const> = world:spawn(
    tecs.ecs.EntityKey("player"),
    tecs.ecs.Name("Player ship")
)

assert(world:byKey("player") == player)
local samePlayer <const> = world:requireKey("player")
```

::: tip
Use `EntityKey` for hot-reload rebinding, authored references, tooling and save-compatible lookups. Use
[`Name`](#name) for human-readable labels.
:::

### ChildOf {#childof}

An exclusive parent-child relationship between two entities.

**Registered with:** `exclusive = true`, `sparse = true`, `reverseIndex = true`, `cascadeDelete = true`.

Sparse storage keeps a per-target component type from fragmenting archetypes, the reverse index makes
`world:targets` and `world:traverse` possible, and cascade delete means despawning a parent despawns its
children, and their children in turn.

**Example:**

```teal
local parent <const> = world:spawn()
local child <const> = world:spawn(tecs.ecs.ChildOf(parent))

-- Visit the children of a parent
world:targets(parent, tecs.ecs.ChildOf, function(childId: integer)
    print("Child:", childId)
end)

-- Despawning the parent cascades to the children
world:despawn(parent)
```

See [Relationships](/ecs/relationships/) for sparse storage and cascade delete in full.

### Transform {#transform}

An entity's position, rotation, scale and layer, backed by an FFI struct.

This is the transform the renderer reads. [`tecs.gfx`](/modules/gfx/) does not carry a second one and does
not re-export this: a transform positions everything a world holds rather than only what draws, so the
hierarchy, the sequencer, physics and the extractor all move this one. Positions are in world units, which are pixels with the origin at the top
left, and lighting works in the same units.

**Fields and defaults:**

| Field      | C type    | Default | Description                   |
| ---------- | --------- | ------- | ----------------------------- |
| `x`        | `float`   | `0`     | The x coordinate              |
| `y`        | `float`   | `0`     | The y coordinate              |
| `z`        | `float`   | `0`     | The z coordinate              |
| `layer`    | `int32_t` | `1`     | The layer. Must be at least 1 |
| `rotation` | `float`   | `0`     | Rotation in radians           |
| `scaleX`   | `float`   | `1`     | Horizontal scale              |
| `scaleY`   | `float`   | `1`     | Vertical scale                |

Constructing a `Transform` with a `layer` below 1 raises an error naming the value.

**Teal type:**

```teal
record Transform is tecs.Component
    x: number
    y: number
    z: number
    layer: integer
    rotation: number
    scaleX: number
    scaleY: number

    metamethod __call: function(
        self,
        x?: number,
        y?: number,
        z?: number,
        layer?: integer,
        rotation?: number,
        scaleX?: number,
        scaleY?: number
    ): Transform

    --- Table-form constructor. `data` is a partial
    --- `{x, y, z, layer, rotation, scaleX, scaleY}`.
    new: function(data: {string: any}): Transform
end
```

**Examples:**

Positional arguments allocate nothing beyond the component itself, and are what a hot spawn path should use:

```teal
local entity <const> = world:spawn(
    tecs.Transform(10, 11, 1, 2) -- x, y, z, layer
)
```

The table form is more readable and allocates the table you pass:

```teal
world:spawn(
    tecs.Transform.new({
        x = 10,
        y = 11,
        z = 1,
        layer = 2
    })
)
```

::: warning Writing a Transform marks it dirty only through the mutable accessors
`Transform` is an FFI component, and consumers downstream of it are dirty-gated. Write through
`archetype:getMut(Transform)` inside a query loop, or through `world:getMut(entity, Transform)`, both of which
mark the component dirty on the archetype. A field written through the read accessor `world:get` needs an
explicit `world:markComponentDirty(entity, Transform)` afterwards, or the write is never picked up.
:::

```teal
local transform <const> = world:getMut(entity, tecs.Transform)
transform.rotation = math.pi / 4
transform.scaleX = 2
transform.scaleY = 2
```

An entity is drawn when it carries `Transform`, `Tint` and `Renderable`, which is the query the extractor
matches renderables with. A `Transform` on its own is a position, which is what most entities in a world
actually are. See [`components`](/modules/gfx/).

### RelativeTransform {#relativetransform}

An entity's transform expressed relative to its parent. The builtin plugin composes the parent's world-space
`Transform` with this offset and writes the result into the child's own `Transform`.

`RelativeTransform` declares `requires = {Transform}`, so adding it to an entity adds a `Transform` in the same
archetype transition when one is not already there. It also needs a [`ChildOf`](#childof) relationship to name
the parent; add that yourself alongside it.

**Fields and defaults:**

| Field      | C type  | Default | Description                                                 |
| ---------- | ------- | ------- | ----------------------------------------------------------- |
| `x`        | `float` | `0`     | The x offset from the parent                                |
| `y`        | `float` | `0`     | The y offset from the parent                                |
| `z`        | `float` | `0`     | The z offset from the parent                                |
| `rotation` | `float` | `0`     | The rotation offset in radians                              |
| `scaleX`   | `float` | `1`     | The x scale multiplier relative to the parent               |
| `scaleY`   | `float` | `1`     | The y scale multiplier relative to the parent               |
| `originX`  | `float` | `0`     | Origin as a fraction of width: 0 left, 0.5 center, 1 right  |
| `originY`  | `float` | `0`     | Origin as a fraction of height: 0 top, 0.5 center, 1 bottom |

**Teal type:**

```teal
record RelativeTransform is tecs.Component
    x: number
    y: number
    z: number
    rotation: number
    scaleX: number
    scaleY: number
    originX: number
    originY: number

    metamethod __call: function(
        self,
        x?: number,
        y?: number,
        z?: number,
        rotation?: number,
        scaleX?: number,
        scaleY?: number,
        originX?: number,
        originY?: number
    ): RelativeTransform

    new: function(data: {string: any}): RelativeTransform
end
```

**Example:**

```teal
local parent <const> = world:spawn(
    tecs.Transform(100, 100, 0)
)

local child <const> = world:spawn(
    tecs.ecs.ChildOf(parent),
    tecs.ecs.RelativeTransform(50, 30)  -- 50 right, 30 down
)
```

The child's `Transform` resolves to (150, 130), and follows the parent as it moves. Composition applies the
parent's rotation and scale to the offset, adds the rotations, multiplies the scales, and copies the parent's
`layer` down.

### TTL {#ttl}

Despawns an entity once its time to live reaches zero. The builtin plugin runs the system that counts it down.

`TTL(remaining)` sets `startingTime` to the same value. Pass both to start part-way through:
`TTL(remaining, startingTime)`, where `startingTime` must be at least `remaining`. Both must be greater than
zero.

**Teal type:**

```teal
record TTL is tecs.Component
    --- The total amount of time the entity had to live.
    startingTime: number

    --- The remaining time the entity has to live.
    remaining: number

    --- Completion as a number between 0 and 1.
    percentComplete: function(self): number

    metamethod __call: function(self, remaining: number): TTL
end
```

**Example:**

```teal
world:spawn(
    -- Despawn the entity after 10 seconds
    tecs.ecs.TTL(10)
)
```

### Disabled {#disabled}

A tag marking an entity as disabled. Every query excludes `Disabled` automatically unless the query includes it
explicitly, which makes this the way to hide an entity without despawning it. The extractor's queries are
ordinary queries, so a disabled entity is not extracted and therefore is not drawn.

```teal
local entity <const> = world:spawn(
    tecs.ecs.Disabled
)
```

### Paused {#paused}

A tag marking an entity as paused. Unlike `Disabled`, `Paused` is **not** excluded from every query, because a
paused entity keeps rendering: the extractor's renderable and light queries declare no query type, so they
match paused entities and keep drawing them. A query declared `type = "logic"` excludes `Paused`; so does
listing it in `exclude`.

The [state stack](/ecs/states) manages this tag for you when a state's `onBlur` policy is `"pause"`, and you can
also set it yourself:

```teal
world:set(entity, tecs.ecs.Paused)
world:remove(entity, tecs.ecs.Paused)
```

## Events

| Event                                         | Description                                        |
| --------------------------------------------- | -------------------------------------------------- |
| [`OnSpawn`](#onspawn-event)                   | An entity was spawned                              |
| [`OnDespawn`](#ondespawn-event)               | An entity was despawned                            |
| [`ArchetypeCreated`](#archetypecreated-event) | A new archetype was created                        |
| [`StateEnter`](#state-transition-events)      | A state was pushed                                 |
| [`StateExit`](#state-transition-events)       | A state was popped                                 |
| [`StateBlur`](#state-transition-events)       | A state stopped being top                          |
| [`StateFocus`](#state-transition-events)      | A state became top again                           |
| [`OnSnapshotSave`](#snapshot-events)          | A snapshot is being written                        |
| [`StartSnapshotLoad`](#snapshot-events)       | A snapshot has been restored, before data dispatch |
| [`FinishSnapshotLoad`](#snapshot-events)      | A snapshot load has completed                      |

See [Events](/ecs/events) for `world:observe` and `world:emit`.

### OnSpawn {#onspawn-event}

Emitted when an entity is spawned, at address `0`. It is an FFI event carrying the entity ID as a `double`, so
the packed ID survives with its generation bits intact.

```teal
record OnSpawn is tecs.Event
    entity: integer

    metamethod __call: function(self, entity: integer): OnSpawn
end
```

::: info Event timing
`OnSpawn` is emitted once the spawn has been staged and before it is committed. The entity is not yet in an
archetype and not yet visible to queries, and mutations an observer makes on the ID stage onto the same pending
entity. A world with an `OnSpawn` observer routes `world:spawn` through the staged path for exactly this
reason, and drains before returning, so the caller still receives a committed entity.

`world:batchSpawn` does not emit `OnSpawn`. Use a query's entity-added callback to react to bulk spawns.
:::

```teal
world:observe(0, tecs.ecs.OnSpawn, function(event: tecs.ecs.OnSpawn)
    print("Entity spawned: " .. event.entity)
end)
```

### OnDespawn {#ondespawn-event}

Emitted when an entity is despawned, both at the entity's own address and at address `0`. It is an FFI event
carrying the entity ID as a `double`.

```teal
record OnDespawn is tecs.Event
    entity: integer

    metamethod __call: function(self, entity: integer): OnDespawn
end
```

::: info Event timing
`OnDespawn` is emitted during the despawn call, before the row is physically removed at commit. While the
observers run, the entity's components are still readable through `world:get`. Once they have run, every
observer registered at that entity's address is cleared, so nothing survives into the next entity that recycles
the slot.
:::

Observe one entity:

```teal
world:observe(entityId, tecs.ecs.OnDespawn, function(e: tecs.ecs.OnDespawn)
    -- The entity is still readable until the despawn commits
    local transform <const> = world:get(e.entity, tecs.Transform)
    if transform then
        spawnExplosionAt(transform.x, transform.y)
    end
end)
```

Or observe every despawn:

```teal
world:observe(0, tecs.ecs.OnDespawn, function(e: tecs.ecs.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)
```

### ArchetypeCreated {#archetypecreated-event}

Emitted at address `0` when a new archetype is created, that is when some entity first takes on a component
combination the world has not seen.

```teal
record ArchetypeCreated is tecs.Event
    archetype: tecs.Archetype

    metamethod __call: function(self, archetype: tecs.Archetype): ArchetypeCreated
end
```

```teal
world:observe(0, tecs.ecs.ArchetypeCreated, function(event: tecs.ecs.ArchetypeCreated)
    local archetype <const> = event.archetype
    -- inspect newly created archetypes here
end)
```

::: info Advanced
Queries use this event internally to track the archetypes they match. To react to entities matching a component
signature, prefer [query callbacks](/ecs/queries/callbacks).
:::

### State transition events {#state-transition-events}

All four are emitted at address `0` by the [state stack](/ecs/states).

```teal
record StateEnter is tecs.Event
    --- The state name being entered.
    state: string
    metamethod __call: function(self, state: string): StateEnter
end

record StateExit is tecs.Event
    --- The state name being exited.
    state: string
    metamethod __call: function(self, state: string): StateExit
end

record StateBlur is tecs.Event
    --- The state losing focus.
    state: string
    --- The state being pushed on top.
    pushed: string
    metamethod __call: function(self, state: string, pushed: string): StateBlur
end

record StateFocus is tecs.Event
    --- The state regaining focus.
    state: string
    --- The state that was popped.
    popped: string
    metamethod __call: function(self, state: string, popped: string): StateFocus
end
```

### Snapshot events {#snapshot-events}

Three events bracket save and load, all emitted at address `0`. See [Save games](/ecs/save-games) for the
snapshot API itself.

`OnSnapshotSave` is emitted at the start of a save, before archetype data is written. An observer can attach
keyed metadata, or exclude entities a plugin will re-derive on load:

```teal
record OnSnapshotSave is tecs.Event
    --- Encode a (key, value) pair into the snapshot's data section.
    --- Keys must be strings and values must be `string.buffer`-encodable.
    addData: function(self, key: string, value: any)

    --- Skip every entity carrying `component`.
    exclude: function(self, component: tecs.Component)

    metamethod __call: function(self): OnSnapshotSave
end
```

`StartSnapshotLoad` is emitted after the world has been restored and before the data section is dispatched.
Observers register per-key callbacks, each of which fires once per matching entry written during the save:

```teal
record StartSnapshotLoad is tecs.Event
    --- Register a callback for the data entry keyed by `key`. Multiple
    --- listeners may register the same key; all fire in registration order.
    onData: function(self, key: string, callback: function(value: any))

    metamethod __call: function(self): StartSnapshotLoad
end
```

`FinishSnapshotLoad` is emitted once the load is complete, after every entity is restored and every data
callback has run:

```teal
record FinishSnapshotLoad is tecs.Event
    --- The snapshot prelude, carrying the version and the counts.
    prelude: any

    metamethod __call: function(self): FinishSnapshotLoad
end
```

Namespace the keys a plugin writes, `"mygame.scoreboard"` rather than `"scoreboard"`, so two plugins cannot
collide.

## The builtin plugin

Constructing a world installs the builtin plugin, which registers three systems:

| System                          | Phase         | What it does                                                                                                                         |
| ------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `ttl`                           | `FixedUpdate` | Counts `TTL.remaining` down by the step and despawns the entity at zero.                                                             |
| `RelativeTransform`             | `PostUpdate`  | Composes each child's world-space `Transform` from its parent's transform and its `RelativeTransform`, following `ChildOf`.          |
| `RelativeTransformDirtySampler` | `RenderLast`  | Samples whether hierarchy state changed after the update phases, so a write made during rendering still opens the next frame's gate. |

`PostUpdate` runs before `RenderFirst`, which is where the engine extracts the frame, so a child's composed
`Transform` is already correct by the time it is read for drawing.

The `ttl` query is declared `type = "logic"`, so a [paused](#paused) entity does not burn down its time to live.
The hierarchy system is dirty-gated: it recomposes only when an archetype carrying `Transform`,
`RelativeTransform` or `ChildOf` changed this frame or at the end of the previous one, and it writes a child's
`Transform` only when the composed values actually differ, so an idle hierarchy costs a scan and marks nothing.
