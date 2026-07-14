---
description: "Component overview with world get, getMut, set, remove, has, requires, and transient"
outline: deep
---

# Components

A component is a plain data object attached to an entity. Components describe traits like position, velocity,
or health, and are the building blocks of game state.

## Component types

Tecs provides several component kinds for different use cases.

* [Table component](/tecs/components/table-components): backed by a Lua table. Use this when the data can't fit a
  fixed C struct: strings, nested tables, Love2D handles, or any value needing Lua reference semantics.
* [Tag component](/tecs/components/tag-components): carries no data; presence is the whole signal.
* [FFI component](/tecs/components/ffi): backed by an FFI struct. Use this for numeric and primitive data that
  maps cleanly to fixed-size C fields.
* [Scalar component](/tecs/components/scalar-components): a single string, number, or boolean value. Use this
  when a component is really just one value (e.g., `Health`).

## World methods

These methods are available on every `World`.

| Method | Description |
| ------ | ----------- |
| [`world:get`](#world-get) | Return one component from an entity. |
| [`world:getMut`](#world-get-mut) | Return a component for in-place mutation and mark its column dirty. |
| [`world:getFirstRelationship`](#world-get-first-relationship) | Return the first relationship instance for a relationship container. |
| [`world:has`](#world-has) | Check whether an entity has a component or relationship target. |
| [`world:set`](#world-set) | Attach or replace a component on an entity. |
| [`world:remove`](#world-remove) | Remove a component from an entity. |
| [`world:markComponentDirty`](#world-mark-component-dirty) | Mark a component column dirty for one entity's archetype. |

### world:get {#world-get}

Retrieves a component from an entity.

```teal
function World:get<T is Component>(entity: integer, component: T): T
```

**Parameters:**

- `entity`: Entity ID.
- `component`: Component type or relationship instance to retrieve.

**Returns:**

- The component instance, or `nil` if not found.

### world:getMut {#world-get-mut}

Mutable counterpart to `world:get`. It returns the component and marks that component dirty on the entity's archetype.
Use this whenever you intend to mutate the returned reference in place.

```teal
function World:getMut<T is Component>(entity: integer, component: T): T
```

**Parameters:**

- `entity`: Entity ID.
- `component`: Component type or relationship instance to get and mark dirty.

**Returns:**

- The component instance, or `nil` if not found.

See [Dirty tracking](/tecs/components/dirty-tracking) for when dirty marks are needed.

### world:getFirstRelationship {#world-get-first-relationship}

Returns the first relationship instance for a relationship container on an entity. For exclusive relationships, this is
the single instance.

```teal
function World:getFirstRelationship<T is Relationship>(entity: integer, relationship: T): T
```

**Parameters:**

- `entity`: Entity ID.
- `relationship`: Relationship container type.

**Returns:**

- The relationship instance, or `nil` if not found.

### world:has {#world-has}

Checks whether an entity currently has a component.

```teal
function World:has(entity: integer, component: Component): boolean
```

For sparse relationships, passing the relationship container checks whether the entity has any target for that
relationship; passing a relationship instance checks for that specific target.

```teal
world:has(entity, Health)
world:has(entity, ChildOf)
world:has(entity, ChildOf(specificParent))
```

### world:set {#world-set}

Attaches or replaces a component on an entity.

```teal
function World:set(entity: integer, component: Component, value?: any)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: Component instance to attach, or a component type when using the optional scalar value form.
- `value`: Optional raw value for scalar component writes.

This is a [deferred operation](/tecs/world#deferred-operations) inside query iteration, callbacks, explicit defer
scopes, and batch callbacks.

### world:remove {#world-remove}

Removes a component from an entity.

```teal
function World:remove(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: Component type or relationship instance to remove.

This is a [deferred operation](/tecs/world#deferred-operations) inside query iteration, callbacks, explicit defer
scopes, and batch callbacks.

### world:markComponentDirty {#world-mark-component-dirty}

Marks a component dirty on the entity's archetype. Prefer `world:getMut(entity, component)` when you are fetching and
then mutating the component; use this when you already have a reference from another path.

```teal
function World:markComponentDirty(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: Component type whose column was mutated.

See [Dirty tracking](/tecs/components/dirty-tracking) for the full dirty-bit model.

## Getting components

Access an entity's components with `world:get`.

```teal
local name = world:get(entityId, tecs.builtins.Name)
```

::: details Component access is typed
Tecs is built from the ground-up to be strongly typed with [Teal](https://teal-language.org); the `get` method is
generic over the provided component type. So in the above example, the return value of `get` is an instance of
`tecs.builtins.Name` or `nil` if not found.
:::

## Setting components

Set components on entities with `world:set`.

```teal
world:set(entityId, tecs.builtins.Name("Frank"))
```

You can also set components when spawning an entity.

```teal
world:spawn(
    tecs.builtins.Name("Frank"),
    tecs.builtins.Position(100, 200)
)
```

## Removing components

Remove components from entities with `world:remove`.

```teal
world:remove(entityId, tecs.builtins.Name)
```

## Getting components from archetypes

When iterating entities in a system, the query gives you the archetype directly. You can bind the component's
column once and then index by row, avoiding per-entity lookups:

```teal
local query: tecs.Query = world:query({include = {Position, Velocity}})

world:addSystem({
    name = "Movement",
    phase = tecs.phases.Update,
    run = function(dt: number, _world: tecs.World)
        for archetype, length in query:iter() do
            local positions = archetype:getMut(Position)  -- bind column, mark dirty
            local velocities = archetype:get(Velocity)        -- read-only column
            for row = 1, length do
                positions[row].x = positions[row].x + velocities[row].x * dt
                positions[row].y = positions[row].y + velocities[row].y * dt
            end
        end
    end
})
```

This is significantly faster than calling `world:get` per entity because the archetype and column are already
known: each access is just an array index.

## Auto-dependencies with `requires`

Declare components that must accompany another component using `requires`. When a component with `requires` is
added to an entity (via `world:set`, `world:spawn`, or any other path), every listed component that is not
already present is added in the same archetype transition, so the entity skips intermediate archetypes.

Entries may be either component **types** (the container is called with no args to produce a default instance)
or instance values (shared by every entity that auto-adds the dependency). The closure is transitive: if a
required component itself declares `requires`, those are pulled in too.

```teal
local record Position is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Position
end

local record Velocity is tecs.Component
    vx: number
    vy: number
    metamethod __call: function(self, vx?: number, vy?: number): Velocity
end

tecs.newComponent({
    name = "Position",
    container = Position,
    fields = {"x", "y"},
    defaults = {0, 0},
})

tecs.newComponent({
    name = "Velocity",
    container = Velocity,
    fields = {"vx", "vy"},
    defaults = {0, 0},
    requires = {Position},  -- Velocity implies Position
})

-- Spawning Velocity auto-adds a default Position in the same transition.
local entity: integer = world:spawn(Velocity(10, 20))
assert(world:get(entity, Position) ~= nil)
```

For lifecycle reactions ("run code when an entity gains or loses this component"), use
[query callbacks](/tecs/queries/callbacks): `onEntitiesAdded` and `onEntitiesRemoved` on
`world:query(...)`.

## Transient components

Set `transient = true` on any component or relationship whose value is runtime projection state rather than
durable world state.

[Snapshot saves](/tecs/save-games) skips transient component columns while keeping the entity itself. After load,
recreate the transient component from durable source-of-truth components during normal systems or
`FinishSnapshotLoad`.

```teal
tecs.newFFIComponent({
    name = "SpriteData",
    container = SpriteData,
    transient = true,
    fields = {
        {"width", "float"},
        {"height", "float"},
    }
})
```

`transient = true` is mutually exclusive with `serialize`. The option is accepted by `newComponent`, `newFFIComponent`,
`newTagComponent`, `newScalarComponent`, `newRelationship`, and `newFFIRelationship`.

See [Serialization](/tecs/components/serialization#skipping-a-component-from-snapshots) for examples and save/load
guidance.
