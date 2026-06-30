---
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

See [Serialization](/tecs/components/serialization) for how components round-trip through save games, networking,
and the MCP server.
