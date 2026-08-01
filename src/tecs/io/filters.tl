--[=[
Incremental byte transforms over directional I/O endpoints.

The public constructors live on `tecs.io`. This module keeps the concrete
state machines below that surface so users depend only on `Reader` and
`Writer`.
]=]

local ffi <const> = require("ffi")
local buffer <const> = require("tecs.io.buffer")
local bufferpool <const> = require("tecs.io.bufferpool")
local pump <const> = require("tecs.io.pump")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local zlib <const> = require("tecs.ffi.zlib")
local type types = require("tecs.io.types")

local type IOBuffer = types.Buffer
local type ByteView = types.ByteView
local type Reader = types.Reader
local type Writer = types.Writer
local type Input = Reader | FILE
local type Output = Writer | FILE

local C <const> = zlib.C
local K <const> = zlib.K
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min

local CHUNK <const> = 64 * 1024
local DEFAULT_READ_BYTES <const> = 16 * 1024
local MAX_ZLIB_CHUNK <const> = 0x40000000
local MAX_INTEGER <const> = 9007199254740991
local DEFAULT_MAX_INFLATE_BYTES <const> = 256 * 1024 * 1024
local WINDOW_BITS <const> = 15
local VERSION <const> = loader.textConstants("zlib").ZLIB_VERSION
local STREAM_SIZE <const> = ffi.sizeof("z_stream") as integer

local inflateInit2 <const> = C.inflateInit2_ as function(
    stream: loader.CValue, windowBits: integer, version: string, size: integer
): integer
local inflate <const> = C.inflate as function(stream: loader.CValue, flush: integer): integer
local inflateEnd <const> = C.inflateEnd as function(stream: loader.CValue): integer
local deflateInit2 <const> = C.deflateInit2_ as function(
    stream: loader.CValue,
    level: integer,
    method: integer,
    windowBits: integer,
    memoryLevel: integer,
    strategy: integer,
    version: string,
    size: integer
): integer
local deflate <const> = C.deflate as function(stream: loader.CValue, flush: integer): integer
local deflateEnd <const> = C.deflateEnd as function(stream: loader.CValue): integer

local SDL <const> = sdl.C
local iconvOpen <const> = SDL.SDL_iconv_open as function(toEncoding: string, fromEncoding: string): loader.CPtr
local iconvClose <const> = SDL.SDL_iconv_close as function(handle: loader.CPtr): integer
local iconv <const> = SDL.SDL_iconv as function(
    handle: loader.CPtr,
    input: loader.CArray | nil,
    inputLeft: loader.CArray | nil,
    output: loader.CArray,
    outputLeft: loader.CArray
): loader.CValue
local ICONV_HANDLE_ERROR <const> = ffi.cast("SDL_iconv_t", -1) as loader.CPtr
local ICONV_ERROR <const> = ffi.cast("size_t", -1) as loader.CValue
local ICONV_E2BIG <const> = ffi.cast("size_t", -2) as loader.CValue
local ICONV_EILSEQ <const> = ffi.cast("size_t", -3) as loader.CValue
local ICONV_EINVAL <const> = ffi.cast("size_t", -4) as loader.CValue

local enum ReaderKind
    "inflate"
    "base64"
    "hex"
    "transcode"
end

local enum WriterKind
    "deflate"
    "base64"
    "hex"
    "transcode"
end

local record Converter
    handle: loader.CPtr
    fromEncoding: string
    normalized: string
    staging: IOBuffer
    carryLength: integer
    inputBytes: integer
    input: loader.CArray
    inputLeft: loader.CArray
    output: loader.CArray
    outputLeft: loader.CArray
end

local type InflateReaderOptions = types.InflateReaderOptions
local type DeflateWriterOptions = types.DeflateWriterOptions

local record FilterReader is Reader
    _kind: ReaderKind
    _source: Input
    _input: IOBuffer
    _output: IOBuffer
    _outputAt: integer
    _decodeCount: integer
    _decodeFirst: integer
    _decodeSecond: integer
    _decodeThird: integer
    _sawPadding: boolean
    _stream: loader.CValue
    _fields: loader.CStruct
    _sourceEOF: boolean
    _finished: boolean
    _closed: boolean
    _failure: string
    _produced: integer
    _maxBytes: integer
    _converter: Converter
end

local record FilterWriter is Writer
    _kind: WriterKind
    _destination: Output
    _output: IOBuffer
    _carryCount: integer
    _carryFirst: integer
    _carrySecond: integer
    _stream: loader.CValue
    _fields: loader.CStruct
    _closed: boolean
    _failure: string
    _closeResult: boolean
    _closeReason: string
    _converter: Converter
    _writePointer: function(self: FilterWriter, pointer: loader.BytePointer, length: integer): boolean, string
end

local FilterReaderMT <const>: metatable<FilterReader> = {__index = FilterReader}
local FilterWriterMT <const>: metatable<FilterWriter> = {__index = FilterWriter}
local rawSetMetatable <const> = setmetatable as function(any, any): any

local CODE_NAMES <const>: {integer: string} = {
    [K.Z_STREAM_ERROR] = "its state is inconsistent",
    [K.Z_DATA_ERROR] = "it is corrupt",
    [K.Z_MEM_ERROR] = "zlib could not allocate",
    [K.Z_VERSION_ERROR] = "the zlib in this process is not the one these bindings were generated against",
}

