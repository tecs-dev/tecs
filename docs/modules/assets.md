---
description: "Asynchronous image and sound loading on a worker thread, with handles, batches and explicit release"
outline: deep
---

# tecs.assets

`tecs.assets` decodes images and sounds off the main thread. Decoding a PNG is milliseconds of pure CPU work
with no GPU involvement, so it happens on a worker and the main thread only uploads. A load never blocks a
frame: it hands back a handle immediately, the handle reports that it is still loading, and callers draw
something else until it is not. Sound takes the same route for the same reason, because reading a file is a
syscall a frame should not wait on.

Nothing here creates a GPU resource. Decoding and residency are separate decisions: the renderer knows what
layout its textures need, and an asset that has been decoded is useful before anything has decided where it
will live. Turning a decoded image into something drawable is [`Renderer`](/modules/Renderer); turning a
decoded clip into something audible is [`Audio`](/modules/Audio).

::: info An image is a PNG or a JPEG
SDL_image offers eighteen formats and the build turns off every other one, because each is a codec a shipped
binary carries whether or not it loads one. An atlas in any other format is converted at build time, not
enabled at configure time. Sound is the other way round: whatever the mixer's decoders can read loads, and
`Audio.decoders()` reports what the mixer actually linked.
:::

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.assets`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily
on first field access.

## The worker

### install

Starts the loading worker.

```teal
function assets.install(luaPath?: string)
```

**Parameters:**

- `luaPath`: `package.path` for the worker's state. Defaults to this state's.

Installing twice is installing once. Spawning unconditionally would leave the first thread running with both
its channels and nothing reading them, and every decode already queued would answer into a channel that has
been dropped, so a load in flight across the second call would never resolve.

[`Application`](/modules/Application) owns this: it installs the worker, calls `update` once per iteration and
`shutdown` at teardown, so a game that loads an image and does nothing else still sees its handle resolve and
the decoding thread still stops. A headless tool or a test that loads assets installs it itself.

### installed

```teal
function assets.installed(): boolean
```

**Returns:** whether the loading worker is running. For a subsystem that loads an asset of its own and has no
way of knowing whether the game has started the worker yet.

### update

Takes finished decodes and resolves their handles. Call once per frame.

```teal
function assets.update(): integer
```

**Returns:** how many decodes were completed by this call. Zero when no worker is running.

### pending

```teal
function assets.pending(): integer
```

**Returns:** how many handles are still waiting on the worker.

### waitAll

Blocks until every queued load has finished.

```teal
function assets.waitAll(timeoutMs?: number)
```

**Parameters:**

- `timeoutMs`: milliseconds to spend. Defaults to 5000.

For startup and tests. A frame polls `update` instead. The budget is wall clock rather than a count of pumps,
because a pump returns as soon as one message arrives.

### shutdown

```teal
function assets.shutdown()
```

Stops the loading worker and drops what was queued. Loading after this needs another `install`.

## Loading

### loadImage

Queues an image for loading and returns its handle immediately.

```teal
function assets.loadImage(path: string): Handle
```

**Parameters:**

- `path`: an absolute path, or one [`paths`](/modules/paths) has resolved against the content root.

**Returns:** a `Handle` in the `"loading"` state. Calling this before `install` raises.

Two loads of one path that overlap share a decode and get the same handle, because decoding the same PNG twice
at once is work with no result the first decode does not already have. They share the surface with it, so the
last of them to release is the one that frees. A load that starts after the first has resolved decodes again:
nothing here is a cache, and a handle that has been released is not something to hand out a second time.

```teal
local handle <const> = tecs.assets.loadImage(tecs.paths.asset("sprites/hero.png"))
-- ... frames later, once handle.status == "ready"
local sprite <const> = renderer:registerImage(handle)
handle:release()
```

### loadSound

Queues a sound for loading and returns its handle immediately.

```teal
function assets.loadSound(path: string, mode: string, streamMs: integer): Handle
```

**Parameters:**

- `path`: the file to read. Whatever the mixer's decoders can read loads, so the format is the file's business
  rather than the caller's.
- `mode`: `"resident"`, `"stream"` or `"auto"`.
- `streamMs`: the threshold `"auto"` decides on.

| Mode         | Effect                                              |
| ------------ | --------------------------------------------------- |
| `"resident"` | Decoded once, up front, and held as PCM.            |
| `"stream"`   | Nothing held; each voice opens the file for itself. |
| `"auto"`     | Resident under `streamMs`, streamed at or over it.  |

The auto case reads the file twice when it turns out to be short: once without decoding, to ask how long it is,
and once to decode it. That is a second read of a small file, off the main thread, against holding a decoded
copy of a piece of music.

A handle whose mixer could not be initialised comes back already `"failed"` rather than raising.
[`Audio`](/modules/Audio) is the normal caller; a game loads clips through it rather than through here.

## Handle

What a load hands back. It is a one-shot future, not a cache: it settles once and release is terminal.

| Field        | Type      | Description                                                                                             |
| ------------ | --------- | ------------------------------------------------------------------------------------------------------- |
| `kind`       | `string`  | What was asked for: `"image"` or `"sound"`.                                                             |
| `status`     | `string`  | `"loading"`, `"ready"`, `"failed"` or `"released"`.                                                     |
| `path`       | `string`  | The path this load was for.                                                                             |
| `pixels`     | cdata     | Decoded RGBA pixels, valid until `release`. Images only.                                                |
| `width`      | `integer` | Image width in pixels.                                                                                  |
| `height`     | `integer` | Image height in pixels.                                                                                 |
| `pitch`      | `integer` | Row stride in bytes, which a decoder may pad beyond `width * 4`.                                        |
| `audio`      | cdata     | The loaded clip, valid until `release`. Sounds only, and nil for one that streams, which holds nothing. |
| `resident`   | `boolean` | Whether the clip is held in memory. Sounds only.                                                        |
| `durationMs` | `integer` | Length in milliseconds, or `-1` when the file cannot say. Sounds only.                                  |
| `error`      | `string`  | Set if loading failed.                                                                                  |

Images are decoded to one normalised RGBA layout on the worker, so the upload path handles exactly one layout
and the conversion cost lands off the main thread with the decode.

`"released"` is terminal and reached only through `release`, so something handed a handle whose decode it no
longer owns is told that rather than finding nil where the pixels were. That is the difference between a clear
error at the upload and a null dereference inside it.

### release

Frees what was decoded.

```teal
function Handle:release()
```

Called once whatever needed it has taken a copy, which for an image means after it has been uploaded. A voice
reads a clip where it lies, so a clip is released when nothing will play it again; a track holds its own
reference, so releasing one that is still sounding is safe and the mixer drops it when the last track using it
does.

Releasing a load still in flight is allowed: what the worker returns is destroyed on arrival. Where several
loads shared one decode this releases one of them, and the last one frees. Releasing twice does nothing.

## Batch

A set of loads to wait on, with something of the caller's beside each.

Waiting on several handles at once is not one subsystem's problem. Sound holds a clip per handle, text holds an
atlas per handle, and a sidecar holds whatever it was read for; each of them wants the same three things, which
are how many are still in flight, a callback per one that finished, and a blocking form for startup and tests.

### batch

```teal
function assets.batch<T>(finished: function(key: T, handle: Handle)): Batch<T>
```

**Parameters:**

- `finished`: called once per load that leaves the `"loading"` state, with the caller's own value beside it.
  Required; passing nil raises.

`T` is the caller's and nothing here reads it. The callback is given once rather than at every drain, because
what a batch does with a load is a property of who made it and not of the moment it is looked at.

### Batch methods

```teal
function Batch:add(handle: Handle, key: T)
function Batch:pending(): integer
function Batch:resolve(): integer
function Batch:wait(timeoutMs?: number): integer
```

- `add` adds a load to wait on, with the caller's value beside it.
- `pending` answers how many of its loads are still in flight.
- `resolve` drains the worker itself, hands every finished load to the callback, drops it, and returns how many
  were resolved. Taking whatever the worker has answered first is what lets a subsystem polling only its own
  batch still see its loads finish.
- `wait` blocks until nothing is in flight, then resolves. `timeoutMs` defaults to 5000. For startup, shutdown
  and tests; a frame calls `resolve` instead.

::: warning A callback must not add to the batch it is being called from
Resolving compacts the batch in place, so a frame with loads in flight allocates nothing. The price of that is
that the compaction is walking the list the callback would be appending to.
:::

```teal
local loads <const> = tecs.assets.batch(function(name: string, handle: tecs.assets.Handle)
    if handle.status == "ready" then
        atlases[name] = renderer:registerImage(handle)
    end
    handle:release()
end)

