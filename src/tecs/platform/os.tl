--[=[
Runtime capabilities, clipboard access, child processes, and desktop services.

## Capabilities

Ask the installed build instead of inferring support from a target name.
`capabilities` distinguishes targets that share an operating system but differ
in JIT, worker, shader, storage, or device support. It reports the process
sandbox separately because that environment can restrict filesystem and child
process access without changing the target.

## Clipboard

The clipboard belongs to the desktop and can change between frames.
`events.clipboardUpdate` reports a change; read the current value when the
event arrives or when the user requests paste. Text stays UTF-8, keeps its line
endings, and stops at the first NUL. `clipboardData` preserves NULs.

Headless builds report the clipboard as unavailable. Primary selection remains
independent of the clipboard. On platforms without a shared primary selection,
reads may return only the value this process wrote.

## Child processes

`runProcess` runs the child on a worker and returns immediately. Pump
`updateProcesses` once per frame until the future settles:

```teal
local run <const> = tecs.platform.os.runProcess({
    args = {"git", "rev-parse", "HEAD"},
    timeoutMs = 2000,
})

tecs.platform.os.updateProcesses()
if run.status == "ready" and run.value:succeeded() then
    tecs.platform.os.setClipboardText(run.value.output)
elseif run.status == "failed" then
    print(run.error)
end
```

A child that exits nonzero still settles `"ready"`; `succeeded` checks its exit
code. `"failed"` means the child never started. A timeout, explicit kill, or
shutdown settles `"canceled"`.

The result contains complete output, not a stream. Set `timeoutMs` for a
command that may run or print without bound.
]=]
-- Implementation details:
-- Clipboard reads copy SDL allocations before freeing them. Arbitrary MIME
-- writes stay out of the public surface because SDL retains a producer
-- callback and may invoke it from a thread LuaJIT did not create. Headless
-- checks avoid calling clipboard entry points before SDL video starts.
--
-- The worker owns every SDL process handle because SDL does not make process
-- operations thread-safe. It polls waits and pipes without blocking so kill
-- requests remain prompt. Shutdown asks children to exit, forces them after
-- the grace period, and copies only output, pid, and exit code back to Lua.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local adapter <const> = require("tecs.platform.adapter")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local workers <const> = require("tecs.workers")
local time <const> = require("tecs.platform.time")
local Future <const> = require("tecs.Future")
local buffer <const> = require("tecs.io.buffer")
local type iotypes = require("tecs.io.types")
local type Window = require("tecs.platform.window").Window
local type IOBuffer = iotypes.Buffer

loader.declare("dialogs")

local C <const> = sdl.C
local K <const> = sdl.K
local D <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "dialogs")
local VIDEO <const> = sdl.K.SDL_INIT_VIDEO

--- Describes one preferred language and country.
local record Locale
    --- Read-only. Contains an ISO 639 language code, such as `"en"`.
    language: string
    --- Read-only. Contains an ISO 3166 country code, such as `"US"`, or an empty string when the
    --- platform names only a language.
    country: string
end

