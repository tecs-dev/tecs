--- Child processes, run without stalling a frame.
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
--- `proc.run` serves the child whose output you want when it finishes:
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
--- `proc.shutdown` therefore kills rather than detaching or reaping. Reaping
--- alone has no bound, and a child that never exits parks teardown; detaching
--- leaves a thread running inside a library the process is about to unmap,
--- which is the failure `loader`'s `RTLD_NODELETE` already exists for. Killing
--- is gentle first and forced after a grace period, and a forced kill is not
--- refusable, so the join that follows is bounded by the kernel reaping the
--- child.
---
--- ## Failure is a status
---
--- A program that cannot be started resolves the handle at `"failed"` with
--- `error` set, rather than raising. A caller that shells out is already
--- branching on the exit code, and a spawn that failed is one more branch on
--- the same value; a raise would be the only path in the module that has to be
--- wrapped.
---
--- ## Headless
---
--- SDL's process API needs no subsystem initialised, and nothing here
--- initialises one. This side does not reach SDL at all: the whole binding is
--- inside the worker's source, so a state that only ever queues runs loads the
--- worker library and nothing else. That is the point, since this is one of
--- the few subsystems more useful without a window than with one; it works
--- under a plain interpreter with no video, no device and no host.

local workers <const> = require("tecs.workers")

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

local record proc
    --- What to run, and what the child inherits.
    record Options
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

    --- A run in flight, or one that has finished.
    record Proc
        --- "running", "exited", "killed", or "failed". A child that ran is
        --- "exited" whatever its exit code; "killed" means this process ended
        --- it, through `kill`, a timeout, or shutdown; "failed" means it never
        --- started.
        status: string
        --- The program and its arguments, as given.
        args: {string}
        --- The child's process id, or 0 before it has started and for a run
        --- that failed to start.
        pid: integer
        --- The child's exit code, or the negated signal that ended it. Zero
        --- until the run finishes.
        exitCode: integer
        --- Everything the child wrote to standard output.
        output: string
        --- Everything it wrote to standard error, or "" when `mergeStderr`
        --- folded that into `output`.
        errorOutput: string
        --- Why the run failed or was killed. Nil for a child that exited on
        --- its own, whatever its exit code.
        error: string

        --- Id the worker answers with.
        _id: integer

        --- Whether the child ran to completion and reported success.
        succeeded: function(self: Proc): boolean

        --- Whether the child is still going.
        isRunning: function(self: Proc): boolean

        --- Asks the worker to end the child.
        ---
        --- Queued rather than immediate: every process call belongs to the
        --- worker, so this is picked up on its next pass. Gentle by default,
        --- which a child may ignore; `force` cannot be refused but leaves
        --- whatever it was writing half written.
        kill: function(self: Proc, force?: boolean)

        --- Blocks until this run finishes, pumping the worker.
        ---
        --- For startup, tools and tests. A frame calls `proc.update` instead.
        --- @param timeoutMs How long to wait. Defaults to 30000. Running out
        ---     leaves the handle at "running"; it does not kill the child.
        --- @return This handle.
        wait: function(self: Proc, timeoutMs?: number): Proc
    end
end

local type Proc = proc.Proc
local type Options = proc.Options

local ProcMT <const>: metatable<Proc> = { __index = Proc }

--- How long `Proc:wait` waits when the caller names nothing.
local DEFAULT_WAIT_MS <const> = 30000

--- How long `shutdown` gives a child to end gently before forcing it.
local DEFAULT_GRACE_MS <const> = 250

--- How long `shutdown` waits for a forced kill to be reaped.
local FORCED_WAIT_MS <const> = 5000

--- Milliseconds spent in one blocking pump.
local PUMP_MS <const> = 8

local pending: {integer: Proc} = {}
local pendingCount = 0
local nextId = 1
local worker: workers.Worker = nil

--- Starts the runner worker.
---
--- Called for you by the first `run`, so a process that never shells out never
--- starts a thread. Call it directly to pay that cost up front, or to give the
--- worker a module path other than this state's.
function proc.install(luaPath?: string)
    if worker ~= nil then return end
    worker = workers.spawn({
        source = RUNNER,
        luaPath = luaPath or package.path,
    })
end

--- Whether the runner worker is running.
function proc.installed(): boolean
    return worker ~= nil
end

