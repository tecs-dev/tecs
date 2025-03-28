---
outline: deep
---

# Archetypes

Archetypes organize entities by their component composition for efficient querying and iteration.
Each entity in Tecs belongs to exactly one archetype, which is determined by the entity's specific combination of
components. When a component is added or removed from an entity, the entity changes archetypes.

## Entities, rows, and columns

* **Entities**: Identified by unique IDs, entities are stored in the `entities` array of an archetype. Their index
  in this array is their "row".
* **Rows**: The position of an entity within an archetype. When a component operation needs to access entity
  data, it uses the row index, not the entity ID.
* **Columns**: Each component in an archetype has its own "column", an array containing component data for all
  entities in the archetype. These columns are accessed by component type and indexed by row position. This kind of
  access is called a _structure of arrays_, or SOA.

This design enables high-performance iteration over entities with the same component structure, as component data is
stored in contiguous memory blocks.

## Archetype interface

```lua
--- An archetype is a collection of entities with the same components.
interface Archetype
    --- The unique identifier of the archetype in the ECS container.
    id: integer

    --- An immutable array of entity IDs that belong in this archetype.
    entities: {integer}

    --- The raw mapping of component types to their column of data.
    columns: {Component: {Component}}

    --- The number of columns in this archetype.
    columnsCount: integer

    --- A hash of the components in this archetype.
    componentHash: integer

    --- Provides a type-safe way to get a component column for a component type using normal table access.
    ---
    --- Note: we don't actually use __index to access components. This is simply to satisfy Teal.
    ---
    --- @param component The component type to get the column for.
    --- @return The column of component data for the specified component type or nil.
    metamethod __index: function<C is Component>(self: Archetype, component: C): {C}

    --- Gets a component value for a specific entity in this archetype.
    ---
    --- @param component The component type to retrieve.
    --- @param row The row position of the entity in this archetype (not the entity ID).
    --- @return The component value, or nil if the component or entity doesn't exist in this archetype.
    get: function<T is Component>(self, component: T, row: integer): T

    --- Checks if this archetype exactly matches the given components.
    ---
    --- @param components The components to check against this archetype.
    --- @return true if this archetype matches the components exactly, false otherwise.
    isExactMatch: function(self, components: {Component}): boolean

    --- Checks if this archetype has any of the given components.
    ---
    --- @param components The components to check for.
    --- @return true if this archetype has at least one of the components, false otherwise.
    hasAnyOf: function(self, components: {Component}): boolean


    --- Creates an iterator for all relationship instances of the given relationship container for an entity.
    ---
    --- @param relationshipContainer The relationship container to retrieve relationships from.
    --- @param row The row position of the entity in this archetype (not the entity ID).
    --- @return A lazy iterator that yields each relationship of this type for the given entity.
    getRelationships: function<T is Relationship>(self, relationshipContainer: T, row: integer): function(): T

    --- Gets the first relationship instance of the given relationship container for an entity, if any.
    ---
    --- @param relationshipContainer The relationship container to retrieve a relationship from.
    --- @param row The row position of the entity in this archetype (not the entity ID).
    --- @return The first relationship of this type for the given entity, or nil if none exists.
    getFirstRelationship: function<T is Relationship>(self, relationshipContainer: T, row: integer): T
end
```

## ArchetypeChangeObserver interface

Changes to archetypes are emitted to `ArchetypeChangeObserver` instances.

:::tip You probably won't use this
This is a more advanced interface that is primarily used to keep queries continuously updated. You likely don't need
to interact directly with archetype ChangeObserver directly.
:::

```lua
--- An observer interface for monitoring changes to archetypes.
interface ArchetypeChangeObserver
    --- Called when a new archetype is created.
    ---
    --- @param archetype The newly created archetype.
    onNewArchetype: function(self, archetype: Archetype)

    --- Called when an entity is added to, removed from, or changes archetypes.
    ---
    --- @param id The entity ID that changed.
    --- @param from The archetype the entity was previously in, or nil if the entity was just spawned.
    --- @param to The archetype the entity moved to, or nil if the entity was despawned.
    --- @param row The row position of the entity in the new archetype (only applicable when 'to' is not nil).
    onEntityChange: function(self, id: integer, from: Archetype, to: Archetype, row: integer)
end
```

Change observers are notified when:
1. A new entity is added to an archetype
2. An entity is removed because it was despawned
3. An entity moves from one archetype to another due to component changes

