---
outline: deep
---

# FFI Relationships

FFI-backed relationships store relationship data in a LuaJIT FFI struct for compact, high-performance
storage. This page covers only the FFI-specific storage side. For general relationship concepts (targets,
`exclusive`, `sparse`, traversal) see [Relationships](/tecs/relationships/); for the shared constructor
model see [Component Construction](/tecs/components/construction). If you only need a target with no extra
payload, a [target-only relationship](/tecs/relationships/#creating-simple-relationships) (`newRelationship`
with just a name) is FFI-backed automatically.

FFI relationships provide:

- **High performance**: data lives in an FFI struct, avoiding per-instance table allocation
- **Compact memory**: tightly packed fields with no per-field boxing
- **Type safety**: strongly typed fields with compile-time guarantees
- **Full feature set**: works with `sparse`, `reverseIndex`, and `cascadeDelete`

## FFI relationships with data

FFI-backed relationships can store additional data along with the target while maintaining FFI performance benefits.

```teal
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

```teal
-- Positional __call: target first, then fields in order
world:set(follower, FastFollows(targetEntity, 0.3, 50.0))

-- Table form: target is a key alongside the data
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
| `init`          | Validation and initialization hook (positional args only; `.new` unpacks before calling)       |
| `new`           | Override the auto-codegenned `.new(data)` table-form constructor (optional)                   |
| `transient`     | If `true`, omit this relationship from snapshots. Mutually exclusive with `serialize`          |

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

```teal
local record SafeFollows is tecs.Relationship
    delay: number
    maxDistance: number
end

local SafeFollows = tecs.newFFIRelationship({
    name = "SafeFollows",
    container = SafeFollows,
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
        instance.delay = math.max(0.1, delay)
        instance.maxDistance = math.max(1, maxDistance)
    end,
})
```

The init hook receives the allocated relationship instance plus the positional
arguments. By the time it runs, `target` and any generated/defaulted field
population have already occurred.
