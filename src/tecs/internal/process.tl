--[=[
Implements caller-owned child processes and their nonblocking SDL pipes.

SDL creates, reads, writes, polls, terminates, and reaps every child. No Lua
callback crosses the native boundary, and no worker state copies accumulated
output back into this one. The public declarations live in
`tecs.io.processtypes` so this implementation can sit below the public process
module without a require cycle. `tecs.io.Process` exposes only the constructor;
the runtime lifecycle hooks remain internal here.
]=]

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local Completion <const> = require("tecs.internal.completion")
local task <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")
local time <const> = require("tecs.platform.time")
local buffer <const> = require("tecs.io.buffer")
local type types = require("tecs.io.types")
local type processtypes = require("tecs.io.processtypes")
local type Path = require("tecs.io.Path")

local C <const> = sdl.C
local K <const> = sdl.K
local floor <const> = math.floor
local min <const> = math.min

local type IOBuffer = types.Buffer
local type ByteView = types.ByteView
local type ProcessOptions = processtypes.ProcessOptions
local type CommunicateOptions = processtypes.CommunicateOptions
local type ProcessExit = processtypes.ProcessExit
local type ProcessResult = processtypes.ProcessResult
local type ProcessReader = processtypes.ProcessReader
local type ProcessWriter = processtypes.ProcessWriter
local type Process = processtypes.Process
local type ExitCompletion = Completion<ProcessExit>
local type Source = Completion.Source

local DEFAULT_READ_BYTES <const> = 16 * 1024
local MAX_READ_BYTES <const> = 64 * 1024
local DEFAULT_MAX_OUTPUT_BYTES <const> = 256 * 1024 * 1024
local DEFAULT_WAIT_MS <const> = 30000
local DEFAULT_PIPE_TIMEOUT_MS <const> = 30000
local WAIT_SLICE_MS <const> = 8
local MAX_INTEGER <const> = 9007199254740991
local MAX_TIMEOUT_MS <const> = 2147483647
local PIPE_READ_TIMEOUT_REASON <const> = "the process produced no bytes within the reader's timeout"
local PIPE_WRITE_TIMEOUT_REASON <const> = "the process took no bytes within the writer's timeout"

local enum PipeKind
    "stdout"
    "stderr"
end

local record State
    handle: loader.CPtr
    input: loader.CPtr
    output: loader.CPtr
    errors: loader.CPtr
    running: boolean
    closed: boolean
    killed: boolean
    timedOut: boolean
    deadline: number
    exitCode: integer
    finished: ExitCompletion
    at: integer
end

local record Exit
    exitCode: integer
    killed: boolean
    timedOut: boolean
    succeeded: function(self: Exit): boolean
end

local record Result
    exit: Exit
    output: string
    errorOutput: string
    succeeded: function(self: Result): boolean
end

local record ReaderImpl is ProcessReader
    _state: State
    _kind: PipeKind
    _closed: boolean
    _eof: boolean
    _scratch: loader.CArray
    _capacity: integer
    _timeoutMs: integer
end

local record WriterImpl is ProcessWriter
    _state: State
    _closed: boolean
    _timeoutMs: integer
end

local record ProcessImpl
    pid: integer
    stdin: ProcessWriter
    stdout: ProcessReader
    stderr: ProcessReader
    _finished: ExitCompletion
    _state: State
end

local ExitMT <const>: metatable<Exit> = {__index = Exit}
local ResultMT <const>: metatable<Result> = {__index = Result}
local ReaderMT <const>: metatable<ReaderImpl> = {__index = ReaderImpl}
local WriterMT <const>: metatable<WriterImpl> = {__index = WriterImpl}
local ProcessMT <const>: metatable<ProcessImpl> = {__index = ProcessImpl}

local live <const>: {State} = {}
local count = 0
local exitOut <const> = loader.newArray("int[1]")

-- One parked pipe operation. A parked read wakes on every process poll and
-- parks again until its pipe produces bytes, so the readiness gate and its
-- cancellation closure are built once and recycled rather than rebuilt per
-- wake, which would allocate once per parked pipe per frame.
local record PipeWaiter
    active: boolean
    gate: task.Gate
    cancel: function()
