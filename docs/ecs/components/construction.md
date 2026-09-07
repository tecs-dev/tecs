---
description: "Constructor inputs, stored values, defaults and validation"
---

# Component construction

Structured components map public constructor arguments to stored values.

- `Component(...)` calls the registered `construct` function and carries the
  result across a spawn or set boundary.
- `default` returns a fresh value when the component is added without a value.
- `world:get` returns the stored value, or nil when the entity lacks it.

## Positional fields

```nupp
local record HealthValue
    value: number
    max: number
end

local Health = tecs.ecs.newComponent({
    name = "Health",
    construct = function(value: number?, maximum: number?): HealthValue
        return new HealthValue(value = value or 100, max = maximum or 100)
    end,
    default = function(): HealthValue
        return new HealthValue(value = 100, max = 100)
    end,
})

local full = Health()
local damaged = Health(80, 120)
```

Defaults belong in the constructor. A false value is a valid boolean default;
do not use `value or true` when false must be preserved.

## Named construction {#table-construction}

Use a typed options record as the constructor argument when names make a call
clearer. Create Nupp records with `new Record(field = value)`. The ECS
component token remains the value supplied to `world:spawn` or `world:set`.

## Validation and derived values

Use defaults for static values. Validate, normalize, and calculate derived state
inside the constructor before it returns. Put shared initialization in one helper
and call it from `construct` and `default`.

## Custom call shapes

Constructor arguments can describe an operation rather than a field list.
For example, an emitter constructor can accept a typed effect configuration and
return the record a system will later read. See [Record components](table-components.md).
