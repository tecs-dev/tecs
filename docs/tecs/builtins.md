---
description: "Built-in components like Name, Key, ChildOf, Transform, TTL, Disabled, Paused, and lifecycle events registered on every world"
outline: deep
---

# Builtins

Tecs provides various builtin plugins, components, and events. These builtins are registered with every
[World](/tecs/world) by default.

## Components

| Component                                           | Description                                         |
| --------------------------------------------------- | --------------------------------------------------- |
| [Name](#name-component)                             | Provides a name for an entity                       |
| [Key](#key-component)                               | Provides a durable unique lookup key                |
| [ChildOf](#childof-relationship-component)          | Parent/child relationship between entities          |
| [Transform](#transform-component)                   | Position, rotation, scale, and layer                |
| [RelativeTransform](#relativetransform-component)   | Transform relative to parent entity                 |
| [TTL](#ttl-component)                               | Automatically despawn after time expires            |
| [Disabled](#disabled-component)                     | Excludes entity from all queries                    |
| [Paused](#paused-component)                         | Excludes from gameplay queries, keeps rendering     |

### Name component

Provides a human/debug label for an entity. Stored as a [scalar component](/tecs/components/scalar-components) of
kind `string`, so the column holds the raw string and `world:get(id, Name)` returns a string directly.

`Name` is not unique. Use [`Key`](#key-component) when runtime code, tooling, or hot-reload startup needs a durable
address for an entity.

**Teal type:**

```teal
Name: tecs.ScalarComponent<string>
```

**Example:**

```teal
local tecs = require("tecs")

local entity = world:spawn(
    tecs.builtins.Name("Phreddy")
)

local name = world:get(entity, tecs.builtins.Name) -- "Phreddy"
```

To update an existing entity's name, prefer the 3-arg form of `world:set`:

```teal
world:set(entity, tecs.builtins.Name, "Greg")
```

### Key component

Provides a durable, developer-assigned lookup key for an entity. Keys are unique within a world: spawning or setting
a `Key` already claimed by another live entity raises an error. Keys are saved in snapshots and the key index is
rebuilt on load.

::: tip
Use `Key` for hot-reload rebinding, authored scene references, tooling, and save-compatible lookups. Use
[`Name`](#name-component) for human-readable labels.
:::

**Teal type:**

```teal
Key: tecs.ScalarComponent<string>
```

**Example:**

```teal
local player = world:spawn(
    tecs.builtins.Key("player"),
    tecs.builtins.Name("Player ship")
)

assert(world:byKey("player") == player)
local samePlayer = world:requireKey("player")
```

For the save/load handle-rebinding pattern, see [Save games: runtime handles after load](/tecs/save-games#runtime-handles-after-load).

When an entity despawns, its key is removed from the index and can be reused by another entity.

### ChildOf relationship component

Defines an exclusive parent-child relationship between two entities. Uses sparse storage with cascade delete:
despawning a parent automatically despawns all children (and grandchildren, recursively).

**Registered with:** `exclusive = true`, `sparse = true`, `reverseIndex = true`, `cascadeDelete = true`

**Example:**

```teal
local parent = world:spawn()
local child = world:spawn(tecs.builtins.ChildOf(parent))

-- Find all children of a parent
world:targets(parent, tecs.builtins.ChildOf, function(childId: integer)
    print("Child:", childId)
end)

-- Despawning the parent cascades to children
world:despawn(parent)
```

See [Relationships](/tecs/relationships/) for details on sparse storage and cascade delete.

### Transform component

Provides the position, rotation, scale, and layer of an entity. You can use this component if it works for your game,
or ignore it if not.

**Teal type:**

```teal
record Transform is components.Component
    --- The x coordinate of the entity.
    x: number

    --- The y coordinate of the entity.
    y: number

    --- The z coordinate of the entity.
    z: number

    --- The layer of the entity (default: 1; must be at least 1).
    layer: integer

    --- The rotation of the entity in radians (default: 0).
    rotation: number

    --- The horizontal scale of the entity (default: 1).
    scaleX: number

    --- The vertical scale of the entity (default: 1).
    scaleY: number

    --- Creates a new Transform component.
    ---
    --- @param x The x position.
    --- @param y The y position.
    --- @param z The z position.
    --- @param layer The layer (defaults to 1).
    --- @param rotation The rotation in radians (defaults to 0).
    --- @param scaleX The x scale (defaults to 1).
    --- @param scaleY The y scale (defaults to 1).
    --- @return the created transform component.
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

    --- Table-form constructor. `data` is a partial `{x, y, z, layer, rotation, scaleX, scaleY}`.
    new: function(data: {string: any}): Transform
end
```

**Examples:**

You can create a Transform component using positional arguments. This is ideal for performance:

```teal
local entity = world:spawn(
    tecs.builtins.Transform(10, 11, 1, 2) -- x, y, z, layer
)
```

Alternatively, you can pass a table of named arguments. This generates garbage due to the table input, but it's
more readable.

```teal
world:spawn(
    tecs.builtins.Transform.new({
        x = 10,
        y = 11,
        z = 1,
        layer = 2
    })
)
```

After the component is created, you can modify anything inside of it as needed, like rotation and scale.

```teal
local transform = world:get(entity, tecs.builtins.Transform)
transform.rotation = math.pi / 4  -- Rotate 45 degrees
transform.scaleX = 2              -- Scale 2x horizontally
transform.scaleY = 2              -- Scale 2x vertically
```

::: tip Auto-sync
Modifying anything in the `Transform` component automatically syncs to all builtin GPU systems in Tecs. No dirty
tracking needed.
:::

### RelativeTransform component

Defines an entity's transform relative to its parent entity. Requires the `ChildOf` component to be present on the same
entity. A builtin system automatically composes the parent's transform with the relative transform to compute the final
world-space position, rotation, and scale.

This component:

* Can position an entity relative to another, allowing use cases like GUI elements
* Causes child entities to hierarchically inherit the position, scaling, and rotation of a parent entity
* Automatically adds a `Transform` component if one is not present when added to an entity

**Parameters:**

- `x`: The x offset from the parent (default: 0)
- `y`: The y offset from the parent (default: 0)
- `z`: The z offset from the parent (default: 0)
- `rotation`: The rotation offset in radians from the parent (default: 0)
- `scaleX`: The x scale multiplier relative to the parent (default: 1)
- `scaleY`: The y scale multiplier relative to the parent (default: 1)
- `originX`: Origin as a fraction (0-1) of the entity's width; 0 = left, 0.5 = center, 1 = right (default: 0)
- `originY`: Origin as a fraction (0-1) of the entity's height; 0 = top, 0.5 = center, 1 = bottom (default: 0)

**Teal type:**

```teal
record RelativeTransform is components.Component
    x: number
    y: number
    z: number
    rotation: number
    scaleX: number
    scaleY: number
    --- Origin as a fraction (0-1) of the entity's width: 0 = left, 0.5 = center, 1 = right.
    originX: number
    --- Origin as a fraction (0-1) of the entity's height: 0 = top, 0.5 = center, 1 = bottom.
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
end
```

**Examples:**

Create a child entity positioned relative to its parent:

```teal
local parent = world:spawn(
    tecs.builtins.Transform(100, 100, 0)
)

local child = world:spawn(
    tecs.builtins.ChildOf(parent),
    tecs.builtins.RelativeTransform(50, 30)  -- 50px right, 30px down
)
```

The child's world-space position is automatically calculated as (150, 130) and updated each frame as the
parent moves.

### TTL component

Automatically despawns an entity when the TTL, or "time to live", reaches zero. Tecs automatically
adds a system that tracks entities with a TTL and despawns them.

**Teal type:**

```teal
--- Despawns an entity when the TTL reaches zero.
record TTL is components.Component
    --- The total amount of time the entity had to live.
    startingTime: number

    --- The remaining time the entity has to live.
    remaining: number

    --- Compute the percentage of completion as a number between 0 and 1.
    percentComplete: function(self): number

    --- Create a new TTL component.
    ---
    --- @param remaining The amount of time the entity has to live.
    --- @return the created TTL component.
    metamethod __call: function(self, remaining: number): TTL
end
```

**Example:**

```teal
world:spawn(
    -- Despawn the entity after 10 seconds.
    tecs.builtins.TTL(10)
)

```

### Disabled component

A tag component that marks an entity as disabled, causing it to be excluded from all queries by default.
This is useful for temporarily hiding entities without despawning them.

**Usage:**

```teal
-- Spawn a disabled entity (won't appear in queries by default)
local entity = world:spawn(
    tecs.builtins.Disabled
)
```

::: tip See also
See *[Disabled entities](/tecs/queries/#disabled-entities)* for more on how disabled entities work with queries.
:::

### Paused component

A tag component that marks an entity as paused. Unlike `Disabled`, `Paused` is **not** auto-excluded from queries.
Paused entities should still render; only gameplay systems that need to skip them should use `exclude = {Paused}`.

This is typically managed automatically by the [state stack](/tecs/states) when a state's `onBlur` policy
is set to `"pause"`. You can also add it manually:

```teal
-- Pause an entity (excluded from gameplay queries, still renders)
world:set(entity, tecs.builtins.Paused)

-- Unpause
world:remove(entity, tecs.builtins.Paused)
```

When `Paused` is added to an entity with a `Sprite` component, the sprite animation is automatically frozen
at the current frame. When `Paused` is removed, the animation resumes from where it left off.

::: tip See also
See *[Paused entities](/tecs/queries/#paused-entities)* for more on how paused entities work with queries.
:::

## Events

| Event                                               | Description                                         |
| --------------------------------------------------- | --------------------------------------------------- |
| [ArchetypeCreated](#archetypecreated-event)         | Emitted when a new archetype is created             |
| [OnSpawn](#onspawn-event)                           | Emitted when an entity is spawned                   |
| [OnDespawn](#ondespawn-event)                       | Emitted when an entity is despawned                 |
| `StateEnter`                                        | Emitted when a state is first pushed. See [States](/tecs/states).       |
| `StateExit`                                         | Emitted when a state is popped. See [States](/tecs/states).             |
| `StateBlur`                                         | Emitted when a state is no longer top. See [States](/tecs/states).      |
| `StateFocus`                                        | Emitted when a state becomes top again. See [States](/tecs/states).     |
| `OnSnapshotSave`                                    | Emitted while saving a snapshot. See [Save games](/tecs/save-games).    |
| `StartSnapshotLoad`                                 | Emitted before restoring a snapshot. See [Save games](/tecs/save-games). |
| `FinishSnapshotLoad`                                | Emitted after restoring a snapshot. See [Save games](/tecs/save-games). |

### ArchetypeCreated event

An event emitted when a new archetype is created in the world. Observe this event at address 0 (world-level) to
discover new archetypes as entities with new component combinations are spawned.

**Teal type:**

```teal
--- An event emitted when a new archetype is created.
record ArchetypeCreated is events.Event
    archetype: Archetype

    --- Create a new ArchetypeCreated event.
    metamethod __call: function(self, archetype: Archetype): ArchetypeCreated
end
```

**Usage:**

```teal
world:observe(0, tecs.builtins.ArchetypeCreated, function(event: tecs.builtins.ArchetypeCreated)
    local archetype = event.archetype
    if archetype:get(Position) and archetype:get(Velocity) then
        -- Inspect or introspect newly-created archetypes here.
    end
end)
```

::: info Advanced feature
This event is primarily used internally by queries to track matching archetypes. For normal "react when
entities match a component signature" use cases, prefer [query callbacks](/tecs/queries/callbacks)
(`onEntitiesAdded` / `onEntitiesRemoved`).
:::

### OnSpawn event

An event emitted when an entity is spawned. The event is emitted globally (address 0).
Observe this event to react when entities are created.

::: info Event timing
The `OnSpawn` event is emitted at spawn time (when `world:spawn`, `world:spawnAt`, or a bundle
spawn is called), before the entity is committed:
- The entity is not yet placed in an archetype or visible to queries
- `world:isAlive(entity)` returns `false` until commit
- You can stage further mutations on the entity ID between spawn and commit
- Bulk spawns (`batchSpawn`, `batchSpawnAt`) do not emit `OnSpawn`; use a query's
  [`onEntitiesAdded`](/tecs/queries/callbacks) instead

See the [Mutation model](/tecs/mutation-model#event-timing) for per-path event timing.
:::

**Teal type:**

```teal
--- An event emitted when a specific entity is spawned.
record OnSpawn is events.Event
    entity: integer

    --- Create a new OnSpawn event.
    metamethod __call: function(self, entity: integer): OnSpawn
end
```

**Usage:**

Observe globally to react to all spawns:

```teal
world:observe(0, tecs.builtins.OnSpawn, function(event: tecs.builtins.OnSpawn)
    print("Entity spawned: " .. event.entity)
end)
```

### OnDespawn event

An event emitted when an entity is despawned. The event is emitted both globally (address 0) and to the
entity's address. Observe this event to clean up resources, spawn effects, or react to entity removal.

::: info Event timing
The `OnDespawn` event is emitted during the despawn call, before the entity is
physically removed at commit. When this event fires:
- `world:isAlive(entity)` still returns `true` (the entity index entry is intact)
- Entity components are still accessible via `world:get()`
- The entity has not yet been removed from queries
- After all observers complete, all observers on the entity's address are automatically cleaned up
:::

**Teal type:**

```teal
--- An event emitted when a specific entity is despawned.
record OnDespawn is events.Event
    entity: integer

    --- Create a new OnDespawn event.
    metamethod __call: function(self, entity: integer): OnDespawn
end
```

**Usage:**

Observe a specific entity:

```teal
world:observe(entityId, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    -- The entity is still alive and readable until despawn commits.
    local pos = world:get(e.entity, Position)
    if pos then
        spawnExplosionAt(pos.x, pos.y)
    end
    print("Entity " .. e.entity .. " was despawned")
end)
```

Observe globally to react to all despawns:

```teal
world:observe(0, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " was despawned")
end)
```
