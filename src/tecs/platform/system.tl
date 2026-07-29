--- The operating system, asked directly: what this build can do here, the
--- clipboard, another program, and the services a desktop offers.
---
--- One module because none of these is a subsystem a game builds on. Each is a
--- few calls a game makes when a player asks for something, and each was too
--- small to be a name of its own: a game copying a path to the clipboard and
--- then opening a folder in the file manager was naming three modules to do one
--- thing. There is deliberately no `tecs.platform`, since that is where this
--- tree keeps an implementation category rather than a task a game performs.
---
--- Names are qualified by what they act on, because one module makes a bare
--- `text`, `data`, `clear`, `run` or `update` mean nothing on its own.
---
--- ```teal
--- local run <const> = tecs.system.runProcess({args = {"git", "rev-parse", "HEAD"}})
---
--- -- Once a frame, until the child answers.
--- tecs.system.updateProcesses()
--- if run.status == "ready" and run.value:succeeded() then
---     tecs.system.setClipboardText(run.value.output)
--- end
--- ```
---
--- ## Capabilities
---
--- Read rather than inferred. Selecting behavior from `ffi.os` guesses: it
--- cannot tell a build that linked a shader compiler from one that did not, or
--- an interpreter-only LuaJIT from a jitting one, and both distinctions change
--- what the engine is allowed to attempt.
---
--- ## Clipboard
--- `events.clipboardUpdate` reports that the clipboard changed and lists the
--- mime types now on offer. This is the other half: what those bytes are, and
--- how to put text there.
---
--- Nothing here is cached. The clipboard belongs to the desktop rather than to
--- this process, so a value read a frame ago may already be wrong, and
--- `clipboardUpdate` is the only invalidation there is.
---
--- ## Ownership of what SDL returns
---
--- Every read hands back an allocation the caller frees, and a failed read
--- hands back an empty string rather than nothing, so the free is owed on that
--- case too. `loader.toString` copies and does not free, which is the right
--- converter and only half the job; the pairing lives in `take` here rather
--- than at each call site, because a read that forgot would leak once per
--- paste and nothing would point at the clipboard as the cause.
---
--- ## Offering bytes that are not text
---
--- `setText` is the whole write surface, and SDL copies the string it is
--- given, so the value's lifetime is SDL's from the moment the call returns.
---
--- Offering an arbitrary mime type is the one clipboard entry point that works
--- the other way round. `SDL_SetClipboardData` takes no copy: it retains a
--- callback and calls it when some other application asks for the bytes, which
--- may be long after the call returned and is a moment this process does not
--- choose. In Lua that is an FFI callback pinned for the lifetime of the offer
--- and entered from wherever SDL fulfils the request, and `physics.TaskPool`
--- already records why this engine keeps its callbacks native rather than
--- taking that bet. Reading an arbitrary mime type carries none of it, so
--- `mimeTypes`, `hasData` and `data` are here and the offer side is not.
---
--- ## Primary selection
---
--- A second, independent clipboard: X11 and Wayland fill it with whatever was
--- last selected and paste it on a middle click, with no copy step at all. It
--- is not a flavour of the clipboard and does not track it.
---
--- Elsewhere there is no such concept. SDL does not fail there; it keeps the
--- value in the video device, so `setPrimary` succeeds, `primary` reads back
--- what this process wrote, and nothing outside the process ever sees it. Read
--- it as a hint that may be answered locally rather than as a shared surface.
---
--- ## With no video
---
--- The clipboard is part of SDL's video subsystem and every entry point fails
--- with "Video subsystem has not been initialized" without it. This module
--- answers the same shape without calling SDL at all: `available` is false,
--- reads are empty, writes fail. A headless tool gets an answer rather than a
--- crash, and SDL's error string is left holding whatever last set it instead
--- of being overwritten by a question that was never going to be answered.
---
--- ## Encoding
---
--- Clipboard text is UTF-8 and passes through byte for byte. Line endings are
--- not normalized, so text copied on Windows arrives as CRLF and stays CRLF,
--- and nothing is trimmed from either end. Text stops at the first NUL,
--- because that is what terminates the C string SDL returns and what every
--- producer of clipboard text intends; `data` uses the length SDL reports
--- instead, so a blob keeps its NULs.
---
--- ## Child processes
---
--- A command line tool, a resource pipeline or an asset build wants to shell
--- out, and a game wants to do it between two frames rather than instead of
--- them. `SDL_ReadProcess` and a blocking `SDL_WaitProcess` both hold the
--- calling thread for as long as the child runs, so neither is called on the
--- main thread. A run goes out to a worker, the loop pumps, and a handle
--- resolves; that is the same shape `tecs.assets` uses for a decode, for the
--- same reason.
---
--- ## One shape: run to completion
---
--- `proc.runProcess` serves the child whose output you want when it finishes:
--- `git rev-parse`, `sips`, a shader translator, a packer. The result arrives
--- whole, once, with the exit status beside it.
---
--- It deliberately does not serve the long-running child whose output you want
--- as it appears. That is a different API, not a flag on this one: it has to
--- answer what a chunk is (bytes, or lines, with a partial line held back),
--- what happens when a chatty child outruns the reader, and how two streams
--- interleave once they are delivered separately over time. Every one of those
--- is a guess here and a requirement there. The worker below already reads
--- incrementally, because that is what keeps it interruptible and what keeps a
--- child from filling a pipe and stopping, so a streaming variant grows from
--- that seam rather than replacing it. Until it exists, bound what you run:
--- output is accumulated whole, so a child that prints forever is a child that
--- allocates forever, and `timeoutMs` is the answer.
---
--- ## What crosses the worker boundary
---
--- Nothing but the request and the answer. The child is created, fed, polled,
--- read, killed and destroyed entirely on the worker; what comes back is
--- bytes, an exit code and a pid.
---
--- An `SDL_Process` could cross the way a decoded surface does, as an address
--- with ownership attached, and it must not. SDL documents `SDL_WaitProcess`,
--- `SDL_KillProcess`, `SDL_ReadProcess` and `SDL_DestroyProcess` as *not*
--- thread safe, and unlike a surface a process is not a block of memory whose
--- ownership can simply move: it is a pid that may be reaped exactly once and
--- a set of pipe descriptors. Two states holding it means two states able to
--- reap it, and the second reap lands on whatever pid the kernel has since
--- handed out. The one reason to move it would be to call something from the
--- main thread, and every call worth making there is one of the four above.
---
--- So the address stays on the worker and the caller gets a copy of the
--- output. That copy is the price, and it is the right one at this size: a
--- decoded 4K texture is sixty-four megabytes and copying it twice is the
--- frame, while `git rev-parse` answers forty-one bytes and a translator's
--- diagnostics are kilobytes.
---
--- ## Killing, and shutdown
---
--- Because every process call belongs to the worker, the main thread asks
--- rather than acts: `Proc:kill` queues a request the worker picks up on its
--- next poll. That only works if the worker is never parked in C, which is why
--- it polls `SDL_WaitProcess` with `block` false and reads the child's pipes
--- through the non-blocking streams SDL hands out, instead of calling
--- `SDL_ReadProcess` and disappearing for the child's lifetime.
---
--- `proc.shutdownProcesses` therefore kills rather than detaching or reaping. Reaping
--- alone has no bound, and a child that never exits parks teardown; detaching
--- leaves a thread running inside a library the process is about to unmap,
--- which is the failure `loader`'s `RTLD_NODELETE` already exists for. Killing
--- is gentle first and forced after a grace period, and a forced kill is not
--- refusable, so the join that follows is bounded by the kernel reaping the
--- child.
---
--- ## Failure is a status
---
--- A program that cannot be started settles its future at `"failed"` with
--- `error` set, rather than raising. A caller that shells out is already
--- branching on the exit code, and a spawn that failed is one more branch on
--- the same value; a raise would be the only path in the module that has to be
--- wrapped.
---
--- An exit code is not a failure. A child that ran and exited 1 settles
--- `"ready"`, because the run did what it was asked to and the code is the
--- answer rather than an error; `Result:succeeded` is the separate question.
--- Reading that the other way would make every non-zero exit propagate as a
--- failure through `map`, which is wrong for everything that shells out to a
--- tool whose exit code is data. `"failed"` means the child never started and
--- `"canceled"` means this process ended it, through `kill`, a timeout, or
--- shutdown.
---
--- ## Headless
---
--- SDL's process API needs no subsystem initialized, and nothing here
--- initializes one. No process call is made on this side: the whole binding is
--- inside the worker's source, so a state that only ever queues runs starts no
--- child of its own. That is the point, since this is one of the few
--- subsystems more useful without a window than with one; it works under a
--- plain interpreter with no video, no device and no host.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local adapter <const> = require("tecs.platform.adapter")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local workers <const> = require("tecs.workers")
local time <const> = require("tecs.platform.time")
local Future <const> = require("tecs.Future")
local type Window = require("tecs.platform.window").Window