end

local pipeWaiters: {PipeWaiter} = {}
local pipeWaiterCount = 0
local idleWaiters: {PipeWaiter} = {}
local idleWaiterCount = 0
local MAX_PIPE_WAITERS <const> = 1024
local MAX_IDLE_WAITERS <const> = 64

local source: Source
local pollRuntime: function(): integer

-- Registration is tracked with this flag rather than inferred from `count`,
-- because the count is also what `releaseSource` reads and a second
-- `runtime.register` under the same name raises.
local sourceRegistered = false

local function retainSource()
    if not sourceRegistered then
        sourceRegistered = true
        runtime.register("processes", 20, pollRuntime, nil)
    end
end

local function releaseSource()
    if sourceRegistered and count == 0 then
        sourceRegistered = false
        runtime.unregister("processes")
    end
end

local function integerIn(value: integer, low: integer, high: integer, what: string, level: integer): integer
    if type(value) ~= "number" or value ~= floor(value) or value < low or value > high then
        error(("tecs: %s must be an integer from %d through %d"):format(what, low, high), level)
    end
    return value
end

local function range(
    length: integer, offset: integer, countValue: integer, what: string, level: integer
): integer, integer
    offset = offset or 0
    if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > length then
        error(("tecs: %s offset is outside the source"):format(what), level)
    end
    if countValue == nil then
        countValue = length - offset
    elseif
        type(countValue) ~= "number"
        or countValue ~= floor(countValue)
        or countValue < 0
        or countValue > length - offset
    then
        error(("tecs: %s count is outside the source"):format(what), level)
    end
    return offset, countValue
end

local function streamFor(reader: ReaderImpl): loader.CPtr
    if reader._kind == "stdout" then
        return reader._state.output
    end
    return reader._state.errors
end

local function setStream(reader: ReaderImpl, value: loader.CPtr)
    if reader._kind == "stdout" then
        reader._state.output = value
    else
        reader._state.errors = value
    end
end

local function destroyWhenReleased(state: State)
    if state.handle == nil or state.running or state.input ~= nil or state.output ~= nil or state.errors ~= nil then
        return
    end
    local handle <const> = state.handle
    state.handle = nil
    ffi.gc(handle as ffi.CData, nil)
    C.SDL_DestroyProcess(handle)
end

local function closeInput(state: State): boolean, string
    if state.input == nil then
        return true
    end
    local input <const> = state.input
    state.input = nil
    if not C.SDL_CloseIO(input) then
        destroyWhenReleased(state)
        return false, sdl.error()
    end
    destroyWhenReleased(state)
    return true
end

local function removeLive(state: State)
    if state.at == 0 then
        return
    end
    local at <const> = state.at
    local last <const> = count
    local moved <const> = live[last]
    live[last] = nil
    count = count - 1
    if at < last then
        live[at] = moved
        moved.at = at
    end
    state.at = 0
    releaseSource()
end

function Exit:succeeded(): boolean
    return not self.killed and self.exitCode == 0
end

function Result:succeeded(): boolean
    return self.exit:succeeded()
end

local function settle(state: State, exitCode: integer): boolean
    if not state.running then
        return false
    end
    state.running = false
    state.exitCode = exitCode
    removeLive(state)
    closeInput(state)
    local answer <const> = setmetatable(
        {
            exitCode = exitCode,
            killed = state.killed,
            timedOut = state.timedOut,
        } as Exit,
        ExitMT
    )
    if state.finished.status == "pending" then
        state.finished:complete(answer as ProcessExit)
    end
    destroyWhenReleased(state)
    return true
end

local function pollState(state: State): boolean
    if not state.running then
        return false
    end
    if state.deadline ~= nil and not state.killed and time.now() * 1000.0 >= state.deadline then
        if C.SDL_KillProcess(state.handle, true) then
            state.killed = true
            state.timedOut = true
        end
    end
    if C.SDL_WaitProcess(state.handle, false, exitOut) then
        return settle(state, tonumber(exitOut[0]) as integer)
    end
    return false
