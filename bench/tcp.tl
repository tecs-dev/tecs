--- Loopback TCP strings against reusable Buffers.
---
--- This benchmark holds one client/server connection pair open and measures
--- only complete queue, drain, and consume operations:
---
---   string  `TCPSocket:write` and `TCPSocket:read`.
---   buffer  `TCPSocket:writeFrom` and `TCPSocket:readInto`.
---   task    The same Buffer calls directly from two cooperative Tasks through
---           the process-wide readiness pump used by ordinary systems.
---
--- The Buffer row allocates its source and destination once, reserves the
--- destination once, and reuses both through warmup and measured samples.
--- `writeFrom` still makes the native send queue's ownership copy; it avoids
--- only the intermediate Lua string. The string fixture is also reused, while
--- each `read` necessarily returns a new Lua string.
---
--- The synchronous rows queue, fully drain, and consume each chunk before the
--- next one. The Task row keeps one writer and one reader active for the full
--- operation, which lets the native reactor pipeline them without blocking
--- the Lua thread. Every row leaves no bytes for the next sample. Hashing runs
--- before measured samples and is never inside their window.
---
--- Clean latency and Lua allocation share one pass with collection stopped.
--- The clock starts after the before-heap reading and stops before the
--- after-heap reading. Throughput is calculated for every sample, then p50 and
--- p05 use the nearest-rank rule. Native queue and socket allocations are not
--- part of the Lua heap delta, and writes do not force durable media.
---
--- TCP socket setup, asynchronous numeric resolution, port selection, accept,
--- teardown, and Buffer allocation are outside all warmup and measured
--- operations. The listener tries ports 27140 through 27239 and fails
--- actionably if another process owns the whole private range.
---
---   BENCH_TCP_CHUNK       Bytes in one queue/drain/consume turn. Defaults to
---                         65536 and cannot exceed 65536.
---   BENCH_TCP_CHUNKS      Turns in one operation. Defaults to 16.
---   BENCH_TCP_WARMUP      Untimed operations per row. Defaults to 120.
---   BENCH_TCP_SAMPLES     Measured operations per row. Defaults to 600.
---   BENCH_TCP_TIMEOUT_MS  Maximum wait for one drain, read, or setup step.
---                         Defaults to 2000.
---   BENCH_TCP_CASES       Comma-separated `string`, `buffer`, and `task`.
---                         Defaults to all three.
---   BENCH_TCP_VALIDATE    Set to 1 for correctness only, with no timings.
---
--- The xtask runs this benchmark under system LuaJIT without a window, GPU, or
--- frame loop. Sanitizer presets are rejected because the instrumented native
--- host does not execute this entry point. Run measurements only on a quiet
--- machine.

local getenv <const> = os.getenv
local char <const> = string.char
local format <const> = string.format
local concat <const> = table.concat
local sort <const> = table.sort
local ceil <const> = math.ceil
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local collect <const> = collectgarbage

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local sdl <const> = require("tecs.ffi.sdl3")
local type binaryIO = require("tecs.io")
local type iotypes = require("tecs.io.types")
local type tasks = require("tecs.internal.taskruntime")
local task <const> = require("tecs.internal.taskruntime")

local C <const> = sdl.C
local ioModule <const> = tecs.io
local runtime <const> = require("tecs.internal.runtime")
local data <const> = tecs.data
local time <const> = tecs.platform.time
local now <const> = time.now
local ticksNanoseconds <const> = time.ticksNanoseconds

local type IOBuffer = iotypes.Buffer
local type TCPSocket = binaryIO.TCPSocket

local VALIDATE <const> = getenv("BENCH_TCP_VALIDATE") == "1"
local MIB <const> = 1024.0 * 1024.0
local KIB <const> = 1024.0
local MAX_INTEGER <const> = 9007199254740991
local FIRST_PORT <const> = 27140
local PORT_COUNT <const> = 100
local MAX_CHUNK <const> = 64 * 1024
local CASE_NAMES <const>: {string: boolean} = {
    ["string"] = true,
    ["buffer"] = true,
    ["task"] = true,
}

