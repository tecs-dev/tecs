---
description: "LuaJIT sampling profiler and trace-abort tracker through tecs.utils.profile"
outline: deep
---

# Profiling

`tecs.utils.profile` answers two different questions about a running game, through two independent channels
that share the LuaJIT zone stack for attribution:

1. A sampling profiler that writes [collapsed-stack][2] output: "which parts of my code are slow?"
2. A trace-abort tracker: "is the JIT actually compiling my hot code?"

Each call returns a session handle. `:stop()` ends the session and returns its report; calling it twice raises.
One sample session and one trace session may be active at a time.

This one is not a field on `tecs`. The `tecs.utils.*` modules are supported API and are required directly:

```teal
local profile <const> = require("tecs.utils.profile")
```

## What neither channel sees

Both channels report on code while it runs. Two costs sit outside what either of them, or a frame-time average,
can show, so a game chasing one of these has to measure it deliberately.

**Latency.** Frame time cannot see how long a player waits between a press and the frame that reacted to it, and
the two move independently: anything that pipelines a frame buys throughput and pays for it in latency. Measure
the interval from the event arriving to the frame that consumed it being submitted, over the frames that
actually consumed one. A frame nobody was waiting on has no latency, and averaging it in only makes the number
smaller. Charge a batch of events to the frame from its oldest event, which is that batch's worst case.

**Allocation.** A frame that allocates has bought a collection some later frame pays for, so the cost lands away
from where it was incurred and arrives as a tail nobody can attribute. Measuring it is mostly a matter of not
being fooled three times:

- `collectgarbage("count")` reports the size of the heap, not what was allocated, so a collection inside the
  measurement window eats the delta and more work can read as less. Stop the collector for the window.
- `collectgarbage` is not compiled by LuaJIT, so a probe inside the frame aborts every trace that would have
  covered it. The compiler then spends the run recording and recompiling, which is itself heap traffic charged
  to the frame being measured. Measure twice instead: once with no probe in the frame at all, for the total, and
  once with probes at phase boundaries, for the breakdown, counting only the frames the compiler did not touch.
- LuaJIT removes allocations that do not escape a trace, so the same source measures differently depending on
  what happened to be compiled. A cursor that never leaves the loop it opens is the everyday case: it costs
  nothing once the traversal is compiled, and no reading can see it.

`profile.trace` is what confirms the second point in your own code. If the abort report grows when the probes go
in, the reading is measuring the compiler rather than the frame.

## Sampling profiler

The sampler tags every collected stack with the active [zone path][1], and the pipeline pushes those zones for
you. Each `world:update` runs inside `beforeFixed`, `fixedLoop`, or `afterFixed`, and each system inside that
runs in a zone named `"<phase>:<system>"`, so a sample lands somewhere like
`afterFixed/Render:game.DrawScene`. Push your own zones inside that for finer regions.

Output is the standard collapsed-stack format consumed by [speedscope.app][3], [FlameGraph.pl][4], inferno,
pyroscope, and most other flamegraph tools.

### Timed session

Start a session, then schedule a one-shot system to stop it after a delay. `tecs.ecs.runif.after` fires once and
removes the system from the pipeline. Pass a path to `:stop()` to write the collapsed-stack text straight to
disk.

```teal
local profile <const> = require("tecs.utils.profile")

local session = profile.sample()

world:addSystem({
    phase = tecs.ecs.phases.First,
    runIf = tecs.ecs.runif.after(5),
    run = function()
        session:stop(tecs.filesystem.writablePath("tecs.collapsed"))
    end,
})
```

`tecs.filesystem.writablePath` resolves against the only directory a build may write to, which matters on targets where
the working directory is read-only.

### Custom zones

Push a `jit.zone` to tag any region you want samples attributed to:

```teal
local zone <const> = require("jit.zone")

world:addSystem({
    name = "myGame.Render",
    phase = tecs.ecs.phases.Render,
    run = function()
        zone("uploadBuffers")
        uploadBuffers()
        zone()
        zone("drawScene")
        drawScene()
        zone()
    end,
})
```

::: tip Where to put zones