local function zlibReason(fields: loader.CStruct, status: integer): string
    if status == K.Z_NEED_DICT then
        return "tecs: this zlib stream needs a preset dictionary, which is not supported"
    end
    if fields.msg ~= nil then
        return ("tecs: the compressed stream is not valid: %s"):format(loader.toString(fields.msg as loader.CValue))
    end
    return ("tecs: the compressed stream is not valid: %s"):format(
        CODE_NAMES[status] or ("zlib returned %d"):format(status)
    )
end

local function nonNegative(value: integer, what: string, level: integer): integer
    if type(value) ~= "number" or value ~= floor(value) or value < 0 or value > MAX_INTEGER then
        error(("tecs: %s must be a non-negative integer"):format(what), level)
    end
    return value
end

local function checkedReader(value: Input, what: string): Input
    local dynamic <const> = value as {string: any}
    local kind <const> = type(value as any)
    if
        (kind ~= "table" and kind ~= "userdata" and kind ~= "cdata")
        or type(dynamic.read) ~= "function"
        or type(dynamic.close) ~= "function"
    then
        error(("tecs: %s must implement io.Reader"):format(what), 3)
    end
    return value
end

local function checkedWriter(value: Output, what: string): Output
    local dynamic <const> = value as {string: any}
    local kind <const> = type(value as any)
    if
        (kind ~= "table" and kind ~= "userdata" and kind ~= "cdata")
        or type(dynamic.write) ~= "function"
        or type(dynamic.flush) ~= "function"
        or type(dynamic.close) ~= "function"
    then
        error(("tecs: %s must implement io.Writer"):format(what), 3)
    end
    return value
end

local function base64Value(byte: integer): integer
    if byte >= 65 and byte <= 90 then
        return byte - 65
    elseif byte >= 97 and byte <= 122 then
        return byte - 71
    elseif byte >= 48 and byte <= 57 then
        return byte + 4
    elseif byte == 43 then
        return 62
    elseif byte == 47 then
        return 63
    end
    return nil
end

local BASE64 <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_BYTES <const>: {integer} = {}

local function hexValue(byte: integer): integer
    if byte >= 48 and byte <= 57 then
        return byte - 48
    elseif byte >= 65 and byte <= 70 then
        return byte - 55
    elseif byte >= 97 and byte <= 102 then
        return byte - 87
    end
    return nil
end

local HEX <const> = "0123456789abcdef"
local HEX_BYTES <const>: {integer} = {}
for index = 1, #BASE64 do
    BASE64_BYTES[index] = BASE64:byte(index) as integer
end
for index = 1, #HEX do
    HEX_BYTES[index] = HEX:byte(index) as integer
end

local function validEncoding(name: string, what: string)
    if type(name) ~= "string" or name == "" then
        error(("tecs: %s must be a non-empty encoding name"):format(what), 3)
    end
    if name:find("\0", 1, true) ~= nil then
        error(("tecs: %s must not contain NUL bytes"):format(what), 3)
    end
end

local function continuation(byte: integer): boolean
    return byte >= 0x80 and byte <= 0xBF
end

-- Returns the complete, valid prefix. An incomplete final character remains
-- in the converter until another write or end of input proves it truncated.
local function validUTF8Prefix(
    pointer: loader.BytePointer, length: integer, final: boolean, base: integer
): integer, string
    local index = 0
    while index < length do
        local first <const> = pointer[index] as integer
        local count = 0
        local secondMin = 0x80
        local secondMax = 0xBF
        if first <= 0x7F then
            index = index + 1
        elseif first >= 0xC2 and first <= 0xDF then
            count = 1
        elseif first >= 0xE0 and first <= 0xEF then
            count = 2
            if first == 0xE0 then
                secondMin = 0xA0
            elseif first == 0xED then
                secondMax = 0x9F
            end
        elseif first >= 0xF0 and first <= 0xF4 then
            count = 3
            if first == 0xF0 then
                secondMin = 0x90
            elseif first == 0xF4 then
                secondMax = 0x8F
            end
        else
            return nil, ("tecs: invalid UTF-8 input at byte %d"):format(base + index + 1)
        end
        if count > 0 then
            if index + count >= length then
                if final then
                    return nil, ("tecs: incomplete UTF-8 input at byte %d"):format(base + index + 1)
                end
                return index
            end
            local second <const> = pointer[index + 1] as integer
            if second < secondMin or second > secondMax then
                return nil, ("tecs: invalid UTF-8 input at byte %d"):format(base + index + 1)
            end
            for offset = 2, count do
                if not continuation(pointer[index + offset] as integer) then
                    return nil, ("tecs: invalid UTF-8 input at byte %d"):format(base + index + 1)
                end
            end
            index = index + count + 1
        end
    end
    return length
end

local function word(pointer: loader.BytePointer, index: integer, little: boolean): integer
    local first <const> = pointer[index] as integer
    local second <const> = pointer[index + 1] as integer
    return little and first + second * 0x100 or first * 0x100 + second
end

local function validUTF16Prefix(
    pointer: loader.BytePointer, length: integer, final: boolean, base: integer, little: boolean, name: string
): integer, string
    local index = 0
    while index < length do
        if index + 1 >= length then
            if final then
                return nil, ("tecs: incomplete %s input at byte %d"):format(name, base + index + 1)
            end
            return index
        end
        local first <const> = word(pointer, index, little)
        if first >= 0xD800 and first <= 0xDBFF then
            if index + 3 >= length then
                if final then
                    return nil, ("tecs: incomplete %s input at byte %d"):format(name, base + index + 1)
                end
                return index
            end
            local second <const> = word(pointer, index + 2, little)
            if second < 0xDC00 or second > 0xDFFF then
                return nil, ("tecs: invalid %s input at byte %d"):format(name, base + index + 1)
            end
            index = index + 4
        elseif first >= 0xDC00 and first <= 0xDFFF then
            return nil, ("tecs: invalid %s input at byte %d"):format(name, base + index + 1)
        else
            index = index + 2
        end
    end
    return length
end

local function validUTF32Prefix(
    pointer: loader.BytePointer, length: integer, final: boolean, base: integer, little: boolean, name: string
): integer, string
    local complete <const> = length - length % 4
    if final and complete ~= length then
        return nil, ("tecs: incomplete %s input at byte %d"):format(name, base + complete + 1)
    end
    for index = 0, complete - 1, 4 do
        local a <const> = pointer[index] as integer
        local b <const> = pointer[index + 1] as integer
        local c <const> = pointer[index + 2] as integer
        local d <const> = pointer[index + 3] as integer
        local codepoint = little and a + b * 0x100 + c * 0x10000 + d * 0x1000000
            or a * 0x1000000 + b * 0x10000 + c * 0x100 + d
        if codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
            return nil, ("tecs: invalid %s input at byte %d"):format(name, base + index + 1)
        end
    end
    return complete
end

local function validPrefix(
    converter: Converter, pointer: loader.BytePointer, length: integer, final: boolean, base: integer
): integer, string
    local normalized <const> = converter.normalized
    if normalized == "UTF8" then
        return validUTF8Prefix(pointer, length, final, base)
    elseif normalized == "UTF16LE" then
        return validUTF16Prefix(pointer, length, final, base, true, converter.fromEncoding)
    elseif normalized == "UTF16BE" then
        return validUTF16Prefix(pointer, length, final, base, false, converter.fromEncoding)
    elseif normalized == "UTF32LE" or normalized == "UCS4LE" then
        return validUTF32Prefix(pointer, length, final, base, true, converter.fromEncoding)
    elseif normalized == "UTF32BE" or normalized == "UCS4BE" then
        return validUTF32Prefix(pointer, length, final, base, false, converter.fromEncoding)
    end
    return length
end

local function retainConverterSuffix(converter: Converter, pointer: loader.BytePointer, length: integer)
    local staging <const> = converter.staging:getFFIPointer()
    for index = 0, length - 1 do
        staging[index] = pointer[index]
    end
    converter.carryLength = length
    converter.staging:resize(length)
end

local function convertPointer(
    converter: Converter, pointer: loader.BytePointer, length: integer, final: boolean, destination: IOBuffer
): boolean, string
    destination:clear()
    local total <const> = converter.carryLength + length
    if length > 0 then
        local staging <const>, previous = buffer.prepareWrite(converter.staging, converter.carryLength, length)
        ffi.copy(staging as ffi.CData, pointer as ffi.CData, length)
        buffer.commitWrite(converter.staging, converter.carryLength, length, previous)
    end
    converter.inputBytes = converter.inputBytes + length
    local staging <const> = converter.staging:getFFIPointer()
    local taking, invalid <const> = validPrefix(converter, staging, total, final, converter.inputBytes - total)
    if taking == nil then
        return false, invalid
    end

    converter.input[0] = ffi.cast("const char *", staging)
    converter.inputLeft[0] = taking
    local produced = 0
    while tonumber(converter.inputLeft[0]) > 0 do
        local outputPointer <const>, previous = buffer.prepareWrite(destination, produced, CHUNK)
        converter.output[0] = outputPointer
        converter.outputLeft[0] = CHUNK
        local result <const> = iconv(
            converter.handle, converter.input, converter.inputLeft, converter.output, converter.outputLeft
        )
        local wrote <const> = CHUNK - (tonumber(converter.outputLeft[0]) as integer)
        buffer.commitWrite(destination, produced, wrote, previous)
        produced = produced + wrote
        if result == ICONV_E2BIG then

        elseif result == ICONV_EINVAL and not final then
            local remaining <const> = tonumber(converter.inputLeft[0]) as integer
            retainConverterSuffix(converter, ffi.cast("uint8_t *", converter.input[0]) as loader.BytePointer, remaining)
            return true
        elseif result == ICONV_EILSEQ or result == ICONV_EINVAL or result == ICONV_ERROR then
            return false, ("tecs: invalid or incomplete %s input"):format(converter.fromEncoding)
        elseif tonumber(converter.inputLeft[0]) == 0 then
            break
        else
            return false, ("tecs: cannot transcode %s input"):format(converter.fromEncoding)
        end
    end
    retainConverterSuffix(converter, staging + taking, total - taking)
    if final then
        if converter.carryLength > 0 then
            return false, ("tecs: incomplete %s input"):format(converter.fromEncoding)
        end
        while true do
            local outputPointer <const>, previous = buffer.prepareWrite(destination, produced, CHUNK)
            converter.output[0] = outputPointer
            converter.outputLeft[0] = CHUNK
            local result <const> = iconv(converter.handle, nil, nil, converter.output, converter.outputLeft)
            local wrote <const> = CHUNK - (tonumber(converter.outputLeft[0]) as integer)
            buffer.commitWrite(destination, produced, wrote, previous)
            produced = produced + wrote
            if result == ICONV_E2BIG then

            elseif result == ICONV_ERROR or result == ICONV_EILSEQ or result == ICONV_EINVAL then
                return false, "tecs: target encoding could not be finalized"
            else
                break
            end
        end
    end
    return true
end

local function newConverter(fromEncoding: string, toEncoding: string): Converter
    validEncoding(fromEncoding, "fromEncoding")
    validEncoding(toEncoding, "toEncoding")
    local handle <const> = iconvOpen(toEncoding, fromEncoding)
    if handle == ICONV_HANDLE_ERROR then
        error(("tecs: cannot transcode from %q to %q"):format(fromEncoding, toEncoding), 3)
    end
    return {
        handle = handle,
        fromEncoding = fromEncoding,
        normalized = fromEncoding:upper():gsub("[_%-]", ""),
        staging = bufferpool.acquire(CHUNK),
        carryLength = 0,
        inputBytes = 0,
        input = loader.newArray("const char *[1]"),
        inputLeft = loader.newArray("size_t[1]"),
        output = loader.newArray("char *[1]"),
        outputLeft = loader.newArray("size_t[1]"),
    }
end

local function closeConverter(converter: Converter): boolean
    if converter == nil then
        return true
    end
    local closed = true
    if converter.handle ~= nil then
        closed = iconvClose(converter.handle) == 0
        converter.handle = nil
    end
    if converter.staging ~= nil then
        bufferpool.release(converter.staging)
        converter.staging = nil
    end
    return closed
end

local function outputAvailable(self: FilterReader): integer
    return self._output:length() - self._outputAt
end

local function readSourcePointer(self: FilterReader): loader.BytePointer, integer, string
    local dynamic <const> = self._source as {string: any}
    if type(dynamic._readPointer) == "function" then
        return (dynamic._readPointer as function(any, integer): loader.BytePointer, integer, string)(
            self._source, CHUNK
        )
    end
    local read <const>, reason = pump.readInto(self._source, self._input, 0, CHUNK)
    return read ~= nil and read > 0 and self._input:getFFIPointer() or nil, read, reason
end

local function fillHexReader(self: FilterReader, pointer: loader.BytePointer, length: integer): string
    local capacity <const> = floor((self._decodeCount + length) / 2)
    local output <const>, previous = buffer.prepareWrite(self._output, 0, capacity)
    local wrote = 0
    for index = 0, length - 1 do
        local value <const> = hexValue(pointer[index] as integer)
        if value == nil then
            buffer.commitWrite(self._output, 0, 0, previous)
            return "tecs: hexadecimal text contains a non-hexadecimal character"
        end
        if self._decodeCount == 0 then
            self._decodeFirst = value
            self._decodeCount = 1
        else
            output[wrote] = self._decodeFirst * 16 + value
            wrote = wrote + 1
            self._decodeCount = 0
        end
    end
    buffer.commitWrite(self._output, 0, wrote, previous)
    return nil
end

local function fillBase64Reader(self: FilterReader, pointer: loader.BytePointer, length: integer): string
    local capacity <const> = floor((self._decodeCount + length) / 4) * 3
    local output <const>, previous = buffer.prepareWrite(self._output, 0, capacity)
    local wrote = 0
    for index = 0, length - 1 do
        local byte <const> = pointer[index] as integer
        if self._sawPadding then
            buffer.commitWrite(self._output, 0, 0, previous)
            return "tecs: Base64 text has malformed padding"
        end
        if self._decodeCount == 0 then
            self._decodeFirst = byte
        elseif self._decodeCount == 1 then
            self._decodeSecond = byte
        elseif self._decodeCount == 2 then
            self._decodeThird = byte
        else
            local first <const> = base64Value(self._decodeFirst)
            local second <const> = base64Value(self._decodeSecond)
            if first == nil or second == nil then
                buffer.commitWrite(self._output, 0, 0, previous)
                return "tecs: Base64 text contains a character outside the RFC 4648 alphabet"
            end
            output[wrote] = first * 4 + floor(second / 16)
            wrote = wrote + 1
            if self._decodeThird == 61 then
                if byte ~= 61 or second % 16 ~= 0 then
                    buffer.commitWrite(self._output, 0, 0, previous)
                    return "tecs: Base64 text has malformed padding"
                end
                self._sawPadding = true
            else
                local third <const> = base64Value(self._decodeThird)
                if third == nil then
                    buffer.commitWrite(self._output, 0, 0, previous)
                    return "tecs: Base64 text contains a character outside the RFC 4648 alphabet"
                end
                output[wrote] = second % 16 * 16 + floor(third / 4)
                wrote = wrote + 1
                if byte == 61 then
                    if third % 4 ~= 0 then
                        buffer.commitWrite(self._output, 0, 0, previous)
                        return "tecs: Base64 text has malformed padding"
                    end
                    self._sawPadding = true
                else
                    local fourth <const> = base64Value(byte)
                    if fourth == nil then
                        buffer.commitWrite(self._output, 0, 0, previous)
                        return "tecs: Base64 text contains a character outside the RFC 4648 alphabet"
                    end
                    output[wrote] = third % 4 * 64 + fourth
                    wrote = wrote + 1
                end
            end
            self._decodeCount = -1
        end
        self._decodeCount = self._decodeCount + 1
    end
    buffer.commitWrite(self._output, 0, wrote, previous)
    return nil
end

local function fillTextReader(self: FilterReader): boolean, string
    self._output:clear()
    self._outputAt = 0
    while self._output:length() == 0 and not self._finished do
        local pointer <const>, read, reason = readSourcePointer(self)
        if read == nil then
            return false, reason
        end
        if read == 0 then
            self._finished = true
            if self._decodeCount ~= 0 then
                return false,
                    self._kind == "hex" and "tecs: hexadecimal text must contain whole byte pairs"
                        or "tecs: Base64 text length must be a multiple of four"
            end
            return true
        end
        local invalid: string
        if self._kind == "hex" then
            invalid = fillHexReader(self, pointer, read)
        else
            invalid = fillBase64Reader(self, pointer, read)
        end
        if invalid ~= nil then
            return false, invalid
        end
    end
    return true
end

