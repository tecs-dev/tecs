---
description: "Constructor inputs, stored values, defaults and validation"
---

# Component construction

Derived components use Nupp's own field defaults and constructors. A value made
with `new` goes directly into `world:spawn` or `world:set`:

```nupp
@derive(tecs.ecs.Component)
local struct Health
    value: number = 100
    max: number = 100
end

local entity = world:spawn(new Health(80, 120))
world:batchSpawn(100, {Health})
```

The derive publishes an initializer so default additions and bulk spawns use
the same initialization rules. Native bulk defaults initialize rows in place.
Registration inspects the declaration and never evaluates a user constructor.
Reusable initializers require one unambiguous construction path. Nupp rejects
multiple constructors, generic owners, affine fields, and constructors that let
`self` escape or transfer owned arguments into fields. Such declarations can
instead use an explicit named factory without the ECS derive.

## Factory configuration

Use a factory when a separate component identity or custom call shape is useful.

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

local Health = tecs.ecs.newComponent(HealthValue, {
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
definition wraps factory-created values supplied to `world:spawn` or `world:set`.
Values of derived declarations need no wrapper.

## Validation and derived values

Use defaults for static values. Validate, normalize, and calculate derived state
inside the constructor before it returns. Put shared initialization in one helper
and call it from `construct` and `default`.

## Custom call shapes

Constructor arguments can describe an operation rather than a field list.
For example, an emitter constructor can accept a typed effect configuration and
return the record a system will later read. See [Record components](table-components.md).
