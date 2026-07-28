---
description: "DEFLATE compression and decompression through zlib, in wrapped and raw forms"
outline: deep
---

# tecs.compress

`tecs.compress` compresses and decompresses DEFLATE data: zlib streams, and the raw form inside them. Binary asset
formats use both directions: readers inflate existing chunks, while tooling, save formats and network protocols
produce compatible ones.

zlib does both. It is pinned, generated into bindings, carried through the ABI check and loaded the way every
other native library is, because libcurl needs it to answer a `Content-Encoding`. Once it is in the process for
that, an implementation written here would be a second copy of the format to keep correct, and the slower
one. It loads on a worker the same way, so a [worker](/modules/workers) that requires this module gets the
bindings there rather than inheriting anything from the thread that spawned it.

## inflate

Decompresses a zlib stream, the form RFC 1950 defines.

```teal
function compress.inflate(bytes: string, sizeHint?: integer): string
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
local payload <const> = tecs.compress.inflate(chunk, header.decompressedSize)
```

## inflateRaw

Decompresses a raw DEFLATE stream, the form RFC 1951 defines.

```teal
function compress.inflateRaw(bytes: string, sizeHint?: integer): string
```

**Parameters:**

- `bytes`: the raw stream, with no header and no trailer. An empty string raises.
- `sizeHint`: as above, an allocation hint only.

**Returns:** the decompressed bytes. Raises when the stream does not decode.

There is no header and no checksum, so nothing here can tell a corrupt stream from a stream of something else
until the codes stop making sense. A container that carries a length or a checksum of its own should check it;
[`hash.adler32`](/modules/hash#adler32) is there for a container whose checksum is the one RFC 1950 names.

Both entry points go through `inflate` over a stream rather than `uncompress`, because `uncompress` wants the
decompressed size up front and treats a wrong one as a failure while `sizeHint` is a hint whose whole contract
is that being wrong costs a copy, and because the window size is what selects the wrapper: negating it asks
for the raw form, so one loop answers both.

## deflate

Compresses `bytes` as a zlib stream.

```teal
function compress.deflate(bytes: string, level?: integer): string
```

`level` is `-1` for zlib's default or an integer from 0 through 9. Zero stores without compression; 1 favours
speed and 9 favours size. The default is `-1`. Empty input is valid and produces a complete empty stream.

## deflateRaw

Compresses `bytes` as raw RFC 1951 DEFLATE, with no zlib header or checksum trailer.

```teal
function compress.deflateRaw(bytes: string, level?: integer): string
```

The level contract is the same. Both compressors allocate once from `deflateBound`, hand zlib the whole input,
and return exactly the bytes it produced. Use wrapped `deflate` unless an enclosing format supplies its own
framing and checksum.

## What is refused

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
<!-- @generated by docs/scripts/reference.py from src/tecs/compress.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/compress.tl`.

<a id="tecs.compress.deflate"></a>

### tecs.compress.deflate

<pre><code v-pre>function <a href="#tecs.compress.deflate">tecs.compress.deflate</a>(bytes: string, level: integer): string
</code></pre>

Compresses bytes as an RFC 1950 zlib stream, including its header and
Adler-32 trailer.

#### Parameters

| Type                       | Name                     | Description                                                                                                      |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>  | <code v-pre>bytes</code> |                                                                                                                  |
| <code v-pre>integer</code> | <code v-pre>level</code> | Minus one or omitted uses zlib's default. Zero stores without compression; one through nine trade time for size. |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.compress.deflateRaw"></a>

### tecs.compress.deflateRaw

<pre><code v-pre>function <a href="#tecs.compress.deflateRaw">tecs.compress.deflateRaw</a>(bytes: string, level: integer): string
</code></pre>

Compresses bytes as a raw RFC 1951 DEFLATE stream.

#### Parameters

| Type                       | Name                     | Description                                                                                                      |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>  | <code v-pre>bytes</code> |                                                                                                                  |
| <code v-pre>integer</code> | <code v-pre>level</code> | Minus one or omitted uses zlib's default. Zero stores without compression; one through nine trade time for size. |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.compress.inflate"></a>

### tecs.compress.inflate

<pre><code v-pre>function <a href="#tecs.compress.inflate">tecs.compress.inflate</a>(bytes: string, sizeHint: integer): string
</code></pre>

Decompresses a zlib stream, the form RFC 1950 defines.

The header is checked before anything is decoded and the Adler-32 trailer
after, both inside zlib, so bytes that are not a zlib stream are named as
such rather than surfacing as a decode failure from somewhere inside a
block, and a stream that decoded into something other than what was
compressed does not return.

A preset dictionary is refused rather than ignored. The flag means the
compressor started from bytes that are not in the stream, so decoding
without them produces plausible-looking wrong output, which is the one
failure worth never returning. zlib stops and asks for the dictionary, and
since there is nowhere to get one, the ask is the refusal.

#### Parameters

| Type                       | Name                        | Description                                                                                                                    |
| -------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code>  | <code v-pre>bytes</code>    | The whole stream, header and Adler-32 trailer included. An empty string raises, since it is not one.                           |
| <code v-pre>integer</code> | <code v-pre>sizeHint</code> | The decompressed size, when the caller's format records it. Only an allocation hint: a wrong one costs a copy, never an error. |

#### Returns

| Type                      | Description                                                                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code> | The decompressed bytes, which may be empty. Never nil: a bad header, a corrupt block, a truncated stream and a trailer that disagrees all raise. |

<a id="tecs.compress.inflateRaw"></a>

### tecs.compress.inflateRaw

<pre><code v-pre>function <a href="#tecs.compress.inflateRaw">tecs.compress.inflateRaw</a>(bytes: string, sizeHint: integer): string
</code></pre>

Decompresses a raw DEFLATE stream, the form RFC 1951 defines.

No header and no checksum, so nothing here can tell a corrupt stream from a
stream of something else until the codes stop making sense. A container that
carries a length or a checksum of its own should check it.

#### Parameters

| Type                       | Name                        | Description                                                                                                                    |
| -------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code>  | <code v-pre>bytes</code>    | The whole stream, compressed. An empty string raises, since it is not one.                                                     |
| <code v-pre>integer</code> | <code v-pre>sizeHint</code> | The decompressed size, when the caller's format records it. Only an allocation hint: a wrong one costs a copy, never an error. |

#### Returns

| Type                      | Description                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | The decompressed bytes, which may be empty. Never nil: a stream that does not decode raises. |
