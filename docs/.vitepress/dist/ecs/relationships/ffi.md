---
url: /ecs/relationships/ffi.md
description: >-
  FFI struct-backed relationships via newFFIRelationship with packed field types
  and target semantics
---

# FFI Relationships

FFI-backed relationships store relationship data in a LuaJIT FFI struct for compact, high-performance
storage. This page covers only the FFI-specific storage side. For general relationship concepts (targets,
`exclusive`, `sparse`, traversal) see [Relationships](/ecs/relationships/); for the shared constructor
model see [Components](/ecs/components/). If you only need a target with no extra
payload, a [target-only relationship](/ecs/relationships/#creating-simple-relationships) (`newRelationship`
with just a name) is FFI-backed automatically.

This is the same storage the engine's render components use. `Transform`, `Tint`, `Sprite`, `PointLight` and the
rest are FFI components for one reason: their columns are contiguous C memory, so a walk over rows can write
straight into mapped GPU staging instead of reading fields one entity at a time through a table. An FFI
relationship puts an edge's payload in that same shape.

FFI relationships provide:

* **High performance**: data lives in an FFI struct, avoiding per-instance table allocation
* **Compact memory**: tightly packed fields with no per-field boxing
* **Type safety**: strongly typed fields with compile-time guarantees
* **Full feature set**: works with `exclusive`, `sparse`, `reverseIndex`, and `cascadeDelete`

## FFI relationships with data

FFI-backed relationships can store additional data along with the target while maintaining FFI performance benefits.

```teal
local tecs <const> = require("tecs")

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
local FastFollows = tecs.ecs.newFFIRelationship({
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

See [Components](/ecs/components/) for the shared `fields` / `defaults` / `init` / `.new` rules, and
[Relationships](/ecs/relationships/) for target, exclusive and sparse semantics.

`name`, `container` and `fields` are all required; omitting any of them errors at registration.

## The target field

The `target` field is added to the FFI struct for you, as the struct's first member, and you must not declare it
yourself. It is typed `double` rather than an integer: an entity id packs a 22-bit slot together with a
generation, so an `int32_t` would truncate targets once generations climbed and a saved relationship would come
back pointing at the wrong entity.

Everything else in `fields` is your payload, and only your payload.

## Configuration reference

The `tecs.ecs.newFFIRelationship` function accepts a configuration table with these fields:

| Property        | Description                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------- |
| `name`          | **Required** - The name of the FFI relationship                                             |
| `container`     | **Required** - Type for the FFI relationship data                                           |
| `fields`        | **Required** - Array of field tuples `{name, type}` for the FFI struct definition           |
| `defaults`      | Positional defaults, in the same order as `fields` (`nil` means no default)                 |
| `metatable`     | Metatable applied to FFI instances, for instance methods                                    |
| `exclusive`     | Whether only one target can exist per entity (default: `false`)                             |
| `sparse`        | Use entity-indexed storage instead of per-target archetype components (default: `false`)    |
| `reverseIndex`  | Maintain an inverse index for `world:targets()` and `world:traverse()`                      |
| `cascadeDelete` | Despawning the target despawns all source entities. Requires `exclusive` and `reverseIndex` |
| `init`          | Validation and initialization hook, called with the positional args after allocation        |
| `__call`        | Replaces the generated positional constructor entirely; `init` is not auto-run on this path |
| `new`           | Override the generated `.new(data)` table-form constructor                                  |
| `serialize`     | Custom serialization. Mutually exclusive with `transient`                                   |
| `deserialize`   | Custom deserialization; defaults to routing through `.new(data)`                            |
| `transient`     | If `true`, omit this relationship from snapshots. Mutually exclusive with `serialize`       |

::: info Positional shape is auto-generated
FFI relationships generate their positional base constructor from the `fields`
definition. Use `defaults` for static defaults and `init` for validation or
derived state.
:::

### FFI field types

A field's type string is emitted verbatim into a `typedef struct { ... }` handed to LuaJIT's `ffi.cdef`, so any C
type LuaJIT understands works. These are the ones worth naming:

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

A trailing `[N]` makes the field a fixed-size array, for example `{"weights", "float[4]"}`.

Field definitions are validated at registration. A field name must be a non-empty, valid C identifier, must not
repeat another field's name, and must carry a non-empty type.

### Init hooks

FFI relationships support `init` hooks for validation and derived state:

```teal
local record SafeFollows is tecs.Relationship
    delay: number
    maxDistance: number
end

local SafeFollows = tecs.ecs.newFFIRelationship({
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
arguments, target first. By the time it runs, `target` and any generated or defaulted field
population have already occurred.

`init` needs either `fields` or an explicit `new`, because otherwise `.new(data)` would have no way to unpack a
table into positional arguments. Supplying your own `__call` takes over the whole constructor: `init` is not
called for you on that path, so invoke it yourself if you want it.

### Snapshots

An FFI relationship serializes its declared fields plus `target`, and deserializes by routing the same table back
through `.new(data)`. Set `transient = true` to leave it out of snapshots entirely; that cannot be combined with a
custom `serialize`.
