---
description: "LuaJIT sampling profiler and trace-abort tracker through tecs.utils.profile"
outline: deep
---

# Profiling

`tecs.utils.profile` exposes two independent sessions:

- Sampling answers where CPU time goes.
- Trace tracking reports where LuaJIT abandons compilation.

Require this supported utility directly:

```teal
local profile <const> = require("tecs.utils.profile")
```

Only one sampling session and one trace session may run at a time. Stopping a
session twice raises.

## Sampling a run

The sampler writes [collapsed stacks][collapsed] for Speedscope, FlameGraph,
Inferno, Pyroscope, and similar tools. Pipeline zones attribute samples to
fixed-loop regions, phases, and systems.

This system records five seconds and writes the result under the writable
root:

```teal
local session <const> = profile.sample({
    intervalMs = 10,
    stackDepth = 16,
})

world:addSystem({
    name = "profile.StopSample",
    phase = tecs.ecs.phases.First,
    runIf = tecs.ecs.runif.after(5),
    run = function()
        session:stop(
            tecs.io.files.writablePath("tecs.collapsed")
        )
    end,
})
```

Longer intervals reduce overhead. Deeper stacks cost more per sample. A zone
prefix can restrict output to one pipeline subtree.

Add [`jit.zone`][zones] around expensive regions inside a system:

```teal
local zone <const> = require("jit.zone")

zone("uploadBuffers")
uploadBuffers()
zone()
```

Leave useful zone calls in production code. They do almost nothing when no
profiling session needs them. Do not push and pop zones inside hot row loops.

## Trace failures

Sampling shows slow code but cannot say whether LuaJIT compiled it.
`profile.trace` aggregates trace aborts by reason, source location, and active
zone:

```teal
local session <const> = profile.trace()

-- Run the workload.

local report <const> = session:stop(
    tecs.io.files.writablePath("aborts.csv")
)

print(report.totalAborts, report.blacklisted)
```

The report and its file use RFC 4180 CSV. Rows sort actionable failures first.

| Severity    | Meaning                                              | Response                                     |
| ----------- | ---------------------------------------------------- | -------------------------------------------- |
| `blacklist` | LuaJIT stopped attempting the trace for this run.    | Investigate hot sites.                       |
| `warn`      | Recording hit unsupported bytecode or a trace limit. | Rewrite only when the site matters.          |
| `info`      | Normal trace-formation events.                       | Include only during a focused investigation. |

Many aborts occur in cold code and cost nothing important. Use the zone and
location to decide whether a row belongs to a hot workload.

Pause and resume either session to exclude setup or teardown while preserving
data from both sides of the pause.

## Measurements outside the profiler

Sampling and trace reports cannot answer every performance question.

Frame timing reports `extract` once per world update as the sum of every
enabled rendering domain. `extractSprites` and `extractMeshes` attribute that
same work to the 2D and 3D domains. The aggregate is a frame-level sample, not
an interleaving of unrelated domain samples under one name, so its percentiles
can be compared directly with `simulate`, `record`, and `submit`.

Input latency measures the time from the oldest consumed input event to the
submission of the frame that reacted to it. Frame averages cannot substitute
for that measurement. A pipelined frame may improve throughput while
increasing latency.

Allocation measurements need a separate run. `collectgarbage("count")`
reports heap size, not allocated bytes, and a collection can erase the delta.
Stop the collector during the measurement window. Do not put
`collectgarbage` probes inside the frame you want to characterize because the
probe itself aborts traces.

Run once without frame probes for the total, then run again with coarse phase
probes for attribution. Use trace tracking to reject runs in which the probes
changed compilation.

[zones]: https://luajit.org/ext_profiler.html#jit_zone
[collapsed]: https://www.brendangregg.com/flamegraphs.html