local function feedInflateReader(self: FilterReader): boolean, string
    if self._fields.avail_in ~= 0 or self._sourceEOF then
        return true
    end
    local pointer <const>, read, reason = readSourcePointer(self)
    if read == nil then
        return false, reason
    end
    if read == 0 then
        self._sourceEOF = true
    else
        self._fields.next_in = pointer
        self._fields.avail_in = read
    end
    return true
end

local function inflateInto(self: FilterReader, destination: IOBuffer, count: integer, offset: integer): integer, string
    while not self._finished do
        local fed <const>, feedReason = feedInflateReader(self)
        if not fed then
            return nil, feedReason
        end
        local remaining <const> = self._maxBytes - self._produced
        local room <const> = min(count, remaining + 1)
        local output <const>, previous = buffer.prepareWrite(destination, offset, room)
        self._fields.next_out = output
        self._fields.avail_out = room
        local status <const> = inflate(self._stream, K.Z_NO_FLUSH)
        local wrote <const> = room - (self._fields.avail_out as integer)
        if wrote > remaining then
            buffer.commitWrite(destination, offset, 0, previous)
            return nil, ("tecs: inflated data exceeds maxBytes (%d)"):format(self._maxBytes)
        end
        if status == K.Z_STREAM_END then
            self._finished = true
        elseif status ~= K.Z_OK and status ~= K.Z_BUF_ERROR then
            buffer.commitWrite(destination, offset, 0, previous)
            return nil, zlibReason(self._fields, status)
        elseif self._sourceEOF and self._fields.avail_in == 0 and wrote == 0 then
            buffer.commitWrite(destination, offset, 0, previous)
            return nil, "tecs: the compressed stream ends inside a block"
        end
        buffer.commitWrite(destination, offset, wrote, previous)
        self._produced = self._produced + wrote
        if wrote > 0 then
            return wrote
        end
    end
    return 0
end

local function fillInflateReader(self: FilterReader): boolean, string
    self._output:clear()
    self._outputAt = 0
    local wrote <const>, reason = inflateInto(self, self._output, CHUNK, 0)
    return wrote ~= nil, reason
end

local function fillTranscodeReader(self: FilterReader): boolean, string
    self._output:clear()
    self._outputAt = 0
    while self._output:length() == 0 and not self._finished do
        local pointer <const>, read, reason = readSourcePointer(self)
        if read == nil then
            return false, reason
        end
        local final <const> = read == 0
        local ok, convertReason <const> = convertPointer(self._converter, pointer, read, final, self._output)
        if not ok then
            return false, convertReason
        end
        if final then
            self._finished = true
        end
    end
    return true
end

local function fillReader(self: FilterReader): boolean, string
    if self._failure ~= nil then
        return false, self._failure
    end
    local ok: boolean
    local reason: string
    if self._kind == "inflate" then
        ok, reason = fillInflateReader(self)
    elseif self._kind == "transcode" then
        ok, reason = fillTranscodeReader(self)
    else
        ok, reason = fillTextReader(self)
    end
    if not ok then
        self._failure = reason
    end
    return ok, reason
end

function FilterReader:read(count: integer): string, string
    if self._closed then
        return nil, "the reader is closed"
    end
    local wanted <const> = max(1, count)
    if outputAvailable(self) == 0 then
        local ok, reason <const> = fillReader(self)
        if not ok then
            return nil, reason
        end
    end
    local taking <const> = min(wanted, outputAvailable(self))
    if taking == 0 then
        return ""
    end
    local result <const> = loader.toBytes((self._output:getFFIPointer() + self._outputAt) as loader.CValue, taking)
    self._outputAt = self._outputAt + taking
    return result
end

function FilterReader:readInto(destination: IOBuffer, offset?: integer, count?: integer): integer, string
    if self._closed then
        return nil, "the reader is closed"
    end
    offset = nonNegative(offset or 0, "Reader:readInto offset", 2)
    count = nonNegative(count or DEFAULT_READ_BYTES, "Reader:readInto count", 2)
    if count == 0 then
        return 0
    end
    if self._failure ~= nil then
        return nil, self._failure
    end
    if self._kind == "inflate" and outputAvailable(self) == 0 then
        local wrote <const>, reason = inflateInto(self, destination, count, offset)
        if wrote == nil then
            self._failure = reason
        end
        return wrote, reason
    end
    if outputAvailable(self) == 0 then
        local ok, reason <const> = fillReader(self)
        if not ok then
            return nil, reason
        end
    end
    local taking <const> = min(count, outputAvailable(self))
    if taking == 0 then
        return 0
    end
    local output <const>, previous = buffer.prepareWrite(destination, offset, taking)
    ffi.copy(output as ffi.CData, (self._output:getFFIPointer() + self._outputAt) as ffi.CData, taking)
    buffer.commitWrite(destination, offset, taking, previous)
    self._outputAt = self._outputAt + taking
    return taking
end

function FilterReader:close()
    if self._closed then
        return
    end
    self._closed = true
    if self._stream ~= nil then
        inflateEnd(self._stream)
        self._stream = nil
        self._fields = nil
    end
    closeConverter(self._converter)
    bufferpool.release(self._input)
    bufferpool.release(self._output)
    local source <const> = self._source as {string: any}
    (source.close as function(any))(self._source)
end

local function writeOutput(self: FilterWriter): boolean, string
    local offset = 0
    local length <const> = self._output:length()
    while offset < length do
        local wrote, reason = pump.writeFrom(self._destination, self._output, offset, length - offset)
        if wrote == nil then
            return false, reason
        end
        if wrote == 0 then
            return false, "the destination accepted no bytes"
        end
        offset = offset + wrote
    end
    return true
