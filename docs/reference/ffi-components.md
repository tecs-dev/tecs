# FFI Components

FFI (Foreign Function Interface) components leverage LuaJIT's FFI capabilities to provide high-performance,
cache-friendly component storage using C structs instead of Lua tables. When LuaJIT FFI is available, FFI components
provide maximum performance. When FFI is not available (e.g., standard Lua 5.1+), they automatically fall back to
optimized table-based storage with the same API. Use FFI components if your data is mostly made up of numbers,
booleans, and other primitive types that map cleanly to LuaJIT FFI. Otherwise, use normal components.

FFI components have the following benefits:

- **Performance**: Direct memory access without Lua table overhead
- **Cache Locality**: Struct-of-Arrays layout for better CPU cache utilization
- **Memory Efficiency**: Compact C struct representation
- **Type Safety**: C type definitions with automatic conversions
- **Zero-Copy Operations**: Direct memory operations without intermediate allocations

## Basic Usage

Define FFI components using `tecs.newFFIComponent`:

```lua
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

## Field Types

FFI components support all standard C types:

### Numeric Types

- **Integers**: `int8_t`, `int16_t`, `int32_t`, `int64_t`, `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t`
- **Floating Point**: `float`, `double`, `long double`
- **Standard C**: `char`, `short`, `int`, `long`, `size_t`, `ptrdiff_t`
- **Boolean**: `bool`, `_Bool`

### Pointer Types

- **Generic**: `void*`
- **String**: `char*`, `const char*`
- **Numeric**: `int*`, `float*`, `double*`

### Fixed-Size Arrays

You can define fixed-size arrays by appending `[size]` to any type:
- **Numeric Arrays**: `float[16]`, `int32_t[4]`, `uint8_t[256]`
- **Matrix/Vector**: `float[3]` for vec3, `float[16]` for mat4
- **Buffers**: `char[256]` for string buffers

Example with various types including arrays:

```lua
-- Transform with matrix
local record Transform3D is tecs.Component
    matrix: {number, number, number, number} -- 4x4 matrix
    position: {number, number, number}       -- vec3
end

tecs.newFFIComponent({
    name = "Transform3D",
    container = Transform3D,
    fields = {
        {"matrix", "float[16]"},  -- 4x4 matrix
        {"position", "float[3]"}  -- x, y, z
    }
})

-- Player with various types
local record Player is tecs.Component
    health: integer
    inventory: {integer}  -- item IDs
end

tecs.newFFIComponent({
    name = "Player",
    container = Player,
    fields = {
        {"health", "int32_t"},
        {"inventory", "int32_t[10]"}, -- 10 item slots
    }
})
```

## Constructor Support

FFI components support multiple construction patterns:

### Positional Arguments

Positional arguments are preferred since they require no intermediate table allocations.

```lua
-- Define component
local record Position is tecs.Component
    x: number
    y: number
    z: number
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
local pos1 = Position(10, 20)      -- z defaults to 0
local pos2 = Position(10, 20, 30)  -- all values provided
```

### Table Arguments

A table of arguments can be provided so long as the key value pairs in the table match the fields. This constructor
style is useful for more complex components.

```lua
-- Same component, constructed with table
local pos3 = Position({x = 10, y = 20})
local pos4 = Position({x = 10, y = 20, z = 30})
```

### Default Values

FFI components automatically provide sensible defaults:

- Numeric types: `0` or `0.0`
- Pointers: `nil`
- Booleans: `false`
- See https://luajit.org/ext_ffi_semantics.html#init_table

## Fallback Behavior

If LuaJIT FFI is unavailable, components automatically fall back to Lua tables:

```lua
-- This code works identically with FFI or table storage
local vel = Velocity(10, 20)
vel.x = vel.x + 5
print(vel.x, vel.y)  -- 15, 20
```

## Limitations

For more details on LuaJIT FFI limitations and semantics, see the
[official LuaJIT FFI documentation](https://luajit.org/ext_ffi.html) and
[FFI semantics](https://luajit.org/ext_ffi_semantics.html).

## API Reference

### tecs.newFFIComponent(options)

Creates an FFI-based component with optimized memory layout and optional recycling.

| Parameter             | Type                      | Description                               | Required  |
|-----------------------|---------------------------|-------------------------------------------|-----------|
| `options`             | `table`                   | Configuration options for FFI component   | Yes       |
| `options.name`        | `string`                  | Component name                            | Yes       |
| `options.container`   | `Component`               | Component container/type                  | Yes       |
| `options.fields`      | `{ {string, string} }`    | Array of field tuples `{name, type}`      | Yes       |
| `options.recycle`     | `boolean`                 | Enable component recycling (pool of 64)   | No        |
| `options.constructor` | `function`                | Optional constructor function             | No        |
| `options.initializer` | `function`                | Validation and initialization function    | No        |
| `options.onAdd`       | `function`                | Hook called when component is added       | No        |
| `options.onRemove`    | `function`                | Hook called when component is removed     | No        |

**Returns:** The created FFI `Component`

**Example:**

```lua
local record Velocity is tecs.Component
    x: number
    y: number
    speed: {number, number}
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},       -- Field name and C type
        {"y", "float"},
        {"speed", "float[2]"} -- Arrays supported
    },
    recycle = true
})
```

### Initializers

FFI components can include an optional `initializer` function for validation and custom defaults:

```lua
initializer = function(constructor: function(...: any): Component, ...: any): Component
```

```lua
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
    initializer = function(
        constructor: function(...: any): Health,
        current: integer,
        maximum: integer
    ): Health
        current = current or 100
        maximum = maximum or 100
        if current < 0 then
            error("Health current cannot be negative")
        end
        if maximum <= 0 then
            error("Health maximum must be positive")
        end
        return constructor(current, maximum)
    end
})
```

## Component Recycling

When `recycle = true` is set, FFI storage maintains a pool of reusable components:

1. **Pool Initialization**: Pre-allocates 64 components when storage is created
2. **Component Creation**: Pulls from recycle pool if available, otherwise allocates new
3. **Component Removal**: Clears component to defaults and returns to pool (up to 64)
4. **Memory Efficiency**: Reduces allocation overhead for frequently created/destroyed entities

### Performance Considerations

Recycling is beneficial for:
- **Particles**: Thousands of short-lived entities
- **Projectiles**: Frequently spawned and despawned
- **Temporary Effects**: Visual effects, damage numbers, etc.
- **High-Frequency Spawning**: Any component created/destroyed multiple times per frame

Not recommended for:
- **Persistent Entities**: Players, terrain, UI elements
- **Rare Components**: Components created only a few times
- **Large Structs**: Very large components (recycling overhead may exceed allocation cost)

## See Also

- **[Relationships](/reference/relationships)**: Learn about FFI relationships with `newFFIRelationship` for
  high-performance entity relationships that store data
- **[Components](/reference/components)**: Regular component creation and management