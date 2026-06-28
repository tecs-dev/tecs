---
outline: deep
---

# Component Bundles

Bundles are reusable templates for spawning entities with a predefined set of
components. They provide:

- **Consistent entity creation**: define once, spawn anywhere
- **Default values**: optional components can have default factories
- **Required components**: mark components that must be supplied at spawn time
- **Performance**: each bundle compiles a specialized spawn routine that caches
  its target archetype and writes straight into component columns, so repeat
  spawns skip the archetype walk and deferred bursts batch through a single drain

## Creating a Bundle

Create bundles through the world with a declarative definition:

```lua
local playerBundle: tecs.Bundle = world:newBundle("Player", {
    required = { Transform, Health },
    with = {
        [Velocity] = function(): Velocity return Velocity(0, 0) end,
        [PlayerTag] = true,
    },
})
```

`required` is an ordered array of component types. `with` is a map keyed by
component type, where the value is either a factory function or `true`.

Each component type can only appear once in a bundle (across both `required`
and `with`). Passing components that aren't part of the bundle at spawn time
is not supported.

### `required`

Components listed in `required` must be supplied by the caller at spawn time.
They are strictly **positional**: the order in the `required` array determines
the argument order at `bundle:spawn(...)`.

```lua
local enemyBundle: tecs.Bundle = world:newBundle("Enemy", {
    required = { Transform, Health, Damage },
})

-- Spawn: arguments match declaration order
local id: integer = enemyBundle:spawn(
    Transform(100, 200),
    Health(50),
    Damage(10)
)
```

Use `required` when the component's value varies per entity (position, health,
stats, etc.).

### `with`

Components listed in `with` are automatically created at spawn time. The
`with` table is a map keyed by component type; each value is either a factory
function that returns an instance, or `true` for the component's default
constructor.

**With a factory:**

```lua
local bulletBundle: tecs.Bundle = world:newBundle("Bullet", {
    required = { Transform },
    with = {
        [Velocity] = function(): Velocity return Velocity(100, 0) end,
        [Damage] = function(): Damage return Damage(25) end,
    },
})
```

The factory runs on every spawn to produce a fresh instance. Use this when
with-default components need specific initial values.

**With `true` (default constructor):**

```lua
local treeBundle: tecs.Bundle = world:newBundle("Tree", {
    required = { Transform },
    with = {
        [StaticTag] = true,
        [Collidable] = true,
    },
})
```

`true` calls the component's default constructor (`Component()`). This is
useful for tag components or components whose zero-initialized state is the
desired default.

With-default components cannot be overridden at spawn time. If you need a
spawn-time value, move the component to `required` instead.

## Spawning from a Bundle

There are two ways to spawn from a bundle:

### Via the bundle object

```lua
-- Required components in the order they were declared.
local entityId: integer = playerBundle:spawn(
    Transform(100, 200),
    Health(100)
)
```

### Via the world by name

```lua
local entityId: integer = world:spawnBundle("Player",
    Transform(100, 200),
    Health(100)
)
```

`bundle:spawn(...)` and `world:spawnBundle(name, ...)` follow the same
instant-vs-staged rules as [`world:spawn`](/tecs/world#spawn): outside a
deferred scope the entity is placed in its archetype before the call returns;
inside a scope (query iteration, `world:defer()`, a batch op callback) the
entity is staged and applies when the scope closes. The returned id is usable
immediately in either case.

```lua
-- Outside a scope: placed right away.
local id: integer = playerBundle:spawn(Transform(0, 0), Health(100))
assert(world:isAlive(id))

-- Inside a scope (e.g. a query loop), follow-up mutations stage in order.
for _archetype, _len, _entities in someQuery:iter() do
    local newId: integer = playerBundle:spawn(Transform(0, 0), Health(100))
    world:set(newId, CustomTag)  -- staged; applies when the loop exits
end
```

## Looking up Bundles

Get a single bundle by name:

```lua
local bundle: tecs.Bundle = world:getBundle("Player")
```

Get all registered bundles:

```lua
local bundles: {string: tecs.Bundle} = world:getBundles()

for name, bundle in pairs(bundles) do
    print(name)
    print("Required: " .. table.concat(bundle.required, ", "))
    print("Defaulted: " .. table.concat(bundle.defaulted, ", "))
end
```

## Bundle record

Each bundle exposes these fields:

| Field        | Type       | Description                                                        |
| ------------ | ---------- | ------------------------------------------------------------------ |
| `name`       | `string`   | The bundle's registered name.                                      |
| `required`   | `{string}` | Names of components required at spawn time, in declaration order.  |
| `defaulted`  | `{string}` | Names of components filled in by factories.                        |
| `spawn(...)` | `function` | Spawn an entity from this bundle; returns the id.                  |
