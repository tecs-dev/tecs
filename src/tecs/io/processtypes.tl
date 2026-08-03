--[=[
Declares the child-process contracts published by `tecs.io.Process`.

Keeping these declarations beside the process module prevents the general
`tecs.io` reference from publishing process-only types while the implementation
can still depend on them without requiring the public module.
]=]

local type types = require("tecs.io.types")
local type Path = require("tecs.io.Path")
local type coretypes = require("tecs.types")

local type ByteView = types.ByteView
local type Reader = types.Reader
local type Writer = types.Writer
local type Closeable = coretypes.Closeable

--- `ProcessInputMode` selects where a child reads standard input.
local enum ProcessInputMode
    "pipe"
    "inherit"
    "null"
end

--- `ProcessOutputMode` selects where a child writes standard output.
local enum ProcessOutputMode
    "pipe"
    "inherit"
    "null"
end

--- `ProcessErrorMode` selects where a child writes standard error.
local enum ProcessErrorMode
    "pipe"
    "inherit"
    "null"
    "stdout"
end

--- `ProcessOptions` configures a child and its standard streams.
local record ProcessOptions
    --- Caller-writable. Supplies the program in `args[1]` followed by its
    --- arguments. A program without a separator resolves through `PATH`.
    args: {string}

    --- Caller-writable. Selects the child's working directory as a string or
    --- [`Path`](tealdoc:tecs.io.Path), or omits it to inherit the current
    --- directory.
    cwd: string | Path

    --- Caller-writable. Overlays environment variables on the inherited
    --- environment, or supplies the complete environment with `clearEnv`.
    env: {string: string}

    --- Caller-writable. Starts with an empty environment when true. Defaults
    --- to false.
    clearEnv: boolean

    --- Caller-writable. Selects `"pipe"`, `"inherit"`, or `"null"` for
    --- standard input. Defaults to `"pipe"`.
    stdin: ProcessInputMode

    --- Caller-writable. Selects `"pipe"`, `"inherit"`, or `"null"` for
    --- standard output. Defaults to `"pipe"`.
    stdout: ProcessOutputMode

    --- Caller-writable. Selects `"pipe"`, `"inherit"`, `"null"`, or
    --- `"stdout"` for standard error. Defaults to `"pipe"`.
    stderr: ProcessErrorMode

    --- Caller-writable. Forcibly terminates the child after this many
    --- milliseconds, or omits the deadline. The deadline begins when the
    --- process is created.
    timeoutMs: integer
end

--- `CommunicateOptions` controls a complete duplex process exchange.
local record CommunicateOptions
    --- Caller-writable. Supplies complete standard-input bytes as a string,
    --- open [`Buffer`](tealdoc:tecs.io.Buffer), or open
    --- [`ByteView`](tealdoc:tecs.io.ByteView). Omitted input sends EOF
    --- immediately.
    input: string | ByteView

    --- Caller-writable. Limits stdout and stderr together. Defaults to
    --- 268,435,456 bytes. Exceeding it forcibly terminates the child and
    --- returns a failure.
    maxOutputBytes: integer
end

--- `ProcessExit` describes how a child stopped without retaining its output.
local record ProcessExit
    --- Read-only. Reports the platform exit code, or the platform's best
    --- answer after termination.
    exitCode: integer

    --- Read-only. Reports whether Tecs requested termination.
    killed: boolean

    --- Read-only. Reports whether the configured deadline requested that
    --- termination.
    timedOut: boolean

    --- Returns whether the child exited normally with code zero.
    ---
    --- @param self The completed exit to inspect.
    --- @return Returns true only for a normal zero exit.
    succeeded: function(self: ProcessExit): boolean
end

--- `ProcessResult` contains a completed duplex exchange.
local record ProcessResult
    --- Read-only. Contains the child's exit description.
    exit: ProcessExit

    --- Read-only. Contains every captured standard-output byte. It is empty
    --- when stdout was inherited or discarded.
    output: string

    --- Read-only. Contains every captured standard-error byte. It is empty
    --- when stderr was inherited, discarded, or merged into stdout.
    errorOutput: string

    --- Returns whether the child exited normally with code zero.
    ---
    --- @param self The completed exchange to inspect.
    --- @return Returns true only for a normal zero exit.
    succeeded: function(self: ProcessResult): boolean
end

