---
outline: deep
---

# Tecs JSON

Tecs JSON is a high-performance JSON parser and serializer optimized for [LuaJIT](https://luajit.org/).

- **Fast parsing**: Optimized for LuaJIT with [FFI](https://luajit.org/ext_ffi.html) support
- **CData support**: Parse directly from [Love2D ByteData](https://love2d.org/wiki/ByteData) or other FFI pointers
- **Pretty printing**: Optional formatted output with customizable indentation
- **Null handling**: Sentinel values for distinguishing JSON null from Lua nil

## Installation

Tecs JSON is included as part of the tecs package. See the [Tecs Quickstart](/tecs/) for project setup.

## Quick start

```teal
local json = require("tecs.utils.json")

-- Parse JSON string
local data = json.parse('{"name": "Player", "health": 100}')
print(data.name)    -- "Player"
print(data.health)  -- 100

-- Serialize to JSON (key order is unspecified without sortKeys)
local str = json.serialize({name = "Enemy", health = 50})
print(str)  -- e.g. {"name":"Enemy","health":50}
```

## API reference

### parse

Parse a JSON string into a Lua value.

```teal
function json.parse(str: string): any
```

**Parameters:**

- `str`: JSON string to parse

**Returns:**

- Parsed Lua value (table, string, number, boolean, or nil)

**Example:**

```teal
local data = json.parse('{"name": "Player", "health": 100}')
print(data.name)  -- "Player"
```

### parseCData

Parse JSON directly from an FFI pointer. Useful for parsing Love2D ByteData without string conversion.

```teal
function json.parseCData(data: ffi.CData, length: integer): any
```

**Parameters:**

- `data`: Pointer to JSON data
- `length`: Length of data in bytes

**Returns:**

- Parsed Lua value

**Example:**

```teal
local fileData = love.filesystem.read("data", "config.json")
local config = json.parseCData(fileData:getFFIPointer(), fileData:getSize())
```

### serialize

Serialize a Lua value to a compact JSON string.

```teal
function json.serialize(value: any, sortKeys?: boolean): string
```

**Parameters:**

- `value`: Value to serialize (table, string, number, boolean, nil)
- `sortKeys`: Optional. Sort object keys alphabetically (default: false)

**Returns:**

- JSON string

**Example:**

```teal
-- Without sortKeys, object key order is unspecified.
local str = json.serialize({name = "Enemy", health = 50})
print(str)  -- e.g. {"name":"Enemy","health":50}

-- Pass sortKeys = true for deterministic, alphabetically-ordered output.
local str = json.serialize({b = 2, a = 1}, true)
print(str)  -- {"a":1,"b":2}
```

### serializePretty

Serialize a Lua value to a formatted JSON string with indentation.

```teal
function json.serializePretty(value: any, sortKeys?: boolean, indent?: string): string
```

**Parameters:**

- `value`: Value to serialize
- `sortKeys`: Optional. Sort object keys (default: true)
- `indent`: Optional. Indent string (default: two spaces)

**Returns:**

- Formatted JSON string

**Example:**

```teal
local data = {name = "Player", stats = {health = 100}}
print(json.serializePretty(data))
-- {
--   "name": "Player",
--   "stats": {
--     "health": 100
--   }
-- }
```

## Sentinel values

### json.NULL

Represents JSON `null` in Lua. Use this to distinguish explicit null values from missing keys.

```teal
local data = json.parse('[1, null, 3]')
print(data[2] == json.NULL)  -- true

local str = json.serialize({value = json.NULL})
print(str)  -- {"value":null}
```

### json.EMPTY_ARRAY

Explicitly serializes as `[]`. This is the default for empty tables, but provided for symmetry.

```teal
local str = json.serialize(json.EMPTY_ARRAY)  -- []
```

### json.EMPTY_OBJECT

Forces an empty table to serialize as `{}` instead of `[]`.

```teal
local str = json.serialize({})                 -- []
local str = json.serialize(json.EMPTY_OBJECT)  -- {}
```