loader.declare("dialogs")

local C <const> = sdl.C
local K <const> = sdl.K
local D <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "dialogs")
local VIDEO <const> = sdl.K.SDL_INIT_VIDEO

local record Locale
    --- ISO 639 language code, such as `"en"`.
    language: string
    --- ISO 3166 country code, such as `"US"`, or an empty string when the
    --- platform names only a language.
    country: string
end

local record Power
    --- `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
    --- `"charged"` or `"error"`.
    state: string
    --- Seconds of battery life remaining, or -1 when unavailable.
    seconds: integer
    --- Charge percentage in 0..100, or -1 when unavailable.
    percent: integer
end

local record DialogFilter
    --- Label shown beside the filter, such as `"Images"`.
    name: string
    --- Semicolon-separated extensions, such as `"png;jpg;jpeg"`.
    pattern: string
end

local record DialogOptions
    window: Window
    filters: {DialogFilter}
    defaultLocation: string
    multiple: boolean
end

local record DialogResult
    --- Selected paths. Empty when the user canceled.
    paths: {string}
    --- One-based selected filter, or zero when no filter applies.
    filter: integer
    canceled: boolean
end

--- What this build of the engine can do on this target.
local record Capabilities
    --- Platform name as SDL reports it, such as "macOS" or "Android". A
    --- licensed port answers with its own name instead, since everything here
    --- describes the platform actually installed.
    target: string
    --- CPU architecture LuaJIT was built for.
    architecture: string

    --- Whether machine code is being generated. False on a target that
    --- forbids it, where the interpreter runs instead. Independent of `ffi`,
    --- which is required everywhere.
    jit: boolean
    --- Always true. The engine has no path that does not use the FFI, so a
    --- build without it does not run at all rather than running degraded.
    ffi: boolean

    --- Whether a library can be loaded by name at run time. False where every
    --- library is linked into the executable.
    dynamicLibraries: boolean
    --- Whether development-time content reload is present in this build.
    --- Named independently of any one kind the watcher reloads.
    hotReload: boolean
    --- Whether shaders can be compiled from source at run time.
    runtimeShaders: boolean
    --- Whether shaders are being read from a packaged artifact. Independent of
    --- `runtimeShaders`: a development build may have both, and a release has
    --- only this.
    packagedShaders: boolean
    --- Shader formats this target consumes. One entry, since a build supplies
    --- one format.
    shaderFormats: {string}

    --- Whether a touch device is attached right now. A property of the machine
    --- rather than of the target: a desktop with a touchscreen has one.
    touch: boolean
    --- Always true. Every target reaches gamepads through the same subsystem,
    --- so what varies is whether one is plugged in, which `Input:gamepads`
    --- answers.
    gamepad: boolean
    --- Whether the device itself carries a gyroscope or an accelerometer. Says
    --- nothing about a gamepad's sensors, which `Gamepad:hasSensor` answers
    --- per device.
    sensors: boolean
    --- Whether work can be run off the main thread.
    workers: boolean
    --- Logical cores, for sizing a worker pool.
    cores: integer

    --- Always true. Every target has somewhere to write, and
    --- `filesystem.preferencePath` is where: the field exists so a caller can
    --- ask rather than assume, not because a target answers no.
    writableStorage: boolean
end

--- What a game reaches through `tecs.system`: capabilities, the clipboard,
--- child processes, URLs, locales, power, message boxes and native file and
--- folder dialogs.
local record system
    --- What this build of the engine can do on this target.
    type Capabilities = Capabilities

    --- One language the user prefers, in order of preference.
    type Locale = Locale

    --- What the machine is running on, and how much of it is left.
    type Power = Power

    --- One entry in a dialog's file-type filter.
    type DialogFilter = DialogFilter

    --- What a dialog is opened with.
    type DialogOptions = DialogOptions

    --- What the user chose, or that they chose nothing.
    type DialogResult = DialogResult
    --- What to run, and what the child inherits.
    record ProcessOptions
        --- The program and its arguments; `args[1]` is the program. A name
        --- without a separator is resolved against `PATH`.
        args: {string}
        --- Working directory for the child. Omitted inherits this process's.
        cwd: string
        --- Environment variables to set. Applied over this process's
        --- environment, or over an empty one when `clearEnv` is true.
        --- Omitted, and with `clearEnv` unset, the child inherits everything.
        env: {string: string}
        --- Start the child's environment empty rather than inherited, so
        --- `env` is the whole of what it sees. Optional.
        clearEnv: boolean
        --- Fold the child's error output into `output` instead of keeping it
        --- in `errorOutput`. Optional; separate by default, because a tool's
        --- diagnostics interleaved into its output corrupt anything parsing
        --- that output, and the diagnostics are what you want when it fails.
        mergeStderr: boolean
        --- Bytes written to the child's standard input, which is closed once
        --- they are through. Omitted closes it immediately, so a child reading
        --- to end of input sees one rather than waiting. Optional.
        input: string
        --- Kill the child forcibly after this many milliseconds. Omitted lets
        --- it run as long as it likes. Optional.
        timeoutMs: integer
    end

    --- What a child that ran leaves behind.
    ---
    --- Everything here is meaningless before the child ends, which is why none
    --- of it is on the future: a run in flight is a `Future<ProcessResult>` reading
    --- "pending" and a run that ended is the same future carrying one of
    --- these. The one thing worth knowing in between is the child's process id,
    --- and `processResult` answers that from the runner's own bookkeeping.
    record ProcessResult
        --- The program and its arguments, as given.
        args: {string}
        --- The child's process id.
        pid: integer
        --- The child's exit code, or the negated signal that ended it.
        exitCode: integer
        --- Everything the child wrote to standard output.
        output: string
        --- Everything it wrote to standard error, or "" when `mergeStderr`
        --- folded that into `output`.
        errorOutput: string

        --- Whether the child reported success.
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
    --- Nothing here blocks. The future reads "pending" until `updateProcesses`, or
    --- a `wait` on it, takes the worker's answer.
    ---
    --- @param options Read here and sent to the worker, so a later edit to the
    ---     same table does not reach the child. Starting the runner is part of
    ---     this call when nothing has yet.
    --- @return A future that settles "ready" with the result when the child
    ---     ends, however it ended: a non-zero exit is still "ready", and
    ---     `succeeded` is what distinguishes them. It settles "failed" only
    ---     when the child could not be started, and "canceled" when it was
    ---     killed.
    runProcess: function(options: ProcessOptions): Future<ProcessResult>

    --- The record a run fills in, whatever became of it.
    ---
    --- The same object the future carries on "ready", reachable in the two
    --- cases where the future does not carry it. Before the child ends, so
    --- `pid` can be read as soon as it has started, which is the one thing
    --- about a run that means anything before there is an answer. And after a
    --- child was killed, which settles "canceled" with no value but does not
    --- throw away what the child managed to say first.
    ---
    --- The runner's bookkeeping rather than the caller's, which is why it is a
    --- function here rather than a field on the future: a future carries no
    --- fields of any subsystem's own.
    ---
    --- Nil for a run that never started, which has nothing to report, and for
    --- anything that is not a run from here.
    ---
    --- @param run A future `runProcess` handed out. Any other future answers nil
    ---     rather than raising.
    --- @return The runner's own record, not a copy, so it fills in as the child
    ---     runs and the same table is what the future carries when it settles.
    processResult: function(run: Future<ProcessResult>): Result

    --- Asks the worker to end a child.
    ---
    --- Queued rather than immediate: every process call belongs to the worker,
    --- so this is picked up on its next pass. Gentle by default, which a child
    --- may ignore; `force` cannot be refused but leaves whatever it was writing
    --- half written. The future settles "canceled" when the child goes.
    ---
    --- `run:cancel()` is the other spelling, and it counts holders: it ends the
    --- child only when the last consumer of the future has given it up. This
    --- one ends the child whoever else is watching.
    ---
    --- @param run A future `runProcess` handed out. One that has already settled
    ---     is ignored, so this is safe to call on a race it lost.
    --- @param force Sends the signal a child cannot handle. Defaults to false,
    ---     which asks and may be refused.
    killProcess: function(run: Future<ProcessResult>, force?: boolean)

    --- Takes whatever the worker has answered. Call once per frame.
    --- @return How many runs finished.
    updateProcesses: function(): integer

    --- Runs that have not answered yet.
    ---
    --- @return Every run in flight in this process, not one caller's, and
    ---     counting a child that has been asked to die but has not yet.
    pendingProcesses: function(): integer

    --- Starts the runner worker.
    ---
    --- Called for you by the first `run`, so a process that never shells out
    --- never starts a thread. Call it directly to pay that cost up front, or to
    --- give the worker a module path other than this state's.
    ---
    --- @param luaPath Where the worker finds its modules. Defaults to this
    ---     state's own, which is right whenever the two run from the same
    ---     tree. Only read on the call that actually starts the worker, so
    ---     passing it to a second call changes nothing.
    installProcessRunner: function(luaPath?: string)

    --- Whether the runner worker is running.
    ---
    --- @return A fact about the process rather than about any world. False
    ---     costs nothing to act on: `run` starts the worker itself.
    processRunnerInstalled: function(): boolean

    --- Ends every child still running and stops the worker.
    ---
    --- Gentle first, then forced, because a child that is mid-write deserves
    --- the chance to finish the line and a teardown that waits forever deserves
    --- nothing. What it does not do is walk away: a detached child outlives the
    --- process that started it, and the worker still blocked on it would be a
    --- thread running inside a library about to be unmapped, which this
    --- codebase has already paid for once.
    ---
    --- Every future still in flight ends at "canceled", including one whose
    --- child the kernel never reaped. Leaving those pending would be a handle
    --- that reads "still running" for the rest of the process against a runner
    --- that no longer exists.
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

local MESSAGE_FLAGS <const>: {string: integer} = {
    error = K.SDL_MESSAGEBOX_ERROR,
    warning = K.SDL_MESSAGEBOX_WARNING,
    info = K.SDL_MESSAGEBOX_INFORMATION,
}

--- Opens a URL with the operating system's preferred handler.
function system.openURL(url: string): boolean, string
    if url == nil or url == "" then
        return false, "a URL is required"
    end
    if not C.SDL_OpenURL(url) then
        return false, sdl.error()
    end
    return true, nil
end

--- Preferred locales in the user's priority order.
function system.preferredLocales(): {Locale}
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

--- Current battery or external-power state.
function system.power(): Power
    secondsOut[0], percentOut[0] = -1, -1
    local state = tonumber(C.SDL_GetPowerInfo(secondsOut, percentOut)) as integer
    return {
        state = POWER_STATES[state] or "unknown",
        seconds = secondsOut[0] as integer,
        percent = percentOut[0] as integer,
    }
end

--- Shows a native informational, warning or error dialog.
function system.messageBox(kind: string, title: string, message: string, window?: Window): boolean, string
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

local dialogSource <const> = setmetatable({
    sliceMs = 16,
    defaultWaitMs = 300000,
} as DialogSource, DialogSourceMT)

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
function system.openFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(
        D.tecsDialogOpenFile(window, names, patterns, count, given.defaultLocation, given.multiple == true)
    )
end

--- Opens a native save-file picker. At most one path is returned.
function system.saveFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogSaveFile(window, names, patterns, count, given.defaultLocation))
end

--- Opens a native folder picker.
function system.openFolder(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogOpenFolder(window, given.defaultLocation, given.multiple == true))
end

--- Settles file and folder dialogs whose native callback has answered.
---
--- `Application` calls this every frame. It is public for a headless tool that
--- creates dialogs without an application.
function system.updateDialogs(): integer
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

--- Whether LuaJIT is compiling rather than interpreting.
---
--- Reached dynamically so a build whose `jit` module was stripped reports
--- honestly instead of failing to load.
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

--- Forgets the cached answer. A platform change is noticed without this.
function system.resetCapabilities()
    resolved = nil
end

--- Reads the capabilities of the running build.
---
--- Cached, since none of these change while a platform is installed. The cache
--- is keyed on the platform generation, so installing one drops it without
--- anybody calling `resetCapabilities`.
--- @return The same table on every call until the platform changes. Shared,
---     so a caller that means to keep it does not also mean to edit it.
function system.capabilities(): Capabilities
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

    local runtimeShaders <const> = shadercompiler.available()
    resolved = {
        target = platform,
        architecture = ffi.arch,
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

--- Converts a string SDL allocated and frees it.
---
--- Nil is not expected from any of these calls, since SDL answers a failed
--- read with an allocated empty string, and is handled because a null
--- dereference is a worse way to learn otherwise.
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
        error(("tecs: system.%s needs a string"):format(what), 3)
    end
end

--- Whether there is a clipboard to read at all.
---
--- False in a process that never brought up video, where every other function
--- here answers empty or false. Distinguishes that from a clipboard that is
--- simply empty, which no other return value can.
function system.clipboardAvailable(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- The clipboard's text, or an empty string when it holds none.
---
--- Empty is also the answer when the clipboard holds something that is not
--- text, and when there is no video. Ask `hasClipboardText` to tell those from text
--- that is genuinely empty.
function system.clipboardText(): string
    if not system.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetClipboardText())
end

--- Puts `text` on the clipboard, replacing whatever was there.
---
--- SDL copies it, so the string is not retained here. Returns false when the
--- platform refused, which includes having no video.
function system.setClipboardText(text: string): boolean
    required(text, "setClipboardText")
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_SetClipboardText(text) as boolean
end

--- Whether the clipboard holds text.
---
--- Cheaper than reading it: no allocation crosses the boundary, and on a
--- platform where a read negotiates with the owning application, no
--- negotiation happens.
function system.hasClipboardText(): boolean
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardText() as boolean
end

--- Withdraws what this application put on the system.
---
--- The clipboard is left empty rather than restored to what preceded the
--- write, because nothing anywhere remembers what that was.
function system.clearClipboard(): boolean
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_ClearClipboardData() as boolean
end

--- Mime types the clipboard currently offers, in the order SDL reports them.
---
--- The same list `clipboardUpdate` carries, for a caller that wants to ask
--- rather than wait to be told. Empty when the clipboard is empty.
function system.clipboardMimeTypes(): {string}
    local found: {string} = {}
    if not system.clipboardAvailable() then
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

--- Whether the clipboard offers `mimeType`.
function system.hasClipboardData(mimeType: string): boolean
    required(mimeType, "hasClipboardData")
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardData(mimeType) as boolean
end

--- The clipboard's bytes for `mimeType`, or nil when it offers none.
---
--- Nil rather than an empty string, because a mime type can be offered with no
--- bytes behind it and that is not the same as not being offered.
function system.clipboardData(mimeType: string): string
    required(mimeType, "clipboardData")
    if not system.clipboardAvailable() then
        return nil
    end

    local bytes = C.SDL_GetClipboardData(mimeType, sizeOut)
    if bytes == nil then
        return nil
    end
    local blob = loader.toBytes(bytes, tonumber(sizeOut[0]) as integer)
    C.SDL_free(bytes)
    return blob
end

--- The primary selection's text, or an empty string when it holds none.
function system.primarySelection(): string
    if not system.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetPrimarySelectionText())
end

--- Puts `text` in the primary selection.
---
--- Succeeds on a platform that has no primary selection, where SDL keeps the
--- value for this process and nothing else can read it.
function system.setPrimarySelection(text: string): boolean
    required(text, "setPrimarySelection")
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_SetPrimarySelectionText(text) as boolean
end

--- Whether the primary selection holds text.
function system.hasPrimarySelection(): boolean
    if not system.clipboardAvailable() then
        return false
    end
    return C.SDL_HasPrimarySelectionText() as boolean
end

local type Result = system.ProcessResult
local type Options = system.ProcessOptions

local ResultMT <const>: metatable<Result> = {__index = Result}

--- How long a wait on a run spends when the caller names nothing.
---
--- Longer than a decode's, because a child process is a different order of
--- work. It lives on the source, which is what lets the two keep different
--- defaults without a second convention.
local DEFAULT_WAIT_MS <const> = 30000

--- How long `shutdown` gives a child to end gently before forcing it.
local DEFAULT_GRACE_MS <const> = 250

--- How long `shutdown` waits for a forced kill to be reaped.
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
--- Every run's result by its future, which outlives the entry because a child
--- that was killed settles with no value and what it wrote is still worth
--- having. Weak in its keys, so it holds nothing the caller has let go of.
local results <const>: {Future<Result>: Result} = setmetatable({} as {Future<Result>: Result}, {__mode = "k"})
local pendingCount = 0
local nextId = 1
local worker: workers.Worker = nil

function system.installProcessRunner(luaPath?: string)
    if worker ~= nil then
        return
    end
    worker = workers.spawn({
        source = RUNNER,
        luaPath = luaPath or package.path,
    })
end

function system.processRunnerInstalled(): boolean
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
--- `system.killProcess(run, false)`, which is that question spelled out.
function Runner:cancel(future: Future<any>)
    local entry = byFuture[future as Future<Result>]
    if entry == nil or worker == nil then
        return
    end
    worker:send({kind = "kill", id = entry.id, force = true})
end

local runner <const> = setmetatable({
    -- Both live here rather than in `Future`, which is what lets a child
    -- process keep a longer default than a decode without a second convention.
    sliceMs = SLICE_MS,
    defaultWaitMs = DEFAULT_WAIT_MS,
} as Runner, RunnerMT)

local source <const> = runner as Future.Source

-------------------------------------------------------------------------------
-- Running
-------------------------------------------------------------------------------

function system.runProcess(options: Options): Future<Result>
    if options == nil or options.args == nil or #options.args == 0 then
        error("tecs: system.runProcess needs args, starting with the program", 2)
    end
    for index = 1, #options.args do
        if type(options.args[index]) ~= "string" then
            error(("tecs: system.runProcess args[%d] is not a string"):format(index), 2)
        end
    end

    system.installProcessRunner()

    local id = nextId
    nextId = nextId + 1

    local future = Future.pending(source) as Future<Result>
    local entry: Entry = {
        id = id,
        future = future,
        result = setmetatable({
            args = options.args,
            pid = 0,
            exitCode = 0,
            output = "",
            errorOutput = "",
        } as Result, ResultMT),
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

function system.processResult(run: Future<Result>): Result
    if run == nil then
        return nil
    end
    return results[run]
end

function system.killProcess(run: Future<Result>, force?: boolean)
    if worker == nil or run == nil then
        return
    end
    local entry = byFuture[run]
    if entry == nil then
        return
    end
    worker:send({kind = "kill", id = entry.id, force = force == true})
end

function system.updateProcesses(): integer
    return runner:poll()
end

function system.pendingProcesses(): integer
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

function system.shutdownProcesses(graceMs?: number)
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

return system
