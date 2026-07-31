--- Streaming byte transforms into reusable `Buffer` destinations.
---
--- Every row writes its result directly into one retained Buffer:
---
---   hex        `newHexEncodeWriter`.
---   base64     `newBase64EncodeWriter`.
---   deflate    `newDeflateWriter`.
---   inflate    `newInflateReader`.
---   transcode  `newTranscodeWriter`.
---   utf8-string       `utf8.length` over a Lua string.
---   utf8-view         `utf8.length` over a retained ByteView.
---
--- Input construction, expected-result construction, hashing, Buffer
--- allocation, and retained-view allocation stay outside measured windows.
--- Each row measures steady-state reuse after warmup. Lua heap growth does
--- not include native Buffer allocations, so use latency and throughput as
--- the primary result.
---
---   BENCH_DATA_SIZES     Comma-separated input byte counts. Defaults to
---                        4096,65536,1048576.
---   BENCH_DATA_CASES     Comma-separated row labels. Defaults to every row.
---   BENCH_DATA_WARMUP    Untimed operations per row. Defaults to 5.
---   BENCH_DATA_SAMPLES   Measured operations per row. Defaults to 31.
---   BENCH_DATA_VALIDATE  Set to 1 for correctness only, with no timings.
---
--- The xtask runs this benchmark through system LuaJIT with native libraries
--- and no frame loop. Run measurements only on a quiet machine.

local getenv <const> = os.getenv
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
local type iotypes = require("tecs.io.types")
local data <const> = tecs.data
local ioModule <const> = tecs.io
local now <const> = tecs.platform.time.now
local type IOBuffer = iotypes.Buffer
local type Reader = iotypes.Reader
local type Writer = iotypes.Writer

local MAX_INTEGER <const> = 9007199254740991
local MIB <const> = 1024.0 * 1024.0
local VALIDATE <const> = getenv("BENCH_DATA_VALIDATE") == "1"

local record Case
    label: string
    bytes: integer
    run: function(): integer
    verify: function()
    close: function()
end

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

local WARMUP <const> = integerEnvironment("BENCH_DATA_WARMUP", 5)
local SAMPLES <const> = integerEnvironment("BENCH_DATA_SAMPLES", 31)
if SAMPLES < 1 and not VALIDATE then
    error("bench: BENCH_DATA_SAMPLES must be positive", 0)
end

