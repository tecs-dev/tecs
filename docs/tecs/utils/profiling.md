---
outline: deep
---

# Profiling

Tecs provides two methods for performance profiling games:

1. A LuaJIT sampling profiler that writes [collapsed-stack][2] output: "What are the slow parts of my code?"
2. LuaJIT trace aborts: "Is the JIT working on my code?"

## Sampling profiler

The sampling profiler tags every collected stack with the active [zone path][1], so you can attribute time to
phases ("afterFixed/Render"), systems ("gfx.sprite"), and arbitrary sub-regions you push yourself. Output is the
standard collapsed-stack format consumed by [speedscope.app][3], [FlameGraph.pl][4], inferno, pyroscope, and most
other flamegraph tools.

### MCP client

The easiest way to profile is to connect to a running game via the [built-in MCP server][5] and ask your AI agent
to do it.

```
You:    My game feels sluggish, profile it for 5 seconds.
Agent:  *starts profiler*
        ...5 seconds later
        *saves profile to /tmp/tecs.collapsed*
        gfx.GPURender/gBuffer dominates at 83.8% of frame time.
```

### Timed session

Start a session, schedule a one-shot system to stop it after a delay. `tecs.runif.after` fires once and removes itself
from the pipeline. Pass a path to `:stop()` to write the collapsed-stack text directly.

```teal
local profile = require("tecs.utils.profile")

local session = profile.sample()

world:addSystem({
    phase = tecs.phases.First,
    runIf = tecs.runif.after(5),
    run = function()
        session:stop("/tmp/tecs.collapsed")
    end
})
```

::: details Saving in Love2D
In a LOVE game, get a path inside the save directory with:
```teal
local filename = love.filesystem.getSaveDirectory() .. "/tecs.collapsed"
```
:::

### Custom zones

Push a `jit.zone("name")` to tag any region you want samples attributed to:

```teal
local zone = require("jit.zone")

world:addSystem({
    name = "myGame.Render",
    phase = tecs.phases.Render,
    run = function(dt, world)
        zone("uploadBuffers")
        uploadBuffers()
        zone()
        zone("drawScene")
        drawScene()
        zone()
        zone("postProcess")
        postProcess()
        zone()
    end
})
```

::: tip Where to put zones
* Zones are no-ops when no profile session is active, so leaving `zone("foo")` calls sprinkled in shipped builds costs
  essentially nothing.
* Don't push/pop inside hot inner loops, but do fence them around systems and major logic blocks.
:::

## Trace abort tracker

LuaJIT compiles hot loops into traces. When recording fails (NYI bytecode, IR overflow, trace too long, blacklisting
after repeated failures, etc.), the trace is abandoned and that code falls back to the slower interpreter.
Many aborts are harmless, but aborts in hot code are worth investigating. A sampled flamegraph will show the slow code
as slow, but won't tell you the JIT gave up on it.

`profile.trace` attaches to LuaJIT's trace events and aggregates aborts into a report sorted by severity:

| Severity        | What it means                                                                  | What to do                                         |
| --------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------|
| **`blacklist`** | LuaJIT permanently demoted this trace to the interpreter.                      | Investigate.                                       |
| **`warn`**      | NYI bytecode (not yet implemented), FastFunc bailout, or a trace size limit.   | If hot, consider rewriting the offending construct |
| **`info`**      | Benign trace formation events ("leaving loop", "down-recursion").              | Nothing; filtered out unless you opt in.           |

### Starting and stopping

Start a session, do something with the report when you stop it:

```teal
local profile = require("tecs.utils.profile")

local session = profile.trace()
-- ...later...
local report = session:stop()
print(report)
```

Or pass a path to write the formatted report to disk:

```teal
session:stop("/tmp/aborts.txt")
```

Periodic reporting via a system, restarting after each report:

```teal
local session = profile.trace()

world:addSystem({
    name = "profile.traceReport",
    phase = tecs.phases.First,
    runIf = tecs.runif.every(10), -- run every 10 seconds
    run = function()
        local report = session:stop()
        if report.blacklisted > 0 then
            print(report)
        end
        session = profile.trace()
    end
})
```

### Sample report

`tostring(report)` (and the file written by `:stop(filename)`) is RFC 4180 CSV, suitable for
spreadsheets, `sort`, `diff`, and most tools:

```csv
severity,count,reason,location,zone
blacklist,1,blacklisted,src/enemy/ai.lua:142,update/enemyAi
warn,312,"NYI: FastFunc string.format",src/hud/score.lua:38,render/hud
warn,87,"NYI: bytecode CAT",src/dialog.lua:64,render/dialog
warn,37,trace too long,src/inventory.lua:201,update/inventory
```

Rows are sorted by severity (`blacklist` > `warn` > `info`) then count descending, so the most
actionable rows are at the top.

The top-level `durationSec`, `totalAborts`, and `blacklisted` summary values live on the returned
`TraceReport` object (not in the CSV). Read them directly:

