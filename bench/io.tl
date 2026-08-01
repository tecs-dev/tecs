--- Whole-file, endpoint, buffer, and synchronous Stream I/O.
---
--- The rows compare whole-string calls with endpoint and Stream paths:
---
---   read-whole       `files.read`, returning one Lua string.
---   reader-string    `Reader:read`, returning one string per chunk.
---   reader-into      `Reader:readInto`, reusing one FFI-backed Buffer.
---   write-whole      `files.write`, receiving one Lua string.
---   writer-string    `Writer:write`, receiving sliced Lua strings.
---   writer-from      `Writer:writeFrom`, reading an existing Buffer.
---   string-buffer    `newStringStream(...):transferToBuffer()`.
---   buffer-alias     BufferStream's stable zero-copy `transferToBuffer`.
---   byte-buffer      Borrowed ByteStream to a new owned Buffer.
---   file-buffer      `newFileStream(...):transferToBuffer()`.
---   string-transfer  StringStream to BufferStream.
---   file-transfer    FileStream to BufferStream.
---   buffer-file      BufferStream to FileStream.
---   file-writebuf    `FileStream:writeBuffer`.
---   concurrent-file  A batch of equal synchronous FileStream transfers.
---   fallback-file    StringStream to a StorageBackend without `open`;
---                    close concatenates chunks before the backend's whole
---                    write.
---
--- The endpoint chunk size is configurable. Stream transfers use the engine's
--- fixed transfer chunk.
---
--- Hashing is outside every measured window. Each row first proves its result
--- with CRC-32. Operation latency is p50 and p95. Throughput is calculated for
--- every clean sample and then reported at p50 and p05 with the same
--- nearest-rank rule.
---
--- Lua allocation is measured in the same pass. Visible capacity is the peak
--- aggregate capacity of Buffers the case exposes to this harness; private
--- transfer scratch is not reachable through the public API and is deliberately
--- excluded. Neither metric is a native allocator event count, and the
--- operating system's page cache remains outside both.
---
--- Defaults cover a syscall-sized payload, the production Stream chunk, a
--- common asset, and a payload large enough to expose materialization:
---
---   BENCH_IO_SIZES        Comma-separated byte counts. Defaults to
---                         4096,65536,1048576,67108864.
---   BENCH_IO_CASES        Comma-separated row labels. Defaults to every row.
---   BENCH_IO_CHUNK        Endpoint chunk size. Defaults to 65536.
---   BENCH_IO_CONCURRENCY  Transfers in `concurrent-file`. Defaults to 4.
---   BENCH_IO_WARMUP       Untimed operations per row. Defaults to 3.
---   BENCH_IO_SAMPLES      Measured operations per row. Defaults to 21.
---   BENCH_IO_VALIDATE     Set to 1 for correctness only, with no timings.
---
--- The xtask runs this benchmark through the system LuaJIT with native
--- libraries but no window, GPU, or frame loop. Sanitizer presets are rejected
--- because their instrumented native host does not execute this entry point;
--- accepting one would present an unsanitized run as a sanitizer result. Run
--- measurements only on a quiet machine.

local getenv <const> = os.getenv
local temporaryName <const> = os.tmpname
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
local type loader = require("tecs.ffi.loader")
local type iotypes = require("tecs.io.types")
local adapter <const> = require("tecs.platform.adapter")
local pump <const> = require("tecs.io.pump")

local ioModule <const> = tecs.io
local files <const> = ioModule.files
local data <const> = tecs.data
local time <const> = tecs.platform.time
local now <const> = time.now

local type IOBuffer = iotypes.Buffer