## Archetype methods

### get

Gets a component value for a specific entity in this archetype.

```lua
function Archetype:get<T is Component>(component: T, row: integer): T
```

**Parameters:**

- `component`: The component type to retrieve
- `row`: The row position of the entity in this archetype (not the entity ID)

**Returns:**

- The component value, or `nil` if the component or entity doesn't exist in this archetype

**Example:**

```lua
-- Assuming entity with ID 42 is at row 3 in the archetype
-- Get the Position component for this entity
local position = archetype:get(Position, 3)
if position then
    print("Entity position:", position.x, position.y)
end
```

### getColumn

Gets the entire column of components of a specific type from this archetype.

```lua
function Archetype:getColumn<T is Component>(component: T): {T}
```

**Parameters:**

- `component`: The component type to retrieve

**Returns:**

- An array of component values indexed by entity position, or `nil` if the component is not found

**Example:**

```lua
-- Get all Position components in this archetype
local positions = archetype:getColumn(Position)

-- Access the position component of the entity in row 7
print(positions[7].x, positions[7].y)
```

You can also just index into the archetype by the component:

```lua
local positions = archetype[Position]
print(positions[7].x, positions[7].y)
```

### getRelationships

Creates an iterator for all relationship instances of the given relationship container for an entity.

```lua
function Archetype:getRelationships<T is Relationship>(relationshipContainer: T, row: integer): function(): T
```

**Parameters:**

- `relationshipContainer`: The relationship container to retrieve relationships from
- `row`: The row position of the entity in this archetype (not the entity ID)

**Returns:**

- A lazy iterator that yields each relationship of this type for the given entity

**Example:**

```lua
-- Assume there is a Likes relationship.
local Likes = tecs.newRelationship({name = "Likes"})

-- Get the entity ID at row 5.
local entity = archetype.entities[5]

-- Get all Like relationships for entity at row 5.
for likes in archetype:getRelationships(Likes, 5) do
    print("Entity", entity, "likes", likes.target)
end
```

### getFirstRelationship

Gets the first relationship instance of the given relationship container for an entity, if any.

```lua
function Archetype:getFirstRelationship<T is Relationship>(relationshipContainer: T, row: integer): T
```

**Parameters:**

- `relationshipContainer`: The relationship container to retrieve a relationship from
- `row`: The row position of the entity in this archetype (not the entity ID)

**Returns:**

- The first relationship of this type for the given entity, or `nil` if none exists

**Example:**

```lua
-- Assume there is a Likes relationship.
local Likes = tecs.newRelationship({name = "Likes"})

-- Get the entity ID at row 5.
local entity = archetype.entities[5]

-- Get all Like relationships for entity at row 5.
local likes = archetype:getFirstRelationship(Likes, 5)
if likes then
    print("Entity likes parent:", likes.target)
end
```

### isExactMatch

Checks if this archetype exactly matches the given components.

```lua
function Archetype:isExactMatch(components: {Component}): boolean
```

**Parameters:**

- `components`: The components to check against this archetype

**Returns:**

- `true` if this archetype matches the components exactly, `false` otherwise

**Example:**

```lua
local componentSet = {Position, Velocity}
if archetype:isExactMatch(componentSet) then
    print("Archetype is an exact match for Position and Velocity")
else
    print("Archetype has different components")
end
```

:::info Note
This method is generally used by the framework and should rarely need to be used in user code.
:::

### hasAnyOf

Checks if this archetype has any of the given components.

```lua
function Archetype:hasAnyOf(components: {Component}): boolean
```

**Parameters:**

- `components`: The components to check for

**Returns:**

- `true` if this archetype has at least one of the components, `false` otherwise

**Example:**

```lua
local componentSet = {Position, Velocity, Health}
if archetype:hasAnyOf(componentSet) then
    print("Archetype has at least one of: Position, Velocity, or Health")
else
    print("Archetype has none of these components")
end
```

:::info Note
This method is generally used by the framework and should rarely need to be used in user code.
:::

## Working with Archetypes

### Iterating through all entities in an Archetype

```lua
local positions = archetype[Position]
local velocities = archetype[Velocity]

for row = 1, #archetype.entities do
    local position = positions[row]
    local velocity = velocities[row]
    -- Process entity
    position.x = position.x + velocity.x * dt
    position.y = position.y + velocity.y * dt
end
```