end

local function pollAll(): integer
    local settled = 0
    local index = count
    while index >= 1 do
        if pollState(live[index]) then
            settled = settled + 1
        end
        index = index - 1
    end
    -- Completing a gate only queues its task, so no parked operation runs
    -- before this loop ends and none of them can append here while it does.
    local waiting <const> = pipeWaiterCount
    pipeWaiterCount = 0
    for waiterIndex = 1, waiting do
        local waiter <const> = pipeWaiters[waiterIndex]
        pipeWaiters[waiterIndex] = nil
        if waiter.active then
            waiter.active = false
            waiter.gate:complete(true)
        end
    end
    return settled
end

local record ProcessSource
    poll: function(self: ProcessSource): integer
    advance: function(self: ProcessSource, ms: number): integer
    sliceMs: number
    defaultWaitMs: number
end

local ProcessSourceMT <const>: metatable<ProcessSource> = {__index = ProcessSource}

function ProcessSource:poll(): integer
    return pollAll()
end

function ProcessSource:advance(ms: number): integer
    local deadline <const> = time.now() * 1000.0 + ms
    repeat
        local settled <const> = pollAll()
        if settled > 0 or ms <= 0 then
            return settled
        end
        local remaining <const> = deadline - time.now() * 1000.0
        if remaining <= 0 then
            return 0
        end
        C.SDL_Delay(floor(min(remaining, 1)) as integer)
    until false
end

source = setmetatable(
    {sliceMs = WAIT_SLICE_MS, defaultWaitMs = DEFAULT_WAIT_MS} as ProcessSource, ProcessSourceMT
) as Source
pollRuntime = pollAll

local function track(state: State)
    count = count + 1
    state.at = count
    live[count] = state
    retainSource()
end

local function closeReader(reader: ReaderImpl, eof: boolean)
    if reader._closed then
        return
    end
    reader._closed = true
    reader._eof = eof
    local stream <const> = streamFor(reader)
    setStream(reader, nil)
    if stream ~= nil then
        C.SDL_CloseIO(stream)
    end
    destroyWhenReleased(reader._state)
end

local function releaseWaiter(waiter: PipeWaiter)
    if idleWaiterCount >= MAX_IDLE_WAITERS then
        return
    end
    idleWaiterCount = idleWaiterCount + 1
    idleWaiters[idleWaiterCount] = waiter
end

local function acquireWaiter(): PipeWaiter
    if idleWaiterCount > 0 then
        local waiter <const> = idleWaiters[idleWaiterCount]
        idleWaiters[idleWaiterCount] = nil
        idleWaiterCount = idleWaiterCount - 1
        -- Completing a gate consumes its cancellation, so arm this one again.
        waiter.gate:reset(waiter.cancel)
        return waiter
    end
    local waiter: PipeWaiter = {active = false, gate = nil, cancel = nil}
    waiter.cancel = function() waiter.active = false end
    waiter.gate = task.newGate(waiter.cancel)
    return waiter
end

-- Waits for the next process poll and answers whether the caller may wait
-- again. `deadline` is a millisecond reading of the `time.now` clock, and an
-- absent deadline waits without a bound.
local function waitForPipe(what: string, deadline?: number): boolean
    local mode <const> = task.checkWait(what)
    if mode == "blocking" then
        source:advance(1)
        return deadline == nil or time.now() * 1000.0 < deadline
    end
    if pipeWaiterCount >= MAX_PIPE_WAITERS then
        error("tecs: too many process pipe operations are waiting", 3)
    end
    local waiter <const> = acquireWaiter()
    waiter.active = true
    pipeWaiterCount = pipeWaiterCount + 1
    pipeWaiters[pipeWaiterCount] = waiter
    local _ <const>, reason = waiter.gate:wait()
    -- The resumed call owns the waiter until here. A poll that returned it
    -- earlier could hand this gate to another parked read while the runtime
    -- still holds this one's cancellation, and canceling this call would then
    -- silence the wrong reader. A canceled call unwinds instead of arriving,
    -- so its waiter is collected rather than recycled.
    releaseWaiter(waiter)
    if reason ~= nil then
        error(reason, 3)
    end
    return deadline == nil or time.now() * 1000.0 < deadline