end

local function reserveWriterOutput(self: FilterWriter, count: integer): loader.BytePointer, boolean, integer, string
    local dynamic <const> = self._destination as {string: any}
    if type(dynamic._reserve) == "function" and type(dynamic._commit) == "function" then
        local output <const>, reason = (dynamic._reserve as function(any, integer): loader.BytePointer, string)(
            self._destination, count
        )
        return output, true, 0, reason
    end
    self._output:clear()
    local output <const>, previous = buffer.prepareWrite(self._output, 0, count)
    return output, false, previous
end

local function commitWriterOutput(
    self: FilterWriter, direct: boolean, wrote: integer, previous: integer
): boolean, string
    if direct then
        local dynamic <const> = self._destination as {string: any}
        local commit <const> = dynamic._commit as function(any, integer)
        commit(self._destination, wrote)
        return true
    end
    buffer.commitWrite(self._output, 0, wrote, previous)
    return writeOutput(self)
end

local function combinedByte(
    self: FilterWriter, pointer: loader.BytePointer, carryCount: integer, index: integer
): integer
    if index == 0 and carryCount > 0 then
        return self._carryFirst
    elseif index == 1 and carryCount > 1 then
        return self._carrySecond
    end
    return pointer[index - carryCount] as integer
end

local function encodeBase64Pointer(
    self: FilterWriter, pointer: loader.BytePointer, length: integer, final: boolean
): boolean, string
    local carryCount <const> = self._carryCount or 0
    local total <const> = carryCount + length
    local groups <const> = floor(total / 3)
    local remaining <const> = total - groups * 3
    local outputLength <const> = groups * 4 + (final and remaining > 0 and 4 or 0)
    local output: loader.BytePointer
    local direct: boolean
    local previous: integer
    local reason: string
    if outputLength > 0 then
        output, direct, previous, reason = reserveWriterOutput(self, outputLength)
        if output == nil then
            return false, reason
        end
    end
    local at = 0
    for group = 0, groups - 1 do
        local index <const> = group * 3
        local first <const> = carryCount == 0 and pointer[index] as integer
            or combinedByte(self, pointer, carryCount, index)
        local second <const> = carryCount == 0 and pointer[index + 1] as integer
            or combinedByte(self, pointer, carryCount, index + 1)
        local third <const> = carryCount == 0 and pointer[index + 2] as integer
            or combinedByte(self, pointer, carryCount, index + 2)
        output[at] = BASE64_BYTES[floor(first / 4) + 1]
        output[at + 1] = BASE64_BYTES[(first % 4) * 16 + floor(second / 16) + 1]
        output[at + 2] = BASE64_BYTES[(second % 16) * 4 + floor(third / 64) + 1]
        output[at + 3] = BASE64_BYTES[third % 64 + 1]
        at = at + 4
    end
    if final and remaining > 0 then
        local index <const> = groups * 3
        local first <const> = combinedByte(self, pointer, carryCount, index)
        local second = remaining == 2 and combinedByte(self, pointer, carryCount, index + 1) or 0
        output[at] = BASE64_BYTES[floor(first / 4) + 1]
        output[at + 1] = BASE64_BYTES[(first % 4) * 16 + floor(second / 16) + 1]
        output[at + 2] = remaining == 2 and BASE64_BYTES[(second % 16) * 4 + 1] or 61
        output[at + 3] = 61
    end
    if outputLength > 0 then
        local committed <const>, commitReason = commitWriterOutput(self, direct, outputLength, previous)
        if not committed then
            return false, commitReason
        end
    end
    if final then
        self._carryCount = 0
    else
        local index <const> = groups * 3
        self._carryCount = remaining
        self._carryFirst = remaining > 0 and combinedByte(self, pointer, carryCount, index) or 0
        self._carrySecond = remaining > 1 and combinedByte(self, pointer, carryCount, index + 1) or 0
    end
    return true
end

local function encodeHexPointer(self: FilterWriter, pointer: loader.BytePointer, length: integer): boolean, string
    if length > floor(MAX_INTEGER / 2) then
        return false, "tecs: hexadecimal output is too large"
    end
    local outputLength <const> = length * 2
    if outputLength == 0 then
        return true
    end
    local output <const>, direct, previous, reason = reserveWriterOutput(self, outputLength)
    if output == nil then
        return false, reason
    end
    for index = 0, length - 1 do
        local byte <const> = pointer[index] as integer
        output[index * 2] = HEX_BYTES[floor(byte / 16) + 1]
        output[index * 2 + 1] = HEX_BYTES[byte % 16 + 1]
    end
    return commitWriterOutput(self, direct, outputLength, previous)
end

local function deflateBytes(
    self: FilterWriter, pointer: loader.BytePointer, length: integer, flush: integer
): boolean, string
    self._fields.next_in = pointer
    self._fields.avail_in = length
    repeat
        local output <const>, direct, previous, reserveReason = reserveWriterOutput(self, CHUNK)
        if output == nil then
            return false, reserveReason
        end
        self._fields.next_out = output
        self._fields.avail_out = CHUNK
        local status <const> = deflate(self._stream, flush)
        local wrote <const> = CHUNK - (self._fields.avail_out as integer)
        if status == K.Z_BUF_ERROR and flush == K.Z_SYNC_FLUSH and self._fields.avail_in == 0 then
            commitWriterOutput(self, direct, 0, previous)
            return true
        elseif status ~= K.Z_OK and status ~= K.Z_STREAM_END then
            commitWriterOutput(self, direct, 0, previous)
            return false, zlibReason(self._fields, status)
        end
        local ok, reason <const> = commitWriterOutput(self, direct, wrote, previous)
        if not ok then
            return false, reason
        end
        if flush == K.Z_FINISH and status == K.Z_STREAM_END then
            return true
        end
    until self._fields.avail_in == 0 and self._fields.avail_out ~= 0
    return true
