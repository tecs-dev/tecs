--- Loopback HTTP body transport benchmark.
---
--- This measures the HTTP-specific seams rather than `tecs.io.Stream` alone:
--- four request sources cross the bounded upload channel, and two response
--- destinations cross the bounded event queue. Every case sends one request
--- at a time to an in-process TCP server, validates the body hash, discards
--- warmup samples, and reports p50/p95 latency plus payload throughput.
---
--- Run this only on a quiet machine:
---
---     cargo xtask bench http
---
--- `BENCH_HTTP_BYTES`, `BENCH_HTTP_WARMUP`, and `BENCH_HTTP_SAMPLES` control
--- payload size and sample counts. Every request runs through the coroutine
--- completion path. `BENCH_HTTP_FORCE_FAILURE=1` verifies
--- that a guarded application error makes the benchmark process fail after cleanup.
--- No external service or network is used.

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local concat <const> = table.concat
local sort <const> = table.sort
local sub <const> = string.sub
local protect <const> = pcall
local stringify <const> = tostring
local exit <const> = os.exit
local getenv <const> = os.getenv
local remove <const> = os.remove
local tmpname <const> = os.tmpname
local stderr <const> = io.stderr
local setMeta <const> = setmetatable as function(any, any): any

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if sub(root, -1) == "/" then
    root = sub(root, 1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local ffi <const> = require("ffi")
local time <const> = require("tecs.platform.time")
local buffer <const> = require("tecs.io.buffer")
local type iotypes = require("tecs.io.types")
local type tasks = require("tecs.internal.taskruntime")
local task <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")

local tecsIO <const> = tecs.io
local http <const> = tecs.io.http
local crc32 <const> = tecs.data.crc32
local copy <const> = ffi.copy

local BYTES <const> = floor(tonumber(getenv("BENCH_HTTP_BYTES")) or (4 * 1024 * 1024))
local WARMUP <const> = floor(tonumber(getenv("BENCH_HTTP_WARMUP")) or 20)
local SAMPLES <const> = floor(tonumber(getenv("BENCH_HTTP_SAMPLES")) or 100)
local FORCE_FAILURE <const> = getenv("BENCH_HTTP_FORCE_FAILURE") == "1"
local COMPLETION <const> = "coroutine"
local READ_CHUNK <const> = 64 * 1024

if BYTES < 1 then
    error("bench: BENCH_HTTP_BYTES must be positive", 0)
end
if WARMUP < 0 then
    error("bench: BENCH_HTTP_WARMUP must be zero or more", 0)
end
if SAMPLES < 1 then
    error("bench: BENCH_HTTP_SAMPLES must be positive", 0)
end

local type Buffer = iotypes.Buffer
local type Reader = iotypes.Reader
local type Writer = iotypes.Writer
local type ReadableStream = iotypes.ReadableStream
local type WritableStream = iotypes.WritableStream

local payload <const> = ("0123456789abcdef"):rep(floor((BYTES + 15) / 16)):sub(1, BYTES)

local PAYLOAD_HASH <const> = crc32(payload)
local EMPTY_RESPONSE <const> = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
local PAYLOAD_RESPONSE <const> = ("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s"):format(
    #payload, payload
)

local record ChunkReader is Reader
    source: Buffer
    at: integer
    closed: boolean
end

local ChunkReaderMT <const>: metatable<ChunkReader> = {__index = ChunkReader}

function ChunkReader:read(count: integer): string, string
    if self.closed then
        return nil, "reader is closed"
    end
    if self.at >= self.source:length() then
        return ""
    end
    local finish <const> = min(self.source:length(), self.at + max(1, count))
    local result <const> = self.source:getString(self.at, finish - self.at)
    self.at = finish
    return result
end

function ChunkReader:readInto(destination: Buffer, offset?: integer, count?: integer): integer, string
    if self.closed then
        return nil, "reader is closed"
    end
    if self.at >= self.source:length() or count == 0 then
        return 0
    end
    local taking <const> = min(count or 16 * 1024, self.source:length() - self.at)
    local output <const>, previousLength <const> = buffer.prepareWrite(destination, offset or 0, taking)
    copy(output as ffi.CData, (self.source:getFFIPointer() + self.at) as ffi.CData, taking)
    buffer.commitWrite(destination, offset or 0, taking, previousLength)
    self.at = self.at + taking
    return taking
end

function ChunkReader:close(): boolean, string
    self.closed = true
    return true
end

local record ChunkSource is ReadableStream
    buffer: Buffer
    closed: boolean
end

local ChunkSourceMT <const>: metatable<ChunkSource> = {__index = ChunkSource}

function ChunkSource:contentLength(): integer | nil
    return self.buffer:length()
end
function ChunkSource:contentType(): string | nil
    return "application/octet-stream"
end
function ChunkSource:isReadable(): boolean
    return true
end
function ChunkSource:isWritable(): boolean
    return false
end
function ChunkSource:isReplayable(): boolean
    return true
end
function ChunkSource:close(): boolean, string
    self.closed = true
    return true
end
function ChunkSource:newReader(): Reader, string
    if self.closed then
        return nil, "stream is closed"
    end
    return setMeta({source = self.buffer, at = 0, closed = false} as ChunkReader, ChunkReaderMT) as ChunkReader
end
function ChunkSource:readAll(maxBytes?: integer): string, string
    return self.buffer:newStream():readAll(maxBytes)
end
function ChunkSource:transferToBuffer(maxBytes?: integer): Buffer, string
    return self.buffer:newStream():transferToBuffer(maxBytes)
end
function ChunkSource:transferTo(destination: WritableStream): integer, string
    return self.buffer:newStream():transferTo(destination)
end
function ChunkSource:transferToFile(path: string): integer, string
    return self.buffer:newStream():transferToFile(path)
end
function ChunkSource:discard(): integer, string
    return self.buffer:newStream():discard()
end

local record BufferWriter is Writer
    destination: Buffer
    at: integer
    closed: boolean
end

local BufferWriterMT <const>: metatable<BufferWriter> = {__index = BufferWriter}

function BufferWriter:write(bytes: string): boolean, string
    if self.closed then
        return false, "writer is closed"
    end
    self.destination:setString(bytes, self.at)
    self.at = self.at + #bytes
    return true
end
function BufferWriter:writeFrom(source: Buffer, offset?: integer, count?: integer): integer, string
    if self.closed then
        return nil, "writer is closed"
    end
    offset = offset or 0
    count = count or (source:length() - offset)
    local output <const>, previousLength <const> = buffer.prepareWrite(self.destination, self.at, count)
    copy(output as ffi.CData, (source:getFFIPointer() + offset) as ffi.CData, count)
    buffer.commitWrite(self.destination, self.at, count, previousLength)
    self.at = self.at + count
    return count
end
function BufferWriter:flush(): boolean, string
    return not self.closed
end
function BufferWriter:close(): boolean, string
    self.closed = true
    return true
end

local record BufferSink is WritableStream
    buffer: Buffer
    closed: boolean
end

local BufferSinkMT <const>: metatable<BufferSink> = {__index = BufferSink}

function BufferSink:contentLength(): integer | nil
    return self.buffer:length()
end
function BufferSink:contentType(): string | nil
    return "application/octet-stream"
end
function BufferSink:isReadable(): boolean
    return false
end
function BufferSink:isWritable(): boolean
    return true
end
function BufferSink:isReplayable(): boolean
    return false
end
function BufferSink:close(): boolean, string
    self.closed = true
    return true
end
function BufferSink:newWriter(): Writer, string
    self.buffer:clear()
    return setMeta({destination = self.buffer, at = 0, closed = false} as BufferWriter, BufferWriterMT) as BufferWriter
end
function BufferSink:writeAll(bytes: string): integer, string
    return self.buffer:newStream():writeAll(bytes)
end
function BufferSink:writeBuffer(source: Buffer, offset?: integer, count?: integer): integer, string
    return self.buffer:newStream():writeBuffer(source, offset, count)
end

local record Server
    listener: tecs.io.TCPListener
    connection: tecs.io.TCPSocket
    pending: Buffer
    bodyOffset: integer
    bodyLength: integer
    writing: boolean
    responded: boolean
end

local function listen(): Server, integer
    local failures: {string} = {}
    for port = 47980, 48080 do
        local listener <const>, reason = tecsIO.listen(port)
        if listener ~= nil then
            return {
                listener = listener,
                pending = tecsIO.newBuffer(),
                writing = false,
                responded = false,
            }, port
        end
        failures[#failures + 1] = reason or "unavailable"
    end
    error("tecs: HTTP benchmark could not bind a loopback port: " .. concat(failures, ", "), 0)
end

local function pollServer(server: Server, response: string): boolean
    if server.responded then
        return false
    end
    if server.writing then
        local pending <const>, pendingReason = server.connection:pendingWrites()
        if pending == nil then
            error(pendingReason, 0)
        end
        if pending > 0 then
            return false
        end
        server.writing = false
        server.responded = true
        return true
    end
    if server.connection == nil then
        local listening <const>, listenReason = server.listener:wait(0)
        if listenReason ~= nil then
            error(listenReason, 0)
        end
        if not listening then
            return false
        end
        server.connection = server.listener:accept()
        if server.connection == nil then
            return false
        end
    end
    local readable <const>, readyReason = server.connection:wait(0)
    if readyReason ~= nil then
        error(readyReason, 0)
    end
    if not readable then
        return false
    end
    local read <const>, reason = server.connection:readInto(server.pending, server.pending:length(), READ_CHUNK)
    if reason ~= nil then
        -- The client may retire an idle keep-alive connection between
        -- requests. Accept that only at a request boundary and let the next
        -- poll accept the replacement connection.
        if reason == "connection closed" and server.pending:length() == 0 and server.bodyOffset == nil then
            server.connection:close()
            server.connection = nil
            return false
        end
        error(reason, 0)
    end
    if server.bodyOffset == nil and read ~= nil then
        local request <const> = server.pending:getString()
        local boundary <const> = request:find("\r\n\r\n", 1, true)
        if boundary ~= nil then
            server.bodyLength = floor(
                tonumber(request:sub(1, boundary - 1):lower():match("content%-length:%s*(%d+)")) or 0
            )
            server.bodyOffset = boundary + 3
        end
    end
    if server.bodyOffset == nil or server.pending:length() < server.bodyOffset + server.bodyLength then
        return false
    end
    local ok <const>, writeReason = server.connection:write(response)
    if not ok then
        error(writeReason, 0)
    end
    server.writing = true
    return false
end

local function validateRequest(server: Server): integer
    if not server.responded then
        error("tecs: HTTP benchmark validated a request before responding", 0)
    end
    local hash <const> = crc32(server.pending:getString(server.bodyOffset, server.bodyLength))
    server.pending:clear()
    server.bodyOffset = nil
    server.bodyLength = nil
    server.writing = false
    server.responded = false
    return hash
end

local record Result
    name: string
    samples: {number}
    bytes: integer
end

local MODES <const>: {string} = {
    "upload-string",
    "upload-buffer",
    "upload-file",
    "upload-reader",
    "download-buffer",
    "download-writer",
}

local results: {Result} = {}
local server, port = listen()
local client = http.newClient()
local uploadBuffer <const> = tecsIO.newBuffer(payload)
local downloadBuffer <const> = tecsIO.newBuffer()
local uploadPath <const> = tmpname()
local uploadFile <const> = assert(io.open(uploadPath, "wb"))
uploadFile:write(payload)
uploadFile:close()

local mode = 1
local iteration = 0
local pendingTask: tasks.Task<tecs.io.http.Response> = nil
local scheduler <const> = task.newScheduler()
local started = 0.0
local expectedServerHash = crc32("")
local sink: BufferSink = nil

local function begin()
    if FORCE_FAILURE and mode == 1 and iteration == 0 then
        error("forced benchmark failure", 0)
    end
    local name <const> = MODES[mode]
    local request: tecs.io.http.Request = {
        url = tecs.io.URI.new(("http://127.0.0.1:%d/%s"):format(port, name)),
        method = "POST",
    }
    if name == "upload-string" then
        request.body = payload
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-buffer" then
        request.body = uploadBuffer:newStream()
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-file" then
        request.body = tecsIO.newFileStream(uploadPath)
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-reader" then
        request.body = setMeta({buffer = uploadBuffer, closed = false} as ChunkSource, ChunkSourceMT) as ChunkSource
        expectedServerHash = PAYLOAD_HASH
    elseif name == "download-writer" then
        sink = setMeta({buffer = downloadBuffer, closed = false} as BufferSink, BufferSinkMT) as BufferSink
        expectedServerHash = crc32("")
    else
        expectedServerHash = crc32("")
    end
    started = time.now()
    pendingTask = scheduler:spawnImmediate(function(): tecs.io.http.Response return client:send(request) end)
end

local function completionStatus(): string
    return pendingTask.status
end

local function completionError(): string
    return pendingTask.error
end

local function completionResponse(): tecs.io.http.Response
    return pendingTask.value
end

local benchmarkFailure: string = nil
local startRequested = false

local function failBenchmark(app: tecs.Application, reason: any)
    if benchmarkFailure == nil then
        benchmarkFailure = stringify(reason)
    end
    app.quitRequested = true
end

local function percentile(samples: {number}, fraction: number): number
    sort(samples)
    return samples[max(1, floor(#samples * fraction + 0.5))]
end

return tecs.newApplication({
    window = {title = "http benchmark", width = 320, height = 180},
    presentMode = "immediate",
    debugMaxFrames = 1000000,
    plugin = function(world: tecs.World, app: tecs.Application)
        results[1] = {name = MODES[1], samples = {}, bytes = BYTES}
        local began <const>, beginFailure = protect(begin) as (boolean, any)
        if not began then
            failBenchmark(app, beginFailure)
        end
        runtime.register(
            "bench-http",
            1,
            function(): integer
                local progressed = 0
                local advanced <const>, advanceFailure = protect(function()
                    pollServer(server, MODES[mode]:match("^download") ~= nil and PAYLOAD_RESPONSE or EMPTY_RESPONSE)
                    if pendingTask ~= nil and pendingTask.status == "pending" then
                        progressed = progressed + scheduler:step()
                    end
                    if startRequested then
                        startRequested = false
                        begin()
                        progressed = progressed + 1
                    end
                end) as (boolean, any)
                if not advanced then
                    failBenchmark(app, advanceFailure)
                end
                return progressed
            end
        )
        world:addSystem({
            name = "bench.Http",
            phase = tecs.ecs.phases.Update,
            run = function()
                local advanced <const>, advanceFailure = protect(function()
                    local status <const> = completionStatus()
                    if status == "pending" then
                        return
                    end
                    local elapsed <const> = (time.now() - started) * 1000.0
                    if status ~= "ready" then
                        error(completionError(), 0)
                    end
                    local response <const> = completionResponse()
                    local name <const> = MODES[mode]
                    local serverHash <const> = validateRequest(server)
                    if serverHash ~= expectedServerHash then
                        error(("tecs: %s upload hash mismatch"):format(name), 0)
                    end
                    if name == "download-buffer" then
                        local body <const> = (response.body as ReadableStream):readAll()
                        local bodyHash <const> = crc32(body)
                        if bodyHash ~= PAYLOAD_HASH then
                            error(
                                ("tecs: default Buffer download mismatch: got %d bytes/%u, expected %d/%u"):format(
                                    #body, bodyHash, BYTES, PAYLOAD_HASH
                                ),
                                0
                            )
                        end
                    elseif name == "download-writer" then
                        assert((response.body as ReadableStream):transferTo(sink))
                        if crc32(downloadBuffer:getString()) ~= PAYLOAD_HASH then
                            error("tecs: custom Writer download hash mismatch", 0)
                        end
                    end
                    iteration = iteration + 1
                    if iteration > WARMUP then
                        local samples <const> = results[mode].samples
                        samples[#samples + 1] = elapsed
                    end
                    if iteration < WARMUP + SAMPLES then
                        startRequested = true
                        return
                    end
                    mode = mode + 1
                    iteration = 0
                    if mode > #MODES then
                        app.quitRequested = true
                        return
                    end
                    results[mode] = {name = MODES[mode], samples = {}, bytes = BYTES}
                    startRequested = true
                end) as (boolean, any)
                if not advanced then
                    failBenchmark(app, advanceFailure)
                end
            end,
        })
        world:addSystem({
            name = "bench.HttpReport",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                runtime.unregister("bench-http")
                if benchmarkFailure == nil then
                    if #results ~= #MODES then
                        benchmarkFailure = ("completed %d of %d modes"):format(#results, #MODES)
                    else
                        for index = 1, #results do
                            if #results[index].samples ~= SAMPLES then
                                benchmarkFailure = ("%s completed %d of %d samples"):format(
                                    results[index].name, #results[index].samples, SAMPLES
                                )
                                break
                            end
                        end
                    end
                end
                if benchmarkFailure == nil then
                    print("completion: " .. COMPLETION)
                    print("mode                 p50 ms   p95 ms   MiB/s")
                    for index = 1, #results do
                        local result <const> = results[index]
                        local p50 <const> = percentile(result.samples, 0.50)
                        local p95 <const> = percentile(result.samples, 0.95)
                        local throughput <const> = (result.bytes / (1024 * 1024)) / (p50 / 1000.0)
                        print(("%-20s %8.3f %8.3f %8.1f"):format(result.name, p50, p95, throughput))
                    end
                    print(
                        "boundedness: upload = 16 x 64 KiB = 1 MiB; "
                            .. "download = 64 x 64 KiB = 4 MiB; every body hash validated"
                    )
                end
                local cleaned <const>, cleanupFailure = protect(function()
                    client:close()
                    if server.connection ~= nil then
                        server.connection:close()
                    end
                    server.listener:close()
                    server.pending:close()
                    uploadBuffer:close()
                    downloadBuffer:close()
                    remove(uploadPath)
                end) as (boolean, any)
                if not cleaned and benchmarkFailure == nil then
                    benchmarkFailure = "cleanup failed: " .. stringify(cleanupFailure)
                end
                if benchmarkFailure ~= nil then
                    stderr:write("bench: HTTP benchmark failed: " .. benchmarkFailure .. "\n")
                    exit(1)
                end
            end,
        })
    end,
})
