--- JSON, the half of `tecs.data` that turns a Lua value into text and text
--- back into a Lua value.
---
--- The parser and the encoder are lua-cjson, in C, so a snapshot, a debug
--- protocol frame or a sprite sheet crosses without a Lua parser in the way.
---
---     local text <const> = tecs.data.encodeJSON({name = "player", hp = 100})
---     local value <const> = tecs.data.decodeJSON(text)
---
--- Both raise rather than guess. `encodeJSON` raises on a value JSON has no
--- form for, a function or a cdata among them, so a field never silently
--- vanishes from a payload; `decodeJSON` raises on anything malformed, the
--- empty string included, and bounds its own nesting so a hostile document
--- cannot recurse a server to death.
---
--- What a Lua table cannot say for itself, two sentinels say. `null` is the
--- JSON null, which is not `nil`, so a decoded object keeps a key whose value
--- was null instead of losing it. `empty_array` encodes as `[]`, which an
--- empty table cannot: `{}` is ambiguous between an object and a list, and the
--- encoder writes an object.
---
--- Both are lua-cjson's own values rather than copies of them, because a
--- sentinel is compared by identity and a second null of this module's own
--- would be a bug factory: `tecs.data.null == require("cjson").null` and either
--- spelling tests the same thing.
---
--- **The two verbs are qualified and nothing else is.** `tecs.data` also
--- compresses and hashes, so a bare `encode` there would name three things at
--- once. The sentinels and the settings keep lua-cjson's own spelling,
--- `empty_array` and `encode_escape_forward_slash` among them, rather than this
--- tree's camelCase: they are that library's API, and renaming them would leave
--- its documentation describing names that do not exist here.

local loader <const> = require("tecs.ffi.loader")