end

local function writePointer(self: FilterWriter, pointer: loader.BytePointer, length: integer): boolean, string
    if self._failure ~= nil then
        return false, self._failure
    end
    local ok: boolean
    local reason: string
    if self._kind == "deflate" then
        ok = true
        local offset = 0
        while ok and offset < length do
            local taking <const> = min(length - offset, MAX_ZLIB_CHUNK)
            ok, reason = deflateBytes(self, pointer + offset, taking, K.Z_NO_FLUSH)
            offset = offset + taking
        end
    elseif self._kind == "transcode" then
        ok = true
        local offset = 0
        while ok and offset < length do
            local taking <const> = min(length - offset, CHUNK)
            ok, reason = convertPointer(self._converter, pointer + offset, taking, false, self._output)
            if ok then
                ok, reason = writeOutput(self)
            end
            offset = offset + taking
        end
    elseif self._kind == "hex" then
        ok, reason = encodeHexPointer(self, pointer, length)
    else
        ok, reason = encodeBase64Pointer(self, pointer, length, false)
    end
    if not ok then
        self._failure = reason
    end
    return ok, reason
end

function FilterWriter:write(bytes: string): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    return self:_writePointer(ffi.cast("uint8_t *", bytes) as loader.BytePointer, #bytes)
end

function FilterWriter:_writePointer(pointer: loader.BytePointer, length: integer): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    return writePointer(self, pointer, length)
end

function FilterWriter:writeFrom(source: IOBuffer, offset?: integer, count?: integer): integer, string
    if self._closed then
        return nil, "the writer is closed"
    end
    offset = nonNegative(offset or 0, "Writer:writeFrom offset", 2)
    local length <const> = source:length()
    if offset > length then
        error("tecs: Writer:writeFrom offset is past the buffer length", 2)
    end
    count = count == nil and length - offset or nonNegative(count, "Writer:writeFrom count", 2)
    if count > length - offset then
        error("tecs: Writer:writeFrom range is past the buffer length", 2)
    end
    local ok, reason <const> = self:_writePointer(source:getFFIPointer() + offset, count)
    if not ok then
        return nil, reason
    end
    return count
end

function FilterWriter:writeView(source: ByteView, offset?: integer, count?: integer): integer, string
    if self._closed then
        return nil, "the writer is closed"
    end
    offset = nonNegative(offset or 0, "Writer:writeView offset", 2)
    local length <const> = source:length()
    if offset > length then
        error("tecs: Writer:writeView offset is past the view length", 2)
    end
    count = count == nil and length - offset or nonNegative(count, "Writer:writeView count", 2)
    if count > length - offset then
        error("tecs: Writer:writeView range is past the view length", 2)
    end
    local ok, reason <const> = self:_writePointer(source:getFFIPointer() + offset, count)
    if not ok then
        return nil, reason
    end
    return count
end

function FilterWriter:flush(): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    if self._failure ~= nil then
        return false, self._failure
    end
    if self._kind == "deflate" then
        local ok, reason <const> = deflateBytes(self, nil, 0, K.Z_SYNC_FLUSH)
        if not ok then
            self._failure = reason
            return false, reason
        end
    end
    local destination <const> = self._destination as {string: any}
    local ok, reason <const> = (destination.flush as function(any): boolean, string)(self._destination)
    if not ok then
        self._failure = reason
    end
    return ok, reason
end

function FilterWriter:close(): boolean, string
    if self._closed then
        return self._closeResult, self._closeReason
    end
    self._closed = true
    local ok = self._failure == nil
    local reason = self._failure
    if ok and self._kind == "deflate" then
        ok, reason = deflateBytes(self, nil, 0, K.Z_FINISH)
    elseif ok and self._kind == "transcode" then
        ok, reason = convertPointer(self._converter, nil, 0, true, self._output)
        if ok then
            ok, reason = writeOutput(self)
        end
    elseif ok and self._kind == "base64" then
        ok, reason = encodeBase64Pointer(self, nil, 0, true)
    end
    if self._stream ~= nil then
        deflateEnd(self._stream)
        self._stream = nil
        self._fields = nil
    end
    if not closeConverter(self._converter) and ok then
        ok = false
        reason = "tecs: SDL could not close the conversion context"
    end
    bufferpool.release(self._output)
    local destination <const> = self._destination as {string: any}
    local closed, closeReason <const> = (destination.close as function(any): boolean, string)(self._destination)
    if ok and not closed then
        ok = false
        reason = closeReason
    end
    self._closeResult = ok
    self._closeReason = reason
    return ok, reason
end

local function newTextReader(kind: ReaderKind, source: Input): Reader
    return rawSetMetatable(
        {
            _kind = kind,
            _source = checkedReader(source, kind .. " reader source"),
            _input = bufferpool.acquire(CHUNK),
            _output = bufferpool.acquire(CHUNK),
            _outputAt = 0,
            _decodeCount = 0,
            _decodeFirst = 0,
            _decodeSecond = 0,
            _decodeThird = 0,
            _sawPadding = false,
            _sourceEOF = false,
            _finished = false,
            _closed = false,
            _produced = 0,
        } as FilterReader,
        FilterReaderMT
    ) as Reader
end

local function newInflateReader(source: Input, options?: InflateReaderOptions): Reader
    source = checkedReader(source, "inflate reader source")
    if options ~= nil and type(options) ~= "table" then
        error("tecs: inflate reader options must be a table", 2)
    end
    options = options or {} as InflateReaderOptions
    if options.raw ~= nil and type(options.raw) ~= "boolean" then
        error("tecs: inflate reader raw must be a boolean", 2)
    end
    local limit = options.maxBytes == nil and DEFAULT_MAX_INFLATE_BYTES
        or nonNegative(options.maxBytes, "inflate reader maxBytes", 2)
    if limit == MAX_INTEGER then
        error("tecs: inflate reader maxBytes is too large", 2)
    end
    local stream <const> = loader.newStruct("z_stream")
    local fields <const> = stream as loader.CStruct
    local status <const> = inflateInit2(stream, options.raw and -WINDOW_BITS or WINDOW_BITS, VERSION, STREAM_SIZE)
    if status ~= K.Z_OK then
        error(zlibReason(fields, status), 2)
    end
    return rawSetMetatable(
        {
            _kind = "inflate",
            _source = source,
            _input = bufferpool.acquire(CHUNK),
            _output = bufferpool.acquire(CHUNK),
            _outputAt = 0,
            _stream = stream,
            _fields = fields,
            _sourceEOF = false,
            _finished = false,
            _closed = false,
            _produced = 0,
            _maxBytes = limit,
        } as FilterReader,
        FilterReaderMT
    ) as Reader
end

local function newTextWriter(kind: WriterKind, destination: Output): Writer
    return rawSetMetatable(
        {
            _kind = kind,
            _destination = checkedWriter(destination, kind .. " writer destination"),
            _output = bufferpool.acquire(CHUNK),
            _carryCount = 0,
            _carryFirst = 0,
            _carrySecond = 0,
            _closed = false,
            _closeResult = true,
        } as FilterWriter,
        FilterWriterMT
    ) as Writer
end

local function newDeflateWriter(destination: Output, options?: DeflateWriterOptions): Writer
    destination = checkedWriter(destination, "deflate writer destination")
    if options ~= nil and type(options) ~= "table" then
        error("tecs: deflate writer options must be a table", 2)
    end
    options = options or {} as DeflateWriterOptions
    if options.raw ~= nil and type(options.raw) ~= "boolean" then
        error("tecs: deflate writer raw must be a boolean", 2)
    end
    local compression = options.level
    if compression == nil then
        compression = K.Z_DEFAULT_COMPRESSION
    elseif compression ~= floor(compression) or compression < -1 or compression > 9 then
        error("tecs: compression level must be an integer from -1 to 9", 2)
    end
    local stream <const> = loader.newStruct("z_stream")
    local fields <const> = stream as loader.CStruct
    local status <const> = deflateInit2(
        stream,
        compression,
        K.Z_DEFLATED,
        options.raw and -WINDOW_BITS or WINDOW_BITS,
        8,
        K.Z_DEFAULT_STRATEGY,
        VERSION,
        STREAM_SIZE
    )
    if status ~= K.Z_OK then
        error(zlibReason(fields, status), 2)
    end
    return rawSetMetatable(
        {
            _kind = "deflate",
            _destination = destination,
            _output = bufferpool.acquire(CHUNK),
            _stream = stream,
            _fields = fields,
            _closed = false,
            _closeResult = true,
        } as FilterWriter,
        FilterWriterMT
    ) as Writer
end

local function newTranscodeReader(source: Input, fromEncoding: string, toEncoding: string): Reader
    source = checkedReader(source, "transcode reader source")
    local converter <const> = newConverter(fromEncoding, toEncoding)
    return rawSetMetatable(
        {
            _kind = "transcode",
            _source = source,
            _input = bufferpool.acquire(CHUNK),
            _output = bufferpool.acquire(CHUNK),
            _outputAt = 0,
            _sourceEOF = false,
            _finished = false,
            _closed = false,
            _produced = 0,
            _converter = converter,
        } as FilterReader,
        FilterReaderMT
    ) as Reader
end

local function newTranscodeWriter(destination: Output, fromEncoding: string, toEncoding: string): Writer
    destination = checkedWriter(destination, "transcode writer destination")
    local converter <const> = newConverter(fromEncoding, toEncoding)
    return rawSetMetatable(
        {
            _kind = "transcode",
            _destination = destination,
            _output = bufferpool.acquire(CHUNK),
            _closed = false,
            _closeResult = true,
            _converter = converter,
        } as FilterWriter,
        FilterWriterMT
    ) as Writer
end

local record filters
    newInflateReader: function(Input, InflateReaderOptions): Reader
    newDeflateWriter: function(Output, DeflateWriterOptions): Writer
    newBase64DecodeReader: function(Input): Reader
    newBase64EncodeWriter: function(Output): Writer
    newHexDecodeReader: function(Input): Reader
    newHexEncodeWriter: function(Output): Writer
    newTranscodeReader: function(Input, string, string): Reader
    newTranscodeWriter: function(Output, string, string): Writer
end

return {
    newInflateReader = newInflateReader,
    newDeflateWriter = newDeflateWriter,
    newBase64DecodeReader = function(source: Input): Reader return newTextReader("base64", source) end,
    newBase64EncodeWriter = function(destination: Output): Writer return newTextWriter("base64", destination) end,
    newHexDecodeReader = function(source: Input): Reader return newTextReader("hex", source) end,
    newHexEncodeWriter = function(destination: Output): Writer return newTextWriter("hex", destination) end,
    newTranscodeReader = newTranscodeReader,
    newTranscodeWriter = newTranscodeWriter,
} as filters