end

function ReaderImpl:isClosed(): boolean
    return self._closed or streamFor(self) == nil
end

function ReaderImpl:isEOF(): boolean
    return self._eof
end

function ReaderImpl:setTimeout(timeoutMs: integer)
    self._timeoutMs = integerIn(timeoutMs, 0, MAX_TIMEOUT_MS, "process reader timeout", 2)
end

local function available(reader: ReaderImpl, output: loader.BytePointer, countValue: integer): integer, string
    if reader._closed then
        return nil, "the process reader is closed"
    end
    local stream <const> = streamFor(reader)
    if stream == nil then
        return reader._eof and 0 or nil, reader._eof and nil or "the process reader is closed"
    end
    local got <const> = tonumber(C.SDL_ReadIO(stream, output, countValue)) as integer
    if got > 0 then
        return got
    end
    local status <const> = tonumber(C.SDL_GetIOStatus(stream)) as integer
    if status == tonumber(C.SDL_IO_STATUS_ERROR) then
        return nil, sdl.error()
    end
    if status == tonumber(C.SDL_IO_STATUS_EOF) or not reader._state.running then
        closeReader(reader, true)
        return 0
    end
    return nil
end

function ReaderImpl:_readAvailable(maxBytes?: integer): string, string
    local wanted <const> = integerIn(maxBytes or DEFAULT_READ_BYTES, 1, MAX_READ_BYTES, "process read size", 2)
    if wanted > self._capacity then
        self._scratch = loader.newArray("uint8_t[?]", wanted)
        self._capacity = wanted
    end
    local got <const>, reason = available(self, self._scratch as loader.BytePointer, wanted)
    if got == nil then
        return nil, reason
    end
    if got == 0 then
        return ""
    end
    return loader.toBytes(self._scratch as loader.CValue, got)
end

function ReaderImpl:read(maxBytes: integer): string, string
    local wanted <const> = min(math.max(1, maxBytes), MAX_READ_BYTES)
    local deadline: number
    while true do
        local bytes <const>, reason = self:_readAvailable(wanted)
        if bytes ~= nil or reason ~= nil then
            return bytes, reason
        end
        deadline = deadline or time.now() * 1000.0 + self._timeoutMs
        if not waitForPipe("process pipe read", deadline) then
            return nil, PIPE_READ_TIMEOUT_REASON
        end
    end
end

function ReaderImpl:_readAvailableInto(destination: IOBuffer, offset?: integer, maxBytes?: integer): integer, string
    local wanted <const> = integerIn(maxBytes or DEFAULT_READ_BYTES, 1, MAX_READ_BYTES, "process read size", 2)
    local at <const> = offset or 0
    if type(at) ~= "number" or at ~= floor(at) or at < 0 then
        error("tecs: process read offset must be a non-negative integer", 2)
    end
    local output <const>, previous = buffer.prepareWrite(destination, at, wanted)
    local got <const>, reason = available(self, output, wanted)
    if got == nil then
        destination:resize(previous)
        return nil, reason
    end
    buffer.commitWrite(destination, at, got, previous)
    return got
end

function ReaderImpl:readInto(destination: IOBuffer, offset?: integer, maxBytes?: integer): integer, string
    local deadline: number
    while true do
        local got <const>, reason = self:_readAvailableInto(destination, offset, maxBytes)
        if got ~= nil or reason ~= nil then
            return got, reason
        end
        deadline = deadline or time.now() * 1000.0 + self._timeoutMs
        if not waitForPipe("process pipe read", deadline) then
            return nil, PIPE_READ_TIMEOUT_REASON
        end
    end
end

function ReaderImpl:close(): boolean, string
    closeReader(self, false)
    return true
end

function WriterImpl:isClosed(): boolean
    return self._closed or self._state.input == nil
