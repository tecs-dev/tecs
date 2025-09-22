---
outline: deep
---

# Component Construction

All component kinds in Tecs share the same high-level construction model:

- Positional `__call(...)` is the hot path.
- `.new(data)` is the named/table form.
- `fields` define positional order.
- `defaults` fill omitted positional values in field order.
- `init(instance, ...)` runs after the base instance has been allocated and populated.
- optional config `__call(instance, ...)` replaces the default positional field-mapping path.

The storage backend changes how the instance is stored; it does not change the
basic construction rules.

This page documents the shared component model. For backend and category-specific details, see
[Table Components](/tecs/components/table-components),
[FFI Components](/tecs/components/ffi),
[Scalar Components](/tecs/components/scalar-components),
[Tag Components](/tecs/components/tag-components),
[Relationships](/tecs/relationships/),
[Tag Relationships](/tecs/relationships/tag), and
[FFI Relationships](/tecs/relationships/ffi).

## Positional construction

Call the component container directly to construct an instance:

```lua
local record Health is tecs.Component
    current: integer
    maximum: integer
    metamethod __call: function(self, current?: integer, maximum?: integer): Health
end

tecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"current", "maximum"},
    defaults = {100, 100},
})

local a: Health = Health()
local b: Health = Health(80, 120)
```

When `fields` are present, positional arguments map to those fields in order.
For the concrete table-backed and FFI-backed forms of this pattern, see
[Table Components](/tecs/components/table-components) and
[FFI Components](/tecs/components/ffi).

## Table construction

Every component also exposes `.new(data)`:

```lua
local h: Health = Health.new({
    current = 80,
    maximum = 120,
})
```

When `fields` are present, Tecs generates `.new(data)` automatically by
unpacking field names in order and routing through `__call`.

Use an explicit `new = function(data) ... end` only when the table form should
not map directly to the positional form.

This named construction path matters most for [table components](/tecs/components/table-components),
[FFI components](/tecs/components/ffi), and default
[component serialization](/tecs/components/serialization).

## `fields`

`fields` define the positional argument order and the generated base shape.

Table components use:

```lua
fields = {"x", "y", "z"}
```

FFI components use:

```lua
fields = {
    {"x", "float"},
    {"y", "float"},
    {"z", "float"},
}
```

Relationships follow the same rule, except the relationship target is always
the first positional argument and is not included in the public `fields` list.
For relationship-specific construction and target semantics, see
[Relationships](/tecs/relationships/),
[Tag Relationships](/tecs/relationships/tag), and
[FFI Relationships](/tecs/relationships/ffi).

## `defaults`

`defaults` are positional and line up with `fields`.

```lua
defaults = {0, 0, 1}
```

That means:

- field 1 defaults to `0`
- field 2 defaults to `0`
- field 3 defaults to `1`

Use `nil` for “no default”.

```lua
defaults = {nil, nil, 1}
```

For FFI-backed components and relationships, omitted fields that still have no
default remain zero-initialized by the allocator.

For examples of defaults on plain Lua payloads versus FFI-backed payloads, see
[Table Components](/tecs/components/table-components),
[FFI Components](/tecs/components/ffi), and
[Tag Relationships](/tecs/relationships/tag) plus
[FFI Relationships](/tecs/relationships/ffi).

## `init(instance, ...)`

`init` is a post-allocation hook.

The split is:

- generated/base construction owns allocation, field mapping, and defaults
- `init` owns validation, normalization, and derived state

Example:

```lua
tecs.newFFIComponent({
    name = "Transform",
    container = Transform,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"layer", "int32_t"},
    },
    defaults = {0, 0, 1},
    init = function(instance: Transform)
        if instance.layer < 1 then
            error("Transform layer must be greater than 0")
        end
    end,
})
```

By the time `init` runs, `instance.layer` already reflects the positional args
plus any defaults.

If you provide `init`, you must also provide `fields` or `new`. Otherwise Tecs
would have no clear way to implement `.new(data)`.

`init` is most relevant for structured payload components and relationships. For
concrete usage patterns, compare [Table Components](/tecs/components/table-components),
[FFI Components](/tecs/components/ffi),
[Relationships](/tecs/relationships/), and
[Tag Relationships](/tecs/relationships/tag) plus
[FFI Relationships](/tecs/relationships/ffi). Scalar and tag
components have narrower creation APIs; see
[Scalar Components](/tecs/components/scalar-components) and
[Tag Components](/tecs/components/tag-components).

## Custom constructor `__call(instance, ...)`

Supply config `__call` when the public constructor arguments are **not** the same
as the stored fields.

On this path, Tecs:

- allocates the base instance
- applies declarative `defaults`
- calls your custom `__call(instance, ...)`
- does **not** auto-run `init`

That last point is intentional: if you want to share logic, call
`Component.init(instance, ...)` explicitly from the custom `__call`.

```lua
tecs.newFFIComponent({
    name = "Text",
    container = Text,
    fields = {
        {"slabOffset", "uint32_t"},
        {"charCount", "uint16_t"},
        {"fontId", "uint16_t"},
    },
    __call = function(instance: Text, fontPath: string, value: string)
        Text.init(instance, fontPath, value)
    end,
    init = function(instance: Text, fontPath: string, value: string)
        -- custom semantic construction here
    end,
})
```

Use this only when the default positional field mapping is the wrong model.
If your constructor arguments already line up with `fields`, prefer the normal
generated path and `init`.
