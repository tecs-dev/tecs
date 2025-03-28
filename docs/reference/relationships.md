---
outline: deep
---

# Relationships

Relationships in Tecs provide a way to model connections between entities. They allow you to express relationships
like parent-child hierarchies, following behaviors, targeting systems, etc. Tecs automatically manages the
lifecycle of relationships, ensuring referential integrity when entities are despawned.

## Overview

A relationship is a special type of component that references another entity. This enables you to build complex entity
graphs and hierarchies. Relationship features in Tecs includes:

- **Automatic cleanup**: When a target entity is despawned, all relationships pointing to it are automatically removed
- **Type safety**: Relationships are strongly typed in Teal, providing compile-time guarantees
- **Efficient queries**: Query for entities with specific relationships or wildcard relationships
- **Flexible data**: Relationships can store just the target _or_ include additional data about the connection

## Creating simple relationships

Simple relationships store only the reference to the target entity. The `ChildOf` relationship in `tecs.builtins`
is a common example.

Simple relationships are created by calling `newRelationship` without providing a `container`:

```lua
local tecs = require("tecs")

-- Creates a simple relationship
local Likes = tecs.newRelationship({name = "Likes"})
local Follows = tecs.newRelationship({name = "Follows", exclusive = true})
local TargetOf = tecs.newRelationship({name = "TargetOf"})
```

These relationships track which entity is related to which target entity.

## Creating tag relationships (high performance)

For better performance when you only need the target reference, use `newTagRelationship`. This creates relationships
backed by efficient FFI storage that only stores the target entity ID:

```lua
local tecs = require("tecs")

-- Creates a tag relationship with FFI storage
local FastFollows = tecs.newTagRelationship({
    name = "FastFollows",
    exclusive = true,
    onAdd = function(component, world, entityId, changes)
        print("Entity " .. entityId .. " is now following " .. component.target)
    end,
    onRemove = function(component, world, entityId, changes)
        print("Entity " .. entityId .. " stopped following " .. component.target)
    end
})
```

Tag relationships support all the same options as regular relationships (including `onAdd` and `onRemove` hooks)
but are more memory-efficient for simple target-only relationships.

## Applying relationships

Relationships are applied just like any other component, because they are components!

```lua
-- Entity A likes Entity B
world:set(entityA, Likes(entityB))

-- Entity C follows Entity D
world:set(entityC, Follows(entityD))
```

## Creating relationships with data

Sometimes relationships need to carry additional information about the connection. For example, a "following"
relationship might specify a delay, or a "damage" relationship might specify the amount.

First, define a Teal record that implements `tecs.Relationship`:

```lua
local record Follows is tecs.Relationship
    delay: number
    maxDistance: number

    --- Relationship constructor
    metamethod __call: function(
        self,
        target: integer,
        delay: number,
        maxDistance: number
    ): self
end
```

Then create the relationship component:

```lua
tecs.newRelationship({
    name = "Follows",
    container = Follows,
    constructor = function(
        target: integer,
        delay: number,
        maxDistance: number
    ): Follows
        return {
            target = target,
            delay = delay or 0.5,
            maxDistance = maxDistance or 100
        }
    end
})
```

Using data relationships:

```lua
-- Entity follows target with 0.3 second delay and max distance of 50 units
world:set(follower, Follows(target, 0.3, 50))
```

## Creating FFI relationships

For relationships that need to store data along with the target, but want the performance benefits of FFI storage,
use `newFFIRelationship`. This creates relationships backed by FFI structs for optimal memory layout and performance:

```lua
local tecs = require("tecs")

-- Define the relationship record
local record FastFollows is tecs.Relationship
    delay: number
    maxDistance: number

    metamethod __call: function(
        self,
        target: integer,
        delay: number,
        maxDistance: number
    ): self
end

-- Create an FFI-backed relationship
local FastFollows = tecs.newFFIRelationship({
    name = "FastFollows",
    container = FastFollows,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"}
    },
    constructor = function(target, delay, maxDistance): FastFollows
        return {
            target = target,  -- target field is automatically included
            delay = delay or 0.5,
            maxDistance = maxDistance or 100.0
        }
    end,
    recycle = true,  -- Enable component recycling for better performance
    onAdd = function(component, world, entityId, changes)
        print("Entity " .. entityId .. " following " .. component.target ..
              " with delay " .. component.delay)
    end
})
```