end

function WriterImpl:setTimeout(timeoutMs: integer)
    self._timeoutMs = integerIn(timeoutMs, 0, MAX_TIMEOUT_MS, "process writer timeout", 2)
end

local function writeAvailablePointer(
    writer: WriterImpl, pointer: loader.BytePointer, countValue: integer
): integer, string
    if writer._closed or writer._state.input == nil then
        return nil, "the process writer is closed"
    end
    if countValue == 0 then
        return 0
    end
    local wrote <const> = tonumber(C.SDL_WriteIO(writer._state.input, pointer, countValue)) as integer
    if wrote > 0 then
        return wrote
    end
    if tonumber(C.SDL_GetIOStatus(writer._state.input)) == tonumber(C.SDL_IO_STATUS_ERROR) then
        return nil, sdl.error()
    end
    if not writer._state.running then
        return nil, "the child closed standard input"
    end
    return nil
end

local function writeAll(writer: WriterImpl, pointer: loader.BytePointer, length: integer): integer, string
    if length == 0 then
        return writeAvailablePointer(writer, pointer, 0)
    end
    local at = 0
    local deadline: number
    while at < length do
        local wrote <const>, reason = writeAvailablePointer(writer, pointer + at, length - at)
        if wrote == nil then
            if reason ~= nil then
                return nil, reason
            end
            deadline = deadline or time.now() * 1000.0 + writer._timeoutMs
            if not waitForPipe("process pipe write", deadline) then
                return nil, PIPE_WRITE_TIMEOUT_REASON
            end
        else
            at = at + wrote
            -- The bound measures a stall rather than the whole call, so a child
            -- that keeps taking bytes keeps a long write alive.
            deadline = nil
        end
    end
    return length
end

