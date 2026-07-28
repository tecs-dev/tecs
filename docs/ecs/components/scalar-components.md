---
description: "Single-value number, boolean, or string components via newScalarComponent with fast SoA columns"
outline: deep
---

# Scalar Components

Scalar components store a single primitive value per entity (`number`, `boolean`, or `string`) in a direct
column. Use them when you want tight SoA iteration for simple values without per-row table allocation.

If you need the shared constructor model first, see [Component Construction](/ecs/components/construction).
For the bigger picture of when scalar components fit, start from the
[Components overview](/ecs/components/) and compare them with
[table components](/ecs/components/table-components),
[FFI components](/ecs/components/ffi), and
[tag components](/ecs/components/tag-components).

## Creating a scalar component

```teal
local tecs <const> = require("tecs")

local Health = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})
```

```teal
function tecs.ecs.newScalarComponent<T>(options: ScalarComponentOptions<T>): ScalarComponent<T>
```

### Options

| Option      | Type                                | Required | Description                                                                                                                                                                                                                                         |
| ----------- | ----------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`      | `string`                            | yes      | Component name.                                                                                                                                                                                                                                     |
| `kind`      | `"number" \| "boolean" \| "string"` | yes      | Lua type of the value the column holds. Any other value errors at registration.                                                                                                                                                                     |
| `default`   | `T`                                 | no       | Value used when the component is added without a value. Its Lua type must match `kind`. If omitted, defaults to the zero value for the kind: `0`, `false`, or `""`.                                                                                 |
| `requires`  | `{Component}`                       | no       | Declarative auto-dependencies. When this component is added to an entity, any listed components not already present are added in the same archetype transition. Entries may be component types (constructed with no args) or instances. Transitive. |
| `transient` | `boolean`                           | no       | If `true`, omit this scalar component from snapshots.                                                                                                                                                                                               |

**Returns:** the registered component, typed `tecs.ecs.ScalarComponent<T>`. It also carries `scalarKind` and
`scalarDefault` fields describing the registration.

### Typed exports

Scalar columns hold the raw primitive, so there is no container record to hang fields on. To export a scalar
from a module with a precise Teal type, declare the field type on the module record and assign the
registration result to it:

```teal
local tecs <const> = require("tecs")

local record mymodule
    Health: tecs.ecs.ScalarComponent<number>
end

mymodule.Health = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})

return mymodule
```

## Set and get scalar values

The 3-arg `world:set(entity, componentType, value)` form is the fast path for scalar writes:

```teal
local id = world:spawn()

world:set(id, Health, 75)
local hp = world:get(id, Health) -- 75
```

You can also set a scalar without passing a value to write its default:

```teal
world:set(id, Health)
local hp = world:get(id, Health) -- 100
```

`world:get` always returns the raw scalar value, never a wrapper:

```teal
local hp = world:get(id, Health)
print(type(hp))       -- "number"
print(hp == 75)       -- true
```

## Spawn with scalar components

`Health(75)` produces a scalar instance you can pass directly to `world:spawn` alongside other components. The
instance is unwrapped at the spawn boundary, so the column still stores the raw value.

```teal
local id = world:spawn(
    Transform(0, 0),
    Health(75),
    Mana(10)
)
```

The 2-arg `world:set(entity, instance)` form works the same way:

```teal
world:set(id, Health(50))
```

::: warning Scalar instances are wrappers, not raw values
`Health(75)` returns a small wrapper carrying both the component type and the value, so the spawn dispatcher
can route it. That means `Health(75) == 75` is **false**. Treat scalar instances as opaque tokens for
`world:spawn` / `world:set`; for everything else, read the raw value back via `world:get`.

For string-kind scalars, repeated calls with the same value reuse a cached wrapper, so `Name("Frank")` does
not allocate after the first call with `"Frank"`. The cache holds its values weakly, so unreferenced wrappers
are collected.
:::

## Query scalar columns

Scalar columns are regular archetype columns, so query iteration is the same pattern as other components.

```teal
local query = world:query({ include = {Health} })

for archetype, len in query:iter() do
    local health = archetype:getMut(Health)
    for row = 1, len do
        health[row] = health[row] - 1
    end
end
```

## Serialization

Scalar components serialize as an object with a single `value` field:

```json
{ "value": 75 }
```

On deserialize, a missing `value` falls back to the scalar default.

## When to use scalar vs table/FFI

- Scalar components: use when the component is exactly one primitive value and you want simple, fast SoA
  column access.
- Table components: use when you need structured Lua fields and flexible shape. See
  [Table Components](/ecs/components/table-components).
- FFI components: use when you need packed structs and FFI interop. See
  [FFI Components](/ecs/components/ffi).
- Tag components: use when presence alone is the signal and there is no payload at all. See
  [Tag Components](/ecs/components/tag-components).

::: tip Don't overdo scalar components
Scalar components are usually faster than table or FFI components for their narrow use case. But don't
over-apply them and lose abstraction. For example, in most code a single `Position` component with `x` and `y`
is preferable to splitting into separate `PositionX` and `PositionY` components.
:::