local function integerEnvironment(name: string, default: integer): integer
    local text <const> = getenv(name)
    if text == nil then
        return default
    end
    local value <const> = tonumber(text)
    if value == nil or value ~= floor(value) or value < 0 or value > MAX_INTEGER then
        error(format("bench: %s must be a non-negative integer", name), 0)
    end
    return floor(value)
end

local CHUNK <const> = integerEnvironment("BENCH_TCP_CHUNK", MAX_CHUNK)
local CHUNKS <const> = integerEnvironment("BENCH_TCP_CHUNKS", 16)
local WARMUP <const> = integerEnvironment("BENCH_TCP_WARMUP", 120)
local SAMPLES <const> = integerEnvironment("BENCH_TCP_SAMPLES", 600)
local TIMEOUT_MS <const> = integerEnvironment("BENCH_TCP_TIMEOUT_MS", 10000)

if CHUNK < 1 or CHUNK > MAX_CHUNK then
    error(format("bench: BENCH_TCP_CHUNK must be from 1 to %d", MAX_CHUNK), 0)
end
if CHUNKS < 1 then
    error("bench: BENCH_TCP_CHUNKS must be a positive integer", 0)
end
if SAMPLES < 1 and not VALIDATE then
    error("bench: BENCH_TCP_SAMPLES must be a positive integer", 0)
end
if TIMEOUT_MS < 1 or TIMEOUT_MS > 2147483647 then
    error("bench: BENCH_TCP_TIMEOUT_MS must be from 1 to 2147483647", 0)
end
if CHUNK > floor(MAX_INTEGER / CHUNKS) then
    error("bench: BENCH_TCP_CHUNK times BENCH_TCP_CHUNKS is too large", 0)
end

local function casesFromEnvironment(): {string: boolean}
    local given <const> = getenv("BENCH_TCP_CASES")
    if given == nil then
        return CASE_NAMES
    end

    local selected: {string: boolean} = {}
    for label in given:gmatch("[^,]+") do
        if not CASE_NAMES[label] then
            error(format("bench: unknown BENCH_TCP_CASES label %q", label), 0)
        end
        selected[label] = true
    end
    if next(selected) == nil then
        error("bench: BENCH_TCP_CASES must name at least one row", 0)
    end
    return selected
end

local SELECTED_CASES <const> = casesFromEnvironment()
local BYTES_PER_OPERATION <const> = CHUNK * CHUNKS