function WriterImpl:write(bytes: string): boolean, string
    if type(bytes) ~= "string" then
        error("tecs: process write needs a byte string", 2)
    end
    local wrote <const>, reason = writeAll(self, ffi.cast("const uint8_t *", bytes) as loader.BytePointer, #bytes)
    return wrote ~= nil, reason
end

function WriterImpl:writeFrom(sourceBuffer: IOBuffer, offset?: integer, countValue?: integer): integer, string
    local at <const>, length = range(sourceBuffer:length(), offset, countValue, "process buffer write", 2)
    return writeAll(self, sourceBuffer:getFFIPointer() + at, length)
end

function WriterImpl:writeView(sourceView: ByteView, offset?: integer, countValue?: integer): integer, string
    if sourceView == nil or sourceView:isReleased() then
        error("tecs: process write needs an open io.ByteView", 2)
    end
    local at <const>, length = range(sourceView:length(), offset, countValue, "process view write", 2)
    return writeAll(self, sourceView:getFFIPointer() + at, length)
end

function WriterImpl:flush(): boolean, string
    if self:isClosed() then
        return false, "the process writer is closed"
    end
    return true
end

function WriterImpl:close(): boolean, string
    if self._closed then
        return true
    end
    self._closed = true
    return closeInput(self._state)
end

function ProcessImpl:isRunning(): boolean
    pollState(self._state)
    return self._state.running
end

-- The exit completion belongs to the process for the whole of its life, and
-- several callers may wait on one child. `newProcess` retains it for the
-- process, so each wait holds one subscription above that and a wait that gives
-- up releases only its own hold, leaving the completion the exit still has to
-- land in pending for every other caller.
function ProcessImpl:wait(): ProcessExit
    return task.awaitCompletion(self._finished as Completion<ProcessExit>, "process wait")
end

function ProcessImpl:kill(force?: boolean): boolean, string
    local state <const> = self._state
    if state.closed or not state.running then
        return true
    end
    if not C.SDL_KillProcess(state.handle, force == true) then
        return false, sdl.error()
    end
    state.killed = true
    return true
end

local function forceAndReap(state: State)
    if state.running then
        if C.SDL_KillProcess(state.handle, true) then
            state.killed = true
        end
        if C.SDL_WaitProcess(state.handle, true, exitOut) then
            settle(state, tonumber(exitOut[0]) as integer)
        else
            removeLive(state)
            state.running = false
            if state.finished.status == "pending" then
                state.finished:fail(sdl.error())
            end
        end
    end
end

local function closeState(state: State)
    if state.closed then
        return
    end
    state.closed = true
    forceAndReap(state)
    closeInput(state)
    if state.output ~= nil then
        local output <const> = state.output
        state.output = nil
        C.SDL_CloseIO(output)
    end
    if state.errors ~= nil then
        local errors <const> = state.errors
        state.errors = nil
        C.SDL_CloseIO(errors)
    end
    destroyWhenReleased(state)
end

function ProcessImpl:close(): boolean, string
    closeState(self._state)
    return true
end

local function byteRange(bytes: string | ByteView): loader.BytePointer, integer
    if type(bytes) == "string" then
        local text <const> = bytes as string
        return ffi.cast("const uint8_t *", text) as loader.BytePointer, #text
    end
    local view <const> = bytes as ByteView
    if view == nil or view:isReleased() then
        error("tecs: process communication needs a byte string or open io.Buffer or io.ByteView", 3)
    end
    return view:getFFIPointer(), view:length()
end

local function communicationFailure(
    state: State, output: IOBuffer, errors: IOBuffer, reason: string
): ProcessResult, string
    closeState(state)
    output:close()
    errors:close()
    return nil, reason
end

function ProcessImpl:communicate(options?: CommunicateOptions): ProcessResult, string
    local state <const> = self._state
    if state.closed then
        return nil, "the process is closed"
    end
    local given <const> = options or {} as CommunicateOptions
    local maximum <const> = integerIn(
        given.maxOutputBytes or DEFAULT_MAX_OUTPUT_BYTES, 0, MAX_INTEGER, "process maximum output", 2
    )
    local inputPointer: loader.BytePointer = nil
    local inputLength = 0
    if given.input ~= nil then
        if self.stdin == nil or (self.stdin as ProcessWriter):isClosed() then
            error("tecs: process communication input requires piped stdin", 2)
        end
        inputPointer, inputLength = byteRange(given.input)
    end

    local output <const> = buffer.new()
    local errors <const> = buffer.new()
    local inputAt = 0
    local stdoutEOF = self.stdout == nil
    local stderrEOF = self.stderr == nil

    while state.running or not stdoutEOF or not stderrEOF do
        local progressed = false

        if self.stdin ~= nil and not (self.stdin as ProcessWriter):isClosed() then
            if inputAt < inputLength then
                local wrote <const>, writeReason = writeAvailablePointer(
                    self.stdin as WriterImpl, inputPointer + inputAt, inputLength - inputAt
                )
                if wrote ~= nil then
                    inputAt = inputAt + wrote
                    progressed = true
                elseif writeReason ~= nil then
                    return communicationFailure(state, output, errors, writeReason)
                end
            end
            if inputAt >= inputLength then
                local closed <const>, closeReason = (self.stdin as ProcessWriter):close()
                if not closed then
                    return communicationFailure(state, output, errors, closeReason)
                end
                progressed = true
            end
        end

        if not stdoutEOF then
            while true do
                local got <const>, readReason = (self.stdout as ReaderImpl):_readAvailableInto(
                    output, output:length(), MAX_READ_BYTES
                )
                if got == nil then
                    if readReason ~= nil then
                        return communicationFailure(state, output, errors, readReason)
                    end
                    break
                end
                progressed = true
                if got == 0 then
                    stdoutEOF = true
                    break
                end
            end
        end

        if not stderrEOF then
            while true do
                local got <const>, readReason = (self.stderr as ReaderImpl):_readAvailableInto(
                    errors, errors:length(), MAX_READ_BYTES
                )
                if got == nil then
                    if readReason ~= nil then
                        return communicationFailure(state, output, errors, readReason)
                    end
                    break
                end
                progressed = true
                if got == 0 then
                    stderrEOF = true
                    break
                end
            end
        end

        if output:length() + errors:length() > maximum then
            return communicationFailure(state, output, errors, "process output exceeds the configured maximum")
        end

        if pollAll() > 0 then
            progressed = true
        end
        if not progressed then
            waitForPipe("process communication")
        end
    end

    if state.finished.status ~= "ready" then
        local reason <const> = state.finished.error or "the process did not produce an exit result"
        output:close()
        errors:close()
        return nil, reason
    end
    local answer <const> = setmetatable(
        {
            exit = state.finished.value,
            output = output:getString(),
            errorOutput = errors:getString(),
        } as Result,
        ResultMT
    )
    output:close()
    errors:close()
    return answer as ProcessResult
end

local INPUT_MODES <const>: {processtypes.ProcessInputMode: loader.CValue} = {
    pipe = C.SDL_PROCESS_STDIO_APP,
    inherit = C.SDL_PROCESS_STDIO_INHERITED,
    null = C.SDL_PROCESS_STDIO_NULL,
}

local OUTPUT_MODES <const>: {processtypes.ProcessOutputMode: loader.CValue} = {
    pipe = C.SDL_PROCESS_STDIO_APP,
    inherit = C.SDL_PROCESS_STDIO_INHERITED,
    null = C.SDL_PROCESS_STDIO_NULL,
}

local ERROR_MODES <const>: {processtypes.ProcessErrorMode: loader.CValue} = {
    pipe = C.SDL_PROCESS_STDIO_APP,
    inherit = C.SDL_PROCESS_STDIO_INHERITED,
    null = C.SDL_PROCESS_STDIO_NULL,
}

local function environmentFor(options: ProcessOptions): loader.CPtr, string
    if options.env == nil and not options.clearEnv then
        return nil
    end
    local environment <const> = C.SDL_CreateEnvironment(not options.clearEnv)
    if environment == nil then
        return nil, sdl.error()
    end
    if options.env ~= nil then
        for name, value in pairs(options.env) do
            if type(name) ~= "string" or type(value) ~= "string" then
                C.SDL_DestroyEnvironment(environment)
                error("tecs: process environment names and values must be strings", 3)
            end
            if not C.SDL_SetEnvironmentVariable(environment, name, value, true) then
                local reason <const> = sdl.error()
                C.SDL_DestroyEnvironment(environment)
                return nil, reason
            end
        end
    end
    return environment
end

local function newReader(state: State, kind: PipeKind): ProcessReader
    return setmetatable(
        {
            _state = state,
            _kind = kind,
            _closed = false,
            _eof = false,
            _scratch = nil,
            _capacity = 0,
            _timeoutMs = DEFAULT_PIPE_TIMEOUT_MS,
        } as ReaderImpl,
        ReaderMT
    ) as ProcessReader
end

local function newWriter(state: State): ProcessWriter
    return setmetatable(
        {_state = state, _closed = false, _timeoutMs = DEFAULT_PIPE_TIMEOUT_MS} as WriterImpl, WriterMT
    ) as ProcessWriter
end

local record process
    new: function(options: ProcessOptions): Process, string
    poll: function(): integer
    pending: function(): integer
    shutdown: function()
end

function process.new(options: ProcessOptions): Process, string
    if options == nil or options.args == nil or #options.args == 0 then
        error("tecs: io.Process.new needs args beginning with the program", 2)
    end
    for index = 1, #options.args do
        if type(options.args[index]) ~= "string" then
            error(("tecs: io.Process.new args[%d] must be a string"):format(index), 2)
        end
    end
    local stdinMode <const> = options.stdin or "pipe"
    local stdoutMode <const> = options.stdout or "pipe"
    local stderrMode <const> = options.stderr or "pipe"
    if INPUT_MODES[stdinMode] == nil then
        error("tecs: process stdin must be 'pipe', 'inherit', or 'null'", 2)
    end
    if OUTPUT_MODES[stdoutMode] == nil then
        error("tecs: process stdout must be 'pipe', 'inherit', or 'null'", 2)
    end
    if stderrMode ~= "stdout" and ERROR_MODES[stderrMode] == nil then
        error("tecs: process stderr must be 'pipe', 'inherit', 'null', or 'stdout'", 2)
    end
    if options.timeoutMs ~= nil then
        integerIn(options.timeoutMs, 0, MAX_TIMEOUT_MS, "process timeout", 2)
    end

    local argc <const> = #options.args
    local argv <const> = loader.newArray("const char *[?]", argc + 1)
    for index = 1, argc do
        argv[index - 1] = options.args[index]
    end
    argv[argc] = nil

    local properties <const> = C.SDL_CreateProperties()
    if tonumber(properties) == 0 then
        return nil, sdl.error()
    end
    C.SDL_SetPointerProperty(properties, K.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, argv)
    C.SDL_SetNumberProperty(properties, K.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, INPUT_MODES[stdinMode])
    C.SDL_SetNumberProperty(properties, K.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, OUTPUT_MODES[stdoutMode])
    if stderrMode == "stdout" then
        C.SDL_SetBooleanProperty(properties, K.SDL_PROP_PROCESS_CREATE_STDERR_TO_STDOUT_BOOLEAN, true)
    else
        C.SDL_SetNumberProperty(properties, K.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, ERROR_MODES[stderrMode])
    end
    if options.cwd ~= nil then
        local cwd = options.cwd
        if type(cwd) ~= "string" then
            cwd = (cwd as Path):toString()
        end
        C.SDL_SetStringProperty(properties, K.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd)
    end

    local environment <const>, environmentReason = environmentFor(options)
    if environmentReason ~= nil then
        C.SDL_DestroyProperties(properties)
        return nil, environmentReason
    end
    if environment ~= nil then
        C.SDL_SetPointerProperty(properties, K.SDL_PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, environment)
    end

    local handle = C.SDL_CreateProcessWithProperties(properties) as loader.CPtr
    C.SDL_DestroyProperties(properties)
    if environment ~= nil then
        C.SDL_DestroyEnvironment(environment)
    end
    if handle == nil then
        return nil, sdl.error()
    end
    handle = ffi.gc(handle as ffi.CData, C.SDL_DestroyProcess as function(ffi.CData)) as loader.CPtr

    local propertiesOut <const> = C.SDL_GetProcessProperties(handle)
    local errors: loader.CPtr = nil
    if stderrMode == "pipe" then
        errors = ffi.cast(
            "SDL_IOStream *", C.SDL_GetPointerProperty(propertiesOut, K.SDL_PROP_PROCESS_STDERR_POINTER, nil)
        ) as loader.CPtr
    end
    local state: State = {
        handle = handle,
        input = stdinMode == "pipe" and C.SDL_GetProcessInput(handle) or nil,
        output = stdoutMode == "pipe" and C.SDL_GetProcessOutput(handle) or nil,
        errors = errors,
        running = true,
        closed = false,
        killed = false,
        timedOut = false,
        deadline = options.timeoutMs ~= nil and time.now() * 1000.0 + options.timeoutMs or nil,
        exitCode = 0,
        finished = nil,
        at = 0,
    }
    state.finished = Completion.pending(source) as ExitCompletion
    -- The child owns its exit for as long as it runs, so the process holds this
    -- completion itself and no waiter that gives up can settle it.
    state.finished:retain()

    local value <const> = setmetatable(
        {
            pid = tonumber(C.SDL_GetNumberProperty(propertiesOut, K.SDL_PROP_PROCESS_PID_NUMBER, 0)) as integer,
            stdin = state.input ~= nil and newWriter(state) or nil,
            stdout = state.output ~= nil and newReader(state, "stdout") or nil,
            stderr = state.errors ~= nil and newReader(state, "stderr") or nil,
            _finished = state.finished,
            _state = state,
        } as ProcessImpl,
        ProcessMT
    )
    track(state)
    pollState(state)
    return value as Process
end

function process.poll(): integer
    return pollAll()
end

function process.pending(): integer
    return count
end

function process.shutdown()
    while count > 0 do
        closeState(live[count])
    end
end

return process
