---
description: "Record-valued components, construction, validation and lifecycle reactions"
---

# Record components

Table components hold strings, nested tables, opaque handles, and data that
needs reference semantics. Define the record, then register the functions
that construct its values:

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

local entity = world:spawn(Health(40, 100))
world:commit()
local value = assert(world:getMut(entity, Health))
value.value = 50
```

Callers own the instance fields and may mutate them through `getMut`. Tecs owns
the component metadata; callers should treat it as read-only. `Health(...)`
returns a component input token; `world:get` returns the stored `HealthValue`.

## Field construction

`construct` maps caller arguments to a record. `default` produces a fresh value
when the component definition is supplied without a value, including a required component
added automatically. Use defaults for static values.

## Validation and derived fields

Put validation, normalization, and derived state in `construct`. The function
returns the completed record, so Nupp checks the result against the stored type.
Have `default` call the same helper when both paths need those checks.

## Semantic constructors

Constructor arguments may describe an operation rather than a field list.
A constructor can accept a typed options record, calculate derived values, and
return the stored record. The component factory does not invent another
constructor or initializer hook.

## Lifecycle reactions

Record components support in-place writes, so a value change does not pass
through a setter. Use [dirty tracking](dirty-tracking.md) when a consumer needs
to find changed columns.

Snapshots preserve record data by default. Supply `save` and `load` callbacks
for a durable representation of process-local values, or set `transient = true`
for state that should not enter a snapshot. See [Save games](../save-games.md).
