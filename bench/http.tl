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
--- payload size and sample counts. No external service or network is used.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local time <const> = require("tecs.platform.time")
local type Future = require("tecs.Future")
local type iotypes = require("tecs.io.types")

local tecsIO <const> = tecs.io
local http <const> = tecs.io.http
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local sort <const> = table.sort
local sub <const> = string.sub
local getenv <const> = os.getenv
local remove <const> = os.remove
local tmpname <const> = os.tmpname
local crc32 <const> = tecs.data.crc32

local BYTES <const> = floor(tonumber(getenv("BENCH_HTTP_BYTES")) or (4 * 1024 * 1024))
local WARMUP <const> = floor(tonumber(getenv("BENCH_HTTP_WARMUP")) or 20)
local SAMPLES <const> = floor(tonumber(getenv("BENCH_HTTP_SAMPLES")) or 100)
local READ_CHUNK <const> = 64 * 1024

local type Buffer = iotypes.Buffer
local type Reader = iotypes.Reader
local type Writer = iotypes.Writer
local type ReadableStream = iotypes.ReadableStream
local type WritableStream = iotypes.WritableStream

local payload <const> = ("0123456789abcdef"):rep(floor((BYTES + 15) / 16)):sub(1, BYTES)

local PAYLOAD_HASH <const> = crc32(payload)

local record ChunkReader is Reader
    bytes: string
    at: integer
    closed: boolean
end

