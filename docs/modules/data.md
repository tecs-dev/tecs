---
description: "Turning bytes into other bytes: JSON in both directions, DEFLATE in both directions, and a hash over either"
outline: deep
---

# tecs.data

`tecs.data` transforms byte strings. It encodes a Lua value as JSON and decodes text back, compresses and
decompresses DEFLATE, and hashes anything.

One module rather than three, because each of these is a handful of functions over a byte string with no state
to carry, and a game reaching for one is nearly always about to reach for another. A save is encoded,
compressed and stamped; a cache entry is checked the other way round. Three modules of three functions each
would put that one job in three places.

That merge is why the transformations name their format. `encode` on a module that also compresses names two
things at once, so the JSON pair is `encodeJSON` and `decodeJSON`. `fnv1a64` says which hash it is for a
second reason as well: a value produced here is written into files that outlive the process, so the algorithm
is part of the signature and changing it is a rename every caller is rechecked against.

## JSON

```teal
local text <const> = tecs.data.encodeJSON({name = "player", hp = 100})
local value <const> = tecs.data.decodeJSON(text)
```

The parser and the encoder are lua-cjson, in C, so a snapshot, a debug protocol frame or a sprite sheet export
crosses without a Lua parser in the way. Both calls raise rather than guess, which is what makes them safe to
point at data nobody vetted: a value JSON cannot hold fails at the call instead of vanishing from the payload,
and a malformed document fails instead of decoding to something plausible.

Nothing stands between a caller and the library. Every function here is that library's function and every
sentinel is that library's value, so `tecs.data.null == require("cjson").null`. What this tree adds is the two
qualified verbs, since a module that also compresses and hashes cannot have a bare `encode`, and the type
declaration in `src/tecs/data.tl`, which is why a misspelled field, a wrong argument count or a return used as
the wrong type is a type error here rather than a surprise at runtime.

## encodeJSON

Encodes a Lua value as JSON text.

```teal
function data.encodeJSON(value: any): string
```

**Parameters:**

- `value`: any Lua value JSON has a form for. Tables, strings, numbers, booleans, `nil`, and the sentinels
  below.

**Returns:** the encoded text, compact, with no spaces or newlines unless `encode_indent` is set.

**Example:**

```teal
local body <const> = tecs.data.encodeJSON({
    jsonrpc = "2.0",
    id = 1,
    result = {entities = ids},
})
```

A table encodes as an array when its keys run `1..n` and as an object otherwise, which leaves one case the
value cannot settle for itself:

```teal
tecs.data.encodeJSON({}) --> "{}"
```

