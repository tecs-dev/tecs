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
will live. Turning a decoded image into something drawable is [`Renderer`](/modules/gfx/); turning a
decoded clip into something audible is [`Audio`](/modules/audio).

::: info An image is a PNG or a JPEG
SDL_image offers eighteen formats and the build turns off every other one, because each is a codec a shipped
binary carries whether or not it loads one. An atlas in any other format is converted at build time, not
enabled at configure time. Sound is the other way round: whatever the mixer's decoders can read loads, and
`Audio.decoders()` reports what the mixer actually linked.
:::

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

[`Application`](/modules/application) owns this: it installs the worker, calls `update` once per iteration and
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

- `path`: an absolute path, or one [`filesystem`](/modules/filesystem/) has resolved against the content root.

**Returns:** a `Handle` in the `"loading"` state. Calling this before `install` raises.

Two loads of one path that overlap share a decode and get the same handle, because decoding the same PNG twice
at once is work with no result the first decode does not already have. They share the future with it, so the
last of them to release is the one that frees. A load that starts after the first has resolved decodes again:
nothing here is a cache, and a handle that has been released is not something to hand out a second time.

```teal
local handle <const> = tecs.assets.loadImage(tecs.filesystem.assetPath("sprites/hero.png"))
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
[`Audio`](/modules/audio) is the normal caller; a game loads clips through it rather than through here.

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

loads:add(tecs.assets.loadImage(tecs.filesystem.assetPath("ui.png")), "ui")
loads:add(tecs.assets.loadImage(tecs.filesystem.assetPath("tiles.png")), "tiles")
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
local bytes <const> = tecs.filesystem.read(tecs.filesystem.assetPath("levels/1.json"))
local level <const> = tecs.data.decodeJSON(bytes)
```

`assetPath` resolves against the content root and `read` answers nil for a path with no file, so a game
distinguishes an absent document from a malformed one, which the decoder raises on. Every path this process has
read or decoded is recorded, including the ones queued here, and `filesystem.loaded` is what the file watcher
polls instead of walking the content tree.

## What a load hands back, and what it does not