function ChunkReader:read(count: integer): string, string
    if self.closed then
        return nil, "reader is closed"
    end
    if self.at >= #self.bytes then
        return ""
    end
    local finish <const> = min(#self.bytes, self.at + max(1, count))
    local result <const> = sub(self.bytes, self.at + 1, finish)
    self.at = finish
    return result
end

function ChunkReader:readInto(destination: Buffer, count: integer, offset?: integer): integer, string
    if self.closed then
        return nil, "reader is closed"
    end
    if self.at >= #self.bytes or count == 0 then
        return 0
    end
    local taking <const> = min(count, #self.bytes - self.at)
    destination:setString(sub(self.bytes, self.at + 1, self.at + taking), offset or 0)
    self.at = self.at + taking
    return taking
end

function ChunkReader:close()
    self.closed = true
end

local record ChunkSource is ReadableStream
    bytes: string
    closed: boolean
end

function ChunkSource:contentLength(): integer | nil
    return #self.bytes
end
function ChunkSource:contentType(): string | nil
    return "application/octet-stream"
end
function ChunkSource:hasKnownLength(): boolean
    return true
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
function ChunkSource:isAvailable(): boolean
    return not self.closed
end
function ChunkSource:close()
    self.closed = true
end
function ChunkSource:hasBuffer(): boolean
    return false
end
function ChunkSource:newReader(): Reader, string
    if self.closed then
        return nil, "stream is closed"
    end
    return {bytes = self.bytes, at = 0, closed = false} as ChunkReader
end
function ChunkSource:readAll(maxBytes?: integer): Future<string>
    return tecsIO.newStringStream(self.bytes):readAll(maxBytes)
end
function ChunkSource:readBuffer(maxBytes?: integer): Future<Buffer>
    return tecsIO.newStringStream(self.bytes):readBuffer(maxBytes)
end
function ChunkSource:transferTo(destination: WritableStream): Future<integer>
    return tecsIO.newStringStream(self.bytes):transferTo(destination)
end
function ChunkSource:transferToFile(path: string): Future<integer>
    return tecsIO.newStringStream(self.bytes):transferToFile(path)
end
function ChunkSource:discard(): Future<integer>
    return tecsIO.newStringStream(self.bytes):discard()
end

local record BufferWriter is Writer
    destination: Buffer
    at: integer
    closed: boolean
end

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
    self.destination:setString(source:getString(offset, count), self.at)
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

function BufferSink:contentLength(): integer | nil
    return self.buffer:length()
end
function BufferSink:contentType(): string | nil
    return "application/octet-stream"
end
function BufferSink:hasKnownLength(): boolean
    return true
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
function BufferSink:isAvailable(): boolean
    return not self.closed
end
function BufferSink:close()
    self.closed = true
end
function BufferSink:newWriter(): Writer, string
    self.buffer:clear()
    return {destination = self.buffer, at = 0, closed = false} as BufferWriter
end
function BufferSink:writeAll(bytes: string): Future<integer>
    return tecsIO.newBufferStream(self.buffer):writeAll(bytes)
end
function BufferSink:writeBuffer(source: Buffer, offset?: integer, count?: integer): Future<integer>
    return tecsIO.newBufferStream(self.buffer):writeBuffer(source, offset, count)
end

local record Server
    listener: tecs.io.Server
    connection: tecs.io.Connection
    pending: string
end

local function listen(): Server, integer
    local failures: {string} = {}
    for port = 47980, 48080 do
        local listener <const>, reason = tecsIO.listen(port)
        if listener ~= nil then
            return {listener = listener, pending = ""}, port
        end
        failures[#failures + 1] = reason or "unavailable"
    end
    error("tecs: HTTP benchmark could not bind a loopback port: " .. table.concat(failures, ", "), 0)
end

local function requestBody(raw: string): string
    local boundary <const> = raw:find("\r\n\r\n", 1, true)
    if boundary == nil then
        return nil
    end
    local length <const> = floor(tonumber(raw:sub(1, boundary - 1):lower():match("content%-length:%s*(%d+)")) or 0)
    local start <const> = boundary + 4
    if #raw - start + 1 < length then
        return nil
    end
    return raw:sub(start, start + length - 1)
end

local function pollServer(server: Server, responseBytes: string): integer
    if server.connection == nil then
        server.connection = server.listener:accept()
        if server.connection == nil then
            return nil
        end
    end
    local bytes <const>, reason = server.connection:read(READ_CHUNK)
    if reason ~= nil then
        error(reason, 0)
    end
    if bytes ~= nil then
        server.pending = server.pending .. bytes
    end
    local body <const> = requestBody(server.pending)
    if body == nil then
        return nil
    end
    local bodyHash <const> = crc32(body)
    local response <const> = ("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(
        #responseBytes, responseBytes
    )
    local ok <const>, writeReason = server.connection:write(response)
    if not ok then
        error(writeReason, 0)
    end
    server.connection:drain(1000)
    server.connection:close()
    server.connection = nil
    server.pending = ""
    return bodyHash
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
local pending: Future<tecs.io.http.Response> = nil
local started = 0.0
local expectedServerHash = crc32("")
local sink: BufferSink = nil

local function begin()
    local name <const> = MODES[mode]
    local request: tecs.io.http.Request = {
        url = ("http://127.0.0.1:%d/%s"):format(port, name),
        method = "POST",
    }
    if name == "upload-string" then
        request.body = payload
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-buffer" then
        request.body = tecsIO.newBufferStream(uploadBuffer)
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-file" then
        request.body = tecsIO.newFileStream(uploadPath)
        expectedServerHash = PAYLOAD_HASH
    elseif name == "upload-reader" then
        request.body = {bytes = payload, closed = false} as ChunkSource
        expectedServerHash = PAYLOAD_HASH
    elseif name == "download-writer" then
        sink = {buffer = downloadBuffer, closed = false}
        request.into = sink
        expectedServerHash = crc32("")
    else
        expectedServerHash = crc32("")
    end
    started = time.now()
    pending = client:send(request)
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
        begin()
        world:addSystem({
            name = "bench.Http",
            phase = tecs.ecs.phases.Update,
            run = function()
                local serverHash <const> = pollServer(server, MODES[mode]:match("^download") ~= nil and payload or "")
                if serverHash ~= nil and serverHash ~= expectedServerHash then
                    error(("tecs: %s upload hash mismatch"):format(MODES[mode]), 0)
                end
                if pending.status == "pending" then
                    return
                end
                if pending.status ~= "ready" then
                    error(pending.error, 0)
                end
                local name <const> = MODES[mode]
                if name == "download-buffer" then
                    local body <const> = (pending.value.body as ReadableStream):readAll().value
                    if crc32(body) ~= PAYLOAD_HASH then
                        error("tecs: default Buffer download hash mismatch", 0)
                    end
                elseif name == "download-writer" and crc32(downloadBuffer:getString()) ~= PAYLOAD_HASH then
                    error("tecs: custom Writer download hash mismatch", 0)
                end
                iteration = iteration + 1
                if iteration > WARMUP then
                    local samples <const> = results[mode].samples
                    samples[#samples + 1] = (time.now() - started) * 1000.0
                end
                if iteration < WARMUP + SAMPLES then
                    begin()
                    return
                end
                mode = mode + 1
                iteration = 0
                if mode > #MODES then
                    app.quitRequested = true
                    return
                end
                results[mode] = {name = MODES[mode], samples = {}, bytes = BYTES}
                begin()
            end,
        })
        world:addSystem({
            name = "bench.HttpReport",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
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
                client:close()
                server.listener:close()
                uploadBuffer:release()
                downloadBuffer:release()
                remove(uploadPath)
            end,
        })
    end,
})
