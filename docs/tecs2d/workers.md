---
description: "Advanced process-wide worker jobs and composable asynchronous handles in Tecs2D"
outline: deep
---

# Worker jobs

`tecs2d.workers` is the process-wide background job queue used by the asset system and available for game-defined work.
It belongs to the LÖVE runtime, not an ECS world, so jobs continue while a gameplay world is suspended.

This is an advanced API. Use [`tecs2d.assets`](/tecs2d/assets/) for file and game-asset loading.

## Defining a job

LÖVE worker threads have separate Lua states. They cannot receive closures or captured values. A job therefore names a
requireable module and sends channel-safe input to it.

```teal
-- game/jobs/buildnavigation.tl
local workers = require("tecs2d.workers")

local record Input
    cells: {{number}}
end

local record Result
    edges: {{integer}}
end

local record buildnavigation is workers.JobModule<Input, Result>
    run: function(Input): Result
end

function buildnavigation.run(input: Input): Result
    return buildGraph(input.cells)
end

return buildnavigation
```

The caller creates a typed descriptor for that module:

```teal
local workers = require("tecs2d.workers")

local BuildNavigation <const> = workers.newJob(
    "game.jobs.buildnavigation"
) as workers.Job<Input, Result>

local handle = workers.submit(BuildNavigation, {cells = cells})
```

`newJob(moduleName, functionName?)` invokes `run` by default. A module may export multiple named functions when several
jobs share implementation code.

## Transferable data

Inputs and raw results cross `love.thread.Channel`. Use numbers, strings, booleans, transferable LÖVE data objects, and
tables composed from those values. Do not send functions, world objects, entities with metatables, graphics objects, or
main-thread state.

Worker code may use thread-safe LÖVE modules. Graphics construction belongs in a main-thread handle transform.

## Handles

`submit` immediately returns a `Handle<T>`:

```teal
local validated = workers.submit(ParseLevel, input)
    :map(validateLevel)
    :flatMap(function(level)
        return workers.submit(BuildNavigation, level)
    end)
    :handle(function(value, err)
        if err then return fallbackNavigation(err) end
        return value
    end)
```

- `observe` runs once after settlement.
- `map` transforms successful values and propagates errors.
- `flatMap` chains another handle from the same queue.
- `handle` receives both the value and error and can recover.
- Reading `value` blocks by pumping the owning queue and raises on failure.

Transforms and observers run on the main thread from `Queue:update`. Observer failures are logged without preventing
other observers or queue bookkeeping.

Use `workers.all` to retain input order and wait for every handle:

```teal
local combined = workers.all({first, second, third})
```

Every input must belong to the same queue. The combined handle settles after all inputs; if any failed, it carries the
first error in input order.

## Runtime ownership

`tecs2d.run` constructs `workers.queue`, updates it before world updates, and shuts it down on quit or hot restart.
Normal game code uses the module facade:

```teal
workers.submit(job, input)
workers.all(handles)
workers.isBusy()
workers.getStats()
```

The runtime calls `update`; game systems should not call it again each frame.

`workers.queue` is directly assignable and assignment has no lifecycle behavior. This keeps deterministic tests simple:

```teal
local old = workers.queue
workers.queue = testQueue
local ok, err = pcall(runTest)
workers.queue = old
if not ok then error(err) end
```

## Independent queues

```teal
local queue = workers.new({threadCount = 1})
local handle = queue:submit(job, input)

while queue:update() do end
queue:shutdown()
```

The default thread count is `min(4, love.system.getProcessorCount())`. Queue shutdown is idempotent, rejects future
submissions, settles pending handles with errors, and stops its worker threads. Handles always retain their owning queue,
so blocking access and composition do not depend on the current global queue.
