---
description: "Lua-table-backed components via newComponent with fields, init, custom __call, and new"
outline: deep
---

# Table components

Table components hold values that do not fit a fixed C struct: strings, nested
tables, opaque handles, and data that needs Lua reference semantics.

```teal
local record Health is tecs.ecs.Component
    value: number
    max: number

    metamethod __call: function(
        self,
        value?: number,
        max?: number
    ): Health
end

tecs.ecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"value", "max"},
    defaults = {100, 100},
})

local full <const> = Health()
local hurt <const> = Health(40, 100)
local named <const> = Health.new({value = 40, max = 100})
```

Each instance owns a Lua table. Its metatable resolves `componentType`,
methods, and other container fields without copying them onto every instance.
Callers own the instance fields and may mutate them through `getMut`. Tecs owns
the metatable and component metadata; callers should treat those as read-only.

Use [FFI components](/modules/ecs/components/ffi) for fixed-size primitive fields that
hot loops or native code read from contiguous memory.

## Field construction

`fields` controls positional order and generates the table-form `.new`.
`defaults` fills omitted values in the same order; `nil` leaves a field
without a default.

Registration requires only `name` and `container`. A table component may act
as a presence marker with no instance fields:

```teal
local record Renderable2D is tecs.ecs.Component end

tecs.ecs.newComponent({
    name = "Renderable2D",
    container = Renderable2D,
})
```

For field-by-field checking on `.new`, declare a config record and narrow the
inherited signature:

```teal
local record Health is tecs.ecs.Component
    value: number
    max: number

    record Config
        value: number
        max: number
    end

    metamethod __call: function(
        self,
        value?: number,
        max?: number
    ): Health
    new: function(config: Config): Health
end
```

The narrower declaration changes Teal checking only. The generated `.new`
still maps the table through `fields`.

## Validation and derived fields

Add `init` when direct field mapping needs validation or refinement:

```teal
local record Inventory is tecs.ecs.Component
    slots: {string}
    capacity: integer

    metamethod __call: function(
        self,
        slots: {string},
        capacity?: integer
    ): Inventory
end

tecs.ecs.newComponent({
    name = "Inventory",
    container = Inventory,
    fields = {"slots", "capacity"},
    defaults = {nil, 10},
    init = function(inventory: Inventory)
        if inventory.slots == nil then
            error("Inventory requires slots")
        end
        if #inventory.slots > inventory.capacity then
            error("Inventory exceeds capacity")
        end
    end,
})

local inventory <const> = Inventory({"sword"})
```

Tecs fills fields and defaults before `init` runs. Both the positional
constructor and generated `.new` run the hook.

An `init` hook requires `fields` or an explicit `new`. Without one of those,
Tecs cannot map the table form to positional arguments.

## Semantic constructors

Use a custom `__call` when arguments describe an operation rather than a field
list. Tecs allocates the instance and applies defaults before it invokes the
hook. A custom `__call` replaces the generated path and does not invoke
`init`; call shared initialization explicitly.

Pair it with a custom `new` when the table form needs its own mapping:

```teal
tecs.ecs.newComponent({
    name = "ParticleEmitter",
    container = ParticleEmitter,
    requires = {tecs.Transform2D},
    __call = function(emitter: ParticleEmitter, options: EmitterOptions)
        initEmitter(emitter, options)
    end,
    new = function(data: {string: any}): ParticleEmitter
        local emitter <const> = {} as ParticleEmitter
        initEmitter(emitter, data as EmitterOptions)
        return emitter
    end,
})

local sparks <const> = ParticleEmitter({effect = "sparks"})
```

Tecs applies the component metatable to the table returned by `new`.

[Component construction](/modules/ecs/components/construction) covers the rules shared
with FFI components and relationships.

## Lifecycle reactions

Table components support in-place writes, so a value change does not pass
through a setter. Use [dirty tracking](/modules/ecs/components/dirty-tracking) when a
consumer needs to find changed columns.

Use [query callbacks](/modules/ecs/queries/callbacks) when code must react to a
component entering or leaving a matching signature. Query callbacks operate on
contiguous row ranges and can match several components at once.

Snapshots serialize declared fields by default. Use custom
`serialize`/`deserialize` functions for process-local values, or set
`transient = true` for state that should not enter a snapshot. See
[Component serialization](/modules/ecs/components/serialization).
