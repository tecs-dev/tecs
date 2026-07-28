---
description: "lua-cjson with the build's own copy made reachable: encode, decode, the null and empty-array sentinels, and the encoder's settings"
outline: deep
---

# tecs.json

`tecs.json` is lua-cjson, vendored under `vendor/cjson` and compiled as part of the build. The module is a
thin wrapper in one respect only: it puts this tree's own library directories on `package.cpath` and then
returns the C module, so `tecs.json` **is** the `cjson` table. Every field lua-cjson exports is a field on it.

Snapshots, the debug server's protocol and Aseprite sheet exports all round-trip through it, which is why the
parser and the encoder are C rather than Lua.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.json`. `tecs`
is also set as a global, which makes the require line optional, and engine modules such as this one are
resolved lazily on first field access. `require("cjson")` reaches the same table.

## Finding the build's own copy

The build produces the C module twice from one set of sources: linked into the host, where `require("cjson")`
is answered from `package.preload`, and as `lib/cjson.so`, which a plain interpreter has to find on
`package.cpath`. A command line tool built on this ECS runs the second way, and the default `cpath` reaches
whatever the system happens to have installed rather than the copy shipped beside the Lua.

So the tree's own library directories go on the front of `cpath` before the module is asked for, ahead of the
default rather than behind it: a system-wide cjson of some other version otherwise answers first and the
pinned copy is never the one that runs. Under the host, `package.preload` wins whatever `cpath` says and none
of this is consulted.

The directories come from the FFI loader, so where this build put its native code is described once. Entries
there carrying `%s` are `ffi.load` patterns for a named dependency and match no Lua module, so they are
skipped. The suffix is `.so` on every platform, because that is what CMake sets on the module rather than
what the platform would pick.

## Converting

### encode

Encodes a Lua value as JSON text.

```teal
function json.encode(value: any): string
```

**Returns:** the encoded text. Raises rather than skipping on a value it cannot represent, which is what makes
it safe to hand arbitrary component data to: a function or a cdata field fails loudly rather than vanishing
from the payload.

### decode

Decodes JSON text into a Lua value.

```teal
function json.decode(text: string): any
```

**Returns:** the decoded value. Raises on malformed input rather than guessing, including on an empty string,
on a truncated document, and on single-quoted keys. Nesting is bounded, so a hostile payload cannot recurse a
protocol server to death.

**Example:**

```teal
local bytes <const> = tecs.assets.read(tecs.paths.asset("levels/1.json"))
local level <const> = tecs.json.decode(bytes)
```

## Sentinels

| Field                 | What it is                                                              |
| --------------------- | ----------------------------------------------------------------------- |
| `json.null`           | JSON `null`. Decoded values use it, and encoding it writes `null` back. |
| `json.empty_array`    | A value that encodes as `[]`.                                           |
| `json.array_mt`       | A metatable that marks a table as an array.                             |
| `json.empty_array_mt` | A metatable that marks a table as an empty array.                       |

::: warning An empty table has no distinguishable encoding
`{}` encodes as an object, so a field that is sometimes a list comes back the wrong shape when it happens to
be empty, and a client parsing it strictly will reject it. A result carrying a possibly-empty list has to say
so.

```teal
local rows: {any} = collect()
return { rows = #rows > 0 and rows or tecs.json.empty_array }
```

That is why every list-valued field the [debug server](/modules/mcp) returns is written this way.
:::

`null` is a light userdata, not `nil`, so a decoded object keeps a key whose value was `null` rather than
losing it. Compare against `tecs.json.null` to test for one.

## Settings

Each setting is a function: called with no argument it returns the current value, called with one it sets it
and returns the new value. They are process-wide.

| Function                                    | Default      | What it controls                                                      |
| ------------------------------------------- | ------------ | --------------------------------------------------------------------- |
| `encode_empty_table_as_object`              | `on`         | Whether `{}` encodes as `{}` rather than `[]`.                        |
| `encode_sparse_array(convert, ratio, safe)` | `off, 2, 10` | Whether a sparse array is converted to an object rather than raising. |
| `encode_max_depth`                          | `1000`       | Nesting the encoder accepts before raising.                           |
| `decode_max_depth`                          | `1000`       | Nesting the decoder accepts before raising.                           |
| `encode_number_precision`                   | `14`         | Significant digits written for a number.                              |
| `encode_keep_buffer`                        | `on`         | Whether the encode buffer is reused between calls.                    |
| `encode_invalid_numbers`                    | `off`        | Whether NaN and infinity encode rather than raising.                  |
| `decode_invalid_numbers`                    | `on`         | Whether `nan` and `inf` are accepted in input.                        |
| `encode_escape_forward_slash`               | `on`         | Whether `/` is written as `\/`.                                       |
| `encode_skip_unsupported_value_types`       | `off`        | Whether an unencodable value is skipped rather than raising.          |
| `encode_indent`                             | none         | Indent string for pretty output. Unset writes compact JSON.           |
| `decode_array_with_array_mt`                | `off`        | Whether decoded arrays carry `array_mt`.                              |
| `decode_allow_comment`                      | `off`        | Whether comments are tolerated in input.                              |

`json.new()` returns an independent module table with its own settings, for code that needs to change one
without changing it for everybody. `json._NAME` and `json._VERSION` identify the library.

::: tip Integers stay exact
Entity ids round-trip as integers rather than coming back as `1.0` or drifting, which is what lets an id cross
the debug protocol and be used to address the same entity.
:::

## Design record

- [Workers and assets](https://github.com/tecs-dev/tecs/blob/main/README.md#workers-and-assets)
- [The surface is a global](https://github.com/tecs-dev/tecs/blob/main/README.md#the-surface-is-a-global)
