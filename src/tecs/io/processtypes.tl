--[=[
Declares the child-process contracts published by `tecs.io.process`.

Keeping these declarations beside the process module prevents the general
`tecs.io` reference from publishing process-only types while the implementation
can still depend on them without requiring the public module.
]=]

local type Future = require("tecs.Future")
local type types = require("tecs.io.types")
local type pathModule = require("tecs.io.path")
local type coretypes = require("tecs.types")

local type Buffer = types.Buffer
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
    --- [`Path`](tealdoc:tecs.io.path.Path), or omits it to inherit the current
    --- directory.
    cwd: string | pathModule.Path

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
--- Blocking `read` and `readInto` satisfy the ordinary reader workflow.
--- `readAvailable` and `readAvailableInto` never wait and distinguish a pipe
--- with no bytes ready from end of file.
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

    --- Reads immediately available bytes without waiting.
    ---
    --- Nil without a reason means the pipe remains open but has no bytes
    --- ready. An empty string means end of file.
    --- @param self The process reader whose pipe advances.
    --- @param maxBytes The caller supplies 1 through 65,536 bytes or omits it
    ---     for 16,384.
    --- @return Returns available bytes, nil when none are ready, or an empty
    ---     string at end of file.
    --- @return Returns a reason only when reading fails.
    readAvailable: function(self: ProcessReader, maxBytes?: integer): string, string

    --- Reads immediately available bytes into reusable storage.
    ---
    --- Nil without a reason means no bytes are ready. Zero means end of file.
    --- @param self The process reader whose pipe advances.
    --- @param destination The caller supplies an open destination buffer and
    ---     retains ownership.
    --- @param offset The caller supplies a non-negative destination offset or
    ---     omits it for zero.
    --- @param maxBytes The caller supplies 1 through 65,536 bytes or omits it
    ---     for 16,384.
    --- @return Returns bytes read, nil when none are ready, or zero at end of
    ---     file.
    --- @return Returns a reason only when reading fails.
    readAvailableInto: function(
        self: ProcessReader, destination: Buffer, offset?: integer, maxBytes?: integer
    ): integer, string
end

--- A caller-owned writer over one live child-process input pipe.
---
--- Blocking `write`, `writeFrom`, and `writeView` wait for OS-pipe capacity.
--- The available forms return immediately and may accept only a prefix, so a
--- frame loop can apply backpressure without accumulating an unbounded queue.
local interface ProcessWriter is Writer
    --- Returns whether this endpoint has sent EOF or been closed.
    ---
    --- @param self The process writer to inspect.
    --- @return Returns true after `close`.
    isClosed: function(self: ProcessWriter): boolean

    --- Writes as many immediately acceptable string bytes as possible.
    ---
    --- Nil without a reason means the pipe has no capacity yet.
    --- @param self The process writer whose pipe advances.
    --- @param bytes The caller supplies binary bytes including embedded NULs.
    --- @param offset The caller supplies a zero-based string offset or omits
    ---     it for zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns bytes accepted, or nil when none fit immediately.
    --- @return Returns a reason only when writing fails.
    writeAvailable: function(self: ProcessWriter, bytes: string, offset?: integer, count?: integer): integer, string

    --- Writes an immediately acceptable buffer prefix without a Lua string.
    ---
    --- @param self The process writer whose pipe advances.
    --- @param source The caller supplies an open source buffer and retains
    ---     ownership.
    --- @param offset The caller supplies a zero-based source offset or omits
    ---     it for zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns bytes accepted, or nil when none fit immediately.
    --- @return Returns a reason only when writing fails.
    writeAvailableFrom: function(
        self: ProcessWriter, source: Buffer, offset?: integer, count?: integer
    ): integer, string

    --- Writes an immediately acceptable immutable-view prefix.
    ---
    --- @param self The process writer whose pipe advances.
    --- @param source The caller supplies an open source view and retains
    ---     ownership.
    --- @param offset The caller supplies a zero-based source offset or omits
    ---     it for zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns bytes accepted, or nil when none fit immediately.
    --- @return Returns a reason only when writing fails.
    writeAvailableView: function(
        self: ProcessWriter, source: ByteView, offset?: integer, count?: integer
    ): integer, string
end

--- A caller-owned child process and its independently closable pipes.
---
--- The process owns every non-nil endpoint. Closing an endpoint closes only
--- that pipe; closing the process closes all three, forcibly terminates and
--- reaps a live child, and settles `finished`. Repeated closure remains safe.
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

    --- Read-only. Settles ready with the exit description after the child
    --- stops. Canceling this future does not terminate the separately owned
    --- process.
    finished: Future<ProcessExit>

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
    --- The call blocks the current Lua thread, drains both output pipes while
    --- feeding input, closes stdin after the final byte, and returns only
    --- after the child exits and both captured pipes reach EOF. Run it in a
    --- worker when blocking is inappropriate.
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