```teal
local report = session:stop("/tmp/aborts.csv")
print(string.format("%ds, %d aborts, %d blacklisted",
    report.durationSec, report.totalAborts, report.blacklisted))
```

## API

### `profile.sample(opts?)`

```teal
function profile.sample(opts?: SampleOptions): SampleSession
```

Starts a sampling session and returns a handle. Errors if a sample session is already active.

`SampleOptions`:

| Field         | Default | Description                                                                                      |
| ------------- | ------- | ------------------------------------------------------------------------------------------------ |
| `intervalMs`  | `1`     | Sampler interval in ms. 1 is the practical minimum; use 5 or 10 for long sessions.               |
| `zone`        | nil     | Restrict output to samples whose zone path starts with this prefix (e.g. `"afterFixed/Render"`). |

Leaf frames always carry a `_[N]`/`_[I]`/`_[C]`/`_[G]`/`_[J]` marker reflecting the dominant VM state
(Native, Interpreter, C, GC, JIT compiler).

You can start a sample with no options:

```teal
local session = profile.sample()
```

Or pass options to make sampling coarser or restrict to a single zone subtree:

```teal
local session = profile.sample({
    intervalMs = 5,
    zone = "afterFixed/Render",
})
```

### `SampleSession:stop(filename?)`

```teal
function SampleSession:stop(filename?: string): string
```

Stops the session and returns the [collapsed-stack][2] text. If `filename` is given, the text is also written to that
path as a side effect. Errors if called twice or if the file cannot be written.

Stop and inspect the text in memory:

```teal
local session = profile.sample()
-- ...later...
local text = session:stop()
```

Stop and write the text to disk in one call (still returned, so you can also
inspect it):

```teal
local text = session:stop("/tmp/tecs.collapsed")
```

### `SampleSession:pause()` / `SampleSession:resume()`

```teal
function SampleSession:pause()
function SampleSession:resume()
```

Use `:pause()` and `:resume()` to skip recording samples. For example, this might be useful for excluding
setup / teardown from a benchmark harness. Both methods are idempotent and error if the session has been stopped.

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

### `profile.trace(opts?)`

```teal
function profile.trace(opts?: TraceOptions): TraceSession
```

Starts a trace abort tracker and returns a handle. Errors if a trace session is already active.

`TraceOptions`:

| Field             | Default | Description                                                                                                               |
| ----------------- | ------- | ------------------------------------------------------------------------------------------------------------------------- |
| `includeBenign`   | `false` | Include "leaving loop", "down-recursion", "up-recursion", and "inner loop" events. Useful when debugging trace formation. |

You can start a trace with no options:

```teal
local session = profile.trace()
```

Or include the benign trace-formation events that are filtered out by default, useful when investigating why a trace
failed to form:

```teal
local session = profile.trace({includeBenign = true})
```

### `TraceSession:stop(filename?)`

```teal
function TraceSession:stop(filename?: string): TraceReport
```

Stops the session and returns the `TraceReport`. If `filename` is given, the formatted report is also written to that
path as a side effect. Errors if called twice or if the file cannot be written.

The returned `TraceReport` has a `__tostring` metamethod that renders RFC 4180 CSV, so `print(report)` works directly.
The on-disk format is the same CSV you'd get from `tostring(report)`.

### `TraceSession:pause()` / `TraceSession:resume()`

```teal
function TraceSession:pause()
function TraceSession:resume()
```

Use `:pause()` and `:resume()` to skip recording traces. Event registration stays active (cost: one boolean check
per abort); counts captured on either side of the pause window are preserved. Calls are idempotent and error if the
session has been stopped.

You can stop and inspect the report:

```teal
local session = profile.trace()
-- ...later...
local report = session:stop()
if report.blacklisted > 0 then
    print(report)
end
```

You can stop and write the formatted report to disk in one call (the report is still returned):

```teal
local report = session:stop("/tmp/aborts.txt")
```

`TraceReport` fields:

| Field           | Description                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------- |
| `durationSec`   | Wallclock seconds the session was active.                                                           |
| `totalAborts`   | Total abort events recorded. Excludes benign trace-formation events unless `includeBenign` was set. |
| `blacklisted`   | Count of trace blacklist events. Always actionable.                                                 |
| `sites`         | List of `AbortSite` records, sorted by severity then count desc.                                    |

`AbortSite` fields:

| Field        | Description                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| `severity`   | `"blacklist"`, `"warn"`, or `"info"`.                                                                      |
| `count`      | Times this exact `(severity, reason, location, zone)` combination fired.                                   |
| `reason`     | Human-readable reason from `jit.vmdef.traceerr`. NYI bytecode aborts are rendered with the opcode name.    |
| `location`   | `"<file>:<line>"` of the function being recorded at abort time.                                            |
| `zone`       | Active zone path at abort time (empty when no zone was on the stack).                                      |

[1]: https://luajit.org/ext_profiler.html#jit_zone
[2]: https://www.brendangregg.com/flamegraphs.html
[3]: https://speedscope.app
[4]: https://github.com/brendangregg/FlameGraph
[5]: /tecs2d/mcp/tools#profiler_start
