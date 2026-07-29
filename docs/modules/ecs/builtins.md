---
description: "The components, relationship, events and systems every world registers automatically, all on tecs.ecs"
outline: deep
---

# Builtins

Every world registers the same core components, relationship, events, and
systems. Games use them directly from `tecs.ecs`, except for `tecs.Transform`,
which sits at the root because every subsystem moves it.

The durable entity-key component uses the public name `EntityKey` and the
registered name `"Key"`. Snapshots persist the registered name for
compatibility. `tecs.ecs.Key` instead names the typed resource-key type.

## Name {#name}

`Name` stores a non-unique string label:

```teal
local entity <const> = world:spawn(tecs.ecs.Name("Phreddy"))
print(world:get(entity, tecs.ecs.Name))

world:set(entity, tecs.ecs.Name, "Greg")
```

The scalar column stores the raw string. Callers may replace it through
`world:set`; Tecs owns the column and scalar wrapper.

Use `Name` for display and debugging. Use [`EntityKey`](#entitykey) when code
must rediscover an entity.

## EntityKey {#entitykey}

`EntityKey` adds a durable, developer-chosen string to the world's unique
index:

```teal
local player <const> = world:spawn(
    tecs.ecs.EntityKey("player"),
    tecs.ecs.Name("Player ship")
)

assert(world:byKey("player") == player)
assert(world:requireKey("player") == player)
```

Callers choose and may replace the key through `world:set`. Tecs owns the
index, rejects duplicate live keys, releases a key on removal or despawn, and
rebuilds the index after snapshot load.

## ChildOf {#childof}

`ChildOf` links one child to one parent. Its registration enables exclusive
targets, sparse storage, a reverse index, and cascade delete.

```teal
local parent <const> = world:spawn()
local child <const> = world:spawn(tecs.ecs.ChildOf(parent))

world:targets(parent, tecs.ecs.ChildOf, function(childId: integer)
    print(childId)
end)

world:despawn(parent) -- also despawns child
```

Tecs owns the relationship target field; callers treat it as read-only and
replace the edge through `world:set`. [Relationships](/modules/ecs/relationships/)
covers storage and traversal.

## Transform {#transform}

`Transform` holds world position, layer, rotation, and scale in one FFI
component. Positions use world units, which map to pixels with the origin at
the top left. Rotation uses radians. Layer starts at 1 and rejects values below 1.

The positional constructor orders values as `x`, `y`, `z`, `layer`,
`rotation`, `scaleX`, and `scaleY`:

```teal
local entity <const> = world:spawn(
    tecs.Transform(10, 11, 1, 2)
)

local transform <const> = world:getMut(entity, tecs.Transform)
transform.rotation = math.pi / 4
transform.scaleX = 2
transform.scaleY = 2
```

Callers may write transform fields through `getMut`. Tecs owns storage and
dirty marks. A write through `world:get` changes the cdata but marks nothing,
so that path requires `world:markComponentDirty(entity, tecs.Transform)`.

The hierarchy, sequencer, physics, and renderer share this component.
Rendering additionally requires `Tint` and `Renderable`.

## RelativeTransform {#relativetransform}

`RelativeTransform` expresses a child pose relative to its `ChildOf` parent:

```teal
local parent <const> = world:spawn(tecs.Transform(100, 100))
local child <const> = world:spawn(
    tecs.ecs.ChildOf(parent),
    tecs.ecs.RelativeTransform(50, 30)
)
```

The component requires `Transform`, so both enter the same archetype
transition. Callers own and may mutate the relative fields through `getMut`.
The builtin hierarchy system owns the resulting world `Transform` while the
entity carries both `ChildOf` and `RelativeTransform`; a later composition
overwrites direct edits to that derived transform.

Composition rotates and scales the offset by the parent, adds rotations,
multiplies scales, and copies the parent's layer. Origin fields express a
fraction of size, with `0`, `0.5`, and `1` marking the near edge, center, and
far edge.

## TTL {#ttl}

`TTL` despawns an entity when its remaining fixed-clock time reaches zero:

```teal
world:spawn(tecs.ecs.TTL(10))
```

`TTL(remaining)` uses the same value for the starting time.
`TTL(remaining, startingTime)` starts partway through and requires
`startingTime >= remaining > 0`.

Callers set the starting values and may adjust them through `getMut`. The
builtin `ttl` system owns the per-step decrement of `remaining`.
`percentComplete()` reports progress from zero to one.

## Disabled {#disabled}

`Disabled` removes an entity from every query unless the descriptor explicitly
includes the tag. Renderer queries follow the same rule, so a disabled entity
does not draw.

```teal
world:set(entity, tecs.ecs.Disabled)
world:remove(entity, tecs.ecs.Disabled)
```

## Paused {#paused}

`Paused` keeps presentation visible while stopping logic queries. A query with
`type = "logic"` excludes the tag. Render queries and untyped queries continue
to match it unless they list `Paused` under `exclude`.

The [state stack](/modules/ecs/states) manages this tag for a state whose `onBlur`
policy equals `"pause"`. Games may also add or remove it directly.

## Events {#events}

Observers should treat every event payload as read-only. Tecs owns the payload
for the duration of dispatch and may reuse its backing storage afterwards.

### OnSpawn {#onspawn-event}

`OnSpawn` carries the entity ID at address `0`. `world:spawn` emits it while
the entity remains staged, before archetype placement. An observer may stage
follow-up mutations against the ID.

`batchSpawn` and `batchSpawnAt` do not emit `OnSpawn`; use their fill callback
or a query's `onEntitiesAdded`.

### OnDespawn {#ondespawn-event}

`OnDespawn` carries the entity ID first at the entity address, then at address
`0`. The entity remains alive and readable during both dispatches. Tecs clears
every observer at the entity address after dispatch, then removes the row at
commit.

### ArchetypeCreated {#archetypecreated-event}

`ArchetypeCreated` carries a newly created archetype at address `0`. Tecs owns
the `archetype` field and callers treat it as read-only. Queries consume this
event internally; game code should use
[query callbacks](/modules/ecs/queries/callbacks) for match-set changes.

### State transition events {#state-transition-events}

The state stack emits `StateEnter`, `StateExit`, `StateBlur`, and `StateFocus`
at address `0`. Their engine-owned string fields identify the state and, for
blur or focus, the pushed or popped state.

### Snapshot events {#snapshot-events}

`OnSnapshotSave`, `StartSnapshotLoad`, and `FinishSnapshotLoad` bracket
snapshot work at address `0`. Their engine-owned payloads expose functions for
adding data, excluding derived entities, and subscribing to keyed load data.
Callers may invoke those functions but must not replace them.

[Save games](/modules/ecs/save-games) covers the lifecycle and recommends named
snapshot handlers for ordinary subsystem state.

## Builtin plugin {#builtin-plugin}

World construction installs three systems:

| System                          | Phase         | Work                                               |
| ------------------------------- | ------------- | -------------------------------------------------- |
| `ttl`                           | `FixedUpdate` | Decrement `TTL.remaining` and despawn at zero      |
| `RelativeTransform`             | `PostUpdate`  | Compose child world transforms                     |
| `RelativeTransformDirtySampler` | `RenderLast`  | Carry late hierarchy dirtiness into the next frame |

The `ttl` query uses `type = "logic"`, so paused entities keep their remaining
time. Hierarchy composition runs before `RenderFirst` extraction and only
writes a child `Transform` when the composed values differ.
