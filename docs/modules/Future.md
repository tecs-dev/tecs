---
description: "A value that settles once: four states, combinators, a source-driven wait, counted cancellation and the sequence bridge"
outline: deep
---

# tecs.Future

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

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.Future`. `tecs`
is also set as a global, which makes the require line optional, and engine modules are resolved lazily on first
field access.

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
tecs.Future.all(runs):onSettle(function(joined)
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

The type is reachable as `tecs.Future.Source`.

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

## Design record

- [A value that settles once](https://github.com/tecs-dev/tecs/blob/main/README.md#a-value-that-settles-once)
