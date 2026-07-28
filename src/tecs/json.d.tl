--- JSON: a Lua value to text, and text back to a Lua value.
---
--- The parser and the encoder are lua-cjson, in C, so a snapshot, a debug
--- protocol frame or a sprite sheet crosses without a Lua parser in the way.
---
---     local text <const> = tecs.json.encode({name = "player", hp = 100})
---     local value <const> = tecs.json.decode(text)
---
--- Both raise rather than guess. `encode` raises on a value JSON has no form
--- for, a function or a cdata among them, so a field never silently vanishes
--- from a payload; `decode` raises on anything malformed, the empty string
--- included, and bounds its own nesting so a hostile document cannot recurse
--- a server to death.
---
--- What a Lua table cannot say for itself, two sentinels say. `null` is the
--- JSON null, which is not `nil`, so a decoded object keeps a key whose value
--- was null instead of losing it. `empty_array` encodes as `[]`, which an
--- empty table cannot: `{}` is ambiguous between an object and a list, and
--- the encoder writes an object.
---
--- Both are lua-cjson's own values rather than copies of them, because a
--- sentinel is compared by identity and a second null of this module's own
--- would be a bug factory: `tecs.json.null == require("cjson").null` and
--- either spelling tests the same thing. The whole module is that library's
--- table, so every field here is the field `require("cjson")` answers with,
--- and this file declares them rather than wrapping them. `json.tl` beside it
--- is the other half: it makes the build's own copy reachable and returns it.
---
--- The settings keep lua-cjson's own spelling, `encode_escape_forward_slash`
--- and its siblings, rather than this tree's camelCase. They are that
--- library's API, and renaming them would leave its documentation describing
--- names that do not exist here.
local record json
    --- A value standing for something a Lua table cannot express: `null` and
    --- `empty_array`, and nothing else.
    ---
    --- Opaque, and named rather than typed. It is a C light userdata, which
    --- Teal has no name for, and the only things done with one are `==` and
    --- putting it in a payload beside values of every other type. A record
    --- would make `#rows > 0 and rows or json.empty_array`, which is how the
    --- sentinel is nearly always reached, fail to type-check for expressing
    --- exactly what it is for.
    type Sentinel = any

    --- Encodes a Lua value as JSON text.
    ---
    --- Raises on a value JSON has no form for: a function, a coroutine, a
    --- cdata, or a number that is NaN or infinite unless
    --- `encode_invalid_numbers` says otherwise. A table is an array when its
    --- keys run `1..n` and an object otherwise, so an empty one is an object
    --- and `empty_array` is how to say the other thing.
    encode: function(value: any): string

    --- Decodes JSON text into a Lua value.
    ---
    --- Objects and arrays both answer as tables, and a JSON null answers as
    --- `null`. Raises on malformed input rather than returning nil, so code
    --- that expects to be handed rubbish wraps this in `pcall`.
    decode: function(text: string): any

    --- JSON `null`, which is not `nil`.
    ---
    --- A decoded object keeps a key whose value was null and gives it this,
    --- so an absent key and a null one stay apart: `value.name == nil` is
    --- absent and `value.name == json.null` is null. Encoding it writes
    --- `null` back, which is how a field says that it was asked and the
    --- answer is nothing:
    ---
    ---     return {world = worldContext() or json.null}
    null: Sentinel

    --- A value that encodes as `[]`.
    ---
    --- An empty Lua table has no distinguishable encoding, so a field that is
    --- sometimes a list comes back as `{}` exactly when it is empty, and a
    --- client parsing it strictly rejects it. Say which one is meant:
    ---
    ---     return {rows = #rows > 0 and rows or json.empty_array}
    empty_array: Sentinel

    --- Metatable marking a table as an array whatever it holds.
    ---
    --- What `empty_array` is for a value nobody fills in, this is for a table
    --- that is built and may come out empty: `setmetatable(rows, array_mt)`
    --- once, and it encodes as a list whether or not anything went in. The
    --- encoder then writes `#rows` entries and skips its sparse-array check,
    --- so a table with a hole is truncated at the hole rather than raising.
    array_mt: metatable<{any}>

    --- Metatable turning an otherwise empty table into `[]`.
    ---
    --- Reached only once the table has been found to hold no entries at
    --- `1..n`, so it settles the empty case and changes nothing else. Set it
    --- rather than `array_mt` on a table that will be filled and might not
    --- be, when keeping the sparse-array check matters.
    empty_array_mt: metatable<{any}>

    --- Whether `{}` encodes as an object rather than as `[]`. On by default.
    ---
    --- Every setting reads the same way: called with no argument it answers
    --- the current value, called with one it sets it and answers the new one.
    --- They are process-wide, which is what `new` exists to escape.
    encode_empty_table_as_object: function(setting?: boolean | string): boolean

    --- Whether a decoded array carries `array_mt`, so that it re-encodes as a
    --- list even when it decoded empty. Off by default.
    decode_array_with_array_mt: function(setting?: boolean | string): boolean

    --- Whether `/* ... */` and `// ...` are tolerated in input. Off by
    --- default, since neither is JSON.
    decode_allow_comment: function(setting?: boolean | string): boolean

    --- Whether a sparse array is converted to an object rather than raising,
    --- and when an array counts as sparse.
    ---
    --- `ratio` is the multiple of the entry count that the largest index may
    --- reach before the array is called sparse, and `safe` is a largest index
    --- below which it never is. Off, 2 and 10 by default.
    encode_sparse_array: function(
        convert?: boolean | string, ratio?: integer, safe?: integer
    ): boolean, integer, integer

    --- Nesting the encoder accepts before raising. 1000 by default.
    encode_max_depth: function(depth?: integer): integer

    --- Nesting the decoder accepts before raising. 1000 by default, and what
    --- keeps a hostile document from exhausting the C stack.
    decode_max_depth: function(depth?: integer): integer

    --- Significant digits written for a number. 14 by default, which is what
    --- keeps an entity id exact rather than writing it back as `1.0`.
    encode_number_precision: function(precision?: integer): integer

    --- Whether the encode buffer is kept between calls rather than freed. On
    --- by default: it trades a resident buffer for not reallocating one per
    --- encode.
    encode_keep_buffer: function(keep?: boolean | string): boolean

    --- What NaN and infinity encode as. Off by default, which raises;
    --- `"null"` writes them as null, and on writes them as `NaN` and
    --- `Infinity`, which no other parser reads.
    encode_invalid_numbers: function(setting?: boolean | string): boolean | string

    --- Whether `nan` and `inf` are accepted in input. On by default.
    decode_invalid_numbers: function(setting?: boolean | string): boolean

    --- Whether `/` is written as `\/`. On by default.
    encode_escape_forward_slash: function(setting?: boolean | string): boolean

    --- Whether a value JSON has no form for is skipped rather than raising.
    --- Off by default, and worth leaving off: skipping is how a field goes
    --- missing from a payload with nothing said about it.
    encode_skip_unsupported_value_types: function(setting?: boolean | string): boolean

    --- Indent string for pretty output, answered as the current one. Unset,
    --- and by default, the encoder writes compact JSON.
    encode_indent: function(indent?: string): string

    --- An independent module table with its own settings.
    ---
    --- The settings above are process-wide, so code that has to change one
    --- without changing it for everybody takes a copy. The sentinels are
    --- shared with every copy, since identity is the whole point of them.
    new: function(): json

    --- The library's own name, `"cjson"`.
    _NAME: string

    --- The library's version.
    _VERSION: string
end

return json
