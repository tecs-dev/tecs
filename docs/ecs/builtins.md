---
description: "The components, relationship, events and systems every world registers automatically, all on tecs.ecs"
outline: deep
---

# Builtins

Every world registers the same core components, relationship, events, and
systems. Games use them directly from `tecs.ecs`, including `Transform2D`,
which every spatial subsystem shares.

The durable entity-key component uses the public name `EntityKey` and the
externally typed registered name `"Key"`. Typed resource keys and stores come from `nupp.store`.

## Name {#name}

`Name` stores a non-unique string label:

```nupp
local entity = world:spawn(tecs.ecs.Name("Phreddy"))
world:commit()
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

```nupp
local player = world:spawn(
    tecs.ecs.EntityKey("player"),
    tecs.ecs.Name("Player ship")
)

world:commit()
assert(world:byKey("player") == player)
assert(world:requireKey("player") == player)
```

Callers choose and may replace the key through `world:set`. Tecs owns the
index, rejects duplicate live keys, releases a key on removal or despawn, and
rebuilds the index after snapshot load.

## ChildOf {#childof}

`ChildOf` links one child to one parent. Its registration enables exclusive
targets, a reverse index, and cascade delete.

```nupp
local parent = world:spawn()
local child = world:spawn(tecs.ecs.ChildOf(parent))

world:commit()
for _, childId in ipairs(world:relationshipSources(tecs.ecs.ChildOf, parent)) do
    print(childId)
end

world:despawn(parent) -- also despawns child
```

Tecs owns the relationship target field; callers treat it as read-only and
replace the edge through `world:set`. [Relationships](relationships/index.md)
covers storage and traversal.

## Transform2D {#transform}

`Transform2D` holds world position, layer, rotation, and scale in one record
component. Positions use world units, which map to pixels with the origin at
the top left. Rotation uses radians. Layer starts at 1 and rejects values below 1.

The positional constructor orders values as `x`, `y`, `z`, `layer`,
`rotation`, `scaleX`, and `scaleY`:

```nupp
local entity = world:spawn(
    tecs.ecs.Transform2D(10, 11, 1, 2)
)

world:commit()
local transform = assert(world:getMut(entity, tecs.ecs.Transform2D))
transform.rotation = math.pi / 4
transform.scaleX = 2
transform.scaleY = 2
```

Callers may write transform fields through `getMut`. Tecs owns storage and
dirty marks. A write through `world:get` changes the record but marks nothing,
so that path requires `world:markComponentDirty(entity, tecs.ecs.Transform2D)`.

The hierarchy, sequencer, physics, and renderer share this component.
Rendering additionally requires `Tint` and `Renderable2D`.

## RelativeTransform2D {#relativetransform}

`RelativeTransform2D` expresses a child pose relative to its `ChildOf` parent:

```nupp
local parent = world:spawn(tecs.ecs.Transform2D(100, 100))
local child = world:spawn(
    tecs.ecs.ChildOf(parent),
    tecs.ecs.RelativeTransform2D(50, 30)
)
```

The component requires `Transform2D`, so both enter the same archetype
transition. Callers own and may mutate the relative fields through `getMut`.
The builtin hierarchy system owns the resulting world `Transform2D` while the
entity carries both `ChildOf` and `RelativeTransform2D`; a later composition
overwrites direct edits to that derived transform.

Composition rotates and scales the offset by the parent, adds rotations,
multiplies scales, and copies the parent's layer. Origin fields express a
fraction of size for layout consumers; the hierarchy compositor carries them
without using them to adjust the pose.

## TTL {#ttl}

`TTL` despawns an entity when its remaining fixed-clock time reaches zero:

```nupp
world:spawn(tecs.ecs.TTL(10))
```

`TTL(remaining)` uses the same value for the starting time.
`TTL(remaining, startingTime)` starts partway through and requires
`startingTime >= remaining > 0`.

Callers set the starting values and may adjust them through `getMut`. The
builtin `ttl` system owns the per-step decrement of `remaining`.
`percentComplete()` reports progress from zero to one.

## Disabled {#disabled}

`Disabled` is an explicit query exclusion. Rendering excludes it, so disabled
entities do not draw. Game queries should list it under `exclude` too.

```nupp
world:set(entity, tecs.ecs.Disabled)
world:remove(entity, tecs.ecs.Disabled)
```

## Paused {#paused}

Exclude `Paused` in logic queries to stop their work while keeping presentation
visible. The [state stack](states.md) manages this tag for a state whose
`onBlur` policy equals `"pause"`. Games may also add or remove it directly.

## Events {#events}

Observers receive typed payloads and should treat them as read-only.

### OnSpawn {#onspawn-event}

`OnSpawn` carries the entity ID at address `0` after the entity becomes
committed and alive. An observer can read its initial components and stage
follow-up mutations.

### OnDespawn {#ondespawn-event}

`OnDespawn` carries the entity ID first at the entity address, then at address
`0`. The entity remains alive and readable during both dispatches. Tecs clears
observers at the entity address and removes the row after dispatch.

### State transition events {#state-transition-events}

The state stack emits `StateEnter`, `StateExit`, `StateBlur`, and `StateFocus`
at address `0`. Their string fields identify the state and, for blur or focus,
the pushed or popped state. See [Events](events.md).

## Builtin systems {#builtin-plugin}

World construction installs four systems:

| System                          | Phase         | Work                                               |
| ------------------------------- | ------------- | -------------------------------------------------- |
| `tecs.SnapshotTransforms`       | `FixedFirst`  | Copy previous poses for interpolation              |
| `ttl`                           | `FixedUpdate` | Decrement `TTL.remaining` and despawn at zero      |
| `RelativeTransform2D`           | `PostUpdate`  | Compose child world transforms                     |
| `RelativeTransformDirtySampler` | `Last`        | Carry late hierarchy dirtiness into the next frame |

The TTL query excludes paused and disabled entities. Hierarchy composition
writes a child `Transform2D` only when the composed values differ.
