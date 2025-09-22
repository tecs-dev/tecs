---
outline: deep
---

# FFI Relationships

FFI-backed relationships provide high-performance storage for relationship data using LuaJIT's FFI (Foreign Function
Interface). This page covers FFI-specific relationship features. For general relationship concepts, see the
[Relationships](/tecs/relationships/) documentation.

FFI relationships use the same shared constructor model documented in
[Component Construction](/tecs/components/construction). This page only covers
the FFI-specific storage side. If you only need a target with no extra payload,
see [Tag Relationships](/tecs/relationships/tag).

## FFI relationships with data

FFI-backed relationships can store additional data along with the target while maintaining FFI performance benefits.

```lua
local tecs = require("tecs")

-- Define the relationship record
local record FastFollows is tecs.Relationship
    delay: number
    maxDistance: number

    metamethod __call: function(
        self,
        target: integer,
        delay: number,
        maxDistance: number
    ): self
end

-- Create an FFI-backed relationship
local FastFollows = tecs.newFFIRelationship({
    name = "FastFollows",
    container = FastFollows,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"}
    },
})
```

Both construction forms are generated automatically from the `fields`
definition. Positional arguments are mapped to fields in order with `target`
always first; the table form takes `target` as a key:

```lua
-- Positional __call — target first, then fields in order
world:set(follower, FastFollows(targetEntity, 0.3, 50.0))

-- Table form — target is a key alongside the data
world:set(follower, FastFollows.new({
    target = targetEntity,
    delay = 0.3,
    maxDistance = 50.0,
}))
```

See [Component Construction](/tecs/components/construction) for the shared
`fields` / `defaults` / `init` / `.new` rules, and
[Relationships](/tecs/relationships/) for target/exclusive/sparse
semantics.

FFI relationships provide:
- **High performance**: FFI struct storage with zero-copy operations
- **Memory efficiency**: Compact memory layout
- **Type safety**: Strongly typed fields with compile-time guarantees
- **Full features**: Support for `sparse`, `reverseIndex`, and `cascadeDelete`

Note that the `target` field is automatically included in the FFI struct; you only need to specify additional data
fields.

## Configuration reference

The `tecs.newFFIRelationship` function accepts a configuration table with these fields:

| Property        | Description                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------- |
| `name`          | **Required** - The name of the FFI relationship                                               |
| `container`     | **Required** - Type for the FFI relationship data                                             |
| `fields`        | **Required** - Array of field tuples `{name, type}` for FFI struct definition                 |
| `exclusive`     | Whether only one target can exist per entity (default: `false`)                               |
| `sparse`        | Use entity-indexed storage instead of per-target archetype components (default: `false`)      |
| `reverseIndex`  | Maintain an inverse index for `world:targets()`, `world:traverse()`, and `world:walkUp()`     |
| `cascadeDelete` | Despawning the target despawns all source entities. Requires `exclusive` and `reverseIndex`    |
| `init`          | Validation and initialization hook (positional args only — `.new` unpacks before calling)      |
| `new`           | Override the auto-codegenned `.new(data)` table-form constructor (optional)                   |

::: info Positional shape is auto-generated
FFI relationships generate their positional base constructor from the `fields`
definition. Use `defaults` for static defaults and `init` for validation or
derived state.
:::

### FFI field types

The `fields` array supports standard FFI types:

| Type         | Description             |
| ------------ | ----------------------- |
| `"float"`    | 32-bit floating point   |
| `"double"`   | 64-bit floating point   |
| `"int8_t"`   | 8-bit signed integer    |
| `"uint8_t"`  | 8-bit unsigned integer  |
| `"int16_t"`  | 16-bit signed integer   |
| `"uint16_t"` | 16-bit unsigned integer |
| `"int32_t"`  | 32-bit signed integer   |
| `"uint32_t"` | 32-bit unsigned integer |
| `"int64_t"`  | 64-bit signed integer   |
| `"bool"`     | Boolean value           |

### Init Hooks

FFI relationships support `init` hooks for validation and derived state:

```lua
local SafeFollows = tecs.newFFIRelationship({
    name = "SafeFollows",
    container = FollowsType,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"}
    },
    init = function(
        instance: SafeFollows,
        target: integer,
        delay: number,
        maxDistance: number
    )
        delay = math.max(0.1, delay)
        maxDistance = math.max(1, maxDistance)
        instance.delay = delay
        instance.maxDistance = maxDistance
    end,
})
```

The init hook receives the allocated relationship instance plus the positional
arguments. By the time it runs, `target` and any generated/defaulted field
population have already occurred.
