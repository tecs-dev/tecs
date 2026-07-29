---
description: "Asynchronous image and sound loading on a worker thread, answering futures over refcounted payloads"
outline: deep
---

# tecs.assets

`tecs.assets` decodes images and sounds off the main thread. Decoding a PNG is milliseconds of pure CPU work
with no GPU involvement, so it happens on a worker and the main thread only uploads. A load never blocks a
frame: it hands back a [`Future`](/modules/Future) immediately, the future stays `"pending"`, and callers draw
something else until it is not. Sound takes the same route for the same reason, because reading a file is a
syscall a frame should not wait on.

What a load settles to is a value. `loadImage` answers `Future<Image>` and `loadSound` answers `Future<Sound>`,
where an `Image` carries pixels and a `Sound` carries a clip. So a load is transformed, joined and waited on
with the combinators everything else asynchronous in this tree already uses, and `assets` has no vocabulary of
its own for "still going", "finished" and "gave up".

Nothing here creates a GPU resource. Decoding and residency are separate decisions: the renderer knows what
layout its textures need, and an asset that has been decoded is useful before anything has decided where it
will live. Turning a decoded image into something drawable is [`Renderer`](/modules/gfx/); turning a
decoded clip into something audible is [`Audio`](/modules/audio).

::: info An image is a PNG or a JPEG
The Rust image decoder is built with only its PNG and JPEG features, because each additional codec is code a
shipped binary carries whether or not it loads one. An atlas in any other format is converted at build time,
not enabled in the runtime. Sound is the other way round: whatever the mixer's decoders can read loads, and
`Audio.decoders()` reports what the mixer actually linked.
:::

## Cancel before, release after

The two halves of a load are separated by the status line, and the whole rule is one sentence: **before it
lands you cancel the future, after it lands you release the payload.**

| While the future is `"pending"`                                                      | Once it settled `"ready"`                                                       |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| `loading:cancel()`                                                                   | `loading.value:release()`                                                       |
| Gives up this caller's interest in the decode. The last caller to do so abandons it. | Gives up this caller's hold on the pixels or the clip. The last one frees them. |

They are not two spellings of one thing. Cancellation is about work that has not happened; release is about
memory that exists. A future that already settled ignores `cancel`, and an `Image` that was never decoded
cannot be released, so there is no call that means both and no state where the wrong one silently does nothing
useful.

## Worker lifecycle

### install

Starts the loading worker.

```teal
function assets.install(luaPath?: string)
```

**Parameters:**

- `luaPath`: `package.path` for the worker's state. Defaults to this state's.

Installing twice is installing once. Spawning unconditionally would leave the first thread running with both
its channels and nothing reading them, and every decode already queued would answer into a channel that has
been dropped, so a load in flight across the second call would never settle.

[`Application`](/modules/Application) owns this: it installs the worker, calls `update` once per iteration and
`shutdown` at teardown, so a game that loads an image and does nothing else still sees its future settle and
the decoding thread still stops. A headless tool or a test that loads assets installs it itself.

### installed

```teal
function assets.installed(): boolean
```

**Returns:** whether the loading worker is running. For a subsystem that loads an asset of its own and has no
way of knowing whether the game has started the worker yet.

### update

Takes finished decodes and settles their futures. Call once per frame.

```teal
function assets.update(): integer
```

**Returns:** how many decodes settled on this call. Zero when no worker is running.

This is the loader's `Future.Source` poll under a public name. Listeners run from inside it, in the order the
worker answered, so a `map` that uploads an image runs on the frame the decode arrived.

### pending

```teal
function assets.pending(): integer
```

**Returns:** how many loads are still waiting on the worker. A decode every caller has canceled is still
counted until the worker answers for it, because the address it sends still has to be taken and destroyed.

### waitAll

Blocks until every queued load has finished.

```teal
function assets.waitAll(timeoutMs?: number)
```

**Parameters:**

- `timeoutMs`: milliseconds to spend. Defaults to 5000.

For startup and tests. A frame polls `update` instead. The time is spent inside the source's blocking receive
through `Future:wait`, and the budget is wall clock rather than a count of pumps, because a pump returns as
soon as one message arrives.

This is deliberately not a join. `Future.all` over futures a caller holds waits for that caller's loads; this
waits for every load in the process, including ones started by a subsystem the caller has never heard of,
which is what a reload or a startup path actually wants. It is also the only wait that does not end early on a
failure, since `Future.all` fails a join on its first failed input and a missing file fails as fast as the
worker can look.

### shutdown

```teal
function assets.shutdown()
```

Stops the loading worker and drops what was queued. Futures for loads still in flight stay pending forever, so
drain with `waitAll` first if their results are wanted. Loading after this needs another `install`.

## Loading

### loadImage

Queues an image for loading and answers a future for it immediately.

```teal
function assets.loadImage(path: string): Future<Image>
```

**Parameters:**

- `path`: an absolute path, or one [`filesystem`](/modules/filesystem/) has resolved against the content root.

**Returns:** a pending `Future<Image>`. Calling this before `install` raises; a missing file does not, and
reaches the caller as a failed settlement once the worker has looked.

```teal
tecs.assets.loadImage(tecs.filesystem.assetPath("sprites/hero.png"))
    :map(function(image: tecs.assets.Image): tecs.Sprite
        -- registerImage releases this caller's hold; the array holds the pixels now.
        return (renderer:registerImage(image))
    end)
    :onSettle(function(sprite: tecs.Future<tecs.Sprite>)
        if sprite.status == "ready" then
            world:spawn(tecs.Transform(100, 100), sprite.value)
        end
    end)
```

Two loads of one path that overlap share a decode, because decoding the same PNG twice at once is work with no
result the first decode does not already have. They share the `Image`, so the last of them to release is the
one that frees, and each of them holds a **distinct future**, so one canceling is invisible to the others. A
load that starts after the first has settled decodes again: nothing here is a cache.

