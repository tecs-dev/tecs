--[=[
Streaming child processes.

`new` starts the child immediately and returns its live standard-stream
endpoints. Piped stdin is a
[`ProcessWriter`](tealdoc:tecs.io.process.ProcessWriter); piped stdout and
stderr are [`ProcessReader`](tealdoc:tecs.io.process.ProcessReader) values. The
process owns all three endpoints. Closing one endpoint closes only that pipe;
closing the process closes every endpoint, terminates a live child, and reaps
it. Buffers and byte views passed to an endpoint remain caller-owned.

`Process:communicate` is the complete-exchange form for tools and build steps.
It feeds stdin while draining stdout and stderr concurrently, so neither
output pipe can fill and deadlock the child:

```teal
tecs.scoped(function(scope: tecs.Scope)
    local child, startReason = tecs.io.process.new({
        args = {"git", "status", "--porcelain"},
        timeoutMs = 2000,
    })
    if child == nil then
        error(startReason)
    end
    scope:own(child)

    local result, communicateReason = child:communicate()
    if result == nil then
        error(communicateReason)
    end

    if result:succeeded() then
        print(result.output)
    else
        io.stderr:write(result.errorOutput)
    end
end)
```

Interactive children use the same reader and writer vocabulary as files,
buffers, and transforms. Closing stdin sends EOF:

```teal
tecs.scoped(function(scope: tecs.Scope)
    local child, startReason = tecs.io.process.new({args = {"/bin/cat"}})
    if child == nil then
        error(startReason)
    end
    scope:own(child)

    local written, writeReason = child.stdin:write("one request\n")
    if written == nil then
        error(writeReason)
    end
    child.stdin:close()

    local reply, readReason = child.stdout:read(4096)
    if reply == nil then
        error(readReason)
    end
    print(reply)
end)
```

Frame-driven code uses `readAvailable`, `readAvailableInto`, and the matching
writer methods. Nil without a reason means an open pipe has no bytes or
capacity right now; an empty string or zero means output EOF. These methods
make backpressure visible instead of growing an implicit queue. Buffer and
byte-view variants avoid constructing Lua strings.

Use `"inherit"` for a CLI that should share the terminal, `"null"` to discard
a stream, and `stderr = "stdout"` for one ordered transcript. A nonzero child
exit still produces a ready [`Exit`](tealdoc:tecs.io.process.Exit);
`succeeded` performs the separate exit-code check. Spawn failures return nil
and a reason. Deadlines and explicit kills set the exit's `killed` fields.
]=]

local implementation <const> = require("tecs.internal.process")
local type types = require("tecs.io.processtypes")

local record process
    --- `InputMode` selects where a child reads standard input.
    type InputMode = types.ProcessInputMode

    --- `OutputMode` selects where a child writes standard output.
    type OutputMode = types.ProcessOutputMode

    --- `ErrorMode` selects where a child writes standard error.
    type ErrorMode = types.ProcessErrorMode

    --- `Options` configures a child and its standard streams.
    type Options = types.ProcessOptions

    --- `CommunicateOptions` controls a complete duplex exchange.
    type CommunicateOptions = types.CommunicateOptions

    --- `Exit` describes how a child stopped.
    type Exit = types.ProcessExit

    --- `Result` contains a completed duplex exchange.
    type Result = types.ProcessResult

    --- `ProcessReader` reads one live child-process output pipe.
    type ProcessReader = types.ProcessReader

    --- `ProcessWriter` writes one live child-process input pipe.
    type ProcessWriter = types.ProcessWriter

    --- `Process` owns a child and its standard-stream endpoints.
    type Process = types.Process

    --- Starts a caller-owned child process with streaming standard I/O.
    ---
    --- Piped endpoints are nonblocking at their `readAvailable` and
    --- `writeAvailable` boundaries. The process owns them, while buffers and
    --- byte views passed to endpoint methods remain caller-owned.
    --- @param options The caller supplies the program, arguments, environment,
    ---     working directory, standard-stream modes, and optional deadline.
    --- @return Returns a caller-owned process when the platform starts it.
    --- @return Returns the platform reason when the first return is nil.
    new: function(options: types.ProcessOptions): types.Process, string
end

process.new = implementation.new

return process
