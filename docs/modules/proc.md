---
description: "Running child processes on a worker and collecting their output as a future, without stalling a frame"
outline: deep
---

# tecs.proc

`tecs.proc` runs another program. A command line tool, a resource pipeline or an asset build wants to shell out,
and a game wants to do it between two frames rather than instead of them.

Reading a child's output and waiting for it to exit both hold the calling thread for as long as the child runs,
so neither happens on the main thread. A run goes out to a worker, the loop pumps, and a
[`Future`](/modules/Future) settles; that is the same shape [`assets`](/modules/assets) uses for a decode, for
the same reason.

It is one of the few subsystems more useful without a window than with one. No SDL subsystem is initialised and
no process call is made on this side at all, so it works under a plain interpreter with no video, no device and
no host.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.proc`. `tecs`
is also set as a global, which makes the require line optional, and engine modules are resolved lazily on first
field access.

```teal
local run <const> = tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
-- ... frames pass, the loop pumps ...
if run.status == "ready" and run.value:succeeded() then
    print(run.value.output)
end
```

A run is a `Future`, so the words for how it ended are the ones every asynchronous thing in the tree uses, and a
caller who wants the answer rather than the polling writes:

```teal
local head <const> = tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
    :map(function(result: tecs.proc.Result): string return result.output end)
    :recover(function(): string return "unknown" end)
    :wait()