### loadSound

Queues a sound for loading and answers a future for it immediately.

```teal
function assets.loadSound(path: string, mode: string, streamMs: integer): Future<Sound>
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

Two overlapping loads of one path do **not** share, unlike images: each gets its own clip, because that is what
`MIX_LoadAudio` produces. A load whose mixer could not be initialized comes back already failed rather than
raising. [`Audio`](/modules/audio) is the normal caller; a game loads clips through it rather than through here.

## Image

What a `loadImage` future settles to.

| Field    | Type      | Description                                                      |
| -------- | --------- | ---------------------------------------------------------------- |
| `path`   | `string`  | The path this load was for, unchanged and unresolved.            |
| `pixels` | cdata     | Decoded RGBA pixels, valid until the last `release`. Nil after.  |
| `width`  | `integer` | Pixels across, not bytes.                                        |
| `height` | `integer` | Pixel rows.                                                      |
| `pitch`  | `integer` | Row stride in bytes, which a decoder may pad beyond `width * 4`. |

Images are decoded to one normalized RGBA layout on the worker, so the upload path handles exactly one layout
and the conversion cost lands off the main thread with the decode.

### Image:release

```teal
function Image:release()
```

Gives up this caller's hold on the pixels, and frees at the last. Called once whatever needed them has taken a
copy, which for an image means after it has been uploaded; `registerImage` and `replaceImage` do it for you.
Where several loads shared one decode, this releases one of them.

Releasing an image already down to nothing does nothing, so a shutdown path need not know whether something
else got there first, and `pixels` reads nil afterwards rather than pointing at freed memory.

## Sound

What a `loadSound` future settles to.

| Field        | Type      | Description                                                                |
| ------------ | --------- | -------------------------------------------------------------------------- |
| `path`       | `string`  | The path this load was for.                                                |
| `audio`      | cdata     | The loaded clip, valid until the last `release`. Nil for one that streams. |
| `resident`   | `boolean` | Whether the decoded audio is held in memory.                               |
| `durationMs` | `integer` | Length in milliseconds, or `-1` when the container cannot say.             |

### Sound:release

```teal
function Sound:release()
```

Gives up this caller's hold on the clip, and frees at the last. A voice reads a clip where it lies, so a clip
is released when nothing will play it again; a track holds its own reference, so releasing one that is still
sounding is safe and the mixer drops it when the last track using it does.

## Waiting on several

There is no set type here. Several loads are one `Future.all`, and the join settles when the last of them does:

```teal
local sheet <const> = tecs.Future.all({
    tecs.assets.loadImage(base .. ".png"),
    tecs.assets.loadImage(base .. "_n.png"),
}):map(function(images: {tecs.assets.Image}): Sheet
    -- Argument order rather than arrival order, deliberately: a sheet's maps
    -- register as a unit, so the unit's internal order is the one written here
    -- and is the same on every run.
    return buildSheet(renderer, images)
end)
```

A join fails on its first failed input, so a map that is allowed to be absent goes through `recover` before it
reaches the join — and `recover` must produce a value rather than nil, because a join refuses to leave a hole
in the array it promised.

## Reading a document

Bytes a game interprets itself do not go through a decode at all. That is [`filesystem`](/modules/filesystem/),
which reads through the platform rather than through stdio, because on Android content lives inside the package
and `io.open` does not reach it. It answers bytes and never text: a Lua string carries a length, so an image,
an archive or a binary sidecar comes back whole, and a format that is text is a decoder's opinion.

Reading a document is therefore two halves with nothing between them:

```teal
local bytes <const> = tecs.filesystem.read(tecs.filesystem.assetPath("levels/1.json"))
local level <const> = tecs.data.decodeJSON(bytes)
```

`assetPath` resolves against the content root and `read` answers nil for a path with no file, so a game
distinguishes an absent document from a malformed one, which the decoder raises on. Every path this process has
read or decoded is recorded, including the ones queued here, and `filesystem.loaded` is what the file watcher
polls instead of walking the content tree.

## What a load hands back, and why that changed

This page used to say the opposite, and the reasoning is worth keeping rather than quietly replacing. A load
answered with a `Handle`: a private settle-once cell with four words of its own, `"loading"`, `"ready"`,
`"failed"` and `"released"`, read as a field and freed with `Handle:release`. The argument was that a handle
settles once and is read as a field, and that this was deliberately the whole of it, with `Future` reserved for
the general case a child process or a request returns.

What that got right, and what survives here unchanged: nothing became a cache, two overlapping loads of one
path still share one decode, and a payload that has been given back must not read as available. That last one
is the safety property, and it is why `Renderer:registerImage` still refuses an image rather than uploading
from a freed address — the guard simply moved off a status word and onto the pixels themselves.

What changed is not the shape of a load. It is that the number of subsystems reinventing the wait went from two
to three, and the third could not be expressed by either of the first two. `Handle` was two counters wearing one
hat: `_shares` meant "callers who might still want this decode" before settlement and "holders of these pixels"
after it, and `release` did two unrelated jobs decided entirely by which side of settlement it was called on.
Those separate cleanly, and once they do, the pending half is exactly a `Future` and the settled half is
exactly a refcounted value. Nothing is left over, which is why `Handle` was deleted rather than split.

`"released"` was the one real loss, and it was not a loss. It read as a completion state beside `"ready"` and
`"failed"`, but a released image is a load that **succeeded** and then had its memory given back; erasing the
success is less truthful than keeping it. So the four words became `Future`'s four, `"released"` became an
`Image` whose `pixels` are nil, and the sequencer can park on a decode through the same
[`Future.track`](/modules/Future) bridge it parks on everything else.