--- Describes the current power source and remaining battery.
local record Power
    --- Read-only. Reports `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
    --- `"charged"` or `"error"`.
    state: string
    --- Read-only. Reports seconds of battery life remaining, or -1 when
    --- unavailable.
    seconds: integer
    --- Read-only. Reports charge percentage in 0..100, or -1 when unavailable.
    percent: integer
end

--- Describes one file-type filter in a native dialog.
local record DialogFilter
    --- Caller-writable. Sets the label shown beside the filter, such as
    --- `"Images"`.
    name: string
    --- Caller-writable. Sets semicolon-separated extensions, such as
    --- `"png;jpg;jpeg"`.
    pattern: string
end

--- Configures a native file or folder dialog.
local record DialogOptions
    --- Caller-writable. Sets the window that owns the dialog.
    window: Window
    --- Caller-writable. Sets the available file-type filters.
    filters: {DialogFilter}
    --- Caller-writable. Sets the initial file or folder. Omit it to let the
    --- platform choose.
    defaultLocation: string
    --- Caller-writable. Allows the user to select more than one path.
    multiple: boolean
end

--- Contains the result of a completed native dialog.
local record DialogResult
    --- Read-only. Contains selected paths. It is empty when the user canceled.
    paths: {string}
    --- Read-only. Reports the one-based selected filter, or zero when no
    --- filter applies.
    filter: integer
    --- Read-only. Reports whether the user canceled the dialog.
    canceled: boolean
end

--- Describes what this build can do on the current target.
local record Capabilities
    --- Read-only. This is the platform name, such as "macOS" or "Android". A
    --- licensed port answers with its own name instead, since everything here
    --- describes the platform actually installed.
    target: string
    --- Read-only. This is the CPU architecture this build targets.
    architecture: string
    --- Read-only. Reports `"none"`, `"unknownContainer"`, `"flatpak"`,
    --- `"snap"` or `"macOS"` for the process environment SDL detects. A
    --- sandbox can restrict filesystem and child-process access independently
    --- of the target and the build's other capabilities.
    sandbox: string

    --- Read-only. This reports whether the runtime generates machine code.
    --- False on a target that requires interpretation.
    jit: boolean
    --- Read-only. This is always true because every supported build requires
    --- the FFI.
    ffi: boolean

    --- Read-only. Reports whether a library can load by name at run time. It is false where every
    --- build links every library into the executable.
    dynamicLibraries: boolean
    --- Read-only. Reports whether this build supports development-time content reload.
    --- Named independently of any one kind the watcher reloads.
    hotReload: boolean
    --- Read-only. Reports whether this build can compile shaders from source
    --- at run time.
    runtimeShaders: boolean
    --- Read-only. Reports whether the engine reads shaders from a packaged artifact. Independent of
    --- `runtimeShaders`: a development build may have both, and a release has
    --- only this.
    packagedShaders: boolean
    --- Read-only. Lists the shader formats this target consumes. It contains one entry, since a build supplies
    --- one format.
    shaderFormats: {string}

    --- Read-only. Reports whether the machine currently has a touch device. This describes the machine
    --- rather than of the target: a desktop with a touchscreen has one.
    touch: boolean
    --- Read-only. Reports true because every target reaches gamepads through the same subsystem,
    --- so only the connected devices vary, which the `gamepads`
    --- method on [`Input`](tealdoc:tecs.input.Input) answers.
    gamepad: boolean
    --- Read-only. Reports whether the device carries a gyroscope or an accelerometer. This says
    --- nothing about a gamepad's sensors, which `hasSensor` on
    --- [`Gamepad`](tealdoc:tecs.input.Gamepad) answers per device.
    sensors: boolean
    --- Read-only. Reports whether work can run off the main thread.
    workers: boolean
    --- Read-only. Reports the number of logical cores for sizing a worker pool.
    cores: integer

    --- Read-only. Reports true because every target has somewhere to write,
    --- and `tecs.io.files.preferencePath` and `tecs.io.files.cachePath` answer
    --- where: the field exists so a caller can ask rather than assume, not
    --- because a target answers no.
    writableStorage: boolean
end

local record platformOS
    --- Describes what this build can do on this target.
    type Capabilities = Capabilities

    --- Describes one language the user prefers.
    type Locale = Locale

    --- Describes the machine's power source and remaining charge.
    type Power = Power

    --- Describes one file-type filter.
    type DialogFilter = DialogFilter

    --- Describes dialog configuration.
    type DialogOptions = DialogOptions

    --- Describes a completed dialog.
    type DialogResult = DialogResult
    --- Configures a child process and what it inherits.
    record ProcessOptions
        --- Caller-writable. Sets the program and its arguments; `args[1]` is the program. A name
        --- without a separator resolves against `PATH`.
        args: {string}
        --- Caller-writable. Sets the child's working directory. Omitted
        --- inherits this process's directory.
        cwd: string
        --- Caller-writable. Sets environment variables over this process's
        --- environment, or over an empty one when `clearEnv` is true.
        --- Omitted, and with `clearEnv` unset, the child inherits everything.
        env: {string: string}
        --- Caller-writable. Starts the child's environment empty rather than inherited, so
        --- `env` is the whole of what it sees. Optional.
        clearEnv: boolean
        --- Caller-writable. Folds the child's error output into `output` instead of keeping it
        --- in `errorOutput`. Optional; separate by default, because a tool's
        --- diagnostics interleaved into its output corrupt anything parsing
        --- that output, and the diagnostics are what you want when it fails.
        mergeStderr: boolean
        --- Caller-writable. Sets bytes written to the child's standard input, which closes once
        --- they are through. Omitted closes it immediately, so a child reading
        --- to end of input sees one rather than waiting. Optional.
        input: string
        --- Caller-writable. Kills the child forcibly after this many milliseconds. Omitted lets
        --- it run as long as it likes. Optional.
        timeoutMs: integer
    end

    --- Contains the result of a completed child process.
    ---
    --- Everything here is meaningless before the child ends, which is why none
    --- of it is on the future: a run in flight is a
    --- [`Future`](tealdoc:tecs.Future)`<`[`ProcessResult`](tealdoc:tecs.platform.os.ProcessResult)`>` reading
    --- "pending" and a run that ended is the same future carrying one of
    --- these. The one thing worth knowing in between is the child's process id,
    --- and `processResult` answers that from the runner's own bookkeeping.
    record ProcessResult
        --- Read-only. Contains the program and its arguments as given.
        args: {string}
        --- Read-only. Reports the child's process id.
        pid: integer
        --- Read-only. Reports the child's exit code, or the negated signal that
        --- ended it.
        exitCode: integer
        --- Read-only. Contains everything the child wrote to standard output.
        output: string
        --- Read-only. Contains everything the child wrote to standard error, or "" when `mergeStderr`
        --- folded that into `output`.
        errorOutput: string

        --- Reports whether the child returned exit code zero.
        ---
        --- A question about the answer rather than about whether there is one,
        --- which is why it is here and not a status: a result exists exactly
        --- when a child ran to completion, whatever it then reported.
        ---
        --- @return Whether the exit code was zero, which is the convention and
        ---     not a guarantee: a program free to mean something else by it
        ---     needs `exitCode` read directly.
        succeeded: function(self: ProcessResult): boolean
    end

    --- Runs a program and answers a future for it, immediately.
    ---
    --- Nothing here blocks. The future reads "pending" until
    --- `updateProcesses`, or a `wait` on it, takes the answer.
    ---
    --- @param options Copied by this call, so later edits to the same table do
    ---     not reach the child. The first call also starts the process runner.
    --- @return A future that settles "ready" with the result when the child
    ---     ends, however it ended: a non-zero exit is still "ready", and
    ---     `succeeded` is what distinguishes them. It settles "failed" only
    ---     when the operating system cannot start the child, and "canceled"
    ---     when Tecs kills it.
    runProcess: function(options: ProcessOptions): Future<ProcessResult>

    --- Returns the record a run fills in.
    ---
    --- The same object the future carries on "ready", reachable in the two
    --- cases where the future does not carry it. Before the child ends, so
    --- `pid` can be read as soon as it has started, which is the one thing
    --- about a run that means anything before there is an answer. And after a
    --- Tecs killed the child, which settles "canceled" with no value but does not
    --- throw away what the child managed to say first.
    ---
    --- Nil for a run that never started, which has nothing to report, and for
    --- anything that is not a run from here.
    ---
    --- @param run A [`Future`](tealdoc:tecs.Future) from `runProcess`. Any other future answers nil
    ---     rather than raising.
    --- @return The runner's own record, not a copy, so it fills in as the child
    ---     runs and the same table is what the future carries when it settles.
    processResult: function(run: Future<ProcessResult>): Result

    --- Asks a child to end.
    ---
    --- The request completes asynchronously. Gentle by default, which a child
    --- may ignore. The child cannot refuse `force`, but it leaves whatever it was
    --- writing half written. The future settles "canceled" when the child
    --- goes.
    ---
    --- `run:cancel()` is the other spelling, and it counts holders: it ends the
    --- child only when the last consumer of the future has given it up. This
    --- one ends the child whoever else is watching.
    ---
    --- @param run A [`Future`](tealdoc:tecs.Future) from `runProcess`. The call
    ---     ignores one that has already settled, so a lost race remains safe.
    --- @param force Sends the signal a child cannot handle. Defaults to false,
    ---     which asks and the child may refuse.
    killProcess: function(run: Future<ProcessResult>, force?: boolean)

    --- Settles completed process runs. Call once per frame.
    --- @return How many runs finished.
    updateProcesses: function(): integer

    --- Returns the number of runs that have not answered yet.
    ---
    --- @return Every run in flight in this process, not one caller's, and
    ---     counting a child that received a termination request but has not yet ended.
    pendingProcesses: function(): integer

    --- Starts the process runner.
    ---
    --- Called for you by the first `run`. Call it directly to pay that cost up
    --- front or to give the runner a module path other than this state's.
    ---
    --- @param luaPath Where the runner finds its modules. Defaults to this
    ---     state's own, which is right whenever the two run from the same
    ---     tree. Only read on the call that actually starts the runner, so
    ---     passing it to a second call changes nothing.
    installProcessRunner: function(luaPath?: string)

    --- Reports whether the process runner is running.
    ---
    --- @return A fact about the process rather than about any world. False
    ---     costs nothing to act on: `run` starts the worker itself.
    processRunnerInstalled: function(): boolean

    --- Ends every child still running and stops the process runner.
    ---
    --- Each child gets a gentle request first, then a forced kill after
    --- `graceMs`.
    ---
    --- Every future still in flight ends at "canceled".
    --- @param graceMs How long a child gets to end gently. Defaults to 250.
    shutdownProcesses: function(graceMs?: number)
end

--- Runs on the worker. Creates children, polls them, answers when they end.
---
--- Written against `tecs.ffi.sdl3` directly: a worker shares no heap with the
--- state that spawned it, so this is a whole program rather than a closure.
local RUNNER <const> = [==[
local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local workers = require("tecs.workers")

local C = sdl.C
local K = sdl.K
local self = workers.current()

-- How long the worker sleeps between passes over its live children. It is
-- what a kill request waits for and what a finished child's answer waits for,
-- so it is short; one thread ticking at this rate costs nothing measurable.
local POLL_MS = 1

-- Read in one call per pass per stream. Large enough that a chatty child does
-- not need many passes to keep its pipe drained, small enough to sit in a
-- module-level buffer rather than being allocated per read.
local READ_BYTES = 65536

local readBuffer = ffi.new("uint8_t[?]", READ_BYTES)
local exitOut = ffi.new("int[1]")

-- Children that have started and not yet answered, by request id.
local live = {}
local liveCount = 0

-- Takes whatever a non-blocking process pipe is holding.
--
-- SDL gives the child's output and error streams out non-blocking, so a read
-- with nothing behind it answers zero rather than parking the thread. That is
-- the property the whole design rests on: it is what lets one worker hold
-- several children at once and still hear a kill request.
local function drain(stream, chunks)
    if stream == nil then return end
    while true do
        local read = tonumber(C.SDL_ReadIO(stream, readBuffer, READ_BYTES))
        if read <= 0 then return end
        chunks[#chunks + 1] = ffi.string(readBuffer, read)
    end
end

-- The environment a child is given, or nil to inherit this process's whole
-- environment. `clearEnv` starts from an empty one, so `env` is then the
-- entirety of what the child sees.
local function environmentFor(task)
    if task.env == nil and not task.clearEnv then return nil end
    local environment = C.SDL_CreateEnvironment(not task.clearEnv)
    if environment == nil then return nil end
    if task.env ~= nil then
        for name, value in pairs(task.env) do
            C.SDL_SetEnvironmentVariable(environment, name, value, true)
        end
    end
    return environment
end

-- Starts one child, or answers with why it could not be started.
--
-- Always through the properties form. It is a strict superset of
-- SDL_CreateProcess: piping the child's error output separately, a working
-- directory and an environment are all reachable only here, and two creation
-- paths would mean two places where the answer to "what did the child
-- inherit" is written down.
local function start(task)
    local count = #task.args
    local argv = ffi.new("const char *[?]", count + 1)
    for index = 1, count do argv[index - 1] = task.args[index] end
    argv[count] = nil

    local props = C.SDL_CreateProperties()
    C.SDL_SetPointerProperty(props, K.SDL_PROP_PROCESS_CREATE_ARGS_POINTER,
        argv)
    C.SDL_SetNumberProperty(props, K.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER,
        C.SDL_PROCESS_STDIO_APP)
    C.SDL_SetNumberProperty(props, K.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER,
        C.SDL_PROCESS_STDIO_APP)
    if task.mergeStderr then
        C.SDL_SetBooleanProperty(props,
            K.SDL_PROP_PROCESS_CREATE_STDERR_TO_STDOUT_BOOLEAN, true)
    else
        C.SDL_SetNumberProperty(props, K.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER,
            C.SDL_PROCESS_STDIO_APP)
    end
    if task.cwd ~= nil then
        C.SDL_SetStringProperty(props,
            K.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, task.cwd)
    end

    local environment = environmentFor(task)
    if environment ~= nil then
        C.SDL_SetPointerProperty(props,
            K.SDL_PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, environment)
    end

    local process = C.SDL_CreateProcessWithProperties(props)
    -- SDL has taken what it needs by now, including a copy of the argument
    -- vector, so both of these go back before anything can wait on the child.
    C.SDL_DestroyProperties(props)
    if environment ~= nil then C.SDL_DestroyEnvironment(environment) end

    if process == nil then
        self:send({ id = task.id, failed = true, error = sdl.error() })
        return
    end

    local properties = C.SDL_GetProcessProperties(process)
    local run = {
        process = process,
        output = C.SDL_GetProcessOutput(process),
        errors = ffi.cast("SDL_IOStream *", C.SDL_GetPointerProperty(
            properties, K.SDL_PROP_PROCESS_STDERR_POINTER, nil)),
        input = C.SDL_GetProcessInput(process),
        pendingInput = task.input or "",
        written = 0,
        chunks = {},
        errorChunks = {},
        killed = false,
        timedOut = false,
    }
    if task.timeoutMs ~= nil then
        run.deadline = tonumber(C.SDL_GetTicks()) + task.timeoutMs
    end
    live[task.id] = run
    liveCount = liveCount + 1

    self:send({
        id = task.id,
        started = true,
        pid = tonumber(C.SDL_GetNumberProperty(properties,
            K.SDL_PROP_PROCESS_PID_NUMBER, 0)),
    })
end

-- Pushes as much of the caller's input as the child's pipe will take, and
-- closes the pipe once it is all through.
--
-- Partial writes are the normal case for anything larger than a pipe buffer:
-- SDL hands the input stream out non-blocking too, so a child that has not
-- read yet takes some of it and the rest waits for the next pass. Closing is
-- what a child reading to end of input is waiting for, and SDL leaves the
-- stream closed rather than closing it twice at destroy.
local function feed(run)
    if run.input == nil then return end
    local total = #run.pendingInput
    if run.written < total then
        local rest = run.pendingInput:sub(run.written + 1)
        local wrote = tonumber(C.SDL_WriteIO(run.input, rest, #rest))
        if wrote > 0 then run.written = run.written + wrote end
    end
    if run.written >= total then
        C.SDL_CloseIO(run.input)
        run.input = nil
        run.pendingInput = ""
    end
end

-- Answers one finished child and releases it.
local function finish(id, run, exitCode)
    -- Once more, after the child is gone: a pipe holds what was written to it
    -- after the last pass, and this is the read that reaches end of file.
    drain(run.output, run.chunks)
    drain(run.errors, run.errorChunks)
    self:send({
        id = id,
        exitCode = exitCode,
        output = table.concat(run.chunks),
        errorOutput = table.concat(run.errorChunks),
        killed = run.killed,
        timedOut = run.timedOut,
    })
    if run.input ~= nil then C.SDL_CloseIO(run.input) end
    C.SDL_DestroyProcess(run.process)
    live[id] = nil
    liveCount = liveCount - 1
end

-- One pass over every live child: feed it, drain it, time it out, reap it.
local function step()
    local now = tonumber(C.SDL_GetTicks())
    for id, run in pairs(live) do
        feed(run)
        drain(run.output, run.chunks)
        drain(run.errors, run.errorChunks)

        if run.deadline ~= nil and not run.killed and now >= run.deadline then
            C.SDL_KillProcess(run.process, true)
            run.killed = true
            run.timedOut = true
        end

        if C.SDL_WaitProcess(run.process, false, exitOut) then
            finish(id, run, exitOut[0])
        end
    end
end

while true do
    -- Blocking only when nothing is running. A blocking receive answers nil
    -- exactly when the inbox closes, which is how a worker is asked to stop; a
    -- polling one answers nil whenever the queue is empty and says nothing
    -- about the state, so it cannot be read as a stop while children are live.
    local task
    if liveCount == 0 then
        task = self:receive()
    else
        task = self:receive(0)
    end

    if task == nil then
        if liveCount == 0 then break end
    elseif task.kind == "kill" then
        local run = live[task.id]
        if run ~= nil then
            C.SDL_KillProcess(run.process, task.force == true)
            run.killed = true
        end
    else
        start(task)
    end

    if liveCount > 0 then
        step()
        C.SDL_Delay(POLL_MS)
    end
end
]==]

local countOut <const> = loader.newArray("int[1]")
local secondsOut <const> = loader.newArray("int[1]")
local percentOut <const> = loader.newArray("int[1]")

local POWER_STATES <const>: {integer: string} = {
    [tonumber(C.SDL_POWERSTATE_ERROR) as integer] = "error",
    [tonumber(C.SDL_POWERSTATE_UNKNOWN) as integer] = "unknown",
    [tonumber(C.SDL_POWERSTATE_ON_BATTERY) as integer] = "onBattery",
    [tonumber(C.SDL_POWERSTATE_NO_BATTERY) as integer] = "noBattery",
    [tonumber(C.SDL_POWERSTATE_CHARGING) as integer] = "charging",
    [tonumber(C.SDL_POWERSTATE_CHARGED) as integer] = "charged",
}

local SANDBOXES <const>: {integer: string} = {
    [tonumber(C.SDL_SANDBOX_NONE) as integer] = "none",
    [tonumber(C.SDL_SANDBOX_UNKNOWN_CONTAINER) as integer] = "unknownContainer",
    [tonumber(C.SDL_SANDBOX_FLATPAK) as integer] = "flatpak",
    [tonumber(C.SDL_SANDBOX_SNAP) as integer] = "snap",
    [tonumber(C.SDL_SANDBOX_MACOS) as integer] = "macOS",
}

local MESSAGE_FLAGS <const>: {string: integer} = {
    error = K.SDL_MESSAGEBOX_ERROR,
    warning = K.SDL_MESSAGEBOX_WARNING,
    info = K.SDL_MESSAGEBOX_INFORMATION,
}

--- Opens an absolute URI with the operating system's preferred application.
---
--- This is not limited to web URLs. The operating system may route `https:`
--- to a browser, `mailto:` to a mail client, and application-specific schemes
--- such as `steam:` to their registered handler. Tecs passes the string to SDL
--- without parsing it, so the platform decides which schemes it accepts and
--- which application handles them.
---
--- @param url The caller supplies a non-empty absolute URI. Embedded NUL bytes
---     are not supported by SDL's C-string boundary.
--- @return Returns true after the operating system accepts the launch request.
--- @return Returns SDL's reason when the URI is empty, unsupported, malformed,
---     or cannot be opened.
function platformOS.openURL(url: string): boolean, string
    if url == nil or url == "" then
        return false, "a URL is required"
    end
    if not C.SDL_OpenURL(url) then
        return false, sdl.error()
    end
    return true, nil
end

--- Returns the user's preferred locales in priority order.
function platformOS.preferredLocales(): {Locale}
    local out: {Locale} = {}
    local locales = C.SDL_GetPreferredLocales(countOut)
    if locales == nil then
        return out
    end
    local list = locales as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local locale = list[index] as loader.CStruct
        if locale ~= nil then
            out[#out + 1] = {
                language = loader.toString(locale.language as loader.CValue),
                country = loader.toString(locale.country as loader.CValue),
            }
        end
    end
    C.SDL_free(locales)
    return out
end

--- Returns the current battery or external-power state.
function platformOS.power(): Power
    secondsOut[0], percentOut[0] = -1, -1
    local state = tonumber(C.SDL_GetPowerInfo(secondsOut, percentOut)) as integer
    return {
        state = POWER_STATES[state] or "unknown",
        seconds = secondsOut[0] as integer,
        percent = percentOut[0] as integer,
    }
end

--- Shows a native informational, warning or error dialog.
function platformOS.messageBox(kind: string, title: string, message: string, window?: Window): boolean, string
    local flags = MESSAGE_FLAGS[kind]
    if flags == nil then
        return false, ("unknown message-box kind %q"):format(tostring(kind))
    end
    local handle = window ~= nil and window.handle or nil
    if not C.SDL_ShowSimpleMessageBox(flags, title or "", message or "", handle) then
        return false, sdl.error()
    end
    return true, nil
end

-------------------------------------------------------------------------------
-- Asynchronous file and folder dialogs
-------------------------------------------------------------------------------

--- SDL retains the file-dialog callback and may enter it from a thread LuaJIT
--- did not create. The Rust dialog bridge owns that callback and copies its answer;
--- this source polls the copied result and settles futures on the main thread.

local record DialogEntry
    handle: loader.CPtr
    future: Future<DialogResult>
end

local record DialogSource
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: DialogSource): integer
    advance: function(self: DialogSource, ms: number): integer
end

local DialogSourceMT <const>: metatable<DialogSource> = {__index = DialogSource}
local pendingDialogs: {DialogEntry} = {}

local function finishDialog(entry: DialogEntry)
    local handle = entry.handle
    local errorPointer = D.tecsDialogError(handle)
    if errorPointer ~= nil then
        entry.future:fail(loader.toString(errorPointer))
    else
        local paths: {string} = {}
        local count = tonumber(D.tecsDialogPathCount(handle)) as integer
        for index = 0, count - 1 do
            paths[index + 1] = loader.toString(D.tecsDialogPath(handle, index))
        end
        local selected = tonumber(D.tecsDialogFilter(handle)) as integer
        entry.future:complete({
            paths = paths,
            filter = selected >= 0 and selected + 1 or 0,
            canceled = D.tecsDialogCancelled(handle) as boolean,
        })
    end
    D.tecsDialogDestroy(handle)
end

function DialogSource:poll(): integer
    local settled = 0
    for index = #pendingDialogs, 1, -1 do
        local entry = pendingDialogs[index]
        if D.tecsDialogReady(entry.handle) then
            finishDialog(entry)
            table.remove(pendingDialogs, index)
            settled = settled + 1
        end
    end
    return settled
end

function DialogSource:advance(ms: number): integer
    local settled = self:poll()
    if settled > 0 or ms <= 0 then
        return settled
    end
    C.SDL_Delay(math.floor(ms))
    return self:poll()
end

local dialogSource <const> = setmetatable(
    {
        sliceMs = 16,
        defaultWaitMs = 300000,
    } as DialogSource,
    DialogSourceMT
)

local function filterArrays(options: DialogOptions): loader.CArray, loader.CArray, integer
    local filters = options.filters
    if filters == nil or #filters == 0 then
        return nil, nil, 0
    end
    local names = loader.newArray("const char *[?]", #filters)
    local patterns = loader.newArray("const char *[?]", #filters)
    for index = 1, #filters do
        local filter = filters[index]
        if filter.name == nil or filter.name == "" then
            error(("tecs: dialog filter %d needs a name"):format(index), 3)
        end
        if filter.pattern == nil or filter.pattern == "" then
            error(("tecs: dialog filter %d needs a pattern"):format(index), 3)
        end
        names[index - 1] = filter.name
        patterns[index - 1] = filter.pattern
    end
    return names, patterns, #filters
end

local function trackDialog(handle: loader.CPtr): Future<DialogResult>
    if handle == nil then
        return Future.failed("cannot allocate file-dialog state") as Future<DialogResult>
    end
    local future = Future.pending(dialogSource as Future.Source) as Future<DialogResult>
    pendingDialogs[#pendingDialogs + 1] = {handle = handle, future = future}
    -- A setup allocation can fail before SDL opens anything.
    dialogSource:poll()
    return future
end

--- Opens a native file picker.
function platformOS.openFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(
        D.tecsDialogOpenFile(window, names, patterns, count, given.defaultLocation, given.multiple == true)
    )
end

--- Opens a native save-file picker. Returns at most one path.
function platformOS.saveFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogSaveFile(window, names, patterns, count, given.defaultLocation))
end

--- Opens a native folder picker.
function platformOS.openFolder(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogOpenFolder(window, given.defaultLocation, given.multiple == true))
end

--- Settles file and folder dialogs that have answered.
---
--- [`Application`](tealdoc:tecs.Application) calls this every frame. It is public for a headless tool that
--- creates dialogs without an application.
function platformOS.updateDialogs(): integer
    return dialogSource:poll()
end

local resolved: Capabilities = nil
local cachedGeneration = -1

--- Whether the platform reports a touch device.
---
--- Asked rather than inferred from the platform: a desktop with a touchscreen
--- has one and a simulator may not, so neither answer follows from the OS.
local function hasTouch(): boolean
    local count = loader.newArray("int[1]")
    local devices = C.SDL_GetTouchDevices(count)
    if devices == nil then
        return false
    end
    C.SDL_free(devices)
    return tonumber(count[0]) > 0
end

-- Query the optional `jit` module dynamically so a stripped build reports
-- interpretation instead of failing to load.
local function jitEnabled(): boolean
    local ok, module = pcall(require, "jit")
    if not ok then
        return false
    end
    local status = (module as {string: any}).status
    if status == nil then
        return false
    end
    local running = (status as function(): boolean)()
    return running == true
end

--- Forgets the cached answer. Capability lookup notices a platform change without this.
function platformOS.resetCapabilities()
    resolved = nil
end

--- Reads the capabilities of the running build.
---
--- The function caches its answer because these values do not change while a
--- platform remains installed. The platform generation keys the cache, so
--- installing a platform drops the value without
--- anybody calling `resetCapabilities`.
--- @return The same table on every call until the platform changes. Shared,
---     so a caller that means to keep it does not also mean to edit it.
function platformOS.capabilities(): Capabilities
    local generation = adapter.generation()
    if generation ~= cachedGeneration then
        cachedGeneration = generation
        resolved = nil
    end
    if resolved ~= nil then
        return resolved
    end

    -- The platform in use, which is not always SDL: a licensed port installs
    -- its own and everything here has to describe that one.
    local platform = loader.toString(C.SDL_GetPlatform())
    local installed = adapter.current()
    if installed.name ~= "sdl" then
        platform = installed.name
    end

    -- The shader pipeline is asked rather than guessed at: whether a compiler
    -- was linked is a property of the build, and a loaded pack narrows the
    -- format to the one it holds.
    local pack = shadercompiler.pack()
    local formats: {string} = {shaderpack.formatName(shadercompiler.format())}

    local runtimeShaders <const> = shadercompiler.isSupported()
    local sandbox <const> =
        SANDBOXES[tonumber(C.SDL_GetSandbox()) as integer] or "unknownContainer"
    resolved = {
        target = platform,
        architecture = ffi.arch,
        sandbox = sandbox,
        -- Whether machine code is being generated. On a target that forbids
        -- writable executable memory it is not, and the interpreter runs.
        jit = jitEnabled(),
        ffi = true,
        -- A registry means the libraries were linked, which is the case
        -- precisely where loading one by name is not available.
        dynamicLibraries = installed.dynamicLibraries,
        -- Runtime shaders and hot reload are selected by the same development
        -- preset today. They remain separate capabilities so neither consumer
        -- has to infer itself from the other.
        hotReload = runtimeShaders,
        runtimeShaders = runtimeShaders,
        packagedShaders = pack ~= nil,
        shaderFormats = formats,
        touch = hasTouch(),
        gamepad = true,
        sensors = platform == "iOS" or platform == "Android",
        workers = pcall(require, "tecs.workers"),
        cores = tonumber(C.SDL_GetNumLogicalCPUCores()) as integer,
        writableStorage = true,
    }
    return resolved
end

-- One scratch cell for the size and count out-parameters. `mimeTypes` and
-- `data` are the only readers that take one, and neither calls the other, so
-- there is nothing here for a second use to overlap with.
local sizeOut <const> = loader.newArray("size_t[1]")

-- Copies and frees a platform string. The nil guard avoids turning an
-- unexpected null into a dereference.
local function take(pointer: loader.CValue): string
    if pointer == nil then
        return ""
    end
    local text = loader.toString(pointer)
    C.SDL_free(pointer)
    return text
end

--- Raises when a required string argument is missing.
---
--- SDL reads a null `const char *` as an empty string, so a nil slipping into
--- `setClipboardText` would clear the clipboard rather than fail, which is the one
--- outcome nobody meant.
local function required(value: string, what: string)
    if value == nil then
        error(("tecs: os.%s needs a string"):format(what), 3)
    end
end

--- Reports whether a clipboard is available.
---
--- False in a process that never brought up video, where every other function
--- here answers empty or false. Distinguishes that from a clipboard that is
--- simply empty, which no other return value can.
function platformOS.clipboardAvailable(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- Returns the clipboard text, or an empty string when it holds none.
---
--- Empty is also the answer when the clipboard holds something that is not
--- text, and when there is no video. Ask `hasClipboardText` to tell those from text
--- that is genuinely empty.
function platformOS.clipboardText(): string
    if not platformOS.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetClipboardText())
end

--- Puts `text` on the clipboard, replacing whatever was there.
---
--- The platform copies the string before this call returns. Returns false
--- when the platform refused, which includes having no video.
function platformOS.setClipboardText(text: string): boolean
    required(text, "setClipboardText")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_SetClipboardText(text) as boolean
end

--- Reports whether the clipboard holds text.
---
--- Cheaper than reading it: no allocation crosses the boundary, and on a
--- platform where a read negotiates with the owning application, no
--- negotiation happens.
function platformOS.hasClipboardText(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardText() as boolean
end

--- Withdraws what this application put on the system.
---
--- The clipboard is left empty rather than restored to what preceded the
--- write, because nothing anywhere remembers what that was.
function platformOS.clearClipboard(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_ClearClipboardData() as boolean
end

--- Returns the clipboard MIME types in platform order.
---
--- The same list `clipboardUpdate` carries, for a caller that wants to ask
--- rather than wait to be told. Empty when the clipboard is empty.
function platformOS.clipboardMimeTypes(): {string}
    local found: {string} = {}
    if not platformOS.clipboardAvailable() then
        return found
    end

    local list = C.SDL_GetClipboardMimeTypes(sizeOut)
    if list == nil then
        return found
    end
    local items = loader.castPointer("char **", list)
    local count = tonumber(sizeOut[0]) as integer
    for index = 0, count - 1 do
        found[index + 1] = loader.toString(items[index] as loader.CValue)
    end
    -- One allocation holds the array and the strings it points at, so one
    -- free releases all of it and freeing an entry would be a double free.
    C.SDL_free(list)
    return found
end

--- Reports whether the clipboard offers `mimeType`.
function platformOS.hasClipboardData(mimeType: string): boolean
    required(mimeType, "hasClipboardData")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardData(mimeType) as boolean
end

--- Returns the clipboard bytes for `mimeType`, or nil when it offers none.
---
--- The caller releases the returned
--- [`Buffer`](/modules/io/#tecs.io.Buffer).
--- Returns nil rather than an empty buffer because the clipboard can offer a
--- MIME type with no bytes, which differs from not offering that type.
function platformOS.clipboardData(mimeType: string): IOBuffer
    required(mimeType, "clipboardData")
    if not platformOS.clipboardAvailable() then
        return nil
    end

    local bytes = C.SDL_GetClipboardData(mimeType, sizeOut)
    if bytes == nil then
        return nil
    end
    local length <const> = tonumber(sizeOut[0]) as integer
    local blob <const> = buffer.new(length)
    if length > 0 then
        ffi.copy(blob:getFFIPointer() as ffi.CData, bytes as ffi.CData, length)
    end
    C.SDL_free(bytes)
    return blob
end

--- Returns text from the platform's primary selection.
---
--- On X11 and Wayland, selecting text places it in a clipboard separate from
--- the ordinary copy-and-paste clipboard, commonly pasted with the middle
--- mouse button. Platforms without that concept expose only the value this
--- process last supplied through `setPrimarySelection`; other applications do
--- not see it. This function does not read `clipboardText`.
---
--- @return Returns UTF-8 text, or an empty string when the selection is empty
---     or no video subsystem is available.
function platformOS.primarySelection(): string
    if not platformOS.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetPrimarySelectionText())
end

--- Puts `text` in the primary selection.
---
--- Succeeds on a platform that has no shared primary selection, where the
--- value remains visible only to this process.
function platformOS.setPrimarySelection(text: string): boolean
    required(text, "setPrimarySelection")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_SetPrimarySelectionText(text) as boolean
end

--- Reports whether the primary selection holds text.
function platformOS.hasPrimarySelection(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasPrimarySelectionText() as boolean
end

local type Result = platformOS.ProcessResult
local type Options = platformOS.ProcessOptions

local ResultMT <const>: metatable<Result> = {__index = Result}

--- How long a wait on a run spends when the caller names nothing.
---
--- Longer than a decode's, because a child process is a different order of
--- work. It lives on the source, which is what lets the two keep different
--- defaults without a second convention.
local DEFAULT_WAIT_MS <const> = 30000

--- How long `shutdown` gives a child to end gently before forcing it.
local DEFAULT_GRACE_MS <const> = 250

-- How long `shutdown` waits after forcing a child to exit.
local FORCED_WAIT_MS <const> = 5000

--- Milliseconds one blocking slice of a wait spends.
local SLICE_MS <const> = 8

--- A run the worker has not answered for yet.
---
--- The result is built here as the messages arrive rather than at the end,
--- because the child's process id comes back before anything else does and
--- this is where it waits until there is a result to put it in.
local record Entry
    id: integer
    future: Future<Result>
    result: Result
end

local pending: {integer: Entry} = {}
--- The same entries by future, so `kill` can start from what the caller holds.
--- Cleared at settlement, so it is only ever as large as the number of children
--- in flight.
local byFuture: {Future<Result>: Entry} = {}
-- Every run's result by its future. This outlives the entry because killing a
-- child settles with no value while its output may still matter. Weak keys
-- retain nothing after the caller releases the future.
local results <const>: {Future<Result>: Result} = setmetatable({} as {Future<Result>: Result}, {__mode = "k"})
local pendingCount = 0
local nextId = 1
local worker: workers.Worker = nil

function platformOS.installProcessRunner(luaPath?: string)
    if worker ~= nil then
        return
    end
    worker = workers.spawn({
        source = RUNNER,
        luaPath = luaPath or package.path,
    })
end

function platformOS.processRunnerInstalled(): boolean
    return worker ~= nil
end

function Result:succeeded(): boolean
    return self.exitCode == 0
end

--- Forgets an entry, whatever ended it.
local function retire(entry: Entry)
    pending[entry.id] = nil
    byFuture[entry.future] = nil
    pendingCount = pendingCount - 1
end

--- Folds one worker message into its run.
---
--- @return Whether it was the message that ended a run.
local function complete(message: {string: any}): boolean
    local entry = pending[message.id as integer]
    if entry == nil then
        return false
    end

    if message.started == true then
        entry.result.pid = message.pid as integer
        return false
    end

    retire(entry)

    if message.failed == true then
        entry.future:fail(message.error as string)
        return true
    end

    local result = entry.result
    result.exitCode = message.exitCode as integer
    result.output = message.output as string
    result.errorOutput = message.errorOutput as string

    if message.killed == true then
        -- Ended by this process, through `kill`, a deadline, or shutdown. Not a
        -- failure: nothing about the child went wrong, it was stopped.
        entry.future:abandon(message.timedOut == true and "timed out" or "killed")
        return true
    end

    -- Whatever the exit code. A child that ran answered the question it was
    -- asked, and `Result:succeeded` is the separate question about the answer.
    entry.future:complete(result)
    return true
end

-------------------------------------------------------------------------------
-- The source
-------------------------------------------------------------------------------

--- What drives every future this module hands out.
---
--- `poll` and `advance` are the same receive with a different budget, which is
--- the whole of what a future needs from a worker channel.
local record Runner
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Runner): integer
    advance: function(self: Runner, ms: number): integer
    cancel: function(self: Runner, future: Future<any>)
end

local RunnerMT <const>: metatable<Runner> = {__index = Runner}

function Runner:poll(): integer
    if worker == nil then
        return 0
    end
    local finished = 0
    while true do
        local message = worker:receive(0)
        if message == nil then
            break
        end
        if complete(message as {string: any}) then
            finished = finished + 1
        end
    end
    return finished
end

function Runner:advance(ms: number): integer
    if worker == nil then
        return 0
    end
    local message = worker:receive(ms)
    if message == nil then
        return 0
    end
    return complete(message as {string: any}) and 1 or 0
end

--- Asks the worker to end a child whose last watcher has gone.
---
--- Forced, which is the opposite of what "a consumer politely losing interest"
--- suggests and is right for the same reason. The gentle kill exists to let a
--- child finish writing output somebody wants; here the last consumer of that
--- output has just gone, so there is nothing left to be gentle on behalf of,
--- and a refusable signal would leave the child running with no future left to
--- observe it. A caller who does want to ask rather than insist has
--- `tecs.platform.os.killProcess(run, false)`, which is that question spelled out.
function Runner:cancel(future: Future<any>)
    local entry = byFuture[future as Future<Result>]
    if entry == nil or worker == nil then
        return
    end
    worker:send({kind = "kill", id = entry.id, force = true})
end

local runner <const> = setmetatable(
    {
        -- Both live here rather than in `Future`, which is what lets a child
        -- process keep a longer default than a decode without a second convention.
        sliceMs = SLICE_MS,
        defaultWaitMs = DEFAULT_WAIT_MS,
    } as Runner,
    RunnerMT
)

local source <const> = runner as Future.Source

-------------------------------------------------------------------------------
-- Running
-------------------------------------------------------------------------------

function platformOS.runProcess(options: Options): Future<Result>
    if options == nil or options.args == nil or #options.args == 0 then
        error("tecs: os.runProcess needs args, starting with the program", 2)
    end
    for index = 1, #options.args do
        if type(options.args[index]) ~= "string" then
            error(("tecs: os.runProcess args[%d] is not a string"):format(index), 2)
        end
    end

    platformOS.installProcessRunner()

    local id = nextId
    nextId = nextId + 1

    local future = Future.pending(source) as Future<Result>
    local entry: Entry = {
        id = id,
        future = future,
        result = setmetatable(
            {
                args = options.args,
                pid = 0,
                exitCode = 0,
                output = "",
                errorOutput = "",
            } as Result,
            ResultMT
        ),
    }
    pending[id] = entry
    byFuture[future] = entry
    results[future] = entry.result
    pendingCount = pendingCount + 1

    worker:send({
        id = id,
        args = options.args,
        cwd = options.cwd,
        env = options.env,
        clearEnv = options.clearEnv,
        mergeStderr = options.mergeStderr,
        input = options.input,
        timeoutMs = options.timeoutMs,
    })
    return future
end

function platformOS.processResult(run: Future<Result>): Result
    if run == nil then
        return nil
    end
    return results[run]
end

function platformOS.killProcess(run: Future<Result>, force?: boolean)
    if worker == nil or run == nil then
        return
    end
    local entry = byFuture[run]
    if entry == nil then
        return
    end
    worker:send({kind = "kill", id = entry.id, force = force == true})
end

function platformOS.updateProcesses(): integer
    return runner:poll()
end

function platformOS.pendingProcesses(): integer
    return pendingCount
end

-------------------------------------------------------------------------------
-- Shutting down
-------------------------------------------------------------------------------

--- Spends up to `ms` of wall clock taking whatever the worker answers.
---
--- Wall clock rather than a count of slices: `advance` returns as soon as one
--- message arrives, so subtracting the slice size for it would make a "5000 ms"
--- wait into "at most 625 messages".
local function drainFor(ms: number)
    local deadline = time.now() * 1000.0 + ms
    while pendingCount > 0 do
        local remaining = deadline - time.now() * 1000.0
        if remaining <= 0 then
            break
        end
        runner:advance(remaining < runner.sliceMs and remaining or runner.sliceMs)
    end
end

function platformOS.shutdownProcesses(graceMs?: number)
    if worker == nil then
        return
    end

    if pendingCount > 0 then
        for _, entry in pairs(pending) do
            worker:send({kind = "kill", id = entry.id, force = false})
        end
        drainFor(graceMs or DEFAULT_GRACE_MS)
    end

    if pendingCount > 0 then
        for _, entry in pairs(pending) do
            worker:send({kind = "kill", id = entry.id, force = true})
        end
        drainFor(FORCED_WAIT_MS)
    end

    -- Anything still here is a child the kernel has not reaped, which no
    -- further waiting fixes. Its future is settled rather than dropped: the
    -- runner is about to stop, so nothing will ever answer for it, and leaving
    -- it "pending" would be a future that reads "still running" for the rest of
    -- the process against a worker that no longer exists.
    for _, entry in pairs(pending) do
        entry.future:abandon("ended at shutdown")
        byFuture[entry.future] = nil
    end

    worker:stop()
    worker = nil
    pending = {}
    byFuture = {}
    pendingCount = 0
end

return platformOS