local DEFAULT_SIZES <const>: {integer} = {4096, 64 * 1024, 1024 * 1024, 64 * 1024 * 1024}
local VALIDATE <const> = getenv("BENCH_IO_VALIDATE") == "1"
local MIB <const> = 1024.0 * 1024.0
local KIB <const> = 1024.0
local MAX_INTEGER <const> = 9007199254740991
local CASE_NAMES <const>: {string: boolean} = {
    ["read-whole"] = true,
    ["reader-string"] = true,
    ["reader-into"] = true,
    ["write-whole"] = true,
    ["writer-string"] = true,
    ["writer-from"] = true,
    ["string-buffer"] = true,
    ["buffer-alias"] = true,
    ["byte-buffer"] = true,
    ["file-buffer"] = true,
    ["string-transfer"] = true,
    ["file-transfer"] = true,
    ["buffer-file"] = true,
    ["file-writebuf"] = true,
    ["concurrent-file"] = true,
    ["fallback-file"] = true,
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

local CHUNK <const> = integerEnvironment("BENCH_IO_CHUNK", 64 * 1024)
local CONCURRENCY <const> = integerEnvironment("BENCH_IO_CONCURRENCY", 4)
local WARMUP <const> = integerEnvironment("BENCH_IO_WARMUP", 3)
local SAMPLES <const> = integerEnvironment("BENCH_IO_SAMPLES", 21)

if CHUNK < 1 then
    error("bench: BENCH_IO_CHUNK must be a positive integer", 0)
end
if CONCURRENCY < 2 then
    error("bench: BENCH_IO_CONCURRENCY must be at least two", 0)
end
if WARMUP < 0 then
    error("bench: BENCH_IO_WARMUP must be a non-negative integer", 0)
end
if SAMPLES < 1 and not VALIDATE then
    error("bench: BENCH_IO_SAMPLES must be a positive integer", 0)
end

local function sizesFromEnvironment(): {integer}
    local given <const> = getenv("BENCH_IO_SIZES")
    if given == nil then
        return DEFAULT_SIZES
    end

    local sizes: {integer} = {}
    for piece in given:gmatch("[^,]+") do
        local value <const> = tonumber(piece)
        if value == nil or value < 1 or value ~= floor(value) or value > MAX_INTEGER then
            error(format("bench: invalid BENCH_IO_SIZES byte count %q", piece), 0)
        end
        sizes[#sizes + 1] = floor(value)
    end
    if #sizes == 0 then
        error("bench: BENCH_IO_SIZES must name at least one byte count", 0)
    end
    return sizes
end

local SIZES <const> = sizesFromEnvironment()

local function casesFromEnvironment(): {string: boolean}
    local given <const> = getenv("BENCH_IO_CASES")
    if given == nil then
        return CASE_NAMES
    end

    local selected: {string: boolean} = {}
    for label in given:gmatch("[^,]+") do
        if not CASE_NAMES[label] then
            error(format("bench: unknown BENCH_IO_CASES label %q", label), 0)
        end
        selected[label] = true
    end
    if next(selected) == nil then
        error("bench: BENCH_IO_CASES must name at least one row", 0)
    end
    return selected
end

local SELECTED_CASES <const> = casesFromEnvironment()

--- A deterministic 256-byte period, with NUL and every high byte included.
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
    if #sorted == 0 then
        return 0.0
    end
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

local function checkBuffer(label: string, bytes: IOBuffer, expected: string)
    checkHash(label, bytes:getString(), expected)
end

local function readWhole(path: string): string
    local bytes <const> = files.read(path)
    if bytes == nil then
        error(format("bench: cannot read %s", path), 0)
    end
    return bytes
end

local function writeWhole(path: string, bytes: string)
    local ok <const>, failure = files.write(path, bytes)
    if not ok then
        error(format("bench: cannot write %s: %s", path, failure or "unknown"), 0)
    end
end

local function readStrings(path: string, materialize: boolean): string, integer
    local reader <const>, failure = files.open(path)
    if reader == nil then
        error(format("bench: cannot open %s: %s", path, failure or "unknown"), 0)
    end

    local pieces: {string}
    if materialize then
        pieces = {}
    end
    local count = 0
    while true do
        local piece <const>, readFailure = reader:read(CHUNK)
        if piece == nil then
            reader:close()
            error(format("bench: cannot read %s: %s", path, readFailure or "unknown"), 0)
        end
        if piece == "" then
            break
        end
        count = count + #piece
        if materialize then
            pieces[#pieces + 1] = piece
        end
    end
    reader:close()
    return materialize and concat(pieces) or "", count
end

local function readInto(path: string, materialize: boolean): string, integer, integer
    local reader <const>, failure = files.open(path)
    if reader == nil then
        error(format("bench: cannot open %s: %s", path, failure or "unknown"), 0)
    end

    local scratch <const> = ioModule.newBuffer()
    scratch:ensureCapacity(CHUNK)
    local pieces: {string}
    if materialize then
        pieces = {}
    end
    local count = 0
    while true do
        scratch:clear()
        local read <const>, readFailure = pump.readInto(reader, scratch, 0, CHUNK)
        if read == nil then
            reader:close()
            scratch:close()
            error(format("bench: cannot read %s: %s", path, readFailure or "unknown"), 0)
        end
        if read == 0 then
            break
        end
        count = count + read
        if materialize then
            pieces[#pieces + 1] = scratch:getString(0, read)
        end
    end
    reader:close()
    local capacity <const> = scratch:capacity()
    scratch:close()
    return materialize and concat(pieces) or "", count, capacity
end

local function writeStrings(path: string, bytes: string)
    local writer <const>, failure = files.open(path, "w")
    if writer == nil then
        error(format("bench: cannot open %s: %s", path, failure or "unknown"), 0)
    end

    local at = 1
    while at <= #bytes do
        local piece <const> = bytes:sub(at, min(#bytes, at + CHUNK - 1))
        local ok <const>, writeFailure = writer:write(piece)
        if not ok then
            writer:close()
            error(format("bench: cannot write %s: %s", path, writeFailure or "unknown"), 0)
        end
        at = at + #piece
    end
    local closed <const>, closeFailure = writer:close()
    if not closed then
        error(format("bench: cannot close %s: %s", path, closeFailure or "unknown"), 0)
    end
end

local function writeFrom(path: string, bytes: IOBuffer)
    local writer <const>, failure = files.open(path, "w")
    if writer == nil then
        error(format("bench: cannot open %s: %s", path, failure or "unknown"), 0)
    end

    local at = 0
    local length <const> = bytes:length()
    while at < length do
        local wanted <const> = min(CHUNK, length - at)
        local written <const>, writeFailure = pump.writeFrom(writer, bytes, at, wanted)
        if written == nil or written == 0 then
            writer:close()
            error(format("bench: cannot write %s: %s", path, writeFailure or "made no progress"), 0)
        end
        at = at + written
    end
    local closed <const>, closeFailure = writer:close()
    if not closed then
        error(format("bench: cannot close %s: %s", path, closeFailure or "unknown"), 0)
    end
end

local record Observation
    count: integer
    visibleCapacity: integer
end

local function observed(count: integer, visibleCapacity?: integer): Observation
    return {
        count = count,
        visibleCapacity = visibleCapacity or 0,
    }
end

local function syncObservation<T>(value: T, inspect: function(T): integer, capacity: function(T): integer): Observation
    return observed(inspect(value), capacity(value))
end

local type Operation = function(): Observation
local type Validation = function(expected: string)

local record Case
    label: string
    streams: integer
    validate: Validation
    operation: Operation
end

local function measure(case: Case, size: integer, expected: string)
    local expectedCount <const> = size * case.streams
    for _ = 1, WARMUP do
        local result <const> = case.operation()
        if result.count ~= expectedCount then
            error(format("bench: %s processed %d of %d bytes", case.label, result.count, expectedCount), 0)
        end
    end

    local elapsed: {number} = {}
    local throughput: {number} = {}
    local allocated: {number} = {}
    local visibleCapacities: {number} = {}
    for sample = 1, SAMPLES do
        collect("collect")
        collect("stop")
        local before <const> = heapBytes()
        local started <const> = now()
        local result <const> = case.operation()
        local duration <const> = now() - started
        local after <const> = heapBytes()
        collect("restart")
        if result.count ~= expectedCount then
            error(format("bench: %s processed %d of %d bytes", case.label, result.count, expectedCount), 0)
        end
        elapsed[sample] = duration
        throughput[sample] = expectedCount / max(duration, 1e-12) / MIB
        allocated[sample] = max(0.0, after - before)
        visibleCapacities[sample] = result.visibleCapacity
    end
    collect("collect")

    sort(elapsed)
    sort(throughput)
    sort(allocated)
    sort(visibleCapacities)
    local p50Seconds <const> = percentile(elapsed, 0.50)
    local p95Seconds <const> = percentile(elapsed, 0.95)
    local p50Throughput <const> = percentile(throughput, 0.50)
    local p05Throughput <const> = percentile(throughput, 0.05)
    print(
        format(
            "%-17s %9d %2d %8s %8.3f %8.3f %10.1f %10.1f" .. " %9.1f %9.1f %9.1f %11.1f",
            case.label,
            size,
            case.streams,
            expected,
            p50Seconds * 1000.0,
            p95Seconds * 1000.0,
            p50Throughput,
            p05Throughput,
            percentile(allocated, 0.50) / KIB,
            percentile(allocated, 0.95) / KIB,
            allocated[#allocated] / KIB,
            visibleCapacities[#visibleCapacities] / KIB
        )
    )
end

local function runSize(sourcePath: string, sinkPath: string, size: integer)
    local fixture <const> = fixtureOf(size)
    local expected <const> = crc32(fixture)
    local sourceBuffer <const> = ioModule.newBuffer(fixture)
    writeWhole(sourcePath, fixture)

    local cases <const>: {Case} = {
        {
            label = "read-whole",
            streams = 1,
            validate = function(hash: string) checkHash("read-whole", readWhole(sourcePath), hash) end,
            operation = function(): Observation return observed(#readWhole(sourcePath)) end,
        },
        {
            label = "reader-string",
            streams = 1,
            validate = function(hash: string)
                local bytes <const> = readStrings(sourcePath, true)
                checkHash("reader-string", bytes, hash)
            end,
            operation = function(): Observation
                local _, count = readStrings(sourcePath, false)
                return observed(count)
            end,
        },
        {
            label = "reader-into",
            streams = 1,
            validate = function(hash: string)
                local bytes <const> = readInto(sourcePath, true)
                checkHash("reader-into", bytes, hash)
            end,
            operation = function(): Observation
                local _, count, capacity = readInto(sourcePath, false)
                return observed(count, capacity)
            end,
        },
        {
            label = "write-whole",
            streams = 1,
            validate = function(hash: string)
                writeWhole(sinkPath, fixture)
                checkHash("write-whole", readWhole(sinkPath), hash)
            end,
            operation = function(): Observation writeWhole(sinkPath, fixture); return observed(size) end,
        },
        {
            label = "writer-string",
            streams = 1,
            validate = function(hash: string)
                writeStrings(sinkPath, fixture)
                checkHash("writer-string", readWhole(sinkPath), hash)
            end,
            operation = function(): Observation writeStrings(sinkPath, fixture); return observed(size) end,
        },
        {
            label = "writer-from",
            streams = 1,
            validate = function(hash: string)
                writeFrom(sinkPath, sourceBuffer)
                checkHash("writer-from", readWhole(sinkPath), hash)
            end,
            operation = function(): Observation
                writeFrom(sinkPath, sourceBuffer)
                return observed(size, sourceBuffer:capacity())
            end,
        },
        {
            label = "string-buffer",
            streams = 1,
            validate = function(hash: string)
                local source <const> = ioModule.newStringStream(fixture)
                local output <const> = source:transferToBuffer()
                checkBuffer("string-buffer", output, hash)
                output:close()
                source:close()
            end,
            operation = function(): Observation
                local source <const> = ioModule.newStringStream(fixture)
                local value <const> = source:transferToBuffer()
                local result <const> = syncObservation(
                    value,
                    function(output: IOBuffer): integer return output:length() end,
                    function(output: IOBuffer): integer return output:capacity() end
                )
                value:close()
                source:close()
                return result
            end,
        },
        {
            label = "buffer-alias",
            streams = 1,
            validate = function(hash: string)
                local source <const> = sourceBuffer:newStream()
                local output <const> = source:transferToBuffer()
                if output ~= sourceBuffer then
                    error("bench: buffer-alias did not retain the source Buffer", 0)
                end
                checkBuffer("buffer-alias", output, hash)
                source:close()
            end,
            operation = function(): Observation
                local source <const> = sourceBuffer:newStream()
                local value <const> = source:transferToBuffer()
                local result <const> = syncObservation(
                    value,
                    function(output: IOBuffer): integer return output:length() end,
                    function(output: IOBuffer): integer return output:capacity() end
                )
                if value ~= sourceBuffer then
                    error("bench: buffer-alias did not retain the source Buffer", 0)
                end
                source:close()
                return result
            end,
        },
        {
            label = "byte-buffer",
            streams = 1,
            validate = function(hash: string)
                local source <const> = ioModule.newByteStream(sourceBuffer:getFFIPointer() as loader.CValue, size)
                local output <const> = source:transferToBuffer()
                checkBuffer("byte-buffer", output, hash)
                output:close()
                source:close()
            end,
            operation = function(): Observation
                local source <const> = ioModule.newByteStream(sourceBuffer:getFFIPointer() as loader.CValue, size)
                local value <const> = source:transferToBuffer()
                local result <const> = syncObservation(
                    value,
                    function(output: IOBuffer): integer return output:length() end,
                    function(output: IOBuffer): integer return output:capacity() end
                )
                value:close()
                source:close()
                return result
            end,
        },
        {
            label = "file-buffer",
            streams = 1,
            validate = function(hash: string)
                local source <const> = ioModule.newFileStream(sourcePath)
                local output <const> = source:transferToBuffer()
                checkBuffer("file-buffer", output, hash)
                output:close()
                source:close()
            end,
            operation = function(): Observation
                local source <const> = ioModule.newFileStream(sourcePath)
                local value <const> = source:transferToBuffer()
                local result <const> = syncObservation(
                    value,
                    function(output: IOBuffer): integer return output:length() end,
                    function(output: IOBuffer): integer return output:capacity() end
                )
                value:close()
                source:close()
                return result
            end,
        },
        {
            label = "string-transfer",
            streams = 1,
            validate = function(hash: string)
                local output <const> = ioModule.newBuffer()
                local source <const> = ioModule.newStringStream(fixture)
                local destination <const> = output:newStream()
                local _ <const> = source:transferTo(destination)
                checkBuffer("string-transfer", output, hash)
                source:close()
                destination:close()
                output:close()
            end,
            operation = function(): Observation
                local output <const> = ioModule.newBuffer()
                local source <const> = ioModule.newStringStream(fixture)
                local destination <const> = output:newStream()
                local value <const> = source:transferTo(destination)
                local result <const> = syncObservation(
                    value,
                    function(count: integer): integer return count end,
                    function(_count: integer): integer return output:capacity() end
                )
                source:close()
                destination:close()
                output:close()
                return result
            end,
        },
        {
            label = "file-transfer",
            streams = 1,
            validate = function(hash: string)
                local output <const> = ioModule.newBuffer()
                local source <const> = ioModule.newFileStream(sourcePath)
                local destination <const> = output:newStream()
                local _ <const> = source:transferTo(destination)
                checkBuffer("file-transfer", output, hash)
                source:close()
                destination:close()
                output:close()
            end,
            operation = function(): Observation
                local output <const> = ioModule.newBuffer()
                local source <const> = ioModule.newFileStream(sourcePath)
                local destination <const> = output:newStream()
                local value <const> = source:transferTo(destination)
                local result <const> = syncObservation(
                    value,
                    function(count: integer): integer return count end,
                    function(_count: integer): integer return output:capacity() end
                )
                source:close()
                destination:close()
                output:close()
                return result
            end,
        },
        {
            label = "buffer-file",
            streams = 1,
            validate = function(hash: string)
                local source <const> = sourceBuffer:newStream()
                local _ <const> = source:transferToFile(sinkPath)
                checkHash("buffer-file", readWhole(sinkPath), hash)
                source:close()
            end,
            operation = function(): Observation
                local source <const> = sourceBuffer:newStream()
                local value <const> = source:transferToFile(sinkPath)
                local result <const> = syncObservation(
                    value,
                    function(count: integer): integer return count end,
                    function(_count: integer): integer return sourceBuffer:capacity() end
                )
                source:close()
                return result
            end,
        },
        {
            label = "file-writebuf",
            streams = 1,
            validate = function(hash: string)
                local destination <const> = ioModule.newFileStream(sinkPath)
                local _ <const> = destination:writeBuffer(sourceBuffer)
                checkHash("file-writebuf", readWhole(sinkPath), hash)
                destination:close()
            end,
            operation = function(): Observation
                local destination <const> = ioModule.newFileStream(sinkPath)
                local value <const> = destination:writeBuffer(sourceBuffer)
                local result <const> = syncObservation(
                    value,
                    function(count: integer): integer return count end,
                    function(_count: integer): integer return sourceBuffer:capacity() end
                )
                destination:close()
                return result
            end,
        },
        {
            label = "concurrent-file",
            streams = CONCURRENCY,
            validate = function(hash: string)
                local outputs: {IOBuffer} = {}
                local sources: {iotypes.ReadableStream} = {}
                local destinations: {iotypes.WritableStream} = {}
                local counts: {integer} = {}
                for index = 1, CONCURRENCY do
                    outputs[index] = ioModule.newBuffer()
                    sources[index] = ioModule.newFileStream(sourcePath)
                    destinations[index] = outputs[index]:newStream()
                    counts[index] = assert(sources[index]:transferTo(destinations[index]))
                end
                for index = 1, CONCURRENCY do
                    local _ <const> = counts[index]
                    checkBuffer(format("concurrent-file[%d]", index), outputs[index], hash)
                    sources[index]:close()
                    destinations[index]:close()
                    outputs[index]:close()
                end
            end,
            operation = function(): Observation
                local outputs: {IOBuffer} = {}
                local sources: {iotypes.ReadableStream} = {}
                local destinations: {iotypes.WritableStream} = {}
                local counts: {integer} = {}
                for index = 1, CONCURRENCY do
                    outputs[index] = ioModule.newBuffer()
                    sources[index] = ioModule.newFileStream(sourcePath)
                    destinations[index] = outputs[index]:newStream()
                    counts[index] = assert(sources[index]:transferTo(destinations[index]))
                end

                local count = 0
                local capacity = 0
                for index = 1, CONCURRENCY do
                    count = count + counts[index]
                    capacity = capacity + outputs[index]:capacity()
                    sources[index]:close()
                    destinations[index]:close()
                    outputs[index]:close()
                end
                return observed(count, capacity)
            end,
        },
        {
            label = "fallback-file",
            streams = 1,
            validate = function(hash: string)
                local backend <const> = adapter.storage()
                local open <const> = backend.open
                backend.open = nil
                local ok, failure = pcall(function()
                    local source <const> = ioModule.newStringStream(fixture)
                    local _ <const> = source:transferToFile(sinkPath)
                    source:close()
                end) as (boolean, any)
                backend.open = open
                if not ok then
                    error(tostring(failure), 0)
                end
                checkHash("fallback-file", readWhole(sinkPath), hash)
            end,
            operation = function(): Observation
                local backend <const> = adapter.storage()
                local open <const> = backend.open
                backend.open = nil
                local ok, result = pcall(function(): Observation
                    local source <const> = ioModule.newStringStream(fixture)
                    local value <const> = source:transferToFile(sinkPath)
                    local observation <const> = syncObservation(
                        value,
                        function(count: integer): integer return count end,
                        function(_count: integer): integer return 0 end
                    )
                    source:close()
                    return observation
                end) as (boolean, any)
                backend.open = open
                if not ok then
                    error(tostring(result), 0)
                end
                return result as Observation
            end,
        },
    }

    local selectedCount = 0
    for index = 1, #cases do
        local case <const> = cases[index]
        if SELECTED_CASES[case.label] then
            selectedCount = selectedCount + 1
            case.validate(expected)
            if VALIDATE then
                local result <const> = case.operation()
                local expectedCount <const> = size * case.streams
                if result.count ~= expectedCount then
                    error(format("bench: %s processed %d of %d bytes", case.label, result.count, expectedCount), 0)
                end
            else
                measure(case, size, expected)
            end
        end
    end
    sourceBuffer:close()
    if VALIDATE then
        print(format("validated %d bytes across %d paths with CRC-32 %s", size, selectedCount, expected))
    end
end

local function run()
    local sourcePath <const> = temporaryName()
    local sinkPath <const> = temporaryName()
    local ok, failure = pcall(function()
        if VALIDATE then
            print(format("io: correctness only, endpoint chunk %d bytes, concurrency %d", CHUNK, CONCURRENCY))
        else
            print(
                format(
                    "io: %d samples after %d warmup, endpoint chunk %d bytes, concurrency %d",
                    SAMPLES,
                    WARMUP,
                    CHUNK,
                    CONCURRENCY
                )
            )
            print(
                format(
                    "%-17s %9s %2s %8s %8s %8s %10s %10s" .. " %9s %9s %9s %11s",
                    "path",
                    "bytes",
                    "n",
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
        for index = 1, #SIZES do
            runSize(sourcePath, sinkPath, SIZES[index])
        end
    end) as (boolean, any)

    collect("restart")
    files.remove(sourcePath)
    files.remove(sinkPath)
    if not ok then
        error(tostring(failure), 0)
    end
end

run()
