---
description: "Archetype storage groups with row and column layout, get and getMut column access, set, relationship lookups, dirty tracking, and lifecycle observers"
outline: deep
---

# Archetypes

An archetype is a storage group for entities with the same component signature. Each entity belongs to exactly
one archetype at a time. When an entity gains or loses a component, it moves to another archetype.

Most code reaches archetypes through [queries](/ecs/queries/). A query finds the archetypes whose signatures
match its descriptor, then each loop step gives you an archetype, a row count, and the entity ids for those
rows.

The layout is not an implementation detail you can ignore, because it is what the frame is built on. The
engine's render components (`Transform`, `Tint`, `Sprite`, `Material`, `Clip`) are FFI components, so their
columns are contiguous C memory; extraction walks those columns and writes instances straight into mapped GPU
staging, with no intermediate array. A loop that reads and writes columns is a loop the renderer is shaped
around.

## Entities, rows, and columns

Archetypes store entities by row. The same row index addresses the entity id and each of that entity's
component values:

- **Entity ids** live in `archetype.entities`. Rows are 1-based, and `entities[0]` stores the current length.
- **Rows** are the current positions inside an archetype. Use rows while iterating; do not cache them as stable
  identifiers, because despawns and archetype moves reorder rows.
- **Columns** hold component values for every row in the archetype. Bind columns with
  `archetype:get(Component)` for reads or `archetype:getMut(Component)` before writes, then index them by row.

This row and column layout is why query loops bind columns once per archetype:

```teal
local gfx <const> = tecs.gfx

for archetype, length, entities in query:iter() do
    local transforms = archetype:get(tecs.Transform)
    local tints = archetype:get(gfx.Tint)

    for row = 1, length do
        local entity = entities[row]
        local transform = transforms[row]
        local tint = tints[row]
        -- ...
    end
end
```

## Archetype properties

| Name            | Type          | Description                                                                                                                                                                                                |
| --------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`            | `integer`     | Unique identifier of the archetype in the world.                                                                                                                                                           |
| `entities`      | `DoubleArray` | Entity ids by row. `entities[0]` is the length; valid rows are `1..entities[0]`.                                                                                                                           |
| `componentList` | `{Component}` | Component types in this archetype's signature, in the order they were passed at construction. Finalized at creation: archetypes never add or remove components. Iterate with `#componentList` or `ipairs`. |

## Archetype methods

### get / getMut

Column access by component type. Both return the row-indexed column for a component the archetype carries, or
`nil` when it does not. The difference is dirty marking.

```teal
function Archetype:get<T is Component>(component: T): {T}
function Archetype:getMut<T is Component>(component: T): {T}
```

Use `get` when you only read values. Use `getMut` when you will write through the returned column: it marks
the component dirty on this archetype, which is what the render extraction and snapshot paths read to decide
what to re-sync. `get` does not protect the column from writes; it simply does not mark the component dirty.

Never take `getMut` for a column you only read. Doing it in a per-frame loop marks that component dirty on
every archetype every frame, and the extractor then rewrites the whole scene instead of the rows that changed.

```teal
local Transform <const> = tecs.Transform

for archetype, length in spinning:iter() do
    -- Rotation is a write, so the column is taken with getMut.
    local transforms = archetype:getMut(Transform)
    for row = 1, length do
        transforms[row].rotation = transforms[row].rotation + dt * 1.5
    end
end
```

### set

Replaces a component value at a row and marks the component dirty on the archetype. No archetype transition
happens; the row stays where it is. The component **must** already be present on the archetype, and the value
must carry a `componentType`; both are errors otherwise. Use `world:set` when you need to add a component to an
entity or move it to another archetype.

```teal
function Archetype:set<C is Component>(row: integer, value: C)
```

**Parameters:**

- `row`: The 1-based row position of the entity.
- `value`: The new component instance.

**Example:**

```teal
local Tint <const> = tecs.gfx.Tint

for archetype, length in query:iter() do
    for row = 1, length do
        -- Replace the component and mark dirty in one call.
        archetype:set(row, Tint(1, 0, 0, 1))
    end
end
```

For an FFI component the bytes are copied into the existing row rather than the row being repointed, so a
reference someone else took to that row stays valid.

### forEachRelationship

Iterates the relationship instances of the given relationship container for one row. Only concrete
relationship instances are visited; the container itself is not included.

```teal
function Archetype:forEachRelationship<T is Relationship>(
    relationshipContainer: T,
    row: integer,
    callback: function(T)
)
```

