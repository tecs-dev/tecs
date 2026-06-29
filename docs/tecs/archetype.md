---
outline: deep
---

# Archetypes

Archetypes organize entities by their component composition for efficient querying and iteration.
Each entity in Tecs belongs to exactly one archetype. When a component is added or removed from an entity, the entity
changes archetypes.

## Entities, rows, and columns

* **Entities**: Unique IDs stored in the archetype's `entities` array. Their index in this array is their "row".
* **Rows**: The position of an entity within an archetype. Component operations use the row index, not the entity ID.
  Rows are **1-based**: the first entity in the archetype is at row 1, matching column array indexing.
* **Columns**: Each component has its own "column", an array containing component data for all entities in the
  archetype. Access columns by component type and index by row position. This layout is a _structure of arrays_, or SoA.

This design enables high-performance iteration over entities with the same component structure, as component data is
stored in contiguous memory blocks.

## Archetype properties

| Name            | Type          | Description                                                                                                |
| --------------- | ------------- | ---------------------------------------------------------------------------------------------------------- |
| `id`            | `integer`     | Unique identifier of the archetype.                                                                        |
| `entities`      | `DoubleArray` | 1-based array of entity IDs that belong in this archetype (`entities[0]` is the length).                   |
| `componentList` | `{Component}` | 1-based array of component types in this archetype, in construction order. Use `#componentList` for size. |

Per-component columns are accessed via `archetype:get(Component)` (read-only) or
`archetype:getMut(Component)` (read + dirty mark); see "get / getMut" below.

## Archetype methods

### set

Replaces a component value at a row and marks the component dirty on the archetype. No archetype transition
happens; the row stays where it is. The component **must** already be present on the archetype.

```lua
function Archetype:set<C is Component>(row: integer, value: C)
```

**Parameters:**

- `row`: The 1-based row position of the entity.
- `value`: The new component instance.

**Example:**

```lua
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

```lua
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

```lua
local Likes = tecs.newRelationship({name = "Likes"})

archetype:forEachRelationship(Likes, 5, function(likes: Likes)
    print("Entity likes", likes.target)
end)
```

### getFirstRelationship

Gets the first relationship instance of the given relationship container for an entity, if any. For
exclusive relationships (e.g. `ChildOf`) this is the single instance.

```lua
function Archetype:getFirstRelationship<T is Relationship>(relationshipContainer: T, row: integer): T
```

**Parameters:**

- `relationshipContainer`: The relationship container to retrieve a relationship from.
- `row`: The 1-based row position of the entity in this archetype.

**Returns:**

- The first relationship of this type for the entity, or `nil` if none exists.

**Example:**

```lua
local ChildOf = tecs.builtins.ChildOf

local childOf: ChildOf = archetype:getFirstRelationship(ChildOf, 5)
if childOf then
    print("parent id:", childOf.target)
end
```

### get / getMut

Read-only or mutating column access. Both return the row-indexed
column for a component (or nil if the archetype doesn't carry it);
the difference is dirty marking.

```lua
function Archetype:get<T is Component>(component: T): {T}
function Archetype:getMut<T is Component>(component: T): {T}
```

`getMut` flags the component dirty on the archetype so
incremental-sync consumers (renderer shadow buffers, snapshots) re-upload it.
Use it at every site you intend to write into the column, including
direct FFI cdata field writes that the framework can't observe.

```lua
for archetype, len in query:iter() do
    local transforms = archetype:getMut(Transform)
    local velocities = archetype:get(Velocity)  -- read-only
    for row = 1, len do
        transforms[row].x = transforms[row].x + velocities[row].x * dt
    end
end
```

### markComponentDirty / markAllComponentsDirty

Explicit dirty markers for cases where mutation happens through a
path the framework can't intercept.

```lua
function Archetype:markComponentDirty(component: Component)
function Archetype:markAllComponentsDirty()
```

`getMut`, `world:set`, `archetype:set`, spawn, and archetype
move-in / swap-pop all mark dirty internally. Reach for the explicit
markers when none of those apply.

### isComponentDirty / anyComponentDirty / dirtyComponents

Read dirty state.

```lua
function Archetype:isComponentDirty(component: Component): boolean
function Archetype:anyComponentDirty(): boolean
function Archetype:dirtyComponents(): function(): Component
```

Bits are cleared automatically at the end of each `world:update`.

### clearDirtyComponents

Clear every component-dirty bit on this archetype. The world's
end-of-update loop calls this for each archetype that touched the
dirty set during the frame; callers rarely invoke it directly.

```lua
function Archetype:clearDirtyComponents()
```

## Observing entity lifecycle

To receive callbacks when entities join or leave an archetype's match set, attach
[query callbacks](/tecs/queries/callbacks) (`onEntitiesAdded` / `onEntitiesRemoved`) to a
`world:query(...)`. Queries handle archetype discovery, filtering, and observer registration for you.

To discover new archetypes as they're created, observe the
[`ArchetypeCreated`](/tecs/builtins#archetypecreated-event) event on the world (address 0).
