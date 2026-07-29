---
description: "Shared component construction model covering __call, new, fields, defaults, and the init hook"
outline: deep
---

# Component construction

Structured components share one construction model:

- `Component(...)` maps positional arguments to declared fields.
- `Component.new({...})` provides the named form.
- `defaults` fill omitted positional values.
- `init` validates or derives values after field mapping.
- A custom configuration `__call` replaces positional mapping.

Storage changes the allocated value, not these rules.

## Positional fields

Table components list field names. FFI components list name and C type pairs:

```teal
local record Health is tecs.ecs.Component
    current: integer
    maximum: integer

    metamethod __call: function(
        self,
        current?: integer,
        maximum?: integer
    ): Health
end

tecs.ecs.newFFIComponent({
    name = "Health",
    container = Health,
    fields = {
        {"current", "int32_t"},
        {"maximum", "int32_t"},
    },
    defaults = {100, 100},
})

local full <const> = Health()
local damaged <const> = Health(80, 120)
```

Defaults line up with fields. A nil slot means no declared default, while
false remains a valid default. FFI allocation supplies zero values for fields
that positional arguments and defaults omit.

Relationship targets always occupy the first positional argument and do not
appear in the public field list.

## Named construction {#table-construction}

The named form routes fields through the positional constructor:

```teal
local damaged <const> = Health.new({
    current = 80,
    maximum = 120,
})
```

Tecs reads declared fields in order and calls `Health(80, 120)`. The
initializer receives positional values, not the input table.

Provide a custom `new` only when named construction cannot map to the
positional form.

## Validation and derived values

`init(instance, ...)` runs after allocation, field assignment, and defaults:

```teal
tecs.ecs.newFFIComponent({
    name = "Health",
    container = Health,
    fields = {
        {"current", "int32_t"},
        {"maximum", "int32_t"},
    },
    defaults = {100, 100},
    init = function(instance: Health)
        if instance.current < 0 then
            error("Health.current must not be negative")
        end
        if instance.maximum < instance.current then
            error("Health.maximum must cover current health")
        end
    end,
})
```

Use defaults for static values. Use `init` for validation, normalization, and
derived state. An initializer requires declared fields or a custom `new`, so
the named path stays defined.

## Custom call shapes

Supply configuration `__call(instance, ...)` when public constructor arguments
do not match stored fields:

```teal
tecs.ecs.newComponent({
    name = "ParticleEmitter",
    container = ParticleEmitter,
    requires = {tecs.Transform},
    __call = function(
        instance: ParticleEmitter,
        options: EmitterOptions
    )
        initEmitter(instance, options)
    end,
    new = function(data: {string: any}): ParticleEmitter
        local instance <const> = {} as ParticleEmitter
        initEmitter(instance, data as EmitterOptions)
        return instance
    end,
})
```

Tecs allocates the base value and applies defaults before the custom call. It
does not invoke `init` afterwards. Call shared initialization explicitly when
both paths need it.