**Parameters:**

- `relationshipContainer`: The relationship container to iterate.
- `row`: The 1-based row position of the entity in this archetype.
- `callback`: Called with each relationship instance of this type.

**Example:**

```teal
local Likes = tecs.ecs.newRelationship({ name = "Likes", fields = { "weight" } })

archetype:forEachRelationship(Likes, 5, function(likes: Likes)
    print("Entity likes", likes.target)
end)
```

### getFirstRelationship

Gets the first relationship instance of the given container for one row, or `nil` when there is none. For an
exclusive relationship this is the single instance.

```teal
function Archetype:getFirstRelationship<T is Relationship>(relationshipContainer: T, row: integer): T
```

**Parameters:**

- `relationshipContainer`: The relationship container to retrieve a relationship from.
- `row`: The 1-based row position of the entity in this archetype.

**Returns:** the first relationship of this type for the entity, or `nil` if none exists.

::: info Sparse relationships are not archetype columns
Both methods above resolve the archetype's own per-target instance columns, which is where **dense**
relationships live. A sparse relationship (the builtin `ChildOf` is one) keeps its targets in a per-world
store and leaves only the container marker on the archetype, so ask the world instead:
`world:getFirstRelationship(entity, ChildOf)`, `world:targets`, `world:traverse`, `world:walkUp`. See
[Relationships](/ecs/relationships/).
:::

### markComponentDirty / markAllComponentsDirty

Explicit dirty markers for the case where mutation happens through a path the framework cannot intercept, for
example a wrapper that holds an entity id and writes through fetched FFI cdata.

```teal
function Archetype:markComponentDirty(component: Component)
function Archetype:markAllComponentsDirty()
```

`getMut`, `world:set`, `archetype:set`, spawn placement, and archetype move-in and swap-pop all mark dirty
internally. Reach for the explicit markers when none of those applies. `markComponentDirty` is idempotent, and
a component the archetype does not carry is a no-op.

### isComponentDirty / anyComponentDirty / dirtyComponents

Read dirty state.

```teal
function Archetype:isComponentDirty(component: Component): boolean
function Archetype:anyComponentDirty(): boolean
function Archetype:dirtyComponents(): function(): Component
```

This is the gate an incremental consumer writes. Render extraction is one: it rewrites an archetype's rows
only when one of the components it reads is dirty, when the rows moved, or when interpolation moved the drawn
position.

Bits are cleared at the end of each `world:update`, after the pipeline finishes.

## Observing entity lifecycle

`archetype:addEntityObserver(observer)` is the low-level lifecycle API for one archetype. The observer may
implement any subset of:

- `onEntitiesAdded(archetype, firstRow, lastRow, count, sourceArchetype?)`, per contiguous row range, where
  `sourceArchetype` is the archetype the range moved from and is `nil` for spawns;
- `onEntitiesRemoved(archetype, firstRow, lastRow, count, destArchetype?)`, per contiguous row range, where
  `destArchetype` is the archetype the range is moving to and is `nil` for despawns;
- `onEntityMove(archetype, entity, fromRow, toRow)` for swap-pop row moves;
- `onActivated(archetype)` and `onDeactivated(archetype)` for the empty and non-empty transitions;
- `onArchetypeDestroyed(archetype)` for permanent destruction during `world:compact()`, after which the
  observer must drop every reference to the archetype.

The observer remains attached for the archetype's lifetime. Registration applies only to that archetype
instance: it does not discover other archetypes with the same component signature, and there is no unsubscribe.

```teal
local observer: tecs.ArchetypeEntityObserver = {
    onActivated = function(
        _self: tecs.ArchetypeEntityObserver,
        activated: tecs.Archetype
    )
        print("archetype became active:", activated.id)
    end,
    onDeactivated = function(
        _self: tecs.ArchetypeEntityObserver,
        deactivated: tecs.Archetype
    )
        print("archetype became empty:", deactivated.id)
    end,
}

archetype:addEntityObserver(observer)
```

For component-filtered lifecycle callbacks across current and future matching archetypes, attach
[query callbacks](/ecs/queries/callbacks) (`onEntitiesAdded` / `onEntitiesRemoved`) to `world:query(...)`.
Queries handle discovery, filtering, and observer registration for you.

To discover new archetypes as they are created, observe the `ArchetypeCreated` event on the world (address 0).
See [Builtins](/ecs/builtins).
