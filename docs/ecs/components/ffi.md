---
description: "FFI struct-backed components via newFFIComponent with C field types and defaults"
outline: deep
---

# FFI Components

FFI components use LuaJIT's foreign function interface to store a component as a C struct instead of a Lua
table. A column of them is one contiguous block of C memory rather than a column of pointers to per-row
tables. Use FFI components when your data is mostly numbers, booleans, and other primitives that map cleanly
to fixed-size C fields; otherwise use [table components](/ecs/components/table-components).

Shared constructor rules live in [Component Construction](/ecs/components/construction). This page focuses on
FFI-specific storage behavior and field types.

## Why the engine's render components are FFI

The engine's own render components are FFI components on purpose. `Sprite`, `Tint`, `Material`, `Clip`,
`PointLight` and `PreviousTransform`, together with the builtin `Transform`, are what the extractor reads to
build a frame.

That read is the reason for the layout. The extractor walks the archetype's columns and writes GPU instances
straight into mapped staging memory: the source column is contiguous C memory and so is the destination, so a
row becomes a handful of float stores into driver memory rather than a copy between two intermediate buffers.
Per-row Lua tables would put a pointer chase and a hash lookup in front of every field on that path.

The tradeoffs you accept in exchange are real: fields are fixed-size C types, a string has to be represented
some other way (`Sprite` carries an interned image index, not a name), and the shape is decided at
registration. That bargain is worth taking for a component the renderer reads every frame and rarely worth it
for one only game logic touches.

See [components](/modules/components) for the per-component reference.

## Basic usage

Define FFI components with `tecs.newFFIComponent`:

```teal
local tecs <const> = require("tecs")

local record Velocity is tecs.Component
    vx: number
    vy: number
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"vx", "float"},
        {"vy", "float"}
    }
})
```

The engine's `Tint` is the same shape with four lanes and an explicit default of opaque white:

```teal
ecs.newFFIComponent({
    name = "Tint",
    container = Tint,
    fields = {
        { "r", "float" }, { "g", "float" },
        { "b", "float" }, { "a", "float" },
    },
    defaults = { 1, 1, 1, 1 },
})
```

## Field types

Each field is a `{name, type}` tuple. The type string is emitted verbatim into the struct's `cdef`, so any
type LuaJIT's C parser understands can be used.

### Numeric types

- **Integers**: `int8_t`, `int16_t`, `int32_t`, `int64_t`, `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t`
- **Floating point**: `float`, `double`
- **Standard C**: `char`, `short`, `int`, `long`, `size_t`, `ptrdiff_t`
- **Boolean**: `bool`

### Pointer types

- **Generic**: `void*`
- **String**: `char*`, `const char*`
- **Numeric**: `int*`, `float*`, `double*`

### Fixed-size arrays

Append `[size]` to any type to declare a fixed-size array field:

- **Numeric arrays**: `float[16]`, `int32_t[4]`, `uint8_t[256]`
- **Matrix/vector**: `float[3]` for a vec3, `float[16]` for a mat4
- **Buffers**: `char[256]` for a string buffer

Field names must be valid C identifiers and must be unique within the component; both are checked at
registration.

## Constructor support

FFI components use the same `__call(...)` / `.new(data)` / `fields` / `defaults` / `init` model as table
components. The FFI-specific difference is that the base instance is an FFI struct instead of a Lua table.

```teal
local record Position is tecs.Component
    x: number
    y: number
    z: number
    metamethod __call: function(self, x?: number, y?: number, z?: number): Position
end

tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"z", "float"}
    }
})

-- Use with positional arguments
local pos1: Position = Position(10, 20)      -- z stays zero-initialized
local pos2: Position = Position(10, 20, 30)  -- all values provided
```

### Default values

FFI components support explicit `defaults`, just like table components. The builtin `Transform` uses them to
land on layer 1 and unit scale:

```teal
ecs.newFFIComponent({
    name = "Transform",
    container = Transform,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"z", "float"},
        {"layer", "int32_t"},
        {"rotation", "float"},
        {"scaleX", "float"},
        {"scaleY", "float"}
    },
    defaults = {0, 0, 0, 1, 0, 1, 1},
    init = function(instance: Transform)
        if instance.layer < 1 then
            error("Transform layer must be greater than 0, got: " .. tostring(instance.layer))
        end
    end
})
```

Fields with no explicit default remain zero-initialized by the FFI allocator. That means omitted values fall
back to the underlying FFI zero value:

