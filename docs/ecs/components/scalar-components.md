---
description: "Single-value number, boolean, or string components via newScalarComponent with fast SoA columns"
outline: deep
---

# Scalar components

A scalar component stores one number, boolean, or string directly in an
archetype column:

```teal
local Health <const> = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})

local entity <const> = world:spawn(Health(75))

world:set(entity, Health, 50)
print(world:get(entity, Health)) -- 50
```

Use this storage when the component means exactly one primitive value. Use a
tag for presence alone and a table or FFI component for a structured value.

## Values and constructor tokens

`world:get` and archetype columns return the raw primitive. `Health(75)`
instead returns a small component token for spawn and the two-argument
`world:set` form:

```teal
world:set(entity, Health(25))
assert(world:get(entity, Health) == 25)
```

The token does not compare equal to its primitive value. Treat it as an input
to component APIs, not as stored data.

Calling `world:set(entity, Health)` writes the registered default. When no
default exists, the kind supplies `0`, false, or an empty string.

## Column updates

Scalar columns follow ordinary query and dirty rules:

```teal
local living <const> = world:query({
    include = {Health},
    type = "logic",
})

for archetype, length in living:iter() do
    local health <const> = archetype:getMut(Health)
    for row = 1, length do
        health[row] = math.max(0, health[row] - 1)
    end
end
```

Do not split one coherent value into many scalar components only to pursue
column density. A position normally belongs in one structured component
rather than separate X and Y components.

## Typed module exports

Scalar registration has no container record to carry its value type. State
the type on a module export:

```teal
local record combat
    Health: tecs.ecs.ScalarComponent<number>
end

combat.Health = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})

return combat
```

Snapshots store the raw value. A transient scalar stays out of snapshots.