--- A caller-owned reader over one live child-process output pipe.
---
--- `read` and `readInto` return ready bytes inline and otherwise wait according
--- to the caller's execution context, for at most the reader's timeout. They
--- return nil and a reason when that timeout expires.
---
--- The timeout exists because reading one pipe at a time deadlocks against a
--- child that writes to both. A child whose standard-error pipe fills stops
--- running, so it writes no further standard output, and a caller looping on
--- standard output alone waits for bytes that never arrive while the pipe it
--- is not reading holds the child still. Read both pipes, or call
--- `communicate`, which drains both while it feeds standard input. The timeout
--- turns the remaining cases into a reported failure rather than a system
--- parked for the rest of the run.
local interface ProcessReader is Reader
    --- Returns whether this endpoint has been closed.
    ---
    --- @param self The process reader to inspect.
    --- @return Returns true after `close`.
    isClosed: function(self: ProcessReader): boolean

    --- Returns whether the child closed its end and every byte was consumed.
    ---
    --- @param self The process reader to inspect.
    --- @return Returns true after end of file.
    isEOF: function(self: ProcessReader): boolean

    --- Bounds how long `read` and `readInto` wait for the child to send bytes.
    ---
    --- The bound covers waiting only, so a read that already has bytes returns
    --- them however long the reader has been idle. It starts when a call first
    --- finds the pipe empty and ends that call with nil and a reason. The
    --- default is 30,000 milliseconds, and zero returns as soon as one attempt
    --- finds no bytes. The new bound applies to the next call rather than to
    --- one already waiting.
    ---
    --- @param self The process reader to configure.
    --- @param timeoutMs The caller supplies 0 through 2147483647 milliseconds.
    ---     Any other value raises.
    setTimeout: function(self: ProcessReader, timeoutMs: integer)
end

--- A caller-owned writer over one live child-process input pipe.
---
--- `write`, `writeFrom`, and `writeView` return inline when the pipe has room
--- and otherwise wait according to the caller's execution context, for at most
--- the writer's timeout. They report failure and a reason when that timeout
--- expires.
---
--- The timeout exists because writing standard input alone deadlocks against a
--- child that never reads it. The input pipe holds a fixed number of bytes, so
--- a child that leaves it full stops the writer, and a caller sending more than
--- the pipe holds waits for room that never appears. The same stall follows a
--- child that reads its input only after the caller drains the output it has
--- already written, since a full output pipe stops the child. Drain both output
--- pipes while feeding input, or call `communicate`, which does that for the
--- whole exchange. The timeout turns the remaining cases into a reported
--- failure rather than a system parked for the rest of the run.
local interface ProcessWriter is Writer
    --- Returns whether this endpoint has sent EOF or been closed.
    ---
    --- @param self The process writer to inspect.
    --- @return Returns true after `close`.
    isClosed: function(self: ProcessWriter): boolean

    --- Bounds how long `write`, `writeFrom`, and `writeView` wait for the child
    --- to take bytes.
    ---
    --- The bound covers waiting only, so a write the pipe has room for returns
    --- however long the writer has been idle. It starts when a call first finds
    --- the pipe full and ends that call with its failure and a reason, and the
    --- child taking further bytes starts it again, so it bounds one stall
    --- rather than a whole long write. The default is 30,000 milliseconds, and
    --- zero returns as soon as one attempt finds no room. The new bound applies
    --- to the next call rather than to one already waiting.
    ---
    --- @param self The process writer to configure.
    --- @param timeoutMs The caller supplies 0 through 2147483647 milliseconds.
    ---     Any other value raises.
    setTimeout: function(self: ProcessWriter, timeoutMs: integer)
end

--- A caller-owned child process and its independently closable pipes.
---
--- The process owns every non-nil endpoint. Closing an endpoint closes only
--- that pipe; closing the process closes all three, forcibly terminates and
--- reaps a live child, and completes its private wait state. Repeated closure
--- remains safe.
local interface Process is Closeable
    --- Read-only. Reports the operating-system process identifier.
    pid: integer

    --- Read-only. Provides standard input when its mode is `"pipe"`, or nil
    --- when input is inherited or discarded. The process owns it.
    stdin: ProcessWriter

    --- Read-only. Provides standard output when its mode is `"pipe"`, or nil
    --- when output is inherited or discarded. The process owns it.
    stdout: ProcessReader

    --- Read-only. Provides standard error when its mode is `"pipe"`, or nil
    --- when error output is inherited, discarded, or merged into stdout. The
    --- process owns it.
    stderr: ProcessReader

    --- Waits for the child to stop and returns its exit description.
    --- @param self The process to wait for.
    --- @return Returns how the child stopped.
    wait: function(self: Process): ProcessExit

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
    communicate: function(self: Process, options?: CommunicateOptions): ProcessResult, string
end

local record processtypes
    type ProcessInputMode = ProcessInputMode
    type ProcessOutputMode = ProcessOutputMode
    type ProcessErrorMode = ProcessErrorMode
    type ProcessOptions = ProcessOptions
    type CommunicateOptions = CommunicateOptions
    type ProcessExit = ProcessExit
    type ProcessResult = ProcessResult
    type ProcessReader = ProcessReader
    type ProcessWriter = ProcessWriter
    type Process = Process
end

return processtypes