loads:add(tecs.assets.loadImage(tecs.paths.asset("ui.png")), "ui")
loads:add(tecs.assets.loadImage(tecs.paths.asset("tiles.png")), "tiles")
-- once per frame
loads:resolve()
```

## Reading a document

Bytes a game interprets itself do not go through a decode at all. That is [`filesystem`](/modules/filesystem),
which reads through the platform rather than through stdio, because on Android content lives inside the package
and `io.open` does not reach it. It answers bytes and never text: a Lua string carries a length, so an image,
an archive or a binary sidecar comes back whole, and a format that is text is a decoder's opinion.

Reading a document is therefore two halves with nothing between them:

```teal
local bytes <const> = tecs.filesystem.read(tecs.paths.asset("levels/1.json"))
local level <const> = tecs.json.decode(bytes)
```

`paths.asset` resolves against the content root and `read` answers nil for a path with no file, so a game
distinguishes an absent document from a malformed one, which the decoder raises on. Every path this process has
read or decoded is recorded, including the ones queued here, and `filesystem.loaded` is what the file watcher
polls instead of walking the content tree.

## What a load hands back, and what it does not

A `Handle` settles once and is read as a field, and that is deliberately the whole of it. The general
settle-once value with combinators over it, which a child process or a request returns, is
[`Future`](/modules/Future); it carries `status`, `value` and `error`, chains with `map`, `flatMap` and
`recover`, and is what the sequencer's awaitable bridge parks a program on. A load queued here is not one of
those: it is a handle, and the sequencer waits on it through whatever subsystem owns the decode.

## Design record

- [Workers and assets](https://github.com/tecs-dev/tecs/blob/main/README.md#workers-and-assets)
- [A value that settles once](https://github.com/tecs-dev/tecs/blob/main/README.md#a-value-that-settles-once)
- [Touching the filesystem](https://github.com/tecs-dev/tecs/blob/main/README.md#touching-the-filesystem)
