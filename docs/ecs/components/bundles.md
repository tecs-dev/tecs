---
description: "Reusable entity-spawning templates via world:newBundle, spawnBundle, and required-plus-with component definitions"
outline: deep
---

# Component Bundles

Bundles are reusable templates for spawning entities with a predefined set of components. They provide:

- **Consistent entity creation**: define once, spawn anywhere
- **Default values**: components that aren't supplied per entity get a factory
- **Required components**: mark components that must be supplied at spawn time
- **Cached spawn path**: each bundle compiles a spawn routine for its target component set, so repeated spawns
  avoid rebuilding the same component list

## Creating a bundle

Create bundles through the world with a declarative definition:

```teal
local Transform <const> = tecs.Transform
local Renderable <const> = tecs.gfx.Renderable
local Tint <const> = tecs.gfx.Tint

local playerBundle: tecs.ecs.Bundle = world:newBundle("Player", {
    required = { Transform, Health },
    with = {
        [Tint] = function(): Tint return Tint(1, 1, 1, 1) end,
        [Renderable] = true,
    },
})
```

`required` is an ordered array of component types. `with` is a map keyed by component type, where the value is
either a factory function or `true`.

Each component type can only appear once in a bundle (across both `required` and `with`); a duplicate errors
when the bundle is created. Passing components that aren't part of the bundle at spawn time is not supported.

### `required`

Components listed in `required` must be supplied by the caller at spawn time. They are strictly
**positional**: the order in the `required` array determines the argument order at `bundle:spawn(...)`.

```teal
local enemyBundle: tecs.ecs.Bundle = world:newBundle("Enemy", {
    required = { Transform, Health, Damage },
})

-- Spawn: arguments match declaration order
local id: integer = enemyBundle:spawn(
    Transform(100, 200),
    Health(50),
    Damage(10)
)
```

Use `required` when the component's value varies per entity (position, health, stats, and so on).

### `with`

Components listed in `with` are automatically created at spawn time. The `with` table is a map keyed by
component type; each value is either a factory function that returns an instance, or `true` for the
component's default constructor.

**With a factory:**

```teal
local bulletBundle: tecs.ecs.Bundle = world:newBundle("Bullet", {
    required = { Transform },
    with = {
        [Velocity] = function(): Velocity return Velocity(100, 0) end,
        [Damage] = function(): Damage return Damage(25) end,
    },
})
```

The factory runs on every spawn to produce a fresh instance. Use this when defaulted components need specific
initial values.

**With `true` (default constructor):**

```teal
local propBundle: tecs.ecs.Bundle = world:newBundle("Prop", {
    required = { Transform },
    with = {
        [Renderable] = true,
        [StaticTag] = true,
    },
})
```

`true` calls the component's default constructor (`Component()`). This is useful for tag components or
components whose declared `defaults` are already the value you want. Any other value errors.

Defaulted components cannot be overridden at spawn time. If you need a spawn-time value, move the component to
`required` instead.

## World methods

These methods are available on every `World`.

| Method                                     | Description                                       |
| ------------------------------------------ | ------------------------------------------------- |
| [`world:newBundle`](#world-new-bundle)     | Create and register a bundle.                     |
| [`world:spawnBundle`](#world-spawn-bundle) | Spawn an entity from a registered bundle by name. |
| [`world:getBundle`](#world-get-bundle)     | Return one registered bundle by name.             |
| [`world:getBundles`](#world-get-bundles)   | Return all registered bundles.                    |

### world:newBundle {#world-new-bundle}

Creates and registers a bundle for spawning entities with a predefined set of components.

```teal
function World:newBundle(name: string, def?: BundleDef): Bundle
```

**Parameters:**

- `name`: Unique bundle name. Reusing a name errors.
- `def`: Optional bundle definition with `required` and `with` fields.

**Returns:** the registered bundle.

### world:spawnBundle {#world-spawn-bundle}

Spawns an entity from a registered bundle by name. Required components are passed positionally in the order
declared in the bundle. Components from `with` use their registered factory and cannot be overridden at spawn
time. An unknown name errors.

```teal
function World:spawnBundle(name: string, ...: Component): integer
```

**Parameters:**

- `name`: Bundle name.
- `...`: Required components, in declaration order.

**Returns:** the entity ID.

### world:getBundle {#world-get-bundle}

Returns a registered bundle by name.

```teal
function World:getBundle(name: string): Bundle | nil
```

**Parameters:**

- `name`: Bundle name.

**Returns:** the bundle, or `nil` if not found.

### world:getBundles {#world-get-bundles}

Returns all registered bundles as a fresh map keyed by bundle name. Mutating the returned map does not change
the world's registry.

```teal
function World:getBundles(): {string: Bundle}
```

**Returns:** a fresh map of bundle name to bundle.

## Spawning from a bundle

There are two ways to spawn from a bundle:

### Via the bundle object

```teal
-- Required components in the order they were declared.
local entityId: integer = playerBundle:spawn(
    Transform(100, 200),
    Health(100)
)
```

### Via the world by name

```teal
local entityId: integer = world:spawnBundle("Player",
    Transform(100, 200),
    Health(100)
)
```

`bundle:spawn(...)` and `world:spawnBundle(name, ...)` follow the same instant-vs-staged rules as
[`world:spawn`](/ecs/world#spawn): outside a deferred scope the entity is placed in its archetype before the call
returns; inside a scope (query iteration, `world:defer()`, a batch op callback) the entity is staged and
applies when the scope closes. The returned id is usable immediately in either case.

```teal
-- Outside a scope: placed right away.
local id: integer = playerBundle:spawn(Transform(0, 0), Health(100))
assert(world:isAlive(id))

-- Inside a scope (e.g. a query loop), follow-up mutations stage in order.
for _archetype, _len, _entities in someQuery:iter() do
    local newId: integer = playerBundle:spawn(Transform(0, 0), Health(100))
    world:set(newId, CustomTag)  -- staged; applies when the loop exits
end
```

## Looking up bundles

Get a single bundle by name:

```teal
local bundle: tecs.ecs.Bundle = world:getBundle("Player")
```

Get all registered bundles:

```teal
local bundles: {string: tecs.ecs.Bundle} = world:getBundles()

for name, bundle in pairs(bundles) do
    print(name)
    print("Required: " .. table.concat(bundle.required, ", "))
    print("Defaulted: " .. table.concat(bundle.defaulted, ", "))
end
```

## Bundle record

Each bundle exposes these fields:

| Field        | Type       | Description                                                       |
| ------------ | ---------- | ----------------------------------------------------------------- |
| `name`       | `string`   | The bundle's registered name.                                     |
| `required`   | `{string}` | Names of components required at spawn time, in declaration order. |
| `defaulted`  | `{string}` | Names of components filled in by factories.                       |
| `spawn(...)` | `function` | Spawn an entity from this bundle; returns the id.                 |