FFI relationships provide:
- **High performance**: FFI struct storage with zero-copy operations
- **Memory efficiency**: Compact memory layout with component recycling
- **Type safety**: Strongly typed fields with compile-time guarantees
- **Full features**: Support for all relationship features including hooks

Note that the `target` field is automatically included in the FFI struct - you only need to specify additional data
fields.

## Exclusive relationships

By default, an entity can have multiple instances of the same relationship type pointing to different targets. Each
relationship instance (entity-to-target pair) is a unique component. For example, an entity can "like" multiple other
entities:

```lua
world:set(entity, Likes(entityA))
world:set(entity, Likes(entityB))
```

However, some relationships should be exclusive, meaning an entity can only have one instance. The `ChildOf`
relationship is exclusive because an entity can only have one parent:

```lua
local ChildOf = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true
})

world:set(child, ChildOf(parentA))
world:set(child, ChildOf(parentB))  -- Replaces parentA relationship
```

When an exclusive relationship is added, any existing instance is automatically removed.

## Querying relationships

Relationships can be queried like any other component, but with additional flexibility.

### Query for specific relationships

Find all entities with a relationship to a specific target using the `targeting()` method:

```lua
-- Find all children of entity 10
local children = world:query({
    include = {tecs.builtins.ChildOf:targeting(10)}
})

-- Iterate over matching entities
for archetype, len, entities in children() do
    for row = 1, len do
        local childId = entities[row]
        print("Found child:", childId)
    end
end
```

:::tip Using targeting() vs constructor calls
The `targeting()` method is the recommended way to get component types for specific targets. It works consistently for
both basic relationships and data relationships, eliminating the need to guess constructor arguments.
:::

### Query for any relationship

Find all entities that have any instance of a relationship type, regardless of target:

```lua
-- Find all entities that are children of any parent
local allChildren = world:query({
    include = {tecs.builtins.ChildOf}
})

-- Find all entities that follow something
local followers = world:query({
    include = {Follows}
})
```

::: details How this works
Under the hood, when a relationship is added to an entity, Tecs adds both the relationship _and_ a "wildcard"
relationship to the entity.
:::

### Accessing relationship data

When querying for relationship containers, you can access relationship data from each archetype. This is useful
because you might not know which concrete relationships exist for a wildcard relationship.

```lua
local query = world:query({
    include = {Follows}
})

for archetype, len, entities in query() do
    for row = 1, len do
        local entityId = entities[row]
        -- Get all Follows relationships for this entity
        for follow in archetype:getRelationships(Follows, row) do
            print(string.format("Entity %d follows %d with delay %.2f", entityId, follow.target, follow.delay))
        end
    end
end
```

You can access a specific relationship instance from the World when you know the target:

```lua
-- Get the specific Follows component targeting targetId
local follow = world:get(entityId, Follows:targeting(targetId))
if follow then
    print(string.format("Delay: %.2f", follow.delay))
end
```

## The targeting() method

The `targeting()` method provides a consistent API for querying specific relationship targets without having to
worry about relationship target constructors.

For example, let's say the `Follows` relationship requires additional data to create a `Follows` relationship to a
specific target (e.g., `delay`). The _identity_ of a `Follows` relationship to a target is only based on the
component type, `Follows`, and the target entity of the relationship. So if you wanted to query for entities that
follow entity `10`, you don't need to know their delays, but you also need a way to create an appropriate component to
find matching component instances. That's where `:targeting` comes in.

```lua
local likerQuery = world:query({
    include = {Follows:targeting(10)}
})
```

## Relationship lifecycle

### Automatic cleanup

When an entity is despawned, all relationships pointing to it are automatically removed. This prevents dangling
references and maintains referential integrity:

```lua
local parent = world:spawn()
local child1 = world:spawn(tecs.builtins.ChildOf(parent))
local child2 = world:spawn(tecs.builtins.ChildOf(parent))

-- Despawning the parent automatically removes ChildOf from both children
world:despawn(parent)

-- Children no longer have ChildOf component
assert(world:get(child1, tecs.builtins.ChildOf) == nil)
assert(world:get(child2, tecs.builtins.ChildOf) == nil)
```

### Cascading deletes

You can implement cascading deletions using relationship hooks. When a parent entity is despawned, Tecs automatically
removes all relationships pointing to it. You can use the `onRemove` hook to detect this and cascade the
deletion.

#### Simple cascade delete

The simplest approach despawns children whenever their `ChildOf` relationship is removed for any reason:

```lua
local ChildOf = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true,
    onRemove = function(self: tecs.Relationship, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Despawn this entity whenever ChildOf is removed
        world:despawn(entityId)
    end
})

-- Create parent-child hierarchy
local parent = world:spawn()
local child = world:spawn(ChildOf(parent))

-- Any of these will despawn the child:
world:despawn(parent)                 -- Parent despawned
world:remove(child, ChildOf)          -- Explicitly orphaned
world:set(child, ChildOf(newParent))  -- Reparented
```

::: tip Tecs has a built-in ChildOf relationship
The above example just shows how ChildOf could be implemented.
You don't need to make it yourself!
:::

#### Selective cascade delete

To delete children only when the parent is despawned (allowing orphaning and reparenting), check if the target entity
is still alive:

```lua
local ChildOf = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true,
    onRemove = function(self: tecs.Relationship, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Only despawn if parent was despawned
        if not world:isAlive(self.target) then
            world:despawn(entityId)
        end
        -- Otherwise allow orphaning/reparenting
    end
})

-- Create parent-child hierarchy
local parent = world:spawn()
local child = world:spawn(ChildOf(parent))

-- This despawns the child (parent is gone)
world:despawn(parent)

-- But these would keep the child alive:
-- world:remove(child, ChildOf)          -- Child becomes orphaned but lives
-- world:set(child, ChildOf(newParent))  -- Child gets new parent and lives
```

## Relationship constraints with hooks

Use component hooks to enforce constraints or add automatic dependencies:

```lua
local Follows = tecs.newRelationship({
    name = "Follows",
    container = FollowsType,
    constructor = followsConstructor,
    onAdd = function(self: FollowsType, world: tecs.World, entityId: integer, changes: tecs.ChangeView)
        -- Ensure follower has position component
        if not changes:has(Position) then
            changes:set(Position(0, 0))
        end

        -- Ensure follower has velocity for movement
        if not changes:has(Velocity) then
            changes:set(Velocity(0, 0))
        end
    end
})
```

## FFI Relationship Configuration

The `tecs.newFFIRelationship` function accepts a configuration table with these fields:

| Property | Description |
|----------|-------------|
| `name` | **Required** - The name of the FFI relationship |
| `container` | **Required** - Type for the FFI relationship data |
| `fields` | **Required** - Array of field tuples `{name, type}` for FFI struct definition |
| `exclusive` | Whether only one instance can exist per entity (default: `false`) |
| `recycle` | Enable component recycling for performance (default: `true`) |
| `initializer` | Validation and initialization function (optional) |
| `onAdd<R>` | Hook called when relationship of type `R` is added |
| `onRemove<R>` | Hook called when relationship of type `R` is removed |

### FFI Relationship Initializers

FFI relationships support initializers for validation and custom defaults:

```lua
initializer = function(constructor: function(...: any): Relationship, ...: any): Relationship
```

```lua
local SafeFollows = tecs.newFFIRelationship({
    name = "SafeFollows",
    container = FollowsType,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"}
    },
    initializer = function(
        constructor: function(...any): SafeFollows,
        target: integer,
        delay: number,
        maxDistance: number
    ): SafeFollows
        delay = math.max(0.1, delay or 0.5)  -- Minimum 0.1 second delay
        maxDistance = math.max(1, maxDistance or 100)  -- Minimum 1 unit distance
        return constructor(target, delay, maxDistance)
    end
})
```

## Configuration reference

The `tecs.newRelationship` function accepts a configuration table with these fields:

| Property | Description |
|----------|-------------|
| `name` | **Required** - The name of the relationship |
| `exclusive` | Whether only one instance can exist per entity (default: `false`) |
| `container` | Type for relationships with data. If omitted, creates a simple relationship |
| `constructor` | Function to create relationship instances. Cannot be used without `container` |
| `storage` | Custom storage implementation (defaults to table storage) |
| `onAdd<R>` | Hook called when relationship of type `R` is added |
| `onRemove<R>` | Hook called when relationship of type `R` is removed |

### Relationship API methods

All relationships created with `newRelationship` provide these methods:

- `Relationship(targetId, ...)` - Creates a relationship instance targeting the specified entity
- `Relationship:targeting(targetId)` - Returns the appropriate component for queries and world operations targeting the
  specified entity

### Constructor parameters

The constructor function receives:
1. `id` - The target entity ID (always first parameter)
2. Additional parameters for relationship data

```lua
constructor = function(targetId: integer, customData: string): MyRelationship
    return {customData = customData or "default"}
end
```