- The zone stack is refcounted across live sessions and `jit.zone` is a no-op while no session needs it, so
  leaving `zone("foo")` calls in a shipped build costs essentially nothing.
- Do not push and pop inside hot inner loops, but do fence them around systems and major logic blocks.
  :::

## Trace abort tracker

LuaJIT compiles hot loops into traces. When recording fails, on NYI bytecode, an IR overflow, a trace that grew
too long, or blacklisting after repeated failures, the trace is abandoned and that code falls back to the slower
interpreter. Many aborts are harmless; aborts in hot code are worth investigating. A sampled flamegraph shows
the slow code as slow but will not tell you the JIT gave up on it.

`profile.trace` attaches to LuaJIT's trace events and aggregates aborts into a report sorted by severity:

| Severity        | What it means                                                                   | What to do                                          |
| --------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| **`blacklist`** | LuaJIT permanently demoted this trace to the interpreter for the run.           | Investigate.                                        |
| **`warn`**      | Anything else: NYI bytecode, a FastFunc bailout, a trace size limit.            | If hot, consider rewriting the offending construct. |
| **`info`**      | Benign trace-formation events: leaving loop, inner loop, up- or down-recursion. | Nothing; filtered out unless you opt in.            |

### Starting and stopping

```teal
local profile <const> = require("tecs.utils.profile")

local session = profile.trace()
-- ...later...
local report = session:stop()
print(report)
```

Or pass a path to write the formatted report:

```teal
session:stop(tecs.filesystem.writablePath("aborts.csv"))
```

Periodic reporting from a system, restarting after each report:

```teal
local session = profile.trace()

world:addSystem({
    name = "profile.traceReport",
    phase = tecs.ecs.phases.First,
    runIf = tecs.ecs.runif.every(10),
    run = function()
        local report = session:stop()
        if report.blacklisted > 0 then
            print(report)
        end
        session = profile.trace()
    end,
})
```

### Sample report

`tostring(report)`, and the file written by `:stop(filename)`, is RFC 4180 CSV, suitable for spreadsheets,
`sort`, `diff`, and most other tools:

```csv
severity,count,reason,location,zone
blacklist,1,blacklisted,src/enemy/ai.lua:142,fixedLoop/FixedUpdate:game.EnemyAi
warn,312,"NYI: FastFunc string.format",src/hud/score.lua:38,afterFixed/Render:game.Hud
warn,87,"NYI: bytecode CAT",src/dialog.lua:64,afterFixed/Render:game.Dialog
warn,37,trace too long,src/inventory.lua:201,afterFixed/Update:game.Inventory
```

Rows sort by severity, `blacklist` before `warn` before `info`, then by count descending, then by reason and
location, so the most actionable rows are at the top.

The summary values `durationSec`, `totalAborts`, and `blacklisted` live on the returned `TraceReport` object
rather than in the CSV. Read them directly:

```teal
local report = session:stop(tecs.filesystem.writablePath("aborts.csv"))
print(string.format("%ds, %d aborts, %d blacklisted",
    report.durationSec, report.totalAborts, report.blacklisted))
```

## API

### profile.sample

Starts a sampling session and returns a handle. Raises if a sample session is already active.

```teal
function profile.sample(opts?: profile.SampleOptions): profile.SampleSession
```

**Parameters:**

- `opts`: sampler options, all optional.

| Field        | Type      | Default | Description                                                                                                                                                                         |
| ------------ | --------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `intervalMs` | `integer` | `10`    | Sampler interval in milliseconds, so roughly 100 samples a second. Raise it for longer, lower-overhead sessions; below 10 the timer starts stealing real time from the main thread. |
| `stackDepth` | `integer` | `16`    | Per-sample stack depth. Walk cost is linear in depth, so raise it only when an investigation needs deeper stacks.                                                                   |
| `zone`       | `string`  | none    | Restrict output to samples whose zone path starts with this prefix, keeping only that subtree, for example `"fixedLoop"` for the fixed-timestep systems alone.                      |

**Returns:** a `SampleSession`.

Leaf frames always carry an `_[N]`, `_[I]`, `_[C]`, `_[G]`, or `_[J]` marker naming the dominant VM state for
that stack: native, interpreter, C, GC, or JIT compiler.

