---
outline: deep
---

# FFI Components

FFI (Foreign Function Interface) components leverage LuaJIT's FFI capabilities to provide high-performance,
cache-friendly component storage using C structs instead of Lua tables. Use FFI components if your data is mostly
made up of numbers, booleans, and other primitive types that map cleanly to C structs. Otherwise, use normal
table-based components.

Shared constructor rules live in [Component Construction](/tecs/components/construction). This page focuses on
FFI-specific storage behavior and field types.

## Basic usage

Define FFI components using `tecs.newFFIComponent`:

```teal
local tecs = require("tecs")

local record Velocity is tecs.Component
    x: number
    y: number
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})
```

## Field types

FFI components support all standard C types:

### Numeric types

- **Integers**: `int8_t`, `int16_t`, `int32_t`, `int64_t`, `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t`
- **Floating Point**: `float`, `double`, `long double`
- **Standard C**: `char`, `short`, `int`, `long`, `size_t`, `ptrdiff_t`
- **Boolean**: `bool`, `_Bool`

### Pointer types

- **Generic**: `void*`
- **String**: `char*`, `const char*`
- **Numeric**: `int*`, `float*`, `double*`

### Fixed-size arrays

You can define fixed-size arrays by appending `[size]` to any type:
- **Numeric Arrays**: `float[16]`, `int32_t[4]`, `uint8_t[256]`
- **Matrix/Vector**: `float[3]` for vec3, `float[16]` for mat4
- **Buffers**: `char[256]` for string buffers

## Constructor support

FFI components use the same `__call(...)` / `.new(data)` / `fields` / `defaults` /
`init` model as table components. The FFI-specific difference is that the base
instance is an FFI struct instead of a Lua table.

```teal
-- Define component
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
local pos1: Position = Position(10, 20)      -- z defaults to 0
local pos2: Position = Position(10, 20, 30)  -- all values provided
```

### Default values

FFI components support explicit `defaults`, just like table components:

```teal
tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"z", "float"}
    },
    defaults = {0, 0, 0},
})
```

Fields with no explicit default remain zero-initialized by the FFI allocator.
That means omitted values fall back to the underlying FFI zero value:

- Numeric types: `0` or `0.0`
- Pointers: `nil`
- Booleans: `false`
- See https://luajit.org/ext_ffi_semantics.html#init_table

## API compatibility

FFI components share the same API as table-based components. Field access, construction, and mutation work
identically regardless of the underlying storage:

```teal
local vel: Velocity = Velocity(10, 20)
vel.x = vel.x + 5
print(vel.x, vel.y)  -- 15, 20
```

## Limitations

For more details on LuaJIT FFI limitations and semantics, see the
[official LuaJIT FFI documentation](https://luajit.org/ext_ffi.html) and
[FFI semantics](https://luajit.org/ext_ffi_semantics.html).

## API reference

### tecs.newFFIComponent(options)

Creates an FFI-based component with optimized memory layout and optional recycling.

**Parameters**:

* `options`

The `options` table supports the following properties:

| Parameter          | Type                        | Description                                                                                                 | Required    |
| ------------------ | --------------------------- | ----------------------------------------------------------------------------------------------------------- | ----------- |
| `name`             | `string`                    | Component name                                                                                              | Yes         |
| `container`        | `Component`                 | Component container/type                                                                                    | Yes         |
| `fields`           | `{ {string, string} }`      | Array of field tuples `{name, type}`                                                                        | Yes         |
| `metatable`        | `table`                     | Metatable to apply to FFI instances for adding instance methods                                             | No          |
| `defaults`         | `{any}`                     | Default positional values, in the same order as `fields`                                                     | No          |
| `init`             | `function`                  | Validation and initialization hook (positional args only; `.new` routes through it after unpacking)         | No          |
| `__call`           | `function`                  | Custom constructor hook. Receives an allocated instance plus the call args after `defaults` are applied. `init` is not auto-run on this path. | No |
| `new`              | `function(data: {string: any}): Component` | Override the auto-codegenned table-form constructor. Defaults to a field-name unpacker through `__call`. | No |
| `requires`         | `{Component}`               | Components to auto-add alongside this one (see [Auto-dependencies](/tecs/components/#auto-dependencies-with-requires)) | No |
| `serialize`        | `function(instance: Component): {string: any}` | Custom serializer for durable data. Mutually exclusive with `transient`.                      | No          |
| `deserialize`      | `function(world: tecs.World, data: {string: any}): Component`  | Custom deserializer                                                         | No          |
| `transient`        | `boolean`                   | If `true`, omit this component from snapshots. Use for runtime-only backing state such as GPU slots, physics handles, or caches. Mutually exclusive with `serialize`. | No |

To run code when the component is added to or removed from an entity, attach
[query callbacks](/tecs/queries/callbacks) (`onEntitiesAdded` /
`onEntitiesRemoved`) to a query that includes the component.

**Returns:**

* The created FFI `Component`

**Example:**

```teal
local record Velocity is tecs.Component
    x: number
    y: number
    speed: {number, number}
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"},
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
`Component.new({...})`, the framework unpacks the table by field name into positional args *before* calling
`init`, so the hook never sees a table in its first slot and doesn't need a `type(x) == "table"` fork.

### Custom `__call`

For unusual FFI components whose public constructor arguments do not line up with
their raw struct fields, provide config `__call(instance, ...)`.

On that path, Tecs allocates the FFI instance, applies `defaults`, and then calls
your hook. It does **not** auto-run `init` afterwards, so call `Component.init(...)`
explicitly if you want to reuse init logic.

For example:

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

Use `defaults` for static default values; use `init` for validation,
normalization, and derived state.