An empty table is both an empty object and an empty list, and the encoder writes the object. That is what
[`empty_array`](#empty-array) is for.

`nil` encodes as `null`, and so does [`data.null`](#null). A table _field_ set to `nil` is not a field at all,
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

## decodeJSON

Decodes JSON text into a Lua value.

```teal
function data.decodeJSON(text: string): any
```

**Parameters:**

- `text`: a JSON document. A bare number, string, boolean or `null` is one, so `decode("7")` answers `7`.

**Returns:** the decoded value. Objects and arrays both answer as tables, and a JSON null answers as
[`data.null`](#null) rather than `nil`, so a key whose value was null survives the trip.

**Example:**

```teal
local bytes <const> = tecs.filesystem.read(tecs.filesystem.assetPath("levels/1.json"))
local level <const> = tecs.data.decodeJSON(bytes)
```

[`filesystem.read`](/modules/filesystem/) answers `nil` for a path with no file, so an absent document stays
distinguishable from a malformed one, which this raises on.

Malformed means malformed: a truncated document, a single-quoted key, a trailing comma, a comment, and the
empty string. Nesting is bounded by `decode_max_depth`, so a hostile payload cannot recurse a protocol server
to death. Code that expects to be handed rubbish wraps the call:

```teal
local ok, value = pcall(tecs.data.decodeJSON, text)
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
`tecs.data.null == require("cjson").null` is true and a reader comparing against either spelling is comparing
against the same object. A second null of this module's own would be a bug factory: two values that both mean
null and are not equal. Their names are that library's too, `empty_array` rather than `emptyArray`, for the
same reason the settings below keep theirs.

### null

JSON `null`, which is not `nil`.

A decoded object keeps a key whose value was null and gives it this, so an absent key and a null one stay
apart:

```teal
local value <const> = tecs.data.decodeJSON('{"name":null}')
value.name == nil            --> false, the key is there
value.name == tecs.data.null --> true, and its value is null
value.missing == nil         --> true, that key was never sent
```

Encoding it writes `null` back, which is how a field says it was asked and the answer is nothing:

```teal
return {world = worldContext() or tecs.data.null}
```

Written as `nil` instead, that field would be absent, and a client that distinguishes "no world" from "field
not implemented" cannot tell which it got.

### empty_array {#empty-array}

A value that encodes as `[]`.

An empty Lua table encodes as `{}`, so a field that is sometimes a list comes back the wrong shape exactly
when it is empty, and a client parsing it strictly rejects it. The field has to say which one it means:

```teal
local rows: {any} = collect()
return {rows = #rows > 0 and rows or tecs.data.empty_array}
```

That is why every list-valued field the [debug server](/modules/mcp) returns is written this way, and why an
input schema with no properties is `{type = "object", properties = tecs.data.empty_array}`.

### array_mt and empty_array_mt {#array-mt-and-empty-array-mt}

Metatables, for the same problem reached from the other side: a table you are about to fill and might not.

```teal
local rows <const> = setmetatable({}, tecs.data.array_mt)
for _, hit in ipairs(hits) do
    rows[#rows + 1] = describe(hit)
end
return {rows = rows} -- "[]" when nothing matched, a list when something did
```

`array_mt` marks a table as an array whatever it holds. The encoder then writes `#rows` entries and skips its
sparse-array check, so a table with a hole in it is truncated at the hole rather than raising.
`empty_array_mt` is reached only once the table has been found to hold no entries at `1..n`, so it settles the
empty case and changes nothing else, sparse-array check included.

## JSON settings

Each setting is a function. Called with no argument it answers the current value, called with one it sets it
and answers the new one. They are process-wide.

The names are lua-cjson's own, `encode_escape_forward_slash` and its twelve siblings, rather than this tree's
camelCase: they are that library's API, and renaming them would leave its documentation describing names that
do not exist here. Only the two verbs are qualified, and only because `tecs.data` also compresses and hashes.

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

`data.newJSON()` answers an independent JSON table with its own settings, for code that has to change one
without changing it for everybody. It carries the JSON names and none of the compression or hashing ones, since those have nothing to
configure, and the sentinels are shared with every copy because identity is the whole point of them.
`data._NAME` and `data._VERSION` identify the library.

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

## Compression

DEFLATE in both directions: zlib streams, and the raw form inside them. Binary asset formats use both
directions, readers inflating existing chunks while tooling, save formats and network protocols produce
compatible ones.

zlib does both. It is pinned, generated into bindings, carried through the ABI check and loaded the way every
other native library is. HTTP compression belongs to Reqwest now; this copy remains because `tecs.data` exposes
zlib and raw DEFLATE as a public binary-format API. It loads on a worker the same way, so a
[worker](/modules/workers) that requires this module gets the bindings there rather than inheriting anything
from the thread that spawned it.

## inflate

Decompresses a zlib stream, the form RFC 1950 defines.

```teal
function data.inflate(bytes: string, sizeHint?: integer): string
```

**Parameters:**

- `bytes`: the compressed stream, header and trailer included. An empty string raises.
- `sizeHint`: the decompressed size, when the caller's format records it. Only an allocation hint: a wrong one
  costs a copy, never an error. Output otherwise starts at 4096 bytes and doubles, so a caller that knows the
  answer's size should say so and skip the copies entirely.

**Returns:** the decompressed bytes. Raises when the stream does not decode.

The header is checked before anything is decoded and the Adler-32 trailer after, both inside zlib, so bytes
that are not a zlib stream are named as such rather than surfacing as a decode failure from somewhere inside a
block, and a stream that decoded into something other than what was compressed does not return.

A preset dictionary is refused rather than ignored. The flag means the compressor started from bytes that are
not in the stream, so decoding without them produces plausible-looking wrong output, which is the one failure
worth never returning. zlib stops and asks for the dictionary, and since there is nowhere to get one, the ask
is the refusal.

**Example:**

```teal
local payload <const> = tecs.data.inflate(chunk, header.decompressedSize)
```

## inflateRaw

Decompresses a raw DEFLATE stream, the form RFC 1951 defines.

```teal
function data.inflateRaw(bytes: string, sizeHint?: integer): string
```

**Parameters:**

- `bytes`: the raw stream, with no header and no trailer. An empty string raises.
- `sizeHint`: as above, an allocation hint only.

**Returns:** the decompressed bytes. Raises when the stream does not decode.

There is no header and no checksum, so nothing here can tell a corrupt stream from a stream of something else
until the codes stop making sense. A container that carries a length or a checksum of its own should check it;
[`adler32`](#adler32) is there for a container whose checksum is the one RFC 1950 names.

Both entry points go through `inflate` over a stream rather than `uncompress`, because `uncompress` wants the
decompressed size up front and treats a wrong one as a failure while `sizeHint` is a hint whose whole contract
is that being wrong costs a copy, and because the window size is what selects the wrapper: negating it asks
for the raw form, so one loop answers both.

## deflate

Compresses `bytes` as a zlib stream.

```teal
function data.deflate(bytes: string, level?: integer): string
```

`level` is `-1` for zlib's default or an integer from 0 through 9. Zero stores without compression; 1 favors
speed and 9 favors size. The default is `-1`. Empty input is valid and produces a complete empty stream.

## deflateRaw

Compresses `bytes` as raw RFC 1951 DEFLATE, with no zlib header or checksum trailer.

```teal
function data.deflateRaw(bytes: string, level?: integer): string
```

The level contract is the same. Both compressors allocate once from `deflateBound`, hand zlib the whole input,
and return exactly the bytes it produced. Use wrapped `deflate` unless an enclosing format supplies its own
framing and checksum.

## What a stream may not be

Streams are validated rather than trusted, and a malformed one raises rather than returning a short or wrong
answer. A corrupt asset is a file that fails to load, not a decoder that reads past its buffer.

| Failure                                                   | Decided by  |
| --------------------------------------------------------- | ----------- |
| An over-subscribed code table                             | zlib        |
| A distance reaching before the start of the output        | zlib        |
| A stored block whose length disagrees with its complement | zlib        |
| A zlib trailer that does not match what came out          | zlib        |
| A stream that needs a preset dictionary                   | zlib        |
| A truncated stream                                        | this module |

The truncation is the one decided here: all of the input is handed over at once, so a call that stops with
output room to spare is asking for more of a stream that has no more.

::: warning Messages are diagnostics, not an interface
Failures carry zlib's own sentence where it wrote one, because it says which structure was invalid rather than
that one was. Nothing should match against them. Test that a call raises, never which sentence it raised.
:::

## Hashing

Content hashes over byte strings. What a hash is for decides what belongs here, and two callers ask for
different things.

A build artifact carries a hash of the source it was built from, so a pack that no longer matches its shaders
is detected rather than trusted. That wants speed, and a collision rate low enough that an accident never
reaches it. It does not want resistance to a collision built on purpose: the source and the artifact are
produced by the same build, on the same machine, from a tree the person running it already controls. That is
`fnv1a64`.

A compressed stream carries a checksum of what it decompresses to, and the checksum is fixed by the format
rather than chosen. The compressors above hand zlib whole streams, so the trailer is verified inside
zlib and nothing here sits on that path. Adler-32 lives here anyway, because it is a hash function and it is
the one RFC 1950 names: a caller holding a stream it has not inflated, or bytes that came out of one by some
other route, wants a way to check the two against each other.

## fnv1a64

FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex digits.

```teal
function data.fnv1a64(text: string): string
```

**Parameters:**

- `text`: any string. NUL and bytes above 127 hash like any other.

**Returns:** sixteen hex digits, high half first, so hashes sort as their values do and two of them compare as
strings.

**Example:**

```teal
local source <const> = tecs.filesystem.read(path)
local stamp <const> = tecs.data.fnv1a64(source)
if stamp ~= recorded then
    rebuild()
end
```

The arithmetic is done as 64-bit FFI cdata, because FNV-1a is defined over 64-bit arithmetic and there is no
other way to spell that here: a double holds integers exactly only to 2^53. That rests on LuaJIT sinking the
box, which it does inside a compiled trace and not in the interpreter, so the first few dozen bytes of a call
allocate and the rest do not. The bound is the trace threshold, not the length of the input.

::: warning Not an integrity primitive
Sixty-four bits puts an accidental collision far beyond anything a build will produce, and puts a deliberate
one within reach of anyone who wants one. Establishing that a downloaded asset is the asset that was published
is a different question with a different answer: a cryptographic digest over the bytes and a signature over
the manifest that lists them. Nothing here asks that question yet, so nothing here answers it.
:::

::: tip The algorithm is in the name on purpose
A hash produced here is written into files that outlive the process. Called `data.contentHash`, a change to
what it computes would invalidate every stored value with nothing at any call site to notice; called
`data.fnv1a64`, the format is part of the signature and a change is a rename that every caller is rechecked
against.
:::

## adler32

Adler-32 over the bytes of `text`, as a number in [0, 2^32).

```teal
function data.adler32(text: string): integer
```

**Parameters:**

- `text`: any string.

**Returns:** the checksum, seeded from 1, which is what RFC 1950 starts from and what zlib's own documentation
says to pass for the first call.

zlib computes it, since zlib is a pinned dependency of this tree and is thirteen times faster over the same
bytes. It is reached through `adler32_z` rather than `adler32`, because the second takes its length as a 32-bit
`uInt` and a string past 4 GB would wrap it and check out against the wrong bytes.

::: warning A poor content hash, and not offered as one
It is a sum of a sum, it barely mixes on short inputs, and two files that differ by reordering equal-length
runs collide outright. Use `fnv1a64` for identity and this only for the format that specifies it.
:::

## crc32

CRC-32 over the bytes of `text`, using zlib's standard polynomial and initial value.

```teal
function data.crc32(text: string): integer
```

The result is in `[0, 2^32)`. This is the checksum used by PNG, gzip and ZIP; it is present for formats that
specify CRC-32, not as a cryptographic integrity primitive. Like `adler32`, it accepts arbitrary binary strings
and uses zlib's size-aware entry point so a length cannot wrap at 4 GB.
