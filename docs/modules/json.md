---
description: "Encoding a Lua value as JSON and decoding text back: what raises, what an empty table encodes as, the null and empty-array sentinels, and the settings"
outline: deep
---

# tecs.json

`tecs.json` turns a Lua value into JSON text, and JSON text back into a Lua value.

```teal
local text <const> = tecs.json.encode({name = "player", hp = 100})
local value <const> = tecs.json.decode(text)
```

The parser and the encoder are lua-cjson, in C, so a snapshot, a debug protocol frame or an Aseprite sheet
export crosses without a Lua parser in the way. Both calls raise rather than guess, which is what makes them
safe to point at data nobody vetted: a value JSON cannot hold fails at the call instead of vanishing from the
payload, and a malformed document fails instead of decoding to something plausible.

The module is that library's table rather than a wrapper around it. `tecs.json` and `require("cjson")` are one
table, so every function is the same function and every sentinel is the same value. What this tree adds is the
type declaration in `src/tecs/json.d.tl`, which is why a misspelled field, a wrong argument count or a return
used as the wrong type is a type error here rather than a surprise at runtime.

## encode

Encodes a Lua value as JSON text.

```teal
function json.encode(value: any): string
```

**Parameters:**

- `value`: any Lua value JSON has a form for. Tables, strings, numbers, booleans, `nil`, and the sentinels
  below.

**Returns:** the encoded text, compact, with no spaces or newlines unless `encode_indent` is set.

**Example:**

```teal
local body <const> = tecs.json.encode({
    jsonrpc = "2.0",
    id = 1,
    result = {entities = ids},
})
```

A table encodes as an array when its keys run `1..n` and as an object otherwise, which leaves one case the
value cannot settle for itself:

```teal
tecs.json.encode({}) --> "{}"
```

