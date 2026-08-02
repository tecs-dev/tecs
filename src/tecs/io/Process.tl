--[=[
Streaming child processes.

`new` starts the child immediately and returns its live standard-stream
endpoints. Piped stdin is a
[`Writer`](tealdoc:tecs.io.Process.Writer); piped stdout and stderr are
[`Reader`](tealdoc:tecs.io.Process.Reader) values. The
process owns all three endpoints. Closing one endpoint closes only that pipe;
closing the process closes every endpoint, terminates a live child, and reaps
it. Buffers and byte views passed to an endpoint remain caller-owned.

`Process:communicate` is the complete-exchange form for tools and build steps.
It feeds stdin while draining stdout and stderr concurrently, so neither
output pipe can fill and deadlock the child:

```teal
tecs.scoped(function(scope: tecs.Scope)
    local child <const> = scope:own(
        tecs.io.Process.new({
            args = {"git", "status", "--porcelain"},
            timeoutMs = 2000,
        })
    )

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
    local child <const> = scope:own(tecs.io.Process.new({args = {"/bin/cat"}}))

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

`Process:wait`, pipe reads and writes, and `communicate` all use contextual
waiting. They suspend a normal system without blocking SDL and block when
called outside an update. Buffer and byte-view variants avoid constructing Lua
strings.

Use `"inherit"` for a CLI that should share the terminal, `"null"` to discard
a stream, and `stderr = "stdout"` for one ordered transcript. A nonzero child
exit still returns an [`Exit`](tealdoc:tecs.io.Process.Exit);
`succeeded` performs the separate exit-code check. Spawn failures return nil
and a reason. Deadlines and explicit kills set the exit's `killed` fields.
]=]

local implementation <const> = require("tecs.internal.process")
local type types = require("tecs.io.processtypes")
local type Closeable = require("tecs.types").Closeable

local record Process is Closeable
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

    --- `Reader` reads one live child-process output pipe.
    type Reader = types.ProcessReader

    --- `Writer` writes one live child-process input pipe.
    type Writer = types.ProcessWriter

    --- Read-only. Reports the operating-system process identifier.
    pid: integer

    --- Read-only. Provides standard input when its mode is `"pipe"`, or nil
    --- when input is inherited or discarded. The process owns it.
    stdin: Writer

    --- Read-only. Provides standard output when its mode is `"pipe"`, or nil
    --- when output is inherited or discarded. The process owns it.
    stdout: Reader

    --- Read-only. Provides standard error when its mode is `"pipe"`, or nil
    --- when error output is inherited, discarded, or merged into stdout. The
    --- process owns it.
    stderr: Reader

    --- Waits for the child to stop and returns its exit description.
    ---
    --- Inside a system, the call suspends the logical world update without
    --- blocking the host thread. Outside a world update, it blocks.
    --- @param self The process to wait for.
    --- @return Returns how the child stopped.
    wait: function(self: Process): Exit

    --- Returns whether the child has not stopped yet.
    ---
    --- @param self The process to inspect.
    --- @return Returns true while the child remains live.
    isRunning: function(self: Process): boolean

    --- Requests that the child terminate.
    ---
    --- @param self The process to terminate.
    --- @param force The caller requests an unhandleable termination when true
    ---     or a graceful request when false or omitted.
    --- @return Returns whether the request was delivered or the child had
    ---     already stopped.
    --- @return Returns the platform reason when the first return is false.
    kill: function(self: Process, force?: boolean): boolean, string

    --- Feeds stdin and captures stdout and stderr without pipe deadlock.
    ---
    --- The call drains both output pipes while feeding input, closes stdin
    --- after the final byte, and returns after the child exits and both pipes
    --- reach EOF. It suspends a normal system or blocks an ordinary caller.
    --- @param self The open process whose piped endpoints are consumed.
    --- @param options The caller supplies complete input and an output limit,
    ---     or omits both.
    --- @return Returns the complete exchange result.
    --- @return Returns a reason when communication fails or exceeds its
    ---     output limit.
    communicate: function(self: Process, options?: CommunicateOptions): Result, string

    --- Starts a caller-owned child process with streaming standard I/O.
    ---
    --- Piped endpoints use contextual waiting through the ordinary Reader and
    --- Writer methods. The process owns them, while buffers and byte views
    --- passed to endpoint methods remain caller-owned.
    --- @param options The caller supplies the program, arguments, environment,
    ---     working directory, standard-stream modes, and optional deadline.
    --- @return Returns a caller-owned process when the platform starts it.
    --- @return Returns the platform reason when the first return is nil.
    new: function(options: Options): Process, string
end

Process.new = implementation.new as function(options: types.ProcessOptions): Process, string

return Process