A `Handle` settles once and is read as a field, and that is deliberately the whole of it. The general
settle-once value with combinators over it, which a child process or a request returns, is
[`Future`](/modules/future); it carries `status`, `value` and `error`, chains with `map`, `flatMap` and
`recover`, and is what the sequencer's awaitable bridge parks a program on. A load queued here is not one of
those: it is a handle, and the sequencer waits on it through whatever subsystem owns the decode.
<!-- @generated by docs/scripts/reference.py from src/tecs/assets.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/assets.tl`.

<a id="tecs.assets.Batch"></a>

### tecs.assets.Batch

<pre><code v-pre>record <a href="#tecs.assets.Batch">tecs.assets.Batch</a>&lt;T&gt;
</code></pre>

A set of loads to wait on, with something of the caller's beside each.

Waiting on several handles at once is not one subsystem's problem. Sound
holds a clip per handle, text holds an atlas per handle, and a sidecar
holds whatever it was read for; each of them wants the same three things,
which are how many are still in flight, a callback per one that
finished, and a blocking form for startup and tests. That is the whole
shape, so it is here once rather than written again beside every list of
handles.

`T` is the caller's and nothing here reads it. Resolving compacts in
place, so a frame with loads in flight allocates nothing; the price of
that is that a callback must not add to the batch it is being called
from.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

<a id="tecs.assets.Batch.add"></a>

### tecs.assets.Batch.add

<pre><code v-pre>function <a href="#tecs.assets.Batch.add">tecs.assets.Batch.add</a>(self: <a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;, handle: <a href="#tecs.assets.Handle">Handle</a>, key: T)
</code></pre>

Adds a load to wait on, with the caller's value beside it.

Adding one handle twice waits on it twice and calls back twice. Adding one
already finished is allowed; the next `resolve` hands it over.

#### Parameters

| Type                                                               | Name                      | Description                                                                                                                                                                      |
| ------------------------------------------------------------------ | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;</code> | <code v-pre>self</code>   |                                                                                                                                                                                  |
| <code v-pre><a href="#tecs.assets.Handle">Handle</a></code>        | <code v-pre>handle</code> | Held rather than copied, so the batch sees whatever the worker settles it to. Nothing is started here: the load was already in flight before it arrived.                         |
| <code v-pre>T</code>                                               | <code v-pre>key</code>    | The caller's own value, handed back beside the handle at `resolve` so the callback knows which load it is looking at. Not read or compared by the batch, so duplicates are fine. |

<a id="tecs.assets.Batch.pending"></a>

### tecs.assets.Batch.pending

<pre><code v-pre>function <a href="#tecs.assets.Batch.pending">tecs.assets.Batch.pending</a>(self: <a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;): integer
</code></pre>

Loads still in flight.

#### Parameters

| Type                                                               | Name                    | Description |
| ------------------------------------------------------------------ | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                          |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many of the batch's handles read "loading" right now. Counts what is still unresolved, so it drops to zero a `resolve` before the batch empties. |

<a id="tecs.assets.Batch.resolve"></a>

### tecs.assets.Batch.resolve

<pre><code v-pre>function <a href="#tecs.assets.Batch.resolve">tecs.assets.Batch.resolve</a>(self: <a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;): integer
</code></pre>

Hands every finished load to the callback and drops it.

Takes whatever the worker has answered first, so a subsystem
polling only its own batch still sees its loads finish.

The callback gets a failed load as well as a ready one; check `handle.status`
rather than assuming pixels. It must not add to this batch, which is being
compacted underneath it.

#### Parameters

| Type                                                               | Name                    | Description |
| ------------------------------------------------------------------ | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                          |
| -------------------------- | ------------------------------------ |
| <code v-pre>integer</code> | How many were resolved by this call. |

<a id="tecs.assets.Batch.wait"></a>

### tecs.assets.Batch.wait

<pre><code v-pre>function <a href="#tecs.assets.Batch.wait">tecs.assets.Batch.wait</a>(self: <a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;, timeoutMs: number): integer
</code></pre>

Blocks until nothing is in flight, then resolves.

For startup, shutdown and tests. A frame calls `resolve` instead.

#### Parameters

| Type                                                               | Name                         | Description                             |
| ------------------------------------------------------------------ | ---------------------------- | --------------------------------------- |
| <code v-pre><a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;</code> | <code v-pre>self</code>      |                                         |
| <code v-pre>number</code>                                          | <code v-pre>timeoutMs</code> | Milliseconds to wait. Defaults to 5000. |

#### Returns

| Type                       | Description                                                                                                                                                                                     |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many were resolved. A timeout is not an error and is not reported: the count is simply short and the rest stay in the batch, so check `pending` after this rather than trusting the return. |

<a id="tecs.assets.Handle"></a>

### tecs.assets.Handle

<pre><code v-pre><a href="#tecs.assets.Handle">tecs.assets.Handle</a>: Handle
</code></pre>

One asynchronous load.
<a id="tecs.assets.batch"></a>

### tecs.assets.batch

<pre><code v-pre>function <a href="#tecs.assets.batch">tecs.assets.batch</a>&lt;T&gt;(finished: function(T, <a href="#tecs.assets.Handle">Handle</a>)): <a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;
</code></pre>

A batch that hands each finished load to `finished`.

The callback is given once rather than at every drain, because what a batch
does with a load is a property of who made it and not of the moment it is
looked at.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>T</code> |            |             |

#### Parameters

| Type                                                                     | Name                        | Description                                                                                                                   |
| ------------------------------------------------------------------------ | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>function(T, <a href="#tecs.assets.Handle">Handle</a>)</code> | <code v-pre>finished</code> | Called once per load that leaves "loading", ready or failed alike, on the thread that drains the batch. Required; nil raises. |

#### Returns

| Type                                                               | Description                                                                                |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.assets.Batch">Batch</a>&lt;T&gt;</code> | An empty batch. Nothing registers it, so a batch nobody resolves simply holds its handles. |

<a id="tecs.assets.install"></a>

### tecs.assets.install

<pre><code v-pre>function <a href="#tecs.assets.install">tecs.assets.install</a>(luaPath: string)
</code></pre>

Starts the loading worker.

Installing twice is installing once. Spawning unconditionally would leave
the first thread running with both its channels and nothing reading them,
and every decode already queued would answer into a channel that has been
dropped, so a load in flight across the second call would never resolve.

#### Parameters

| Type                      | Name                       | Description                                                                                                                                                                               |
| ------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>luaPath</code> | `package.path` for the worker's own state, which shares no loaded modules with this one. Defaults to this state's, which is what makes the worker resolve the same modules the game does. |

<a id="tecs.assets.installed"></a>

### tecs.assets.installed

<pre><code v-pre>function <a href="#tecs.assets.installed">tecs.assets.installed</a>(): boolean
</code></pre>

Whether the loading worker is running.

For a subsystem that loads an asset of its own and has no way of knowing whether the
game has started the worker yet.

#### Returns

| Type                       | Description                                                                                                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether the worker exists, which is a fact about the process rather than about any world. False means a load raises rather than queueing, so this is the guard rather than an optimisation. |

<a id="tecs.assets.loadImage"></a>

### tecs.assets.loadImage

<pre><code v-pre>function <a href="#tecs.assets.loadImage">tecs.assets.loadImage</a>(path: string): <a href="#tecs.assets.Handle">Handle</a>
</code></pre>

Queues an image for loading and returns its handle immediately.

Two loads of one path that overlap share a decode and get the same handle,
because decoding the same PNG twice at once is work with no result the
first decode does not already have. They share the surface with it, so the
last of them to release is the one that frees. A load that starts after the
first has resolved decodes again: nothing here is a cache, and a handle
that has been released is not something to hand out a second time.

#### Parameters

| Type                      | Name                    | Description                                                                                                              |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code> | <code v-pre>path</code> | PNG or JPEG; no other format is compiled in, and one that is not either fails the decode rather than being refused here. |

#### Returns

| Type                                                        | Description                                                                                                                                                                                                        |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.assets.Handle">Handle</a></code> | A handle at "loading", never nil. Raises instead when `install` has not run. Failures reach it through `status`, not through this call: a missing file is a handle that turns "failed" once the worker has looked. |

<a id="tecs.assets.loadSound"></a>

### tecs.assets.loadSound

<pre><code v-pre>function <a href="#tecs.assets.loadSound">tecs.assets.loadSound</a>(path: string, mode: string, streamMs: integer): <a href="#tecs.assets.Handle">Handle</a>
</code></pre>

Queues a sound for loading and returns its handle immediately.

Whatever the mixer's decoders can read loads, so the format is the file's
business rather than the caller's.

`mode` is "resident", "stream", or "auto", and auto keeps anything shorter
than `streamMs` resident.

The library is initialised here rather than on the worker: `MIX_Init` is
documented as not thread safe, and doing it before the task is sent puts it
in order ahead of every decode without a lock.

Two overlapping loads of one path do not share, unlike images: each gets its own clip.

#### Parameters

| Type                       | Name                        | Description                                                                                                                                           |
| -------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>  | <code v-pre>path</code>     |                                                                                                                                                       |
| <code v-pre>string</code>  | <code v-pre>mode</code>     | "resident", "stream" or "auto". Anything else is treated as "stream".                                                                                 |
| <code v-pre>integer</code> | <code v-pre>streamMs</code> | The boundary "auto" decides on, in milliseconds. Read only under "auto", and a file whose length the container cannot state streams whatever it says. |

#### Returns

| Type                                                        | Description                                                                                                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.assets.Handle">Handle</a></code> | A handle at "loading", or one already at "failed" when the mixer could not be initialised, which is the one failure reported without waiting for the worker. |

<a id="tecs.assets.pending"></a>

### tecs.assets.pending

<pre><code v-pre>function <a href="#tecs.assets.pending">tecs.assets.pending</a>(): integer
</code></pre>

Handles still waiting on the worker.

#### Returns

| Type                       | Description                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Every load in flight in this process, not one caller's. Counted by walking the set, so it is fine per frame and not per entity. |

<a id="tecs.assets.shutdown"></a>

### tecs.assets.shutdown

<pre><code v-pre>function <a href="#tecs.assets.shutdown">tecs.assets.shutdown</a>()
</code></pre>

Stops the loading worker.

Blocks until the thread has exited. Loads still in flight are dropped and their handles
stay at "loading" forever, so drain with `waitAll` first if their results are wanted.
Releasing a handle that is already ready still works afterwards; this frees nothing.
<a id="tecs.assets.update"></a>

### tecs.assets.update

<pre><code v-pre>function <a href="#tecs.assets.update">tecs.assets.update</a>(): integer
</code></pre>

Takes finished decodes and uploads them. Call once per frame.

Polls, never blocks, and drains everything the worker has answered rather than one
result. Handles do not change state without this, so a game that stops calling it has
loads that stay "loading" forever.

#### Returns

| Type                       | Description                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many handles moved off "loading" this call, which is zero when nothing has finished and also zero when no worker is installed. |

<a id="tecs.assets.waitAll"></a>

### tecs.assets.waitAll

<pre><code v-pre>function <a href="#tecs.assets.waitAll">tecs.assets.waitAll</a>(timeoutMs: number)
</code></pre>

Blocks until every queued load has finished.

For startup and tests. A frame should poll `update` instead.

#### Parameters

| Type                      | Name                         | Description                                                                                                                                                      |
| ------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | <code v-pre>timeoutMs</code> | Wall-clock milliseconds, defaulting to 5000. Running out is not an error and is not reported, so read `assets.pending` afterwards to tell the two endings apart. |
