--[=[
The process-wide pump for asynchronous work that settles on the Lua thread.

An [`Application`](tealdoc:tecs.Application) calls `poll` once per host
iteration. A headless program calls the same function from its own loop:

```teal no-format
tecs.scoped(function(scope)
    local client <const> = scope:own(tecs.io.http.newClient())
    local request <const> = client:send({
        url = assert(tecs.io.newURI("https://example.com/data")),
    })

    while request.status == "pending" do
        tecs.runtime.poll()
    end

    print(request.value.status)
end)
```

Each facility registers only while it has an active service or pending work.
Reading `tecs.runtime`, and polling an otherwise idle process, does not load
assets, networking, HTTP, platform services, or the content watcher. That
keeps a headless ECS program independent of every native service it did not
ask for, and lets another asynchronous facility join without adding a reverse
dependency from the runtime to it.

The pump covers process-wide completion sources: process signals, asset loads,
child processes, native dialogs, generic asynchronous I/O, open HTTP clients,
and the installed content watcher. It deliberately has no `pending` operation. An installed file
watcher and an idle reusable HTTP client remain active without work that can
finish, so one process-wide count could not mean either "futures pending" or
"safe to exit". Inspect the future or the facility-specific pending count.

The runtime does not turn synchronous readers and writers into asynchronous
values and does not own application resources. It therefore has no `shutdown`
operation either: MCP polls against a particular world, audio reaps a
particular mixer, and resource owners must retain their own teardown order.

Every future settled by `poll` settles on the Lua thread that called it, and
its listeners run before `poll` returns. Call it from the application's main
Lua state, not from a native callback or another OS thread.
]=]

local record runtime
    --- Advances every active process-wide asynchronous completion source.
    ---
    --- The call never waits. It drains work already ready at the time each
    --- source is reached, in this order: process signals, assets, child
    --- processes and dialogs, generic I/O, HTTP clients, then the content
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