local function sizesFromEnvironment(): {integer}
    local text <const> = getenv("BENCH_DATA_SIZES") or "4096,65536,1048576"
    local sizes: {integer} = {}
    for part in text:gmatch("[^,]+") do
        local value <const> = tonumber(part)
        if value == nil or value ~= floor(value) or value < 1 or value > MAX_INTEGER then
            error("bench: BENCH_DATA_SIZES must contain positive integers", 0)
        end
        sizes[#sizes + 1] = floor(value)
    end
    if #sizes == 0 then
        error("bench: BENCH_DATA_SIZES must contain at least one size", 0)
    end
    return sizes
end

local CASE_NAMES <const>: {string: boolean} = {
    hex = true,
    base64 = true,
    deflate = true,
    inflate = true,
    transcode = true,
    ["utf8-string"] = true,
    ["utf8-view"] = true,
}

local function selectedCases(): {string: boolean}
    local text <const> = getenv("BENCH_DATA_CASES")
    if text == nil then
        return CASE_NAMES
    end
    local selected: {string: boolean} = {}
    for label in text:gmatch("[^,]+") do
        if not CASE_NAMES[label] then
            error(format("bench: unknown BENCH_DATA_CASES label %q", label), 0)
        end
        selected[label] = true
    end
    if next(selected) == nil then
        error("bench: BENCH_DATA_CASES must name at least one row", 0)
    end
    return selected
end

local SELECTED <const> = selectedCases()

local function fixtureOf(size: integer): string
    local period <const> = "Tecs-data-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ\n"
    local repeats <const> = floor(size / #period)
    return period:rep(repeats) .. period:sub(1, size - repeats * #period)
end

local function percentile(values: {number}, fraction: number): number
    local at <const> = max(1, min(#values, ceil(#values * fraction)))
    return values[at]
end

local function digest(bytes: string): integer
    return data.crc32(bytes)
end

local function writeTransform(source: string, destination: IOBuffer, constructor: function(Writer): Writer): IOBuffer
    destination:clear()
    local writer <const> = constructor(destination:newWriter())
    assert(writer:write(source))
    assert(writer:close())
    return destination
end

local function readTransform(source: string, destination: IOBuffer, constructor: function(Reader): Reader): IOBuffer
    destination:clear()
    local reader <const> = constructor(ioModule.newStringReader(source))
    local writer <const> = destination:newWriter()
    assert(ioModule.transfer(reader, writer))
    reader:close()
    assert(writer:close())
    return destination
end

local function pairedCases(size: integer): {Case}
    local source <const> = fixtureOf(size)
    local cases: {Case} = {}

    local function addBuffer(label: string, operation: function(IOBuffer): IOBuffer, expected: string)
        if not SELECTED[label] then
            return
        end
        local destination <const> = ioModule.newBuffer()
        cases[#cases + 1] = {
            label = label,
            bytes = size,
            run = function(): integer return operation(destination):length() end,
            verify = function()
                if digest(destination:getString()) ~= digest(expected) then
                    error("bench: " .. label .. " produced the wrong bytes", 0)
                end
            end,
            close = function() destination:close() end,
        }
    end

    local expected = ioModule.newBuffer()
    local hex <const> = writeTransform(source, expected, ioModule.newHexEncodeWriter):getString()
    addBuffer(
        "hex",
        function(out: IOBuffer): IOBuffer return writeTransform(source, out, ioModule.newHexEncodeWriter) end,
        hex
    )

    local base64 <const> = writeTransform(source, expected, ioModule.newBase64EncodeWriter):getString()
    addBuffer(
        "base64",
        function(out: IOBuffer): IOBuffer return writeTransform(source, out, ioModule.newBase64EncodeWriter) end,
        base64
    )

    local compressed <const> = writeTransform(source, expected, ioModule.newDeflateWriter):getString()
    addBuffer(
        "deflate",
        function(out: IOBuffer): IOBuffer return writeTransform(source, out, ioModule.newDeflateWriter) end,
        compressed
    )
    addBuffer(
        "inflate",
        function(out: IOBuffer): IOBuffer return readTransform(compressed, out, ioModule.newInflateReader) end,
        source
    )

    local transcodeWriter <const> = function(destination: Writer): Writer
        return ioModule.newTranscodeWriter(destination, "UTF-8", "UTF-16LE")
    end
    local utf16 <const> = writeTransform(source, expected, transcodeWriter):getString()
    expected:close()
    addBuffer(
        "transcode", function(out: IOBuffer): IOBuffer return writeTransform(source, out, transcodeWriter) end, utf16
    )

    if SELECTED["utf8-string"] then
        local count = 0
        cases[#cases + 1] = {
            label = "utf8-string",
            bytes = size,
            run = function(): integer count = data.utf8.length(source); return count end,
            verify = function()
                if count ~= size then
                    error("bench: utf8-string returned the wrong count", 0)
                end
            end,
            close = function() end,
        }
    end

    if SELECTED["utf8-view"] then
        local owned <const> = ioModule.newBuffer(source)
        local view <const> = owned:view()
        local count = 0
        cases[#cases + 1] = {
            label = "utf8-view",
            bytes = size,
            run = function(): integer count = data.utf8.length(view); return count end,
            verify = function()
                if count ~= size then
                    error("bench: utf8-view returned the wrong count", 0)
                end
            end,
            close = function() view:close(); owned:close() end,
        }
    end
    return cases
end

local sink = 0

local function measure(case: Case)
    case.run()
    case.verify()
    if VALIDATE then
        print(format("validated %-18s %9d bytes", case.label, case.bytes))
        case.close()
        return
    end
    for _ = 1, WARMUP do
        sink = sink + case.run()
    end

    collect("collect")
    local heapBefore <const> = (collect("count") as number) * 1024.0
    local samples: {number} = {}
    collect("stop")
    for sample = 1, SAMPLES do
        local started <const> = now()
        sink = sink + case.run()
        samples[sample] = now() - started
    end
    local heapAfter <const> = (collect("count") as number) * 1024.0
    collect("restart")
    collect("collect")
    case.verify()

    sort(samples)
    local p50 <const> = percentile(samples, 0.50)
    local p95 <const> = percentile(samples, 0.95)
    local throughput <const> = case.bytes / MIB / p50
    local heapPerOperation <const> = max(0, heapAfter - heapBefore) / SAMPLES
    print(
        format(
            "%-18s %9d bytes  p50 %9.3f ms  p95 %9.3f ms  %9.1f MiB/s  heap %9.0f B/op",
            case.label,
            case.bytes,
            p50 * 1000.0,
            p95 * 1000.0,
            throughput,
            heapPerOperation
        )
    )
    case.close()
end

for _, size in ipairs(sizesFromEnvironment()) do
    for _, case in ipairs(pairedCases(size)) do
        measure(case)
    end
end

if sink == -1 then
    print(concat({"unreachable"}))
end
