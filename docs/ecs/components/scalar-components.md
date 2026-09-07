---
description: "Single-value number, boolean, or string components via newScalarComponent with fast SoA columns"
outline: deep
---

# Scalar components

A scalar component stores one number, boolean, or string directly in an
archetype column:

```nupp
local Health = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})

local entity = world:spawn(Health(75))

world:set(entity, Health, 50)
world:commit()
print(world:get(entity, Health)) -- 50
```

Use this storage when the component means exactly one primitive value. Use a
tag for presence alone and a record component for a structured value.

## Values and constructor tokens

`world:get` and archetype columns return the raw primitive. `Health(75)`
instead returns a small component token for spawn and the two-argument
`world:set` form:

```nupp
world:set(entity, Health(25))
world:commit()
assert(world:get(entity, Health) == 25)
```

The token does not compare equal to its primitive value. Treat it as an input
to component APIs, not as stored data.

Calling `world:set(entity, Health)` writes the registered default. When no
default exists, the kind supplies `0`, false, or an empty string.

## Column updates

Scalar columns follow ordinary query and dirty rules:

```nupp
local living = world:newQuery({
    include = {Health},
    exclude = {tecs.ecs.Disabled, tecs.ecs.Paused},
})

for archetype, length in living:iter() do
    local health = assert(archetype:getMut(Health))
    for row = 1, length as integer do
        health[row] = math.max(0, health[row] - 1)
    end
end
```

Do not split one coherent value into many scalar components only to pursue
column density. A position normally belongs in one structured component
rather than separate X and Y components.

## Typed module exports

Scalar registration carries its value type. State the type on a module export:

```nupp
module combat

export const Health: tecs.ecs.ScalarComponent<number> = tecs.ecs.newScalarComponent({
    name = "Health",
    kind = "number",
    default = 100,
})
```

Snapshots store the raw value. A transient scalar stays out of snapshots.