An empty table is both an empty object and an empty list, and the encoder writes the object. That is what
[`empty_array`](#empty-array) is for.

`nil` encodes as `null`, and so does [`json.null`](#null). A table _field_ set to `nil` is not a field at all,
so it never reaches the encoder and the key is simply absent from the output.

Numbers are written to 14 significant digits by default, which keeps an entity id exact rather than writing it
back as `1.0`.

::: warning It raises rather than skipping
A function, a coroutine, a cdata, a userdata that is not one of the sentinels, and a number that is NaN or
infinite all raise. So does a table nested past `encode_max_depth`, and a table so sparse that
`encode_sparse_array` calls it sparse.

Loud is the point. A payload that silently lost a field is debugged at the far end, by whoever parses it, with
nothing to say which side dropped it. If skipping really is what you want, `encode_skip_unsupported_value_types`
turns it on process-wide.
:::

## decode

Decodes JSON text into a Lua value.

```teal
function json.decode(text: string): any
```

**Parameters:**

- `text`: a JSON document. A bare number, string, boolean or `null` is one, so `decode("7")` answers `7`.

**Returns:** the decoded value. Objects and arrays both answer as tables, and a JSON null answers as
[`json.null`](#null) rather than `nil`, so a key whose value was null survives the trip.

**Example:**

```teal
local bytes <const> = tecs.assets.read(tecs.paths.asset("levels/1.json"))
local level <const> = tecs.json.decode(bytes)
```

[`assets.read`](/modules/assets) answers `nil` for a path with no file, so an absent document stays
distinguishable from a malformed one, which this raises on.

Malformed means malformed: a truncated document, a single-quoted key, a trailing comma, a comment, and the
empty string. Nesting is bounded by `decode_max_depth`, so a hostile payload cannot recurse a protocol server
to death. Code that expects to be handed rubbish wraps the call:

```teal
local ok, value = pcall(tecs.json.decode, text)
if not ok then
    return respond(PARSE_ERROR, "invalid JSON")
end
```

::: warning A decoded `[]` re-encodes as `{}`
Decoding loses the distinction the same way an empty table constructor does: `[]` and `{}` both answer an
empty Lua table, and encoding one writes `{}`. A document that round-trips through this module therefore comes
back with its empty lists turned into empty objects.

`decode_array_with_array_mt` fixes it for a whole decode by marking every decoded array with
[`array_mt`](#array-mt-and-empty-array-mt), which survives to the re-encode.
:::

## Sentinels

Two values say what a Lua table cannot say for itself, and two metatables do the same job for a table that is
built rather than written out.

They are lua-cjson's own values, re-exported rather than copied. A sentinel is tested by identity, so
`tecs.json.null == require("cjson").null` is true and a reader comparing against either spelling is comparing
against the same object. A second null of this module's own would be a bug factory: two values that both mean
null and are not equal.

### null

JSON `null`, which is not `nil`.

A decoded object keeps a key whose value was null and gives it this, so an absent key and a null one stay
apart:

```teal
local value <const> = tecs.json.decode('{"name":null}')
value.name == nil            --> false, the key is there
value.name == tecs.json.null --> true, and its value is null
value.missing == nil         --> true, that key was never sent
```

Encoding it writes `null` back, which is how a field says it was asked and the answer is nothing:

```teal
return {world = worldContext() or tecs.json.null}
```

Written as `nil` instead, that field would be absent, and a client that distinguishes "no world" from "field
not implemented" cannot tell which it got.

### empty_array {#empty-array}

A value that encodes as `[]`.

An empty Lua table encodes as `{}`, so a field that is sometimes a list comes back the wrong shape exactly
when it is empty, and a client parsing it strictly rejects it. The field has to say which one it means:

```teal
local rows: {any} = collect()
return {rows = #rows > 0 and rows or tecs.json.empty_array}
```

That is why every list-valued field the [debug server](/modules/mcp) returns is written this way, and why an
input schema with no properties is `{type = "object", properties = tecs.json.empty_array}`.

### array_mt and empty_array_mt {#array-mt-and-empty-array-mt}

Metatables, for the same problem reached from the other side: a table you are about to fill and might not.

```teal
local rows <const> = setmetatable({}, tecs.json.array_mt)
for _, hit in ipairs(hits) do
    rows[#rows + 1] = describe(hit)
end
return {rows = rows} -- "[]" when nothing matched, a list when something did
```

`array_mt` marks a table as an array whatever it holds. The encoder then writes `#rows` entries and skips its
sparse-array check, so a table with a hole in it is truncated at the hole rather than raising.
`empty_array_mt` is reached only once the table has been found to hold no entries at `1..n`, so it settles the
empty case and changes nothing else, sparse-array check included.

## Settings

Each setting is a function. Called with no argument it answers the current value, called with one it sets it
and answers the new one. They are process-wide.

The names are lua-cjson's own, `encode_escape_forward_slash` and its twelve siblings, rather than this tree's
camelCase: they are that library's API, and renaming them would leave its documentation describing names that
do not exist here.

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

The four that change what a payload _means_ rather than how it looks are worth knowing by name:
`encode_empty_table_as_object` and `decode_array_with_array_mt` decide the empty-list question above,
`encode_number_precision` decides whether an id survives, and `encode_skip_unsupported_value_types` decides
whether a bad field is loud or missing.

`json.new()` answers an independent module table with its own settings, for code that has to change one
without changing it for everybody. The sentinels are shared with every copy, since identity is the whole point
of them. `json._NAME` and `json._VERSION` identify the library.

::: tip Integers stay exact
Entity ids round-trip as integers rather than coming back as `1.0` or drifting, which is what lets an id cross
the debug protocol and be used to address the same entity.
:::

## Finding the build's own copy

Not something a caller does anything about, and here because the alternative is finding it out from a version
mismatch.

The build produces the C module twice from one set of sources: linked into the host, where `require("cjson")`
is answered from `package.preload`, and as `lib/cjson.so`, which a plain interpreter has to find on
`package.cpath`. A command line tool built on this ECS runs the second way, and the default `cpath` reaches
whatever the system happens to have installed rather than the copy shipped beside the Lua. So the tree's own
library directories go on the front of `cpath` before the module is asked for, ahead of the default rather
than behind it: a system-wide cjson of some other version otherwise answers first and the pinned copy is never
the one that runs. Under the host, `package.preload` wins whatever `cpath` says and none of this is consulted.

## Design record

- [Workers and assets](https://github.com/tecs-dev/tecs/blob/main/README.md#workers-and-assets)