local function fixtureOf(size: integer): string
    local bytes: {string} = {}
    for value = 0, 255 do
        bytes[value + 1] = char((value * 73 + 19) % 256)
    end
    local period <const> = concat(bytes)
    local repeats <const> = floor(size / #period)
    return period:rep(repeats) .. period:sub(1, size - repeats * #period)
end

local function heapBytes(): number
    return (collect("count") as number) * 1024.0
end

local function percentile(sorted: {number}, fraction: number): number
    local at <const> = max(1, min(#sorted, ceil(#sorted * fraction)))
    return sorted[at]
end

local function crc32(bytes: string): string
    return format("%08x", data.crc32(bytes))
end

local function checkHash(label: string, bytes: string, expected: string)
    local actual <const> = crc32(bytes)
    if actual ~= expected then
        error(format("bench: %s produced CRC-32 %s, expected %s", label, actual, expected), 0)
    end
end

local function listen(): binaryIO.TCPListener, integer
    for offset = 0, PORT_COUNT - 1 do
        local port <const> = FIRST_PORT + offset
        local server <const> = ioModule.listen(port)
        if server ~= nil then
            return server, port
        end
    end
    error(
        format("bench: no loopback TCP port is available from %d through %d", FIRST_PORT, FIRST_PORT + PORT_COUNT - 1),
        0
    )
end

local function resolved(): binaryIO.Address
    return ioModule.resolve("127.0.0.1")
end

local function connected(address: binaryIO.Address, server: binaryIO.TCPListener, port: integer): TCPSocket, TCPSocket
    local socket <const> = ioModule.connect(address, port)
    local ready <const>, waitReason = server:wait(TIMEOUT_MS)
    if not ready then
        error("bench: loopback accept timed out: " .. (waitReason or "timeout"), 0)
    end
    local peer <const>, acceptReason = server:accept()
    if peer == nil then
        error("bench: loopback accept failed: " .. (acceptReason or "no connection"), 0)
    end
    return socket, peer
end

local function drain(connection: TCPSocket)
    local drained <const>, reason = connection:drain(TIMEOUT_MS)
    if not drained then
        error("bench: loopback send did not drain: " .. (reason or "timeout"), 0)
    end
end

local function waitReadable(connection: TCPSocket)
    local ready <const>, reason = connection:wait(TIMEOUT_MS)
    if not ready then
        error("bench: loopback receive timed out: " .. (reason or "timeout"), 0)
    end
end

local function consumeStrings(connection: TCPSocket, count: integer, pieces?: {string}): integer
    local consumed = 0
    while consumed < count do
        waitReadable(connection)
        local bytes <const>, reason = connection:read(count - consumed)
        if bytes == nil then
            if reason ~= nil then
                error("bench: loopback string read failed: " .. reason, 0)
            end
        else
            consumed = consumed + #bytes
            if pieces ~= nil then
                pieces[#pieces + 1] = bytes
            end
        end
    end
    return consumed
end

local function consumeBuffer(connection: TCPSocket, destination: IOBuffer, count: integer): integer
    destination:clear()
    local consumed = 0
    while consumed < count do
        waitReadable(connection)
        local read <const>, reason = connection:readInto(destination, consumed, count - consumed)
        if read == nil then
            if reason ~= nil then
                error("bench: loopback buffer read failed: " .. reason, 0)
            end
        else
            consumed = consumed + read
        end
    end
    return consumed
end

local function runTasks<T>(body: function(tasks.Scope): T...): T
    local scheduler <const> = task.newScheduler()
    local rootTask <const> = scheduler:spawn(body)
    local deadline <const> = now() + TIMEOUT_MS / 1000
    while rootTask.status == "pending" do
        scheduler:step()
        if rootTask.status == "pending" then
            runtime.poll()
            if now() >= deadline then
                error("bench: cooperative TCP tasks timed out", 0)
            end
        end
    end
    if rootTask.status ~= "ready" then
        error("bench: cooperative TCP task failed: " .. (rootTask.error or rootTask.status), 0)
    end
    return rootTask.value
end

local type Operation = function(): integer
local type Validation = function(): string

local record Case
    label: string
    validate: Validation
    operation: Operation
    visibleCapacity: integer
end

local function measure(case: Case, expectedHash: string)
    for _ = 1, WARMUP do
        local count <const> = case.operation()
        if count ~= BYTES_PER_OPERATION then
            error(format("bench: tcp %s processed %d of %d bytes", case.label, count, BYTES_PER_OPERATION), 0)
        end
    end

    local elapsed: {number} = {}
    local throughput: {number} = {}
    local allocated: {number} = {}
    for sample = 1, SAMPLES do
        collect("collect")
        collect("stop")
        local before <const> = heapBytes()
        local started <const> = now()
        local count <const> = case.operation()
        local duration <const> = now() - started
        local after <const> = heapBytes()
        collect("restart")

        if count ~= BYTES_PER_OPERATION then
            error(format("bench: tcp %s processed %d of %d bytes", case.label, count, BYTES_PER_OPERATION), 0)
        end
        elapsed[sample] = duration
        throughput[sample] = BYTES_PER_OPERATION / max(duration, 1e-12) / MIB
        allocated[sample] = max(0.0, after - before)
    end
    collect("collect")

    sort(elapsed)
    sort(throughput)
    sort(allocated)
    print(
        format(
            "%-8s %9d %6d %8s %9.3f %9.3f %10.1f %10.1f %10.1f %10.1f %10.1f %11.1f",
            case.label,
            BYTES_PER_OPERATION,
            CHUNKS,
            expectedHash,
            percentile(elapsed, 0.50) * 1000.0,
            percentile(elapsed, 0.95) * 1000.0,
            percentile(throughput, 0.50),
            percentile(throughput, 0.05),
            percentile(allocated, 0.50) / KIB,
            percentile(allocated, 0.95) / KIB,
            allocated[#allocated] / KIB,
            case.visibleCapacity / KIB
        )
    )
end

local function run()
    local sdlStarted = false
    local ioStarted = false
    local address: binaryIO.Address
    local server: binaryIO.TCPListener
    local client: TCPSocket
    local peer: TCPSocket
    local sourceBuffer: IOBuffer
    local destinationBuffer: IOBuffer
    local latencySource: IOBuffer
    local latencyDestination: IOBuffer

    local ran <const>, failure = pcall(function()
        if not C.SDL_Init(0) then
            error("bench: SDL initialization failed: " .. sdl.error(), 0)
        end
        sdlStarted = true
        local initialized <const>, initReason = ioModule.init()
        if not initialized then
            error("bench: TCP initialization failed: " .. (initReason or "unknown"), 0)
        end
        ioStarted = true

        address = resolved()
        local port: integer
        server, port = listen()
        client, peer = connected(address, server, port)

        local chunk <const> = fixtureOf(CHUNK)
        local expectedBytes <const> = chunk:rep(CHUNKS)
        local expectedHash <const> = crc32(expectedBytes)
        sourceBuffer = ioModule.newBuffer(chunk)
        destinationBuffer = ioModule.newBuffer()
        destinationBuffer:ensureCapacity(CHUNK)
        latencySource = ioModule.newBuffer("x")
        latencyDestination = ioModule.newBuffer()
        latencyDestination:ensureCapacity(1)
        local function taskTransfer(pieces?: {string}): integer
            return runTasks(function(scope: tasks.Scope): integer
                local writing <const> = scope:spawn(function()
                    for _ = 1, CHUNKS do
                        local queued <const>, writeReason = client:writeFrom(sourceBuffer)
                        if queued == nil then
                            error("bench: loopback task write failed: " .. (writeReason or "unknown"), 0)
                        end
                        if queued ~= CHUNK then
                            error(format("bench: loopback task queued %d of %d bytes", queued, CHUNK), 0)
                        end
                    end
                end)
                local total = 0
                while total < BYTES_PER_OPERATION do
                    destinationBuffer:clear()
                    local read <const>, readReason = peer:readInto(destinationBuffer, 0, CHUNK)
                    if read == nil then
                        error("bench: loopback task read failed: " .. (readReason or "unknown"), 0)
                    end
                    total = total + read
                    if pieces ~= nil then
                        pieces[#pieces + 1] = destinationBuffer:getString()
                    end
                end
                writing:join()
                return total
            end)
        end

        local cases <const>: {Case} = {
            {
                label = "string",
                validate = function(): string
                    local pieces: {string} = {}
                    for _ = 1, CHUNKS do
                        local queued <const>, writeReason = client:write(chunk)
                        if not queued then
                            error("bench: loopback string write failed: " .. (writeReason or "unknown"), 0)
                        end
                        drain(client)
                        consumeStrings(peer, CHUNK, pieces)
                    end
                    return concat(pieces)
                end,
                operation = function(): integer
                    local total = 0
                    for _ = 1, CHUNKS do
                        local queued <const>, writeReason = client:write(chunk)
                        if not queued then
                            error("bench: loopback string write failed: " .. (writeReason or "unknown"), 0)
                        end
                        drain(client)
                        total = total + consumeStrings(peer, CHUNK)
                    end
                    return total
                end,
                visibleCapacity = 0,
            },
            {
                label = "buffer",
                validate = function(): string
                    local pieces: {string} = {}
                    for _ = 1, CHUNKS do
                        local queued <const>, writeReason = client:writeFrom(sourceBuffer)
                        if queued == nil then
                            error("bench: loopback buffer write failed: " .. (writeReason or "unknown"), 0)
                        end
                        if queued ~= CHUNK then
                            error(format("bench: loopback buffer queued %d of %d bytes", queued, CHUNK), 0)
                        end
                        drain(client)
                        consumeBuffer(peer, destinationBuffer, CHUNK)
                        pieces[#pieces + 1] = destinationBuffer:getString()
                    end
                    return concat(pieces)
                end,
                operation = function(): integer
                    local total = 0
                    for _ = 1, CHUNKS do
                        local queued <const>, writeReason = client:writeFrom(sourceBuffer)
                        if queued == nil then
                            error("bench: loopback buffer write failed: " .. (writeReason or "unknown"), 0)
                        end
                        if queued ~= CHUNK then
                            error(format("bench: loopback buffer queued %d of %d bytes", queued, CHUNK), 0)
                        end
                        drain(client)
                        total = total + consumeBuffer(peer, destinationBuffer, CHUNK)
                    end
                    return total
                end,
                visibleCapacity = sourceBuffer:capacity() + destinationBuffer:capacity(),
            },
            {
                label = "task",
                validate = function(): string
                    local pieces: {string} = {}
                    taskTransfer(pieces)
                    return concat(pieces)
                end,
                operation = taskTransfer,
                visibleCapacity = sourceBuffer:capacity() + destinationBuffer:capacity(),
            },
        }

        if VALIDATE then
            print(format("tcp: correctness only, %d chunks of %d bytes", CHUNKS, CHUNK))
        else
            print(format("tcp: %d samples after %d warmup, %d chunks of %d bytes", SAMPLES, WARMUP, CHUNKS, CHUNK))
            print(
                format(
                    "%-8s %9s %6s %8s %9s %9s %10s %10s %10s %10s %10s %11s",
                    "path",
                    "bytes",
                    "chunks",
                    "crc32",
                    "op50ms",
                    "op95ms",
                    "p50MiB/s",
                    "p05MiB/s",
                    "alloc50K",
                    "alloc95K",
                    "allocMaxK",
                    "visibleCapK"
                )
            )
        end

        local selectedCount = 0
        for index = 1, #cases do
            local case <const> = cases[index]
            if SELECTED_CASES[case.label] then
                selectedCount = selectedCount + 1
                checkHash(case.label, case.validate(), expectedHash)
                if VALIDATE then
                    local count <const> = case.operation()
                    if count ~= BYTES_PER_OPERATION then
                        error(
                            format("bench: tcp %s processed %d of %d bytes", case.label, count, BYTES_PER_OPERATION), 0
                        )
                    end
                else
                    measure(case, expectedHash)
                end
            end
        end
        if VALIDATE then
            print(
                format(
                    "validated %d bytes across %d TCP paths with CRC-32 %s",
                    BYTES_PER_OPERATION,
                    selectedCount,
                    expectedHash
                )
            )
        elseif SELECTED_CASES["task"] then
            local dispatch: {number} = {}
            local function dispatchOnce(): number
                local started <const> = ticksNanoseconds()
                runTasks(function(scope: tasks.Scope)
                    local writing <const> = scope:spawn(function()
                        task.yield()
                        local queued <const>, reason = client:writeFrom(latencySource)
                        if queued ~= 1 then
                            error("bench: task latency write failed: " .. (reason or tostring(queued)), 0)
                        end
                    end)
                    latencyDestination:clear()
                    local read <const>, reason = peer:readInto(latencyDestination, 0, 1)
                    if read ~= 1 then
                        error("bench: task latency read failed: " .. (reason or tostring(read)), 0)
                    end
                    writing:join()
                end)
                return ticksNanoseconds() - started
            end
            for _ = 1, WARMUP do
                dispatchOnce()
            end
            for sample = 1, SAMPLES do
                dispatch[sample] = dispatchOnce()
            end
            sort(dispatch)
            print(
                format(
                    "task cooperative wake: p50 %.3f us, p95 %.3f us (park, readiness poll, and resume)",
                    percentile(dispatch, 0.50) / 1000.0,
                    percentile(dispatch, 0.95) / 1000.0
                )
            )
        end
    end) as (boolean, any)

    collect("restart")
    if latencySource ~= nil and not latencySource:isReleased() then
        latencySource:close()
    end
    if latencyDestination ~= nil and not latencyDestination:isReleased() then
        latencyDestination:close()
    end
    if sourceBuffer ~= nil and not sourceBuffer:isReleased() then
        sourceBuffer:close()
    end
    if destinationBuffer ~= nil and not destinationBuffer:isReleased() then
        destinationBuffer:close()
    end
    if client ~= nil then
        client:close()
    end
    if peer ~= nil then
        peer:close()
    end
    if server ~= nil then
        server:close()
    end
    if address ~= nil then
        address:close()
    end

    local cleaned = true
    local cleanupReason: string
    if ioStarted then
        cleaned, cleanupReason = ioModule.shutdown()
    end
    if sdlStarted then
        C.SDL_Quit()
    end
    if not ran then
        error(tostring(failure), 0)
    end
    if not cleaned then
        error("bench: TCP cleanup failed: " .. (cleanupReason or "unknown"), 0)
    end
end

run()