--- Runs a program and returns its handle immediately.
---
--- Nothing here blocks. The handle reports "running" until `proc.update`, or a
--- `wait`, takes the worker's answer.
function proc.run(options: Options): Proc
    if options == nil or options.args == nil or #options.args == 0 then
        error("tecs: proc.run needs args, starting with the program", 2)
    end
    for index = 1, #options.args do
        if type(options.args[index]) ~= "string" then
            error(("tecs: proc.run args[%d] is not a string"):format(index), 2)
        end
    end

    proc.install()

    local handle = setmetatable({
        status = "running", args = options.args, pid = 0, exitCode = 0,
        output = "", errorOutput = "",
    } as Proc, ProcMT)

    local id = nextId
    nextId = nextId + 1
    handle._id = id
    pending[id] = handle
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
    return handle
end

--- Folds one worker message into its handle.
---
--- @return Whether it was the message that ended a run.
local function complete(result: {string: any}): boolean
    local handle = pending[result.id as integer]
    if handle == nil then return false end

    if result.started == true then
        handle.pid = result.pid as integer
        return false
    end

    pending[handle._id] = nil
    pendingCount = pendingCount - 1

    if result.failed == true then
        handle.status = "failed"
        handle.error = result.error as string
        return true
    end

    handle.exitCode = result.exitCode as integer
    handle.output = result.output as string
    handle.errorOutput = result.errorOutput as string
    if result.killed == true then
        handle.status = "killed"
        if result.timedOut == true then
            handle.error = "timed out"
        else
            handle.error = "killed"
        end
        return true
    end
    handle.status = "exited"
    return true
end

--- Takes whatever the worker has answered. Call once per frame.
--- @return How many runs finished.
function proc.update(): integer
    if worker == nil then return 0 end
    local finished = 0
    while true do
        local result = worker:receive(0)
        if result == nil then break end
        if complete(result as {string: any}) then finished = finished + 1 end
    end
    return finished
end

--- Runs that have not answered yet.
function proc.pending(): integer
    return pendingCount
end

--- Waits up to `ms` for one message and folds it in. Shared by everything here
--- that blocks, so there is one description of how a wait is spent.
local function pump(ms: number)
    if worker == nil then return end
    local result = worker:receive(ms)
    if result ~= nil then complete(result as {string: any}) end
end

function Proc:succeeded(): boolean
    return self.status == "exited" and self.exitCode == 0
end

function Proc:isRunning(): boolean
    return self.status == "running"
end

function Proc:kill(force?: boolean)
    if worker == nil or self.status ~= "running" then return end
    worker:send({ kind = "kill", id = self._id, force = force == true })
end

function Proc:wait(timeoutMs?: number): Proc
    local remaining = timeoutMs or DEFAULT_WAIT_MS
    while self.status == "running" and remaining > 0 do
        pump(PUMP_MS)
        remaining = remaining - PUMP_MS
    end
    return self
end

--- Blocks until every run in flight has finished.
---
--- For tools and tests. A frame polls `update` instead.
function proc.waitAll(timeoutMs?: number)
    local remaining = timeoutMs or DEFAULT_WAIT_MS
    while pendingCount > 0 and remaining > 0 do
        pump(PUMP_MS)
        remaining = remaining - PUMP_MS
    end
end

--- Ends every child still running and stops the worker.
---
--- Gentle first, then forced, because a child that is mid-write deserves the
--- chance to finish the line and a teardown that waits forever deserves
--- nothing. What it does not do is walk away: a detached child outlives the
--- process that started it, and the worker still blocked on it would be a
--- thread running inside a library about to be unmapped, which this codebase
--- has already paid for once.
---
--- Handles for children that were still running end at "killed".
--- @param graceMs How long a child gets to end gently. Defaults to 250.
function proc.shutdown(graceMs?: number)
    if worker == nil then return end

    if pendingCount > 0 then
        for _, handle in pairs(pending) do handle:kill(false) end
        local remaining = graceMs or DEFAULT_GRACE_MS
        while pendingCount > 0 and remaining > 0 do
            pump(PUMP_MS)
            remaining = remaining - PUMP_MS
        end
    end

    if pendingCount > 0 then
        for _, handle in pairs(pending) do handle:kill(true) end
        local remaining = FORCED_WAIT_MS
        while pendingCount > 0 and remaining > 0 do
            pump(PUMP_MS)
            remaining = remaining - PUMP_MS
        end
    end

    -- The worker leaves its loop when its inbox closes and nothing is live,
    -- and a forced kill is not something a child can refuse, so by here it has
    -- nothing left to hold. Anything still pending is a handle whose child the
    -- kernel has not reaped, which no amount of further waiting here fixes.
    worker:stop()
    worker = nil
    pending = {}
    pendingCount = 0
end

return proc
