---
description: "FFI struct-backed components via newFFIComponent with C field types and defaults"
outline: deep
---

# FFI components

An FFI component stores each value as a fixed C struct. Its archetype column
forms one contiguous memory block instead of an array of Lua table references.

Use FFI storage for numeric, boolean, pointer, and fixed-array data that hot
systems or native-facing code process in bulk. Use a
[table component](/ecs/components/table-components) for strings, nested Lua
objects, or flexible shape.

## Struct declarations

Pair each public field with a LuaJIT C type:

```teal
local record Velocity is tecs.ecs.Component
    x: number
    y: number

    metamethod __call: function(
        self,
        x?: number,
        y?: number
    ): Velocity
end

tecs.ecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"},
    },
})

local velocity <const> = Velocity(10, 20)
```

Field names must form unique C identifiers. Common choices include:

| Data              | C types                                       |
| ----------------- | --------------------------------------------- |
| Signed integers   | `int8_t`, `int16_t`, `int32_t`, `int64_t`     |
| Unsigned integers | `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t` |
| Floating point    | `float`, `double`                             |
| Boolean           | `bool`                                        |
| Pointer           | `void*`, `const char*`, `float*`              |
| Fixed array       | `float[4]`, `uint8_t[256]`, `char[64]`        |

The type string enters LuaJIT's C parser. Fixed arrays live inside each struct.
Pointers do not own their targets; game code must guarantee the pointed memory
outlives every component value that refers to it.

## Defaults and validation

FFI allocation initializes numbers to zero, booleans to false, and pointers to
nil. Declarative defaults override those values:

```teal
local record Color is tecs.ecs.Component
    r: number
    g: number
    b: number
    a: number
end

tecs.ecs.newFFIComponent({
    name = "Color",
    container = Color,
    fields = {
        {"r", "float"},
        {"g", "float"},
        {"b", "float"},
        {"a", "float"},
    },
    defaults = {1, 1, 1, 1},
})
```

The shared [construction model](/ecs/components/construction) provides
positional calls, named `new`, defaults, validation through `init`, and custom
constructor shapes.

`batchSpawn` bypasses per-instance construction and defaults. Its callback
must assign every field that later code reads.

## Mutation and dirty state

FFI field access looks like ordinary record access, but a cdata reference does
not notify Tecs when code writes through it:

```teal
local velocity <const> = world:getMut(entity, Velocity)
velocity.x = velocity.x + acceleration * dt
```

Use `world:getMut` or `archetype:getMut` for writes. A write through `get`
requires an explicit dirty mark. See
[Dirty tracking](/ecs/components/dirty-tracking).

## Durable representations

Raw fields work well when their bits mean the same thing in every run.
Process-local indices, native handles, pointers, and resolved GPU slots do
not. Give those components a custom durable serializer or mark runtime-only
state transient.

Binary snapshots copy matching FFI columns in bulk. Schema changes can migrate
same-named fields. See
[Component serialization](/ecs/components/serialization).