print(head.value)
```

A `wait` on a run spends up to 30 seconds by default, which is longer than an asset decode's default because a
child process is a different order of work.

## One shape: run to completion

`proc.run` serves the child whose output you want when it finishes: a version query, an image conversion, a
shader translator, a packer. The result arrives whole, once, with the exit status beside it.

It deliberately does not serve the long-running child whose output you want as it appears. That is a different
API, not a flag on this one: it has to answer what a chunk is, what happens when a chatty child outruns its
reader, and how two streams interleave once they are delivered separately over time, and every one of those is a
guess here and a requirement there.

::: warning Bound what you run
Output is accumulated whole, so a child that prints forever is a child that allocates forever, and `timeoutMs`
is the answer.
:::

## run

Runs a program and answers a future for it, immediately.

```teal
function proc.run(options: Options): Future<Result>
```

**Returns:** a future that reads `"pending"` until [`proc.update`](#update), or a `wait` on it, takes the
worker's answer. Nothing here blocks. The first `run` installs the worker, so a process that never shells out
never starts a thread.

**`Options` fields:**

| Field         | Type               | Default   | Description                                                                                                                                                                                                                                                  |
| ------------- | ------------------ | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `args`        | `{string}`         | required  | The program and its arguments; `args[1]` is the program. A name without a separator is resolved against `PATH`. A missing, empty or non-string-carrying list raises.                                                                                         |
| `cwd`         | `string`           | inherited | Working directory for the child.                                                                                                                                                                                                                             |
| `env`         | `{string: string}` | inherited | Environment variables to set. Applied over this process's environment, or over an empty one when `clearEnv` is true.                                                                                                                                         |
| `clearEnv`    | `boolean`          | `false`   | Start the child's environment empty rather than inherited, so `env` is the whole of what it sees.                                                                                                                                                            |
| `mergeStderr` | `boolean`          | `false`   | Fold the child's error output into `output` instead of keeping it in `errorOutput`. Separate by default, because a tool's diagnostics interleaved into its output corrupt anything parsing that output, and the diagnostics are what you want when it fails. |
| `input`       | `string`           | none      | Bytes written to the child's standard input, which is closed once they are through. Omitted closes it immediately, so a child reading to end of input sees one rather than waiting.                                                                          |
| `timeoutMs`   | `integer`          | none      | Kill the child forcibly after this many milliseconds. Omitted lets it run as long as it likes.                                                                                                                                                               |

**Example:**

```teal
local formatted <const> = tecs.proc.run({
    args = { "clang-format", "-" },
    input = source,
    timeoutMs = 5000,
})
```

## Result

What a child that ran leaves behind. It is the value a `"ready"` future carries.

| Field         | Type       | Description                                                                                  |
| ------------- | ---------- | -------------------------------------------------------------------------------------------- |
| `args`        | `{string}` | The program and its arguments, as given.                                                     |
| `pid`         | `integer`  | The child's process id.                                                                      |
| `exitCode`    | `integer`  | The child's exit code, or the negated signal that ended it.                                  |
| `output`      | `string`   | Everything the child wrote to standard output.                                               |
| `errorOutput` | `string`   | Everything it wrote to standard error, or `""` when `mergeStderr` folded that into `output`. |

### Result:succeeded

Whether the child reported success.

```teal
function Result:succeeded(): boolean
```

**Returns:** whether `exitCode` is zero. A question about the answer rather than about whether there is one,
which is why it is a method and not a status: a result exists exactly when a child ran to completion, whatever it
then reported.

### result

The record a run fills in, whatever became of it.

```teal
function proc.result(run: Future<Result>): Result
```

**Returns:** the same object the future carries on `"ready"`, or nil for a run that never started and for
anything that is not a run from here.

It is reachable in the two cases where the future does not carry it. Before the child ends, so `pid` can be read
as soon as it has started, which is the one thing about a run that means anything before there is an answer. And
after a child was killed, which settles `"cancelled"` with no value but does not throw away what the child
managed to say first.

## How a run ends

`"failed"` means the child never started. A program that cannot be started settles there with `error` set,
rather than raising: a caller that shells out is already branching on the exit code, and a spawn that failed is
one more branch on the same value.

An exit code is not a failure. A child that ran and exited 1 settles `"ready"`, because the run did what it was
asked to and the code is the answer; reading it the other way would make every non-zero exit propagate as a
failure through `map`, which is wrong for everything that shells out to a tool whose exit code is data.

`"cancelled"` means this process ended the child, through `kill`, a `timeoutMs` deadline, or `shutdown`.

## Pumping

### update

Takes whatever the worker has answered. Call once per frame.

```teal
function proc.update(): integer
```

**Returns:** how many runs finished. [`Application`](/modules/Application) calls this for you each iteration.

### pending

Runs that have not answered yet.

```teal
function proc.pending(): integer
```

## Ending a child

### kill

Asks the worker to end a child.

```teal
function proc.kill(run: Future<Result>, force?: boolean)
```

**Parameters:**

- `run`: the future `proc.run` answered.
- `force`: whether the kill is unrefusable. Defaults to false, which is gentle and may be ignored by the child;
  a forced kill cannot be refused but leaves whatever the child was writing half written.

Queued rather than immediate: every process call belongs to the worker, so this is picked up on its next pass.
The future settles `"cancelled"` when the child goes.

`run:cancel()` is the other spelling, and it counts holders: it ends the child only when the last consumer of the
future has given it up, and it forces the kill, because the last consumer of the output has just gone and there
is nothing left to be gentle on behalf of. `proc.kill` ends the child whoever else is watching.

### shutdown

Ends every child still running and stops the worker.

```teal
function proc.shutdown(graceMs?: number)
```

**Parameters:**

- `graceMs`: how long a child gets to end gently before it is forced. Defaults to 250.

Gentle first, then forced, because a child that is mid-write deserves the chance to finish the line and a
teardown that waits forever deserves nothing. What it does not do is walk away: a detached child outlives the
process that started it, and the worker still blocked on it would be a thread running inside a library about to
be unmapped.

Every future still in flight ends at `"cancelled"`, including one whose child the kernel never reaped. Leaving
those pending would be a handle that reads "still running" for the rest of the process against a runner that no
longer exists.

The application runs this at teardown.

## The worker

Nothing but the request and the answer crosses the worker boundary. The child is created, fed, polled, read,
killed and destroyed entirely on the worker; what comes back is bytes, an exit code and a pid. The process handle
itself never moves, because it is a pid that may be reaped exactly once plus a set of pipe descriptors, and two
states holding it means two states able to reap it.

The worker polls rather than blocking, which is what makes it interruptible: a kill is a message it picks up on
its next pass, one worker holds any number of children at once, and a child that writes past the pipe buffer
keeps going because something is draining it.

### install

Starts the runner worker.

```teal
function proc.install(luaPath?: string)
```

**Parameters:**

- `luaPath`: module path to give the worker. Defaults to this state's `package.path`.

Called for you by the first `run`. Call it directly to pay that cost up front, or to give the worker a module
path other than this state's.

### installed

Whether the runner worker is running.

```teal
function proc.installed(): boolean
```

## Design record

- [Shelling out](https://github.com/tecs-dev/tecs/blob/main/README.md#shelling-out)
- [A value that settles once](https://github.com/tecs-dev/tecs/blob/main/README.md#a-value-that-settles-once)
- [Workers and assets](https://github.com/tecs-dev/tecs/blob/main/README.md#workers-and-assets)