**Example:**

```teal
local session = profile.sample()
```

Or coarser, restricted to one zone subtree:

```teal
local session = profile.sample({
    intervalMs = 20,
    zone = "afterFixed",
})
```

### SampleSession:stop

Stops the session and returns the [collapsed-stack][2] text. Raises if called twice, or if the file cannot be
written.

```teal
function SampleSession:stop(filename?: string): string
```

**Parameters:**

- `filename`: optional path. When given, the text is also written there as a side effect.

**Returns:** the collapsed-stack text, whether or not a file was written.

**Example:**

```teal
local text = session:stop()
```

```teal
local text = session:stop("/tmp/tecs.collapsed")
```

### SampleSession:pause / SampleSession:resume

Skip recording samples for a while. The timer keeps firing, at the cost of one boolean check per sample, and
data captured either side of the pause window is preserved. Both are idempotent, and both raise if the session
has been stopped.

```teal
function SampleSession:pause()
function SampleSession:resume()
```

**Example:** excluding setup and teardown from a benchmark harness.

```teal
local s = profile.sample()
for _, case in ipairs(cases) do
    setupCase(case)
    s:resume()
    runCase(case)
    s:pause()
    teardownCase(case)
end
local text = s:stop()
```

### profile.trace

Starts a trace abort tracker and returns a handle. Raises if a trace session is already active.

```teal
function profile.trace(opts?: profile.TraceOptions): profile.TraceSession
```

**Parameters:**

- `opts`: tracker options, all optional.

| Field           | Type      | Default | Description                                                                                                                                          |
| --------------- | --------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `includeBenign` | `boolean` | `false` | Include the benign trace-formation events: leaving loop, inner loop, up-recursion, down-recursion. Useful when debugging why a trace failed to form. |

**Returns:** a `TraceSession`.

**Example:**

```teal
local session = profile.trace({includeBenign = true})
```

### TraceSession:stop

Stops the session and returns the `TraceReport`. Raises if called twice, or if the file cannot be written.

```teal
function TraceSession:stop(filename?: string): profile.TraceReport
```

**Parameters:**

- `filename`: optional path. When given, the same CSV that `tostring(report)` renders is also written there.

**Returns:** the `TraceReport`. It carries a `__tostring` metamethod rendering RFC 4180 CSV, so `print(report)`
works directly.

### TraceSession:pause / TraceSession:resume

Skip aggregating aborts for a while. Event registration stays attached, at the cost of one boolean check per
abort, and counts captured either side of the pause window are preserved. Both are idempotent, and both raise if
the session has been stopped.

```teal
function TraceSession:pause()
function TraceSession:resume()
```

### TraceReport

| Field         | Type          | Description                                                                                          |
| ------------- | ------------- | ---------------------------------------------------------------------------------------------------- |
| `durationSec` | `number`      | Wallclock seconds the session was active.                                                            |
| `totalAborts` | `integer`     | Total abort events recorded. Excludes benign trace-formation events unless `includeBenign` was set.  |
| `blacklisted` | `integer`     | Trace blacklist events. Always actionable.                                                           |
| `sites`       | `{AbortSite}` | One entry per unique `(severity, reason, location, zone)`, sorted by severity then count descending. |

### AbortSite

| Field      | Type      | Description                                                                                             |
| ---------- | --------- | ------------------------------------------------------------------------------------------------------- |
| `severity` | `string`  | `"blacklist"`, `"warn"`, or `"info"`.                                                                   |
| `count`    | `integer` | Times this exact `(severity, reason, location, zone)` combination fired.                                |
| `reason`   | `string`  | Human-readable reason from `jit.vmdef.traceerr`. NYI bytecode aborts are rendered with the opcode name. |
| `location` | `string`  | `"<file>:<line>"` of the function being recorded when the abort happened.                               |
| `zone`     | `string`  | Active zone path at abort time, empty when no zone was on the stack.                                    |

[1]: https://luajit.org/ext_profiler.html#jit_zone
[2]: https://www.brendangregg.com/flamegraphs.html
[3]: https://speedscope.app
[4]: https://github.com/brendangregg/FlameGraph
