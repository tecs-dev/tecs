---
description: "Content hashes over byte strings: FNV-1a in 64 bits for identity, and zlib's Adler-32 for the format that specifies it"
outline: deep
---

# hash

`tecs.hash` computes content hashes over byte strings. What a hash is for decides what belongs here, and two
callers ask for different things.

A build artifact carries a hash of the source it was built from, so a pack that no longer matches its shaders
is detected rather than trusted. That wants speed, and a collision rate low enough that an accident never
reaches it. It does not want resistance to a collision built on purpose: the source and the artifact are
produced by the same build, on the same machine, from a tree the person running it already controls. That is
`fnv1a64`.

A compressed stream carries a checksum of what it decompresses to, and the checksum is fixed by the format
rather than chosen. [`compress`](/modules/compress) hands zlib whole streams, so the trailer is verified inside
zlib and nothing here sits on that path. Adler-32 lives here anyway, because it is a hash function and it is
the one RFC 1950 names: a caller holding a stream it has not inflated, or bytes that came out of one by some
other route, wants a way to check the two against each other.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.hash`. `tecs`
is also set as a global, which makes the require line optional, and engine modules such as this one are
resolved lazily on first field access. `hash` and `compress` are two modules rather than one, because
"operations over bytes" is a category and not a concern: a tool that wants a shader's identity has no reason
to load a decompressor.

## fnv1a64

FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex digits.

```teal
function hash.fnv1a64(text: string): string
```

**Parameters:**

- `text`: any string. NUL and bytes above 127 hash like any other.

**Returns:** sixteen hex digits, high half first, so hashes sort as their values do and two of them compare as
strings.

**Example:**

```teal
local source <const> = tecs.assets.read(path)
local stamp <const> = tecs.hash.fnv1a64(source)
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
A hash produced here is written into files that outlive the process. Called `hash.content`, a change to what
it computes would invalidate every stored value with nothing at any call site to notice; called
`hash.fnv1a64`, the format is part of the signature and a change is a rename that every caller is rechecked
against.
:::

## adler32

Adler-32 over the bytes of `text`, as a number in [0, 2^32).

```teal
function hash.adler32(text: string): integer
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

## Design record

- [Hashing and decompression](https://github.com/tecs-dev/tecs/blob/main/README.md#hashing-and-decompression)
