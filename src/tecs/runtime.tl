--[=[
The process-wide pump for cooperative work that resumes on the Lua thread.

An [`Application`](tealdoc:tecs.Application) calls `poll` once per host
iteration. A headless program calls the same function from its own loop:

```teal no-format
local world <const> = tecs.ecs.newWorld()
world:addSystem({
    name = "FetchData",
    run = function()
        tecs.scoped(function(scope)
            local client <const> = scope:own(tecs.io.http.newClient())
            local response <const> = client:send({
                url = assert(tecs.io.URI.new("https://example.com/data")),
            })
            print(response.status)
        end)
    end,
})
```

Each facility registers only while it has an active service or pending work.
Reading `tecs.runtime`, and polling an otherwise idle process, does not load
assets, networking, HTTP, platform services, or the content watcher. That
keeps a headless ECS program independent of every native service it did not
ask for, and lets another cooperative facility join without adding a reverse
dependency from the runtime to it.

The pump covers process-wide completion and readiness sources: process signals,
asset loads, child processes, native dialogs, raw socket readiness, open HTTP
clients, and the installed content watcher. It deliberately has no `pending`
operation. An installed file watcher and an idle reusable HTTP client remain
active without work that can finish, so one process-wide count could not mean
"safe to exit". Inspect the facility-specific pending count instead.

The runtime does not turn synchronous readers and writers into scheduled
operations and does not own application resources. Raw sockets register with
the readiness reactor after `WouldBlock`; asset decoding and blocking library
work use workers; memory, file, and transform endpoints remain synchronous.
It therefore has no `shutdown` operation either: MCP polls against a particular
world, audio reaps a particular mixer, and resource owners retain their own
teardown order.

Every completion or readiness event drained by `poll` resumes its suspended
system on the Lua thread that called it. Call it from the application's main
Lua state, not from a native callback or another OS thread.
]=]

local record runtime
    --- Advances every active process-wide completion or readiness source.
    ---
    --- The call never waits. It drains work already ready at the time each
    --- source is reached, in this order: process signals, assets, child
    --- processes and dialogs, socket readiness, HTTP clients, then the content
    --- watcher. A listener may
    --- start later work, which a later call advances.
    ---
    --- An [`Application`](tealdoc:tecs.Application) calls this automatically
    --- once per host iteration, including while suspended or crashed. Game
    --- systems and plugins must not call it. Only a program without an
    --- application drives it manually.
    ---
    --- @return Returns how many completions, signal deliveries, or watcher
    ---     handlers ran. Zero means no work was delivered, not necessarily
    ---     that every source is inactive.
    poll: function(): integer
end

local process <const> = require("tecs.internal.runtime")

function runtime.poll(): integer
    return process.poll()
end

return runtime
