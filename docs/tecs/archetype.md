---
description: "Archetype storage groups with row/column layout, get and getMut column access, set, relationship iteration, and dirty tracking"
outline: deep
---

# Archetypes

An archetype is a storage group for entities with the same component signature. Each entity belongs to exactly one
archetype at a time. When an entity gains or loses a component, it moves to another archetype.

Most code reaches archetypes through [queries](/tecs/queries/). A query finds the archetypes whose signatures
match its descriptor, then each loop step gives you an archetype, a row count, and the entity IDs for those rows.

## Entities, rows, and columns

Archetypes store entities by row. The same row index addresses the entity ID and each of that entity's component
values:

* **Entity IDs** live in `archetype.entities`. The array is 1-based, and `entities[0]` stores the current length.
* **Rows** are the current positions inside an archetype. Use rows while iterating; don't cache them as stable
  identifiers because despawns and archetype moves can reorder rows.
* **Columns** store component values for every row in the archetype. Bind columns with
  `archetype:get(Component)` for reads or `archetype:getMut(Component)` before writes, then index them by row.

This row/column layout is why query loops bind columns once per archetype:

```teal
for archetype, len, entities in query:iter() do
    local transforms = archetype:get(Transform)
    local sprites = archetype:get(Sprite)

    for row = 1, len do
        local entity = entities[row]
        local transform = transforms[row]
        local sprite = sprites[row]
        -- ...
    end
end
```

## Archetype properties

| Name            | Type                               | Description                                                                                                        |
| --------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `id`            | `integer`                          | Unique identifier of the archetype.                                                                                |
| `entities`      | `DoubleArray`                      | Entity IDs by row. `entities[0]` is the length; valid rows are `1..entities[0]`.                                    |
| `componentList` | `{Component}`                      | Component types in this archetype's fixed signature. Use `#componentList` / `ipairs` to inspect the signature.      |
| `columns`       | `{Component: {Component}}`         | Raw data columns. Treat as read-only; prefer `get` / `getMut` so sparse relationship proxies and dirty marking work correctly. |

## Archetype methods

### get / getMut

Column access by component type. Both methods return the row-indexed column for a component when one exists. The
difference is dirty marking.

```teal
function Archetype:get<T is Component>(component: T): {T}
function Archetype:getMut<T is Component>(component: T): {T}
```

Use `get` when you only read values. Use `getMut` when you will mutate values through the returned column. `getMut`
marks the component dirty on the archetype so incremental-sync consumers such as renderer shadow buffers and
snapshots can resync.

`get` does not protect the column from writes; it simply does not mark the component dirty.

```teal
for archetype, len in query:iter() do
    local transforms = archetype:getMut(Transform)
    local velocities = archetype:get(Velocity)  -- read-only
    for row = 1, len do
        transforms[row].x = transforms[row].x + velocities[row].x * dt
    end
end
```

### set

Replaces a component value at a row and marks the component dirty on the archetype. No archetype transition
happens; the row stays where it is. The component **must** already be present on the archetype. Use `world:set`
when you need to add a component to an entity or move it to another archetype.

```teal
function Archetype:set<C is Component>(row: integer, value: C)
```

**Parameters:**

- `row`: The 1-based row position of the entity.
- `value`: The new component instance.

**Example:**

```teal
for archetype, len in query:iter() do
    for row = 1, len do
        -- Replace the component and mark dirty in one call.
        archetype:set(row, Color(1, 0, 0, 1))
    end
end
```

### forEachRelationship

Iterates all relationship instances of the given relationship container for an entity. Only concrete
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
local Likes = tecs.newRelationship({name = "Likes"})

archetype:forEachRelationship(Likes, 5, function(likes: Likes)
    print("Entity likes", likes.target)
end)
```

### getFirstRelationship

Gets the first relationship instance of the given relationship container for an entity, if any. For
exclusive relationships (e.g. `ChildOf`) this is the single instance.

```teal
function Archetype:getFirstRelationship<T is Relationship>(relationshipContainer: T, row: integer): T
```

**Parameters:**

- `relationshipContainer`: The relationship container to retrieve a relationship from.
- `row`: The 1-based row position of the entity in this archetype.

**Returns:**

- The first relationship of this type for the entity, or `nil` if none exists.

**Example:**

```teal
local ChildOf = tecs.builtins.ChildOf

local childOf: ChildOf = archetype:getFirstRelationship(ChildOf, 5)
if childOf then
    print("parent id:", childOf.target)
end
```

### markComponentDirty / markAllComponentsDirty

Explicit dirty markers for cases where mutation happens through a
path the framework can't intercept.

```teal
function Archetype:markComponentDirty(component: Component)
function Archetype:markAllComponentsDirty()
```

`getMut`, `world:set`, `archetype:set`, spawn, and archetype
move-in / swap-pop all mark dirty internally. Reach for the explicit
markers when none of those apply.

### isComponentDirty / anyComponentDirty / dirtyComponents

Read dirty state.

```teal
function Archetype:isComponentDirty(component: Component): boolean
function Archetype:anyComponentDirty(): boolean
function Archetype:dirtyComponents(): function(): Component
```

Bits are cleared automatically at the end of each `world:update`.

### clearDirtyComponents

Clear every component-dirty bit on this archetype. The world's
end-of-update loop calls this for each archetype that touched the
dirty set during the frame; callers rarely invoke it directly.

```teal
function Archetype:clearDirtyComponents()
```

## Observing entity lifecycle

To receive callbacks when entities join or leave an archetype's match set, attach
[query callbacks](/tecs/queries/callbacks) (`onEntitiesAdded` / `onEntitiesRemoved`) to a
`world:query(...)`. Queries handle archetype discovery, filtering, and observer registration for you.

To discover new archetypes as they're created, observe the
[`ArchetypeCreated`](/tecs/builtins#archetypecreated-event) event on the world (address 0).
