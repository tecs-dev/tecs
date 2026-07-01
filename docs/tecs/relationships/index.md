---
outline: deep
---

# Relationships

Relationships model directed connections between entities, such as parent-child hierarchies, following
behaviors, or targeting. Tecs manages their lifecycle automatically, preserving referential integrity
when entities are despawned.

## Relationship features

- **Automatic cleanup**: When you despawn a target entity, Tecs automatically removes all relationships pointing to it
- **Type safety**: Relationships are strongly typed in Teal, providing compile-time guarantees
- **Efficient queries**: Query for entities with specific relationships or wildcard relationships
- **Flexible data**: Relationships can store just the target or include additional data about the connection
- **Sparse storage**: Relationships can opt into sparse storage to avoid per-target archetype fragmentation
- **Cascade delete**: Declarative cascade deletion for hierarchies like parent-child

## Kinds of relationships

`newRelationship` is the single entry point. What you pass decides the storage:

- **Target-only** (`newRelationship({name = "..."})`, no `fields`): the edge carries nothing but
  the target id. Backed by a compact FFI struct automatically.
- **Data-bearing, Lua payload** (`newRelationship` with a `container` and `fields`): the edge
  carries fields stored in a Lua table, so they can hold any Lua value.
- **Data-bearing, FFI payload** ([`newFFIRelationship`](/tecs/relationships/ffi)): the edge carries
  fields packed into an FFI struct for tight, cache-friendly storage.

## Creating simple relationships

A _simple relationship_ stores only the target entity id, with no extra data on the edge. Create
one by calling `newRelationship` with just a `name`:

```teal
local tecs = require("tecs")

-- "entity A Likes entity B": nothing is recorded but the target.
local Likes: tecs.Relationship = tecs.newRelationship({name = "Likes"})

-- Same target-only shape, but exclusive: one target at a time, so setting a
-- new target replaces the old one.
local Targets: tecs.Relationship = tecs.newRelationship({
    name = "Targets",
    exclusive = true
})
```