- Numeric types: `0` or `0.0`
- Pointers: `nil`
- Booleans: `false`
- See the [LuaJIT table initializer rules](https://luajit.org/ext_ffi_semantics.html#init_table)

::: warning batchSpawn skips FFI defaults
`world:batchSpawn` claims a row range and hands it to your callback without running the per-instance
constructor, so declared `defaults` are not applied. Set every field you care about inside the callback.
:::

## API compatibility

FFI components share the same API as table-based components. Field access, construction, and mutation work
identically regardless of the underlying storage:

```teal
local vel: Velocity = Velocity(10, 20)
vel.vx = vel.vx + 5
print(vel.vx, vel.vy)  -- 15, 20
```

The one asymmetry is dirty tracking: writes through a reference you obtained from `world:get` are invisible to
the framework, because there is no assignment it can observe. Use `world:getMut` / `archetype:getMut`, or call
`world:markComponentDirty(entity, Component)` after the write. See
[Dirty tracking](/ecs/components/dirty-tracking).

For LuaJIT FFI limitations and semantics, see the
[official LuaJIT FFI documentation](https://luajit.org/ext_ffi.html) and
[FFI semantics](https://luajit.org/ext_ffi_semantics.html).

## API reference

### tecs.newFFIComponent(options)

Creates and registers an FFI-backed component.

```teal
function tecs.newFFIComponent<C is Component>(options: FFIComponentOptions<C>): C
```

The `options` table supports the following properties:

| Parameter     | Type                                                  | Description                                                                                                                                                           | Required |
| ------------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `name`        | `string`                                              | Component name.                                                                                                                                                       | Yes      |
| `container`   | `Component`                                           | Component container/type.                                                                                                                                             | Yes      |
| `fields`      | `{ {string, string} }`                                | Array of field tuples `{name, type}`.                                                                                                                                 | Yes      |
| `metatable`   | `{any: any}`                                          | Metatable applied to FFI instances, for adding instance methods.                                                                                                      | No       |
| `defaults`    | `{any}`                                               | Default positional values, in the same order as `fields`.                                                                                                             | No       |
| `init`        | `function(instance: C, ...: any)`                     | Validation and initialization hook (positional args only; `.new` routes through it after unpacking).                                                                  | No       |
| `__call`      | `function(instance: C, ...: any)`                     | Custom constructor hook. Receives an allocated instance plus the call args after `defaults` are applied. `init` is not auto-run on this path.                         | No       |
| `new`         | `function(data: {string: any}): C`                    | Override the auto-generated table-form constructor. Defaults to a field-name unpacker through `__call`.                                                               | No       |
| `requires`    | `{Component}`                                         | Components to auto-add alongside this one. See [Auto-dependencies](/ecs/components/#auto-dependencies-with-requires).                                                 | No       |
| `serialize`   | `function(instance: C): {string: any}`                | Custom serializer for durable data. Mutually exclusive with `transient`.                                                                                              | No       |
| `deserialize` | `function(world: tecs.World, data: {string: any}): C` | Custom deserializer. Receives the world.                                                                                                                              | No       |
| `transient`   | `boolean`                                             | If `true`, omit this component from snapshots. Use for runtime-only backing state such as GPU slots, physics handles, or caches. Mutually exclusive with `serialize`. | No       |

**Returns:** the created FFI `Component`.

To run code when the component is added to or removed from an entity, attach
[query callbacks](/ecs/queries/callbacks) (`onEntitiesAdded` / `onEntitiesRemoved`) to a query that includes
the component.

**Example:**

```teal
local record Velocity is tecs.Component
    vx: number
    vy: number
    speed: {number}
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"vx", "float"},
        {"vy", "float"},
        {"speed", "float[2]"}
    }
})
```

### Init hooks

FFI components can include an optional `init` hook for validation and derived state:

```teal
init = function(instance: Component, ...: any)
```

The init hook receives the allocated instance plus the **positional** arguments. When a caller uses
`Component.new({...})`, the framework unpacks the table by field name into positional args _before_ calling
`init`, so the hook never sees a table in its first slot and doesn't need a `type(x) == "table"` fork.

```teal
local record Health is tecs.Component
    current: integer
    maximum: integer
end

tecs.newFFIComponent({
    name = "Health",
    container = Health,
    fields = {
        {"current", "int32_t"},
        {"maximum", "int32_t"}
    },
    init = function(
        instance: Health,
        current: integer,
        maximum: integer
    )
        if current < 0 then
            error("Health current cannot be negative")
        end
        if maximum <= 0 then
            error("Health maximum must be positive")
        end
    end
})
```

Use `defaults` for static default values; use `init` for validation, normalization, and derived state.

### Custom `__call`

For FFI components whose public constructor arguments do not line up with their raw struct fields, provide
config `__call(instance, ...)`.

On that path, Tecs allocates the FFI instance, applies `defaults`, and then calls your hook. It does **not**
auto-run `init` afterwards, so call `Component.init(...)` explicitly if you want to reuse init logic.
