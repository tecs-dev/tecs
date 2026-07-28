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
--- `"cancelled"` means this process ended it, through `kill`, a timeout, or
--- shutdown.
---
--- ## Headless
---
--- SDL's process API needs no subsystem initialised, and nothing here
--- initialises one. No process call is made on this side: the whole binding is
--- inside the worker's source, so a state that only ever queues runs starts no
--- child of its own. That is the point, since this is one of the few
--- subsystems more useful without a window than with one; it works under a
--- plain interpreter with no video, no device and no host.

local workers <const> = require("tecs.workers")
local time <const> = require("tecs.platform.time")
local Future <const> = require("tecs.Future")

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

    --- What a child that ran leaves behind.
    ---
    --- Everything here is meaningless before the child ends, which is why none
    --- of it is on the future: a run in flight is a `Future<Result>` reading
    --- "pending" and a run that ended is the same future carrying one of
    --- these. The one thing worth knowing in between is the child's process id,
    --- and `proc.pid` answers that from the runner's own bookkeeping.
    record Result
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
        succeeded: function(self: Result): boolean
    end

    --- Runs a program and answers a future for it, immediately.
    ---
    --- Nothing here blocks. The future reads "pending" until `proc.update`, or
    --- a `wait` on it, takes the worker's answer.
    ---
    --- @param options Read here and sent to the worker, so a later edit to the
    ---     same table does not reach the child. Starting the runner is part of
    ---     this call when nothing has yet.
    --- @return A future that settles "ready" with the result when the child
    ---     ends, however it ended: a non-zero exit is still "ready", and
    ---     `succeeded` is what distinguishes them. It settles "failed" only
    ---     when the child could not be started, and "cancelled" when it was
    ---     killed.
    run: function(options: Options): Future<Result>

    --- The record a run fills in, whatever became of it.
    ---
    --- The same object the future carries on "ready", reachable in the two
    --- cases where the future does not carry it. Before the child ends, so
    --- `pid` can be read as soon as it has started, which is the one thing
    --- about a run that means anything before there is an answer. And after a
    --- child was killed, which settles "cancelled" with no value but does not
    --- throw away what the child managed to say first.
    ---
    --- The runner's bookkeeping rather than the caller's, which is why it is a
    --- function here rather than a field on the future: a future carries no
    --- fields of any subsystem's own.
    ---
    --- Nil for a run that never started, which has nothing to report, and for
    --- anything that is not a run from here.
    ---
    --- @param run A future `proc.run` handed out. Any other future answers nil
    ---     rather than raising.
    --- @return The runner's own record, not a copy, so it fills in as the child
    ---     runs and the same table is what the future carries when it settles.
    result: function(run: Future<Result>): Result

    --- Asks the worker to end a child.
    ---
    --- Queued rather than immediate: every process call belongs to the worker,
    --- so this is picked up on its next pass. Gentle by default, which a child
    --- may ignore; `force` cannot be refused but leaves whatever it was writing
    --- half written. The future settles "cancelled" when the child goes.
    ---
    --- `run:cancel()` is the other spelling, and it counts holders: it ends the
    --- child only when the last consumer of the future has given it up. This
    --- one ends the child whoever else is watching.
    ---
    --- @param run A future `proc.run` handed out. One that has already settled
    ---     is ignored, so this is safe to call on a race it lost.
    --- @param force Sends the signal a child cannot handle. Defaults to false,
    ---     which asks and may be refused.
    kill: function(run: Future<Result>, force?: boolean)

    --- Takes whatever the worker has answered. Call once per frame.
    --- @return How many runs finished.
    update: function(): integer

    --- Runs that have not answered yet.
    ---
    --- @return Every run in flight in this process, not one caller's, and
    ---     counting a child that has been asked to die but has not yet.
    pending: function(): integer

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
    install: function(luaPath?: string)

    --- Whether the runner worker is running.
    ---
    --- @return A fact about the process rather than about any world. False
    ---     costs nothing to act on: `run` starts the worker itself.
    installed: function(): boolean

    --- Ends every child still running and stops the worker.
    ---
    --- Gentle first, then forced, because a child that is mid-write deserves
    --- the chance to finish the line and a teardown that waits forever deserves
    --- nothing. What it does not do is walk away: a detached child outlives the
    --- process that started it, and the worker still blocked on it would be a
    --- thread running inside a library about to be unmapped, which this
    --- codebase has already paid for once.
    ---
    --- Every future still in flight ends at "cancelled", including one whose
    --- child the kernel never reaped. Leaving those pending would be a handle
    --- that reads "still running" for the rest of the process against a runner
    --- that no longer exists.
    --- @param graceMs How long a child gets to end gently. Defaults to 250.
    shutdown: function(graceMs?: number)
end

local type Result = proc.Result
local type Options = proc.Options

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

function proc.install(luaPath?: string)
    if worker ~= nil then
        return
    end
    worker = workers.spawn({
        source = RUNNER,
        luaPath = luaPath or package.path,
    })
end

function proc.installed(): boolean
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
--- `proc.kill(run, false)`, which is that question spelled out.
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

function proc.run(options: Options): Future<Result>
    if options == nil or options.args == nil or #options.args == 0 then
        error("tecs: proc.run needs args, starting with the program", 2)
    end
    for index = 1, #options.args do
        if type(options.args[index]) ~= "string" then
            error(("tecs: proc.run args[%d] is not a string"):format(index), 2)
        end
    end

    proc.install()

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

function proc.result(run: Future<Result>): Result
    if run == nil then
        return nil
    end
    return results[run]
end

function proc.kill(run: Future<Result>, force?: boolean)
    if worker == nil or run == nil then
        return
    end
    local entry = byFuture[run]
    if entry == nil then
        return
    end
    worker:send({kind = "kill", id = entry.id, force = force == true})
end

function proc.update(): integer
    return runner:poll()
end

function proc.pending(): integer
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

function proc.shutdown(graceMs?: number)
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

return proc