A target-only relationship is backed by a compact FFI struct. Behavior flags still apply:
`exclusive`, `sparse`, `reverseIndex`, and `cascadeDelete` all work here (see
[Exclusive](#exclusive-relationships), [Sparse](#sparse-relationships), and
[Cascade delete](#cascade-delete) below). Once the edge needs to carry data (a delay, a weight),
add a `container` with `fields` as shown next, or use
[FFI Relationships](/tecs/relationships/ffi).

## Applying relationships

Apply relationships like any other component, because they are components!

```teal
-- Entity A likes entities B and C (multiple targets)
world:set(entityA, Likes(entityB))
world:set(entityA, Likes(entityC))

-- Entity A targets a single enemy (exclusive: one target at a time)
world:set(entityA, Targets(enemy))
```

## Creating relationships with data

Sometimes relationships need to carry additional information about the connection. For example, a "following"
relationship might specify a delay.

First, define a Teal record that implements `tecs.Relationship`:

```teal
local record Follows is tecs.Relationship
    delay: number
    maxDistance: number

    --- Relationship creation. __call takes the target first; .new takes a
    --- config table with a target key.
    metamethod __call: function(
        self,
        target: integer,
        delay: number,
        maxDistance: number
    ): self
end
```

Then create the relationship component. Tecs writes `target` onto the returned instance for you;
you don't store it in `fields`.

Use `fields` (with optional `defaults`) to declare the data fields. The first positional argument
is always the target entity ID; the remaining arguments map to `fields` in order:

```teal
tecs.newRelationship({
    name = "Follows",
    container = Follows,
    fields = {"delay", "maxDistance"},
    defaults = {0.5, 100},
})
```

You now have both a positional and a table construction form:

```teal
-- Positional: target first, then fields in order
world:set(follower, Follows(target, 0.3, 50))

-- Table form: target is a key alongside the data
world:set(follower, Follows.new({ target = target, delay = 0.3, maxDistance = 50 }))
```

See [Component Construction](/tecs/components/construction) for the shared
`fields` / `defaults` / `init` / `.new` rules these inherit.

## Exclusive relationships

By default, an entity can have multiple instances of the same relationship type pointing to different targets. Each
unique target gets its own entry. For example, an entity can "like" multiple other entities:

```teal
world:set(entity, Likes(entityA))
world:set(entity, Likes(entityB))
```

Setting the same target again replaces the value for that target:

```teal
world:set(entity, Likes(entityA))  -- replaces the previous Likes(entityA)
```

Some relationships are marked as exclusive, meaning an entity can only have one target at a time. A
combat AI that `Targets` a single enemy is a natural fit:

```teal
local Targets: tecs.Relationship = tecs.newRelationship({
    name = "Targets",
    exclusive = true
})
```

When an exclusive relationship is set, any existing target is automatically replaced.
Setting `Targets(enemy2)` on an entity that already has `Targets(enemy1)` replaces it.

## Sparse relationships

By default, each unique target creates a distinct component type, which means entities with different targets
end up in different archetypes. This is efficient for querying specific targets but causes archetype fragmentation
when many distinct targets exist (e.g., a UI hierarchy with hundreds of parents).

The `sparse` flag stores relationship data in entity-indexed side storage instead of archetype columns. All entities
with the same sparse relationship share the same archetype regardless of their target:

```teal
local ChildOf: tecs.Relationship = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true,
    sparse = true,
    reverseIndex = true,    -- maintain inverse index for world:targets()
    cascadeDelete = true,   -- despawning parent despawns children
})
```

Sparse relationships work seamlessly with queries. A dense wildcard tag is always added to the archetype, so
`query({include = {ChildOf}})` matches entities with any ChildOf target. Accessing relationship data within a
query uses the same row-indexed pattern as dense columns:

```teal
local query: tecs.Query = world:query({include = {ChildOf, Transform}})

for archetype, len in query:iter() do
    local children = archetype:get(ChildOf)      -- row-indexed proxy
    local transforms = archetype:get(Transform)  -- dense column
    for row = 1, len do
        local childOf: ChildOf = children[row]        -- same pattern as dense access
        local parentId: integer = childOf.target
        -- ...
    end
end
```

You can also look up sparse relationship data per entity:

```teal
-- Get the ChildOf relationship for a specific entity.
local childOf: ChildOf = world:get(entity, ChildOf)
if childOf then
    print("Parent is:", childOf.target)
end

-- Check a specific target.
local rel: ChildOf = world:get(entity, ChildOf(someParent))
```

## Querying relationships

Query relationships like any other component, but with additional flexibility.

### Query for any relationship (wildcard)

Find all entities that have any instance of a relationship type, regardless of target. This works for
both dense and sparse relationships:

```teal
-- Find all entities that are children of any parent
local allChildren: tecs.Query = world:query({
    include = {tecs.builtins.ChildOf}
})

-- Find all entities that follow something
local followers: tecs.Query = world:query({
    include = {Follows}
})
```

::: details How this works
When a relationship is added to an entity, Tecs adds a "wildcard" tag (the relationship container) as a dense
archetype component. This enables efficient wildcard queries regardless of whether the relationship is sparse or dense.
:::

### Query for specific target (dense relationships)

For dense relationships, find all entities with a relationship to a specific target using the `:targeting()` method:

```teal
-- Find all followers of a specific leader
local query: tecs.Query = world:query({
    include = {Follows:targeting(leader)}
})
```

::: info Sparse relationships don't support :targeting() queries
Sparse relationships don't create per-target archetype components, so `:targeting()` is not available.
Use `world:targets()` for reverse lookups or `world:get(entity, Rel(target))` for forward lookups.
:::

### Filtering queries by relationships

You can combine relationships with other components in a single query. The query matches entities that have all
the specified components, and you read both component data and relationship data row-by-row.

**Example: render only entities that have a parent**

```teal
local query: tecs.Query = world:query({
    include = {Sprite, Transform, ChildOf}
})

for archetype, len, entities in query:iter() do
    local sprites = archetype:get(Sprite)
    local transforms = archetype:get(Transform)
    local parents = archetype:get(ChildOf)  -- works for both sparse and dense

    for row = 1, len do
        local sprite: Sprite = sprites[row]
        local transform: Transform = transforms[row]
        local parentId: integer = parents[row].target
        -- ...
    end
end
```

This is the most efficient way to iterate entities with both components and relationships: the wildcard tag on
the archetype narrows iteration to matching entities, and column-bound access avoids per-entity lookups.

**Example: filter to a specific target (dense relationships)**

For dense relationships, use `:targeting()` to narrow the archetype set to entities targeting one specific entity:

```teal
-- Find all sprites that follow a specific leader
local query: tecs.Query = world:query({
    include = {Sprite, Transform, Follows:targeting(leader)}
})
```

For sparse relationships, this isn't supported (no per-target archetypes). Filter inside the loop instead:

```teal
local query: tecs.Query = world:query({include = {Sprite, ChildOf}})

for archetype, len in query:iter() do
    local sprites = archetype:get(Sprite)
    local parents = archetype:get(ChildOf)
    for row = 1, len do
        if parents[row].target == specificParent then
            -- ...
        end
    end
end
```

If you need fast "find all entities targeting X" lookups for a sparse relationship, use `world:targets()`
instead of a query.

**Example: exclude entities that have a relationship**

Use the wildcard in `exclude` to find entities WITHOUT a relationship:

```teal
-- Find root entities (entities with Transform but no parent)
local query: tecs.Query = world:query({
    include = {Transform},
    exclude = {ChildOf}
})
```

### Accessing relationship data in queries

For dense relationships, access relationship data from each archetype:

```teal
for archetype, len, entities in query:iter() do
    for row = 1, len do
        archetype:forEachRelationship(Follows, row, function(follow: Follows)
            print(string.format("Entity %d follows %d", entities[row], follow.target))
        end)
    end
end
```

For sparse relationships, use the row-indexed column proxy:

```teal
for archetype, len in query:iter() do
    local children = archetype:get(ChildOf)
    for row = 1, len do
        local childOf: ChildOf = children[row]
        if childOf then
            print("Parent:", childOf.target)
        end
    end
end
```

## Cascade delete

The `cascadeDelete` flag causes all source entities to be automatically despawned when their target is despawned.
This is how `ChildOf` implements parent-child hierarchies: despawning a parent automatically despawns all children
(and grandchildren, recursively).

```teal
local ChildOf: tecs.Relationship = tecs.newRelationship({
    name = "ChildOf",
    exclusive = true,
    sparse = true,
    reverseIndex = true,
    cascadeDelete = true,
})

local parent: integer = world:spawn()
local child: integer = world:spawn(ChildOf(parent))
local grandchild: integer = world:spawn(ChildOf(child))

-- Despawning parent cascades through the hierarchy.
world:despawn(parent)
world:update(0)
-- parent, child, and grandchild are all despawned.
```

Removing a relationship (without despawning the target) does NOT trigger cascade delete. This allows
safe reparenting:

```teal
-- Orphan the child (remove relationship, keep both entities alive)
world:remove(child, ChildOf)

-- Reparent (exclusive replaces old target, no cascade)
world:set(child, ChildOf(newParent))
```

`cascadeDelete` requires `exclusive = true` and `reverseIndex = true`. It works for both sparse and dense
relationships.

## Hierarchy traversal

Relationships with `reverseIndex = true` maintain an inverse index that enables efficient reverse lookups.
This works for both sparse and dense relationships; the only difference is where forward data is stored.

### world:targets

Invokes a callback once for every source entity targeting the given entity:

```teal
-- Get all children of a parent.
world:targets(parent, ChildOf, function(childId: integer)
    print("Child:", childId)
end)
```

`world:targets` accepts an optional `context` value that is forwarded to the callback as its
**second** argument. This lets you hoist the visitor function to module/plugin scope and
keep its accumulator state on the context table, avoiding per-call closure allocation in hot
paths:

```teal
-- Hoisted once at plugin scope.
local visitorCtx: {count: integer} = {count = 0}
local function countChild(_childId: integer, ctx: {count: integer})
    ctx.count = ctx.count + 1
end

-- Per call: zero new closures.
visitorCtx.count = 0
world:targets(parent, ChildOf, countChild, visitorCtx)
```

Callbacks declared with a single parameter (`function(childId: integer)`) also work; Lua
silently drops the extra `context` argument when the callback doesn't declare it.

### world:traverse

Depth-first traversal over the full subtree of an entity:

```teal
-- Walk the entire hierarchy under root.
for depth, entityId in world:traverse(root, ChildOf) do
    local indent: string = string.rep("  ", depth)
    print(indent .. "Entity:", entityId)
end
```

### world:walkUp

Walks **up** a relationship chain from an entity to its root, calling a callback for each
ancestor. Follows the first target per level (equivalent to repeated `getFirstRelationship`),
so semantics match exclusive relationships like `ChildOf` exactly:

```teal
-- Print every ancestor of `entity`
world:walkUp(entity, ChildOf, function(ancestorId: integer, depth: integer)
    print(depth, ancestorId)
end)
```

Like `world:targets`, an optional `context` is forwarded to the callback (third argument):

```teal
-- Sum scroll offsets up the parent chain, no closure allocation
local accum = {x = 0.0, y = 0.0, offsets = scrollOffsets}
local function sumOffset(ancestorId: integer, _depth: integer, ctx: typeof(accum))
    local off = ctx.offsets[ancestorId]
    if off then
        ctx.x = ctx.x + off[1]
        ctx.y = ctx.y + off[2]
    end
end

world:walkUp(entity, ChildOf, sumOffset, accum)
```

The callback may return `false` to stop the walk early; any other return value (including
`nil` or no return) continues. The optional `maxDepth` parameter (default 100) is a safety
cap; exceeding it raises an error so accidental cycles surface immediately rather than
silently truncating.

All three methods require a relationship with `reverseIndex = true` (sparse or dense).

## Removing relationships

Remove a specific target with the relationship instance:

```teal
-- Remove Likes(entityB) but keep Likes(entityA)
world:remove(entity, Likes(entityB))
```

Remove all targets with the relationship container:

```teal
-- Remove ALL Likes relationships from entity
world:remove(entity, Likes)
```

When the last relationship of a type is removed from an entity, the entity leaves queries that include
that relationship.

## Configuration reference

The `tecs.newRelationship` function accepts a configuration table with these fields:

| Property        | Description                                                                                                                    |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `name`          | **Required** - The name of the relationship                                                                                    |
| `exclusive`     | Whether only one target can exist per entity (default: `false`)                                                                |
| `sparse`        | Use entity-indexed storage instead of per-target archetype components (default: `false`)                                       |
| `reverseIndex`  | Maintain an inverse index for `world:targets()`, `world:traverse()`, and `world:walkUp()` (works on sparse or dense)           |
| `cascadeDelete` | Despawning the target despawns all source entities. Requires `exclusive` and `reverseIndex`.                                   |
| `container`     | Type for relationships with data. If omitted, creates a simple relationship.                                                   |
| `fields`        | Ordered field names for the generated positional base shape.                                                                    |
| `defaults`      | Default values for `fields`, in matching order (`nil` = no default). Requires `fields`.                                        |
| `init`          | Optional hook to validate or refine a relationship instance after allocation. Requires `container`, plus `fields` or `new`.    |
| `transient`     | If `true`, omit this relationship from snapshots. Mutually exclusive with `serialize`.                                         |

To run code when a relationship is added or removed, create a query on the
relationship (or its wildcard container) and attach
[`onEntitiesAdded` / `onEntitiesRemoved`](/tecs/queries/callbacks).

### Relationship API methods

All relationships provide these methods:

- `Relationship(targetId, ...)` - Creates a relationship instance targeting the specified entity
- `Relationship:targeting(targetId)` - Returns the component for target-specific queries (dense relationships only)

World methods for relationships with `reverseIndex = true`:

- `world:targets(entity, Relationship, callback, context?)` - Invokes `callback(sourceId, context)`
  for each source entity targeting `entity`. `context` is optional and forwarded to the callback unchanged.
- `world:traverse(root, Relationship)` - DFS iterator yielding `(depth, entityId)` for the full subtree
- `world:walkUp(entity, Relationship, callback, context?, maxDepth?)` - Walks up the parent chain
  from `entity`, invoking `callback(ancestorId, depth, context)` for each ancestor. Return `false`
  from the callback to stop early. `maxDepth` defaults to 100; exceeding it raises an error.

### Data fields and initialization

Relationships follow the same positional-plus-table pattern as regular components. See
[Component Construction](/tecs/components/construction) for the full shared
rules (`fields` / `defaults` / `init` / `new`, validation, and when to reach
for each). A few details are relationship-specific:

- **Target is always required.** Every relationship carries a target entity id, written
  onto the instance by Tecs. In the positional form it's the first argument
  (`Rel(targetId, ...)`); in the table form it's the `target` key
  (`Rel.new({ target = id, ... })`).
- **`fields` lists data fields only.** Don't include `"target"`; it's implicit and
  set by the framework. Positional args after the target map to `fields` in order.
- **`init` signature starts with `instance, targetId`.** `function(instance, targetId, field1, field2, ...)`.
  When paired with `fields`, it refines the allocated instance while `fields` drives
  the base positional mapping and `.new`.

Reusing the `Follows` relationship from
[Creating relationships with data](#creating-relationships-with-data) (`fields = {"delay", "maxDistance"}`,
`defaults = {0.5, 100}`), positional arguments fill `fields` left to right and `defaults` cover any omitted:

```teal
-- Positional: target first, then fields in order
Follows(target)          -- {delay = 0.5, maxDistance = 100, target = …}
Follows(target, 0.2)     -- {delay = 0.2, maxDistance = 100, target = …}
Follows(target, 0.2, 50) -- {delay = 0.2, maxDistance = 50, target = …}

-- Table form names them instead
Follows.new({ target = target, delay = 0.2, maxDistance = 50 })
```

`fields` and `init` can coexist. Use a custom `init` hook when you need
non-trivial initialization (validation, derived values, external resources); pair
it with `fields` so `.new` still codegens:

```teal
local record CustomRel is tecs.Relationship
    customData: string
    metamethod __call: function(self, target: integer, customData: string): CustomRel
end

tecs.newRelationship({
    name = "CustomRel",
    container = CustomRel,
    fields = {"customData"},
    init = function(instance: CustomRel, _targetId: integer, customData: string)
        assert(customData, "CustomRel requires customData")
        instance.customData = customData
    end,
})
```

Snapshot deserialize for relationships routes through `.new(data)` where `data.target`
is the restored target id, identical in shape to the table form above.

## Relationship lifecycle

### Automatic cleanup

When you despawn an entity, Tecs automatically removes all relationships pointing to it. For sparse relationships
with `cascadeDelete`, source entities are also despawned recursively.

### Dense relationship cleanup

For dense relationships, when a target entity is despawned, Tecs removes the relationship components from all
source entities. To run cleanup logic, attach `onEntitiesRemoved` to a query whose `include` contains the
relationship (or its wildcard container); the callback fires for each archetype that loses members.
