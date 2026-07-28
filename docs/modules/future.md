---
description: "A value that settles once: four states, combinators, a source-driven wait, counted cancellation and the sequence bridge"
outline: deep
---

# tecs.future.Future

Several things in this tree are work in flight: an asset decode, a child process, a request. Each of them used to
own a private settle-once cell with four states, a failure string and a blocking wait that pumped a worker, and
each had a different word for the same four states. `Future` is that object written once, and what a subsystem
hands back instead of a private type: [`proc.run`](/modules/proc) returns a `Future<proc.Result>` rather than a
`Proc`. No subsystem exports an alias for the type; callers write `Future`.

```teal
tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
    :map(function(result) return result.output end)
    :recover(function() return "unknown" end)
    :onSettle(function(future) print(future.value) end)
```

## Four states

`status` is a plain string field rather than a method, because several call sites read it once a frame and a
field read plus a string compare is what that should cost.

| Status        | Meaning                                                       |
| ------------- | ------------------------------------------------------------- |
| `"pending"`   | Nothing has settled it yet. The state a future is created in. |
| `"ready"`     | It settled with a value, which is in `value`.                 |
| `"failed"`    | The work never produced an answer. `error` says why.          |
| `"cancelled"` | The work was given up on or taken away. `error` says why.     |

`"cancelled"` is separate from `"failed"` because [`recover`](#recover) must not run for it: a caller who
cancelled a load did not ask for a fallback value.

An unwelcome answer is not `"failed"` either. A child process that exits 1 and an HTTP response that is 404 both
settle `"ready"`, because the code is the answer rather than an error. `"failed"` means the work never produced
one.

### Fields

| Field    | Type     | Description                                             |
| -------- | -------- | ------------------------------------------------------- |
| `status` | `string` | `"pending"`, `"ready"`, `"failed"` or `"cancelled"`.    |
| `value`  | `T`      | What settled. Valid only on `"ready"`.                  |
| `error`  | `string` | Why it did not. Set on `"failed"` and on `"cancelled"`. |

**Example:**

```teal
if run.status == "ready" then
    use(run.value)
elseif run.status == "failed" then
    report(run.error)
end
```

## Creating one

### pending

Creates a future nothing has settled yet.

```teal
function Future.pending<U>(source?: Source): Future<U>
```

**Parameters:**

- `source`: what a [`wait`](#wait) on it advances, and what a counted-out [`cancel`](#cancel) asks to stop the
  work. Omitted, the future can only be settled by whoever holds it and a `wait` on it returns at once.

**Returns:** a future in `"pending"`.

The producer half, for a source settling its own work and for a test that decides when something finishes.

### settled

A future already carrying a value.

```teal
function Future.settled<U>(value: U): Future<U>
```

### failed

A future already carrying a failure.

```teal
function Future.failed<U>(err: string): Future<U>
```

**Parameters:**

- `err`: the failure. `nil` becomes `"failed"`.

## Settling one

The producer half. Whoever created a future through `Future.pending` owns these; a future handed out by a
subsystem is settled by that subsystem's source, and calling one of these on it is a caller settling work it does
not own. Settling twice is a no-op, so the first answer wins.

### complete

Settles this future with a value, if nothing has settled it yet.

```teal
function Future:complete(value: T)
```

### fail

Settles this future as failed, if nothing has settled it yet.

```teal
function Future:fail(err: string)
```

`nil` becomes `"failed"`.

### abandon

Settles this future as cancelled, if nothing has settled it yet.

```teal
function Future:abandon(err: string)
```

The producer half of the third terminal state, and the counterpart of [`cancel`](#cancel) rather than a spelling
of it: `cancel` is a consumer saying it no longer wants the work and counts the others who might, while this
states an outcome that has already happened. A child killed on request or at its deadline reaches its future
through here, as does a transfer taken off the multi. `nil` becomes `"cancelled"`.

## Listening

### onSettle

Registers a dependent, and returns this future.

```teal
function Future:onSettle(listener: function(Future<T>)): Future<T>
```

**Parameters:**

- `listener`: called with this future once it settles, whichever of the three terminal states it reached. Passing
  nothing raises.

**Returns:** this future, so registrations chain.

The primitive the other combinators are built on. A listener on a future that has already settled runs on the
next drain rather than inline, which is what keeps a chain built one link at a time from growing the Lua stack. A
listener that raises is logged and does not stop the others.

**Example:**

```teal
run:onSettle(function(future)
    if future.status == "ready" then
        print(future.value.output)
    end
end)
```

## Combinators

Each of these returns a new future derived from this one. A derived future inherits its upstream's source, so a
`wait` on the end of a chain advances the work at the start of it, and it counts as one watcher of its upstream.

### map

A future carrying `transform` applied to this one's value.

```teal
function Future:map<U>(transform: function(T): U): Future<U>
```

**Parameters:**

- `transform`: run on `"ready"` only. Passing nothing raises.

**Returns:** a future that settles `"ready"` with the transformed value. A `"failed"` or `"cancelled"` upstream
propagates without calling `transform`, and a raise inside it becomes this link's failure.

### flatMap

A future carrying whatever the future `transform` starts settles to.

```teal
function Future:flatMap<U>(transform: function(T): Future<U>): Future<U>
```

**Parameters:**

- `transform`: run on `"ready"` only, and expected to start work and return a future for it. Passing nothing
  raises; returning no future fails the link.

**Returns:** a future that settles as the inner one does, status and all.

The one combinator that expresses a dependent second request. Two things follow from `transform` starting work
rather than transforming work already done: the derived future's source becomes the inner future's, so a chain
can begin on a worker and end somewhere else; and cancelling before the outer settles stops `transform` from ever
being called, since there is nothing yet to cancel afterwards.

### recover

A future that turns this one's failure into a value.

```teal
function Future:recover(recovery: function(string): T): Future<T>
```

**Parameters:**

- `recovery`: run on `"failed"` only, with the error string. Passing nothing raises.

**Returns:** a future carrying either the upstream's value or the recovered one. A `"cancelled"` upstream is not
recovered, which is the whole reason the two states are distinct, and a raise inside `recovery` becomes this
link's failure.

### all

A future carrying every input's value, in input order.

```teal
function Future.all<U>(inputs: {Future<U>}): Future<{U}>
```

**Parameters:**

- `inputs`: the futures to join. An empty list settles `"ready"` with an empty list immediately. Passing nothing
  raises.

**Returns:** a future that settles when the last input does, whatever order they settle in.

A failed or cancelled input fails the join with that input's error; the rest are left running, because an input
shared with something outside the join is not this join's to stop.

Fan-in does not nest: each listener decrements a counter and only the last input settles the join, so a join over
five hundred loads is two deep rather than five hundred.

**Example:**

```teal
local runs <const> = {
    tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } }),
    tecs.proc.run({ args = { "git", "status", "--porcelain" } }),
}
tecs.future.Future.all(runs):onSettle(function(joined)
    if joined.status == "ready" then
        report(joined.value[1], joined.value[2])
    end
end)
```

## Sources

A `Source` is where a future's settlements come from, and what a blocking wait spends its time in. Every source
in this tree is something that can be told to block for up to N milliseconds and hand over whatever arrived,
which is the whole of what a future needs from the work behind it: an asset decode and a child process are a
worker channel, and an HTTP transfer is a curl multi handle whose poll is the same shape.

The type is reachable as `tecs.future.Source`.

| Field           | Type                                          | Default  | Description                                                                                                                                                                                           |
| --------------- | --------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `poll`          | `function(self: Source): integer`             | required | Takes everything ready and settles what it belongs to, returning how many settled. Called once per frame per source, and costs a non-blocking receive on a frame where nothing finished.              |
| `advance`       | `function(self: Source, ms: number): integer` | required | Blocks up to `ms` for one settlement and takes it, returning how many settled. It must not block for longer than it is asked to.                                                                      |
| `sliceMs`       | `number`                                      | `16`     | Milliseconds one [`wait`](#wait) slice blocks for.                                                                                                                                                    |
| `defaultWaitMs` | `number`                                      | `5000`   | Milliseconds `wait` spends when the caller names nothing. It lives here rather than on `wait` so a subprocess can keep a longer default than a decode without a second convention.                    |
| `cancel`        | `function(self: Source, future: Future<any>)` | unset    | Stops the work behind a root future whose last watcher has gone. A source with no hook leaves the work running and stops caring, which is what a future over something uncancellable can honestly do. |

::: warning One thread
Futures are created and settled on the thread that pumps their source, and there is no synchronisation anywhere
below. That is what removes the atomics a general-purpose future library carries, so it is load-bearing rather
than incidental: **a source must settle its futures on the thread that pumps it.** If a second thread ever pumps
a source, the answer is a queue handing settlements back to the pumping thread, not a lock-free stack.
:::

## Waiting

### wait

Blocks until this future settles, advancing its source.

```teal
function Future:wait(timeoutMs?: number): Future<T>
```

**Parameters:**

- `timeoutMs`: how long to wait. Defaults to the source's `defaultWaitMs`, or 5000. Running out leaves the future
  `"pending"`.

**Returns:** this future.

For startup, tools and tests; a frame polls `status` instead. Never a busy loop: the time is spent inside the
source's blocking receive, a slice at a time. The budget is wall clock rather than a count of slices, so a source
that answers faster than its slice size does not shorten the wait. A future with no source cannot be advanced and
returns at once, as does one that has already settled.

The source is re-read every slice rather than cached, because a [`flatMap`](#flatmap) link moves the chain onto
the inner future's source part way through.

**Example:**

```teal
local head <const> = tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } }):wait()
if head.status == "ready" then
    print(head.value.output)
end
```

## Cancelling

### cancel

Gives up this consumer's interest in the work.

```teal
function Future:cancel()
```

Reference counted, because a shared root is real: two loads of one path that overlap get the same future, and one
of them cancelling must not break the other. So this decrements, and only the last one settles the future
`"cancelled"` and asks the source to stop the work. Cancelling a derived future drops its listener and decrements
its upstream, which may in turn reach zero. Cancelling a settled future is a no-op.

Only a future the source made carries work of its own, so only that one reaches the source's `cancel` hook; a
derived link inherits the source to know what a wait advances and nothing else. Without that distinction a `map`
link giving up would stop the decode its upstream is still waiting for.

## Order

Listeners run in registration order, and futures settled during one drain are drained in the order they settled.
Neither is arbitrary: a listener that registers an image allocates through a shelf packer whose coordinates
depend on arrival order and end up in a `Sprite` component, which a snapshot stores.

Order being fixed does not make the system deterministic, because two decodes still race on the worker and arrive
in whatever order they finish. It means a given arrival order always produces the same result, which is the part
that is in this design's gift.

Settling drains iteratively rather than recursively. A dependent that settles another future extends a loop
instead of the stack, so a chain's depth costs two frames whatever its length; that is also why registering a
listener on an already-settled future queues rather than firing inline. It makes re-entrancy legal by
construction rather than by a rule a caller has to remember: a listener may settle, cancel or register on
anything it likes, including the future it is being called from.

## The sequence bridge

### track

Makes a future something a [sequence](/modules/sequence) can wait for.

```teal
function Future.track<U>(world: World, entity: integer, key: string, future: Future<U>)
```

**Parameters:**

- `world`: the world the sequence runs in. Required.
- `entity`: the entity the wait is bound to. It has to be live, because the sequencer releases a cursor whose
  entity is dead rather than stranding it, so the key is a pair and the entity is the game's own loader.
- `key`: a non-empty program constant naming this piece of work.
- `future`: what to park on. A future that has already settled is not written down, so a program that reaches its
  await after the work finished carries on rather than hanging.

The sequencer has a registry for waiting on work outside it, and this module is its one engine registrant, under
the name `"tecs.future"`. So a program parks on a decode, a subprocess or a request with:

```teal
tecs.sequence.await("tecs.future", tecs.sequence.bind("loader"), "level1")
```

against a future tracked under that same entity and key. The entry is dropped when the future settles, so nothing
accumulates, and tracking a second future under one entity and key replaces the first.

Only the fixed clock delivers awaits, so a program on the frame or presentation clock parked on a future is
released by a fixed step; that is already true of every awaitable. There is no pause: a decode in flight cannot
be paused, and the contract says a provider that cannot pause its work does not offer it.

## Snapshots

A future is never in a snapshot. It holds listeners, a source and, through its source, a native handle. What is
snapshotted is a sequence cursor parked on one, which stores a provider name, an entity and a key.

So after a load the wait survives and the future does not: nothing has been tracked, the provider answers that
nothing is pending, and the parked cursor resumes on the next fixed step. That is why the bridge looks a future
up by world, entity and key and never by object identity. A game that wants the wait to mean something after a
restore re-issues the work and re-tracks it under the same key.
<!-- @generated by docs/scripts/reference.py from src/tecs/Future.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/Future.tl`.

<a id="tecs.future.Future.Source"></a>

### tecs.future.Future.Source

<pre><code v-pre>record <a href="#tecs.future.Future.Source">tecs.future.Future.Source</a>
</code></pre>

Where a future's settlements come from, and what a blocking wait spends
its time in.

Every source in this tree is something that can be told to block for up
to N milliseconds and hand over whatever arrived, which is the whole of
what a future needs from the work behind it. An asset decode and a child
process are a worker channel; an HTTP transfer is a curl multi handle,
whose `curl_multi_poll` is the same shape.
<a id="tecs.future.Future.Source.poll"></a>

### tecs.future.Future.Source.poll

<pre><code v-pre>function <a href="#tecs.future.Future.Source.poll">tecs.future.Future.Source.poll</a>(<a href="#tecs.future.Future.Source">Source</a>): integer
</code></pre>

Takes everything ready and settles what it belongs to.

Called once per frame per source, and costs a non-blocking receive
that answers nil on any frame where nothing finished.

#### Parameters

| Type                                                               | Name | Description |
| ------------------------------------------------------------------ | ---- | ----------- |
| <code v-pre><a href="#tecs.future.Future.Source">Source</a></code> |      |             |

#### Returns

| Type                       | Description       |
| -------------------------- | ----------------- |
| <code v-pre>integer</code> | How many settled. |

<a id="tecs.future.Future.Source.advance"></a>

### tecs.future.Future.Source.advance

<pre><code v-pre>function <a href="#tecs.future.Future.Source.advance">tecs.future.Future.Source.advance</a>(<a href="#tecs.future.Future.Source">Source</a>, number): integer
</code></pre>

Blocks up to `ms` for one settlement and takes it.

What `Future:wait` spends a slice in, so it must not block for
longer than it is asked to.

#### Parameters

| Type                                                               | Name | Description |
| ------------------------------------------------------------------ | ---- | ----------- |
| <code v-pre><a href="#tecs.future.Future.Source">Source</a></code> |      |             |
| <code v-pre>number</code>                                          |      |             |

#### Returns

| Type                       | Description       |
| -------------------------- | ----------------- |
| <code v-pre>integer</code> | How many settled. |

<a id="tecs.future.Future.Source.sliceMs"></a>

### tecs.future.Future.Source.sliceMs

<pre><code v-pre><a href="#tecs.future.Future.Source.sliceMs">tecs.future.Future.Source.sliceMs</a>: number
</code></pre>

Milliseconds one `wait` slice blocks for. Optional; 16 by default.
<a id="tecs.future.Future.Source.defaultWaitMs"></a>

### tecs.future.Future.Source.defaultWaitMs

<pre><code v-pre><a href="#tecs.future.Future.Source.defaultWaitMs">tecs.future.Future.Source.defaultWaitMs</a>: number
</code></pre>

Milliseconds `wait` spends when the caller names nothing. Optional;
5000 by default. It lives here rather than on `wait` so a subprocess
can keep a longer default than a decode without a second
convention.
<a id="tecs.future.Future.Source.cancel"></a>

### tecs.future.Future.Source.cancel

<pre><code v-pre>function <a href="#tecs.future.Future.Source.cancel">tecs.future.Future.Source.cancel</a>(<a href="#tecs.future.Future.Source">Source</a>, Future&lt;&lt;any type&gt;&gt;)
</code></pre>

Stops the work behind a root future whose last watcher has gone.

Optional. A source with no hook leaves the work running and stops
caring, which is what a future over something uncancellable can
honestly do.

#### Parameters

| Type                                                               | Name | Description |
| ------------------------------------------------------------------ | ---- | ----------- |
| <code v-pre><a href="#tecs.future.Future.Source">Source</a></code> |      |             |
| <code v-pre>Future&lt;&lt;any type&gt;&gt;</code>                  |      |             |

<a id="tecs.future.Future.abandon"></a>

### tecs.future.Future.abandon

<pre><code v-pre>function <a href="#tecs.future.Future.abandon">tecs.future.Future.abandon</a>(self: Future&lt;T&gt;, err: string)
</code></pre>

Settles this future as cancelled, if nothing has settled it yet.

The producer half of the third terminal state, and the counterpart of
`cancel` rather than a spelling of it: `cancel` is a consumer saying it
no longer wants the work and counts the others who might, while this
states an outcome that has already happened. A child killed on request
or at its deadline reaches its future through here, as does a transfer
taken off the multi.

#### Parameters

| Type                               | Name                    | Description                                                                                                                  |
| ---------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>self</code> |                                                                                                                              |
| <code v-pre>string</code>          | <code v-pre>err</code>  | Nil becomes "cancelled". No watcher counting happens here: this settles the future outright, whoever else was waiting on it. |

<a id="tecs.future.Future.all"></a>

### tecs.future.Future.all

<pre><code v-pre>function <a href="#tecs.future.Future.all">tecs.future.Future.all</a>&lt;U&gt;(inputs: {Future&lt;U&gt;}): Future&lt;{U}&gt;
</code></pre>

A future carrying every input's value, in input order.

Settles when the last input does, whatever order they settle in. A
failed or cancelled input fails the join with that input's error; the
rest are left running, because an input shared with something outside
the join is not this join's to stop.

Fan-in does not nest: each listener decrements a counter and only the
last input settles the join, so a join over five hundred loads is two
deep rather than five hundred.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                                 | Name                      | Description                                                                                                                    |
| ------------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>{Future&lt;U&gt;}</code> | <code v-pre>inputs</code> | Read once; adding to the list afterwards changes nothing. Empty gives an already-ready future over an empty array. Nil raises. |

#### Returns

| Type                                 | Description                                                                                                                                     |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;{U}&gt;</code> | A future whose value is a fresh array indexed as `inputs` is, so a hole cannot appear: the join only settles "ready" once every slot is filled. |

<a id="tecs.future.Future.cancel"></a>

### tecs.future.Future.cancel

<pre><code v-pre>function <a href="#tecs.future.Future.cancel">tecs.future.Future.cancel</a>(self: Future&lt;T&gt;)
</code></pre>

Gives up this consumer's interest in the work.

Reference counted, because a shared root is real: two loads of one path
that overlap get the same future, and one of them cancelling must not
break the other. So this decrements, and only the last one settles the
future "cancelled" and asks the source to stop the work. Cancelling a
derived future drops its listener and decrements its upstream, which may
in turn reach zero.

Cancelling a settled future is a no-op.

#### Parameters

| Type                               | Name                    | Description |
| ---------------------------------- | ----------------------- | ----------- |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>self</code> |             |

<a id="tecs.future.Future.complete"></a>

### tecs.future.Future.complete

<pre><code v-pre>function <a href="#tecs.future.Future.complete">tecs.future.Future.complete</a>(self: Future&lt;T&gt;, value: T)
</code></pre>

Settles this future with a value, if nothing has settled it yet.

The producer half. Whoever created a future through `Future.pending`
owns this and its sibling `fail`; a future handed out by a subsystem is
settled by that subsystem's source, and calling this on one is a caller
settling work it does not own. Settling twice is a no-op, so the first
answer wins.

#### Parameters

| Type                               | Name                     | Description                                                                                                                                         |
| ---------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>self</code>  |                                                                                                                                                     |
| <code v-pre>T</code>               | <code v-pre>value</code> | Stored as it is, not copied, and read back off `value`. Nil is a legal value and still settles "ready", which is how a future over nothing settles. |

<a id="tecs.future.Future.error"></a>

### tecs.future.Future.error

<pre><code v-pre><a href="#tecs.future.Future.error">tecs.future.Future.error</a>: string
</code></pre>

Why it did not. Set on "failed" and on "cancelled".
<a id="tecs.future.Future.fail"></a>

### tecs.future.Future.fail

<pre><code v-pre>function <a href="#tecs.future.Future.fail">tecs.future.Future.fail</a>(self: Future&lt;T&gt;, err: string)
</code></pre>

Settles this future as failed, if nothing has settled it yet.

#### Parameters

| Type                               | Name                    | Description                                                                                                      |
| ---------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>self</code> |                                                                                                                  |
| <code v-pre>string</code>          | <code v-pre>err</code>  | A sentence for a log, not something to match on. Nil becomes "failed", so `error` is set on every failed future. |

<a id="tecs.future.Future.failed"></a>

### tecs.future.Future.failed

<pre><code v-pre>function <a href="#tecs.future.Future.failed">tecs.future.Future.failed</a>&lt;U&gt;(err: string): Future&lt;U&gt;
</code></pre>

A future already carrying a failure.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                      | Name                   | Description           |
| ------------------------- | ---------------------- | --------------------- |
| <code v-pre>string</code> | <code v-pre>err</code> | Nil becomes "failed". |

#### Returns

| Type                               | Description |
| ---------------------------------- | ----------- |
| <code v-pre>Future&lt;U&gt;</code> |             |

<a id="tecs.future.Future.flatMap"></a>

### tecs.future.Future.flatMap

<pre><code v-pre>function <a href="#tecs.future.Future.flatMap">tecs.future.Future.flatMap</a>&lt;U&gt;(transform: Future&lt;T&gt;, function(T): Future&lt;U&gt;): Future&lt;U&gt;
</code></pre>

A future carrying whatever the future `transform` starts settles to.

The one combinator that expresses a dependent second request. Two things
follow from `transform` starting work rather than transforming work
already done: the derived future's source becomes the inner future's, so
a chain can begin on a worker and end somewhere else; and cancelling
before the outer settles stops `transform` from ever being called, since
there is nothing yet to cancel afterwards.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                                            | Name                         | Description                                                                                                                               |
| ----------------------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code>              | <code v-pre>transform</code> | Called at most once, on "ready" only. Returning nil rather than a future fails this link; nil for `transform` itself raises here and now. |
| <code v-pre>function(T): Future&lt;U&gt;</code> |                              |                                                                                                                                           |

#### Returns

| Type                               | Description                                                                                                                                     |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;U&gt;</code> | A new future settling to whatever the inner one settles to, status and all, so an inner that is cancelled leaves this cancelled and not failed. |

<a id="tecs.future.Future.map"></a>

### tecs.future.Future.map

<pre><code v-pre>function <a href="#tecs.future.Future.map">tecs.future.Future.map</a>&lt;U&gt;(transform: Future&lt;T&gt;, function(T): U): Future&lt;U&gt;
</code></pre>

A future carrying `transform` applied to this one's value.

`transform` runs only on "ready". A "failed" or "cancelled" upstream
propagates without calling it, and a raise inside it becomes this link's
failure.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                               | Name                         | Description                                                                                      |
| ---------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------ |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>transform</code> | Called at most once, with the upstream value. Nil raises here and now rather than at settlement. |
| <code v-pre>function(T): U</code>  |                              |                                                                                                  |

#### Returns

| Type                               | Description                                                                                                                                                |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;U&gt;</code> | A new future watching this one. Cancelling it gives up this link's interest in the upstream and does not settle the upstream unless nothing else wants it. |

<a id="tecs.future.Future.onSettle"></a>

### tecs.future.Future.onSettle

<pre><code v-pre>function <a href="#tecs.future.Future.onSettle">tecs.future.Future.onSettle</a>(self: Future&lt;T&gt;, listener: function(Future&lt;T&gt;)): Future&lt;T&gt;
</code></pre>

Registers a dependent, and returns this future.

The primitive the others are built on. A listener on a future that has
already settled runs on the next drain rather than inline, which is what
keeps a chain built one link at a time from growing the Lua stack. A
listener that raises is logged and does not stop the others.

#### Parameters

| Type                                         | Name                        | Description                                                                                                                               |
| -------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code>           | <code v-pre>self</code>     |                                                                                                                                           |
| <code v-pre>function(Future&lt;T&gt;)</code> | <code v-pre>listener</code> | Called once, with this future, whichever of the three terminal states it reached; read `status` rather than assuming a value. Nil raises. |

#### Returns

| Type                               | Description                                                                                                                        |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code> | This same future, not a derived one, so chaining `onSettle` registers several listeners on one thing rather than building a chain. |

<a id="tecs.future.Future.pending"></a>

### tecs.future.Future.pending

<pre><code v-pre>function <a href="#tecs.future.Future.pending">tecs.future.Future.pending</a>&lt;U&gt;(<a href="#tecs.future.Future.Source">Source</a>): Future&lt;U&gt;
</code></pre>

Creates a future nothing has settled yet.

The producer half, for a source settling its own work and for a test
that decides when something finishes. `source` is what a `wait` on it
advances; omitted, the future can only be settled by whoever holds it
and a `wait` on it returns at once.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                                                               | Name | Description |
| ------------------------------------------------------------------ | ---- | ----------- |
| <code v-pre><a href="#tecs.future.Future.Source">Source</a></code> |      |             |

#### Returns

| Type                               | Description                                                                                                            |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;U&gt;</code> | A future at "pending" with one watcher, so a single `cancel` on it settles it "cancelled" and calls the source's hook. |

<a id="tecs.future.Future.recover"></a>

### tecs.future.Future.recover

<pre><code v-pre>function <a href="#tecs.future.Future.recover">tecs.future.Future.recover</a>(self: Future&lt;T&gt;, recovery: function(string): T): Future&lt;T&gt;
</code></pre>

A future that turns this one's failure into a value.

`recovery` runs only on "failed". A "cancelled" upstream is not
recovered, which is the whole reason the two are distinct states.

#### Parameters

| Type                                   | Name                        | Description                                                                                                                                                |
| -------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code>     | <code v-pre>self</code>     |                                                                                                                                                            |
| <code v-pre>function(string): T</code> | <code v-pre>recovery</code> | Given the upstream's error string. Raising inside it fails this link with that raise instead, so a recovery cannot fail silently. Nil raises here and now. |

#### Returns

| Type                               | Description |
| ---------------------------------- | ----------- |
| <code v-pre>Future&lt;T&gt;</code> |             |

<a id="tecs.future.Future.settled"></a>

### tecs.future.Future.settled

<pre><code v-pre>function <a href="#tecs.future.Future.settled">tecs.future.Future.settled</a>&lt;U&gt;(U): Future&lt;U&gt;
</code></pre>

A future already carrying a value.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                 | Name | Description |
| -------------------- | ---- | ----------- |
| <code v-pre>U</code> |      |             |

#### Returns

| Type                               | Description                                                                                                                                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;U&gt;</code> | A future at "ready" with no source, so `wait` on it returns at once and `cancel` does nothing. A listener added to it still runs on the next drain. |

<a id="tecs.future.Future.status"></a>

### tecs.future.Future.status

<pre><code v-pre><a href="#tecs.future.Future.status">tecs.future.Future.status</a>: string
</code></pre>

"pending", "ready", "failed", or "cancelled".
<a id="tecs.future.Future.track"></a>

### tecs.future.Future.track

<pre><code v-pre>function <a href="#tecs.future.Future.track">tecs.future.Future.track</a>&lt;U&gt;(entity: World, key: integer, future: string, Future&lt;U&gt;)
</code></pre>

Makes a future something a sequence can wait for.

The sequencer has a registry for waiting on work outside it, and this
module is its one engine registrant, under the name `"tecs.future"`. So
a program parks on a decode, a subprocess or a request with

sequence.await("tecs.future", sequence.bind("loader"), "level1")

against a future tracked here under that same entity and key.

Three properties of the machinery underneath, none of them this
function's to change. An await needs a live bound entity, because the VM
releases a cursor whose entity is dead rather than stranding it, so the
key is a pair and the entity is the game's own loader. The key is a
program constant, so a future is awaited by the name it was tracked
under rather than by identity, which is what lets the wait survive a
snapshot the future cannot. And only the fixed clock delivers awaits, so
a program on the frame or presentation clock parked on a future is
released by a fixed step; that is already true of every awaitable.

The entry is dropped when the future settles, so a program that reaches
its await after the work finished carries on rather than hanging, and
nothing accumulates. Tracking a second future under one entity and key
replaces the first.

There is no `setPaused`: a decode in flight cannot be paused, and the
contract says a provider that cannot pause its work does not offer it.

#### Type Parameters

| Name                 | Constraint | Description |
| -------------------- | ---------- | ----------- |
| <code v-pre>U</code> |            |             |

#### Parameters

| Type                               | Name                      | Description                                                                                                                                      |
| ---------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>World</code>           | <code v-pre>entity</code> | What the await binds to, and it must still be alive when the program parks; the VM releases a cursor whose entity is dead.                       |
| <code v-pre>integer</code>         | <code v-pre>key</code>    | A program constant, not something derived per call, since the await names it. Nil or empty raises.                                               |
| <code v-pre>string</code>          | <code v-pre>future</code> | Nil raises. One that has already settled is deliberately not written down, so a later await on that key carries straight on rather than hanging. |
| <code v-pre>Future&lt;U&gt;</code> |                           |                                                                                                                                                  |

<a id="tecs.future.Future.value"></a>

### tecs.future.Future.value

<pre><code v-pre><a href="#tecs.future.Future.value">tecs.future.Future.value</a>: T
</code></pre>

What settled. Valid only on "ready".
<a id="tecs.future.Future.wait"></a>

### tecs.future.Future.wait

<pre><code v-pre>function <a href="#tecs.future.Future.wait">tecs.future.Future.wait</a>(self: Future&lt;T&gt;, timeoutMs: number): Future&lt;T&gt;
</code></pre>

Blocks until this future settles, advancing its source.

For startup, tools and tests; a frame polls `status` instead. Never a
busy loop: the time is spent inside the source's blocking receive. The
budget is wall clock rather than a count of slices, so a source that
answers faster than its slice size does not shorten the wait.

A future with no source cannot be advanced and returns at once.

#### Parameters

| Type                               | Name                         | Description                                                                                           |
| ---------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------- |
| <code v-pre>Future&lt;T&gt;</code> | <code v-pre>self</code>      |                                                                                                       |
| <code v-pre>number</code>          | <code v-pre>timeoutMs</code> | How long to wait. Defaults to the source's `defaultWaitMs`, or 5000. Running out leaves it "pending". |

#### Returns

| Type                               | Description  |
| ---------------------------------- | ------------ |
| <code v-pre>Future&lt;T&gt;</code> | This future. |