-- The parser and encoder are C, from `vendor/cjson`, and the build produces
-- them twice: linked into the host, where `require("cjson")` is answered from
-- `package.preload`, and as `lib/cjson.so`, which a plain interpreter has to
-- find on `package.cpath`. A command line tool built on this ECS runs the
-- second way, and the default `cpath` reaches whatever the system happens to
-- have installed rather than the copy shipped beside the Lua.
--
-- So the tree's own library directories go on the front of `cpath` before the
-- module is asked for. Ahead of the default rather than behind it: a
-- system-wide cjson of some other version otherwise answers first and the
-- pinned copy is never the one that runs. Under the host `package.preload`
-- wins whatever `cpath` says, and none of this is consulted.
--
-- The directories come from the loader, so where this build put its native
-- code is described once. Entries there carrying `%s` are `ffi.load` patterns
-- for a named dependency and match no Lua module, so they are skipped. The
-- suffix is `.so` on every platform, because that is what CMake sets on the
-- module rather than what the platform would pick.
local candidates: {string} = {}
for _, directory in ipairs(loader.searchPaths) do
    if not directory:find("%%s") then
        candidates[#candidates + 1] = directory .. "?.so"
    end
end
candidates[#candidates + 1] = package.cpath
package.cpath = table.concat(candidates, ";")

--- JSON encoding and decoding, and the sentinels and settings lua-cjson carries
--- with them.
local record data
    --- A value standing for something a Lua table cannot express: `null` and
    --- `empty_array`, and nothing else.
    ---
    --- Opaque, and named rather than typed. It is a C light userdata, which
    --- Teal has no name for, and the only things done with one are `==` and
    --- putting it in a payload beside values of every other type. A record
    --- would make `#rows > 0 and rows or data.empty_array`, which is how the
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
    ---
    --- @param value Any Lua value JSON has a form for. Reached recursively, so
    ---     a table holding itself raises at `encode_max_depth` rather than
    ---     running out of stack.
    --- @return The document, compact unless `encode_indent` says otherwise.
    encodeJSON: function(value: any): string

    --- Decodes JSON text into a Lua value.
    ---
    --- @param text A whole document. Objects and arrays both answer as tables,
    ---     and a JSON null answers as `null`.
    --- @return The value. Raises on malformed input rather than returning nil,
    ---     the empty string included, so code that expects to be handed rubbish
    ---     wraps this in `pcall`.
    decodeJSON: function(text: string): any

    --- JSON `null`, which is not `nil`.
    ---
    --- A decoded object keeps a key whose value was null and gives it this,
    --- so an absent key and a null one stay apart: `value.name == nil` is
    --- absent and `value.name == data.null` is null. Encoding it writes
    --- `null` back, which is how a field says that it was asked and the
    --- answer is nothing:
    ---
    ---     return {world = worldContext() or data.null}
    null: Sentinel

    --- A value that encodes as `[]`.
    ---
    --- An empty Lua table has no distinguishable encoding, so a field that is
    --- sometimes a list comes back as `{}` exactly when it is empty, and a
    --- client parsing it strictly rejects it. Say which one is meant:
    ---
    ---     return {rows = #rows > 0 and rows or data.empty_array}
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
    --- They are process-wide, which is what `newJSON` exists to escape.
    ---
    --- @param setting Omitted only reads. A string is read as a boolean, which
    ---     is how lua-cjson takes a setting out of a configuration file.
    --- @return The setting after the call.
    encode_empty_table_as_object: function(setting?: boolean | string): boolean

    --- Whether a decoded array carries `array_mt`, so that it re-encodes as a
    --- list even when it decoded empty. Off by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_array_with_array_mt: function(setting?: boolean | string): boolean

    --- Whether `/* ... */` and `// ...` are tolerated in input. Off by
    --- default, since neither is JSON.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_allow_comment: function(setting?: boolean | string): boolean

    --- Whether a sparse array is converted to an object rather than raising,
    --- and when an array counts as sparse.
    ---
    --- @param convert Omitted only reads, and reads all three.
    --- @param ratio The multiple of the entry count that the largest index may
    ---     reach before the array is called sparse. 2 by default.
    --- @param safe A largest index below which an array never counts as
    ---     sparse. 10 by default.
    --- @return Whether conversion is on, off by default.
    --- @return The ratio after the call.
    --- @return The safe bound after the call.
    encode_sparse_array: function(
        convert?: boolean | string, ratio?: integer, safe?: integer
    ): boolean, integer, integer

    --- Nesting the encoder accepts before raising. 1000 by default.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    encode_max_depth: function(depth?: integer): integer

    --- Nesting the decoder accepts before raising. 1000 by default, and what
    --- keeps a hostile document from exhausting the C stack.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    decode_max_depth: function(depth?: integer): integer

    --- Significant digits written for a number. 14 by default, which is what
    --- keeps an entity id exact rather than writing it back as `1.0`.
    ---
    --- @param precision Omitted only reads. 1 to 14.
    --- @return The precision after the call.
    encode_number_precision: function(precision?: integer): integer

    --- Whether the encode buffer is kept between calls rather than freed. On
    --- by default: it trades a resident buffer for not reallocating one per
    --- encode.
    ---
    --- @param keep Omitted only reads.
    --- @return The setting after the call.
    encode_keep_buffer: function(keep?: boolean | string): boolean

    --- What NaN and infinity encode as. Off by default, which raises;
    --- `"null"` writes them as null, and on writes them as `NaN` and
    --- `Infinity`, which no other parser reads.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call, which is `"null"` rather than a
    ---     boolean when that is what is in force.
    encode_invalid_numbers: function(setting?: boolean | string): boolean | string

    --- Whether `nan` and `inf` are accepted in input. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_invalid_numbers: function(setting?: boolean | string): boolean

    --- Whether `/` is written as `\/`. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_escape_forward_slash: function(setting?: boolean | string): boolean

    --- Whether a value JSON has no form for is skipped rather than raising.
    --- Off by default, and worth leaving off: skipping is how a field goes
    --- missing from a payload with nothing said about it.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_skip_unsupported_value_types: function(setting?: boolean | string): boolean

    --- Indent string for pretty output. Unset, and by default, the encoder
    --- writes compact JSON.
    ---
    --- @param indent Omitted only reads. Whitespace, one level's worth.
    --- @return The indent after the call.
    encode_indent: function(indent?: string): string

    --- An independent JSON table with its own settings.
    ---
    --- The settings above are process-wide, so code that has to change one
    --- without changing it for everybody takes a copy.
    ---
    --- @return A table carrying every name here and none of the compression or
    ---     hashing `tecs.data` also holds, since those have nothing to
    ---     configure. The sentinels are shared with every copy, as identity is
    ---     the whole point of them.
    newJSON: function(): data

    --- The library's own name, `"cjson"`.
    _NAME: string

    --- The library's version.
    _VERSION: string
end

--- What comes straight off lua-cjson under the name that library gives it.
---
--- Listed rather than copied wholesale, so a member the library gains does not
--- appear on the public surface unannounced, and one it drops is a nil this
--- file can be searched for rather than a name that quietly stops resolving.
local CARRIED <const>: {string} = {
    "null",
    "empty_array",
    "array_mt",
    "empty_array_mt",
    "encode_empty_table_as_object",
    "decode_array_with_array_mt",
    "decode_allow_comment",
    "encode_sparse_array",
    "encode_max_depth",
    "decode_max_depth",
    "encode_number_precision",
    "encode_keep_buffer",
    "encode_invalid_numbers",
    "decode_invalid_numbers",
    "encode_escape_forward_slash",
    "encode_skip_unsupported_value_types",
    "encode_indent",
    "_NAME",
    "_VERSION",
}

--- Fills `into` with one lua-cjson table's members under this module's names.
---
--- Runs twice over: once onto the record below, which is what this module
--- returns, and once per `newJSON` onto a fresh table with settings of its own.
local function adopt(into: {string: any}, library: {string: any}): data
    for _, name in ipairs(CARRIED) do
        into[name] = library[name]
    end
    into.encodeJSON = library.encode
    into.decodeJSON = library.decode
    into.newJSON = function(): data
        return adopt({}, (library.new as function(): {string: any})())
    end
    return into as data
end

adopt(data as {string: any}, require("cjson") as {string: any})

return data
