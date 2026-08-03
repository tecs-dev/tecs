--[=[
Binary storage descriptors and contextual byte transfers.

A stream carries the recipe for opening bytes, not a cursor. Every reader and
writer owns its position. Replayable memory and file streams can therefore
open independent readers; a borrowed handle deliberately cannot.

Readers and writers are one pull and push contract. They return bytes or a
write result directly. Memory completes inline; an endpoint whose progress
depends on file, process, socket, or HTTP work may suspend the calling system
through the same method. Transforms preserve that suspension through their
ordinary call stack, and high-level transfers pump bounded reusable chunks.

Scheduling state remains private to concrete endpoints. A game does not select
an asynchronous Reader, poll a Future, or drive a callback form.
]=]

local ffi <const> = require("ffi")
local buffer <const> = require("tecs.io.buffer")
local bufferpool <const> = require("tecs.io.bufferpool")
local pump <const> = require("tecs.io.pump")
local loader <const> = require("tecs.ffi.loader")
local type types = require("tecs.io.types")
local type Files = require("tecs.io.files")
local type Path = require("tecs.io.Path")

local type IOBuffer = types.Buffer
local type ByteView = types.ByteView
local type Reader = types.Reader
local type Writer = types.Writer
local type Stream = types.Stream
local type ReadableStream = types.ReadableStream
local type WritableStream = types.WritableStream
local type ReadWriteStream = types.ReadWriteStream
local type PathInput = string | Path

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min

local record BorrowedBytes
    pointer: any
    length: integer
    owner: any
end

local newStringStream: function(text: string, contentType?: string): ReadableStream
local makeBufferStream: function(sourceBuffer: IOBuffer, contentType?: string, ownsBuffer?: boolean): ReadWriteStream
local makeViewStream: function(sourceView: ByteView, contentType?: string): ReadableStream
local newFileStream: function(path: PathInput, contentType?: string): ReadWriteStream
local withMetadata: function<T is Stream>(
    source: T, contentType?: string, contentLength?: integer, isReplayable?: boolean
): T
local CHUNK <const> = 64 * 1024
local DEFAULT_READ_BYTES <const> = 16 * 1024
local MAX_INTEGER <const> = 9007199254740991

local function acquireScratch(): IOBuffer
    return bufferpool.acquire(CHUNK)
end

local function releaseScratch(scratch: IOBuffer)
    bufferpool.release(scratch)
end

--- Fields shared by concrete descriptors.
local interface Backing
    _contentType: string
    _closed: boolean
end

--- A retained immutable Lua string.
local record StringStream is Backing, ReadableStream
    _text: string
end

--- A borrowed growable buffer, except for storage reconstructed internally.
local record BufferStream is Backing, ReadWriteStream
    _buffer: IOBuffer
    _ownsBuffer: boolean
end

--- Borrowed FFI memory whose owner stays with the caller.
local record ByteStream is Backing, ReadableStream
    _pointer: loader.CValue
    _length: integer
end

--- A retained immutable byte view.
local record ViewStream is Backing, ReadableStream
    _view: ByteView
end

--- A path reopened for each direction.
local record FileStream is Backing, ReadWriteStream
    _path: string
end

--- State shared by a handle stream and every metadata view over it.
local record HandleState
    handle: FILE
    length: integer
    consumed: boolean
end

--- A one-shot borrowed Lua file handle.
local record HandleStream is Backing, ReadWriteStream
    _state: HandleState
end

--- A one-shot reader supplied by an internal progressive transport.
local record ReaderStream is Backing, ReadableStream
    _reader: Reader
    _length: integer
    _opened: boolean
end

local StringStreamMT <const>: metatable<StringStream> = {__index = StringStream}
local BufferStreamMT <const>: metatable<BufferStream> = {__index = BufferStream}
local ByteStreamMT <const>: metatable<ByteStream> = {__index = ByteStream}
local ViewStreamMT <const>: metatable<ViewStream> = {__index = ViewStream}
local FileStreamMT <const>: metatable<FileStream> = {__index = FileStream}
local HandleStreamMT <const>: metatable<HandleStream> = {__index = HandleStream}
local ReaderStreamMT <const>: metatable<ReaderStream> = {__index = ReaderStream}

--- A cursor over a string, buffer, or borrowed pointer.
local record MemoryReader is Reader
    _text: string
    _pointer: loader.CValue
    _view: ByteView
    _length: integer
    _at: integer
    _closed: boolean
    _readPointer: function(self: MemoryReader, count: integer): loader.BytePointer, integer, string
end

--- A cursor over a borrowed Lua file handle.
local record HandleReader is Reader
    _handle: FILE
    _closed: boolean
end

--- A destination over a borrowed Lua file handle.
local record HandleWriter is Writer
    _handle: FILE
    _closed: boolean
end

local interface MetadataState is Stream
    _source: Stream
    _metadataContentType: string
    _metadataLength: integer
    _metadataReplayable: boolean
end

local record MetadataStream is MetadataState
end

local record MetadataReadableStream is MetadataState, ReadableStream
end

local record MetadataWritableStream is MetadataState, WritableStream
end

local record MetadataReadWriteStream is MetadataState, ReadWriteStream
end

local MemoryReaderMT <const>: metatable<MemoryReader> = {__index = MemoryReader}
local HandleReaderMT <const>: metatable<HandleReader> = {__index = HandleReader}
local HandleWriterMT <const>: metatable<HandleWriter> = {__index = HandleWriter}
local MetadataStreamMT <const>: metatable<MetadataStream> = {__index = MetadataStream}
local MetadataReadableStreamMT <const>: metatable<MetadataReadableStream> = {__index = MetadataReadableStream}
local MetadataWritableStreamMT <const>: metatable<MetadataWritableStream> = {__index = MetadataWritableStream}
local MetadataReadWriteStreamMT <const>: metatable<MetadataReadWriteStream> = {__index = MetadataReadWriteStream}
local rawSetMetatable <const> = setmetatable as function(any, any): any

local loadedFiles: Files

local function getFiles(): Files
    if loadedFiles == nil then
        local files <const> = require("tecs.io.files")
        loadedFiles = files
    end
    return loadedFiles
end

local function nonNegative(value: integer, what: string, level: integer): integer
    if type(value) ~= "number" or value ~= floor(value) or value < 0 or value > MAX_INTEGER then
        error(("tecs: %s must be a non-negative integer"):format(what), level)
    end
    return value
end

local function bufferRange(sourceBuffer: IOBuffer, offset: integer, count: integer, level: integer): integer, integer
    offset = nonNegative(offset or 0, "stream buffer offset", level)
    local length <const> = sourceBuffer:length()
    if offset > length then
        error("tecs: stream buffer offset is past its length", level)
    end
    if count == nil then
        count = length - offset
    else
        count = nonNegative(count, "stream buffer count", level)
    end
    if count > length - offset then
        error("tecs: stream buffer range is past its length", level)
    end
    return offset, count
end

local function viewRange(sourceView: ByteView, offset: integer, count: integer, level: integer): integer, integer
    local dynamic <const> = sourceView as {string: any}
    if
        type(sourceView) ~= "table"
        or type(dynamic.length) ~= "function"
        or type(dynamic.getFFIPointer) ~= "function"
        or type(dynamic.view) ~= "function"
        or type(dynamic.isReleased) ~= "function"
        or type(dynamic.close) ~= "function"
        or (dynamic.isReleased as function(any): boolean)(sourceView)
    then
        error("tecs: stream writeView needs an open io.ByteView", level)
    end
    offset = nonNegative(offset or 0, "stream view offset", level)
    local length <const> = sourceView:length()
    if offset > length then
        error("tecs: stream view offset is past its length", level)
    end
    if count == nil then
        count = length - offset
    else
        count = nonNegative(count, "stream view count", level)
    end
    if count > length - offset then
        error("tecs: stream view range is past its length", level)
    end
    return offset, count
end

local function maximum(value: integer, level: integer): integer
    if value == nil then
        return nil
    end
    return nonNegative(value, "stream maximum", level)
end

local function checkedBuffer(value: any, what: string, level: integer): IOBuffer
    if
        type(value) ~= "table"
        or type((value as {string: any}).length) ~= "function"
        or type((value as {string: any}).getFFIPointer) ~= "function"
        or type((value as {string: any}).isReleased) ~= "function"
        or type((value as {string: any}).close) ~= "function"
    then
        error(("tecs: %s needs an io.Buffer"):format(what), level)
    end
    return value as IOBuffer
end

local function checkedStream<T is Stream>(value: T, what: string, level: integer): T
    local dynamic <const> = value as {string: any}
    if
        type(value) ~= "table"
        or type(dynamic.contentLength) ~= "function"
        or type(dynamic.contentType) ~= "function"
        or type(dynamic.isReadable) ~= "function"
        or type(dynamic.isWritable) ~= "function"
        or type(dynamic.isReplayable) ~= "function"
        or type(dynamic.close) ~= "function"
    then
        error(("tecs: %s needs a Stream implementation"):format(what), level)
    end
    if
        (dynamic.isReadable as function(any): boolean)(value)
        and (
            type(dynamic.newReader) ~= "function"
            or type(dynamic.readAll) ~= "function"
            or type(dynamic.transferToBuffer) ~= "function"
            or type(dynamic.transferTo) ~= "function"
            or type(dynamic.transferToFile) ~= "function"
            or type(dynamic.discard) ~= "function"
        )
    then
        error(("tecs: %s claims ReadableStream without its methods"):format(what), level)
    end
    if
        (dynamic.isWritable as function(any): boolean)(value)
        and (
            type(dynamic.newWriter) ~= "function"
            or type(dynamic.writeAll) ~= "function"
            or type(dynamic.writeBuffer) ~= "function"
        )
    then
        error(("tecs: %s claims WritableStream without its methods"):format(what), level)
    end
    return value
end

local function isMetadataView(stream: Stream): boolean
    local mt <const> = getmetatable(stream as any) as any
    return mt == (MetadataStreamMT as any)
        or mt == (MetadataReadableStreamMT as any)
        or mt == (MetadataWritableStreamMT as any)
        or mt == (MetadataReadWriteStreamMT as any)
end

local function metadataBacking(stream: Stream): Stream
    while isMetadataView(stream) do
        stream = (stream as MetadataState)._source
    end
    return stream
end

local function borrowedBytes(source: ReadableStream): BorrowedBytes
    if source == nil or not source:isReadable() then
        return nil
    end
    local backing <const> = metadataBacking(source)
    local mt <const> = getmetatable(backing as any) as any
    if mt == (StringStreamMT as any) then
        if (backing as StringStream)._closed then
            return nil
        end
        local text <const> = (backing as StringStream)._text
        return {
            pointer = ffi.cast("const uint8_t *", text),
            length = #text,
            owner = text,
        }
    elseif mt == (BufferStreamMT as any) then
        local sourceBuffer <const> = (backing as BufferStream)._buffer
        if (backing as BufferStream)._closed or sourceBuffer:isReleased() then
            return nil
        end
        return {
            pointer = sourceBuffer:getFFIPointer(),
            length = sourceBuffer:length(),
            owner = sourceBuffer,
        }
    elseif mt == (ByteStreamMT as any) then
        local bytes <const> = backing as ByteStream
        if bytes._closed then
            return nil
        end
        return {
            pointer = bytes._pointer,
            length = bytes._length,
            owner = backing,
        }
    elseif mt == (ViewStreamMT as any) then
        local view <const> = (backing as ViewStream)._view
        if (backing as ViewStream)._closed or view == nil or view:isReleased() then
            return nil
        end
        return {
            pointer = view:getFFIPointer(),
            length = view:length(),
            owner = view,
        }
    end
    return nil
end

local function nativeFilePath(source: ReadableStream): string
    if source == nil or not source:isReadable() then
        return nil
    end
    local backing <const> = metadataBacking(source)
    if getmetatable(backing as any) ~= (FileStreamMT as any) or (backing as FileStream)._closed then
        return nil
    end
    local adapter <const> = require("tecs.platform.adapter")
    local storagebackend <const> = require("tecs.platform.storagebackend")
    if adapter.storage() ~= storagebackend.sdl then
        return nil
    end
    return (backing as FileStream)._path
end

local function snapshotMetadata(source: Stream): string, integer, boolean
    local contentTypeValue <const> = source:contentType()
    local replayableValue <const> = source:isReplayable()
    local lengthValue: integer = nil
    local cursor = source
    while isMetadataView(cursor) do
        local metadata <const> = cursor as MetadataState
        if lengthValue == nil and metadata._metadataLength ~= nil then
            lengthValue = metadata._metadataLength
        end
        cursor = metadata._source
    end
    return contentTypeValue, lengthValue, replayableValue
end

local function snapshotStream(source: Stream, what: string): {string: any}
    source = checkedStream(source, what, 3)
    local contentTypeValue <const>, lengthValue <const>, replayableValue <const> = snapshotMetadata(source)
    local backing <const> = metadataBacking(source)
    local mt <const> = getmetatable(backing as any) as any
    local saved: {string: any} = {
        streamVersion = 1,
        contentType = contentTypeValue,
        contentLength = lengthValue,
        isReplayable = replayableValue,
    }
    if mt == (StringStreamMT as any) then
        saved.kind = "string"
        saved.text = (backing as StringStream)._text
    elseif mt == (BufferStreamMT as any) then
        saved.kind = "buffer"
        saved.bytes = (backing as BufferStream)._buffer:getString()
    elseif mt == (ByteStreamMT as any) then
        local bytes <const> = backing as ByteStream
        saved.kind = "buffer"
        saved.bytes = loader.toBytes(bytes._pointer, bytes._length)
    elseif mt == (ViewStreamMT as any) then
        saved.kind = "buffer"
        saved.bytes = (backing as ViewStream)._view:getString()
    elseif mt == (FileStreamMT as any) then
        saved.kind = "file"
        saved.path = (backing as FileStream)._path
    elseif mt == (HandleStreamMT as any) then
        error(("tecs: cannot snapshot %s: io.newHandleStream is runtime-only"):format(what), 0)
    else
        error(("tecs: cannot snapshot %s: custom Stream implementations are runtime-only"):format(what), 0)
    end
    return saved
end

local function restoredMetadata<T is Stream>(source: T, saved: {string: any}): T
    return withMetadata(
        source, saved.contentType as string, saved.contentLength as integer, saved.isReplayable as boolean
    )
end

local function restoreStream(saved: {string: any}, what: string): Stream
    if type(saved) ~= "table" then
        error(("tecs: cannot restore %s: stream data is not a table"):format(what), 0)
    end
    if saved.streamVersion ~= 1 then
        error(("tecs: cannot restore %s: unsupported stream version"):format(what), 0)
    end
    local kind <const> = saved.kind as string
    if kind == "string" then
        local text <const> = saved.text as string
        if type(text) ~= "string" then
            error(("tecs: cannot restore %s: string stream has no bytes"):format(what), 0)
        end
        return restoredMetadata(newStringStream(text, saved.contentType as string), saved)
    elseif kind == "buffer" then
        local bytes <const> = saved.bytes as string
        if type(bytes) ~= "string" then
            error(("tecs: cannot restore %s: buffer stream has no bytes"):format(what), 0)
        end
        return restoredMetadata(makeBufferStream(buffer.new(bytes), saved.contentType as string, true), saved)
    elseif kind == "file" then
        local path <const> = saved.path as string
        if type(path) ~= "string" or path == "" then
            error(("tecs: cannot restore %s: file stream has no path"):format(what), 0)
        end
        return restoredMetadata(newFileStream(path, saved.contentType as string), saved)
    end
    error(("tecs: cannot restore %s: unknown stream kind '%s'"):format(what, tostring(kind)), 0)
end

local function sharesBacking(source: Stream, destination: Stream): boolean
    source = metadataBacking(source)
    destination = metadataBacking(destination)
    if (source as any) == (destination as any) then
        return true
    end
    local sourceMT <const> = getmetatable(source as any) as any
    local destinationMT <const> = getmetatable(destination as any) as any
    if sourceMT ~= destinationMT then
        return false
    end
    if sourceMT == (BufferStreamMT as any) then
        return (source as BufferStream)._buffer == (destination as BufferStream)._buffer
    elseif sourceMT == (FileStreamMT as any) then
        return (source as FileStream)._path == (destination as FileStream)._path
    elseif sourceMT == (HandleStreamMT as any) then
        return (source as HandleStream)._state.handle == (destination as HandleStream)._state.handle
    end
    return false
end

local function unavailable(self: Backing): boolean
    return self._closed
end

local function contentType(self: Backing): string | nil
    return self._contentType
end

local function close(self: Backing)
    self._closed = true
end

local function newMemoryReader(
    text: string, pointer: loader.CValue, length: integer, sourceView?: ByteView
): MemoryReader
    return rawSetMetatable(
        {
            _text = text,
            _pointer = pointer,
            _view = sourceView,
            _length = length,
            _at = 0,
            _closed = false,
        } as MemoryReader,
        MemoryReaderMT
    ) as MemoryReader
end

function MemoryReader:read(count: integer): string, string
    if self._closed then
        return nil, "the reader is closed"
    end
    local wanted <const> = max(1, count)
    if self._at >= self._length then
        return ""
    end
    local taking <const> = min(wanted, self._length - self._at)
    local result: string
    if self._text ~= nil then
        result = self._text:sub(self._at + 1, self._at + taking)
    else
        local pointer = loader.bytePointer(self._pointer)
        if self._view ~= nil then
            pointer = self._view:getFFIPointer()
        end
        result = loader.toBytes((pointer + self._at) as loader.CValue, taking)
    end
    self._at = self._at + taking
    return result
end

function MemoryReader:_readPointer(count: integer): loader.BytePointer, integer, string
    if self._closed then
        return nil, nil, "the reader is closed"
    end
    if self._at >= self._length then
        return nil, 0
    end
    local taking <const> = min(max(1, count), self._length - self._at)
    local pointer: loader.BytePointer
    if self._text ~= nil then
        pointer = ffi.cast("uint8_t *", self._text) as loader.BytePointer
    elseif self._view ~= nil then
        pointer = self._view:getFFIPointer()
    else
        pointer = loader.bytePointer(self._pointer)
    end
    pointer = pointer + self._at
    self._at = self._at + taking
    return pointer, taking
end

function MemoryReader:readInto(destination: IOBuffer, offset?: integer, count?: integer): integer, string
    if self._closed then
        return nil, "the reader is closed"
    end
    offset = nonNegative(offset or 0, "Reader:readInto offset", 2)
    count = nonNegative(count or DEFAULT_READ_BYTES, "Reader:readInto count", 2)
    if count == 0 or self._at >= self._length then
        return 0
    end
    local taking <const> = min(count, self._length - self._at)
    local source: loader.BytePointer
    if self._text ~= nil then
        source = ffi.cast("uint8_t *", self._text) as loader.BytePointer
    elseif self._view ~= nil then
        source = self._view:getFFIPointer()
    else
        source = loader.bytePointer(self._pointer)
    end
    local output <const>, previousLength = buffer.prepareWrite(destination, offset, taking)
    ffi.copy(output as ffi.CData, (source + self._at) as ffi.CData, taking)
    buffer.commitWrite(destination, offset, taking, previousLength)
    self._at = self._at + taking
    return taking
end

function MemoryReader:transferTo(destination: Writer): integer, string
    if self._closed then
        return nil, "the reader is closed"
    end
    local dynamic <const> = destination as {string: any}
    if type(dynamic._writePointer) == "function" then
        local pointer <const>, count, reason = self:_readPointer(self._length - self._at)
        if count == nil then
            return nil, reason
        end
        if count == 0 then
            return 0
        end
        local wrote <const>, writeReason = (
            dynamic._writePointer as function(any, loader.BytePointer, integer): boolean, string
        )(destination, pointer, count)
        return wrote and count or nil, writeReason
    end
    return pump.transferBuffered(self, destination)
end

function MemoryReader:close(): boolean, string
    if self._view ~= nil then
        self._view:close()
        self._view = nil
    end
    self._closed = true
    return true
end

function HandleReader:read(count: integer): string, string
    if self._closed then
        return nil, "the reader is closed"
    end
    local piece <const>, reason = self._handle:read(max(1, count))
    if piece ~= nil then
        return piece
    end
    if reason ~= nil then
        return nil, reason
    end
    return ""
end

function HandleReader:readInto(destination: IOBuffer, offset?: integer, count?: integer): integer, string
    offset = nonNegative(offset or 0, "Reader:readInto offset", 2)
    count = nonNegative(count or DEFAULT_READ_BYTES, "Reader:readInto count", 2)
    if count == 0 then
        return 0
    end
    local piece <const>, reason = self:read(count)
    if piece == nil then
        return nil, reason
    end
    destination:setString(piece, offset)
    return #piece
end

function HandleReader:close(): boolean, string
    self._closed = true
    return true
end

function HandleWriter:write(bytes: string): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    local wrote <const>, reason = self._handle:write(bytes)
    if wrote == nil then
        return false, reason or "cannot write the handle"
    end
    return true
end

function HandleWriter:writeFrom(sourceBuffer: IOBuffer, offset?: integer, count?: integer): integer, string
    offset, count = bufferRange(sourceBuffer, offset, count, 2)
    local ok <const>, reason = self:write(sourceBuffer:getString(offset, count))
    if not ok then
        return nil, reason
    end
    return count
end

function HandleWriter:writeView(source: ByteView, offset?: integer, count?: integer): integer, string
    offset, count = viewRange(source, offset, count, 2)
    local bytes <const> = loader.toBytes((source:getFFIPointer() + offset) as loader.CValue, count)
    local ok <const>, reason = self:write(bytes)
    if not ok then
        return nil, reason
    end
    return count
end

function HandleWriter:flush(): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    local ok <const>, reason = self._handle:flush()
    if ok == nil then
        return false, reason or "cannot flush the handle"
    end
    return true
end

function HandleWriter:close(): boolean, string
    if self._closed then
        return true
    end
    local ok <const>, reason = self:flush()
    self._closed = true
    return ok, reason
end

local function closeReader(reader: Reader): string
    local called <const>, reason = pcall(reader.close, reader) as (boolean, any)
    if not called then
        return tostring(reason)
    end
    return nil
end

local function closeWriter(writer: Writer): string
    local called <const>, closed, reason = pcall(writer.close, writer) as (boolean, boolean, string)
    if not called then
        return tostring(closed)
    end
    if not closed then
        return reason or "stream writer could not close"
    end
    return nil
end

local function readIntoBuffer(source: ReadableStream, maxBytes: integer): IOBuffer, string
    maxBytes = maximum(maxBytes, 3)
    local metadataOK <const>, known = pcall(source.contentLength, source) as (boolean, integer)
    if not metadataOK then
        return nil, tostring(known)
    end
    if maxBytes ~= nil and known ~= nil and known > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end

    local allocated <const>, bufferOrReason = pcall(buffer.new) as (boolean, any)
    if not allocated then
        return nil, tostring(bufferOrReason)
    end
    local output <const> = bufferOrReason as IOBuffer
    if known ~= nil and known > 0 then
        local reserved <const>, reserveReason = pcall(output.ensureCapacity, output, known) as (boolean, any)
        if not reserved then
            output:close()
            return nil, tostring(reserveReason)
        end
    end
    local reader <const>, openReason = source:newReader()
    if reader == nil then
        output:close()
        return nil, openReason
    end

    local total = 0
    while true do
        local count = CHUNK
        if maxBytes ~= nil then
            count = min(count, maxBytes - total + 1)
        end
        output:resize(total)
        local got <const>, reason = pump.readInto(reader, output, total, count)
        if got == nil then
            closeReader(reader)
            output:close()
            return nil, reason
        end
        if got == 0 then
            local closeReason <const> = closeReader(reader)
            if closeReason ~= nil then
                output:close()
                return nil, closeReason
            end
            return output
        end
        total = total + got
        if maxBytes ~= nil and total > maxBytes then
            closeReader(reader)
            output:close()
            return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
        end
    end
end

local function readAll(source: ReadableStream, maxBytes: integer): string, string
    local output <const>, reason = readIntoBuffer(source, maxBytes)
    if output == nil then
        return nil, reason
    end
    local result <const> = output:getString()
    output:close()
    return result
end

local function transferToBuffer(source: ReadableStream, maxBytes: integer): IOBuffer, string
    return readIntoBuffer(source, maxBytes)
end

local function transferTo(source: ReadableStream, destination: WritableStream): integer, string
    if sharesBacking(source, destination) then
        return nil, "cannot transfer between streams sharing one backing"
    end
    local reader <const>, readReason = source:newReader()
    if reader == nil then
        return nil, readReason
    end
    local writer <const>, writeReason = destination:newWriter()
    if writer == nil then
        closeReader(reader)
        return nil, writeReason
    end

    local total <const>, failure = pump.transfer(reader, writer)

    local readerClose <const> = closeReader(reader)
    local writerClose <const> = closeWriter(writer)
    return failure == nil and readerClose == nil and writerClose == nil and total or nil,
        failure or readerClose or writerClose
end

local function transferToFile(source: ReadableStream, path: string): integer, string
    if type(path) ~= "string" or path == "" then
        error("tecs: transferToFile needs a path", 3)
    end
    local destination <const> = newFileStream(path)
    local total <const>, reason = source:transferTo(destination)
    destination:close()
    return total, reason
end

local function discard(source: ReadableStream): integer, string
    local scratch <const> = acquireScratch()
    local reader <const>, openReason = source:newReader()
    if reader == nil then
        releaseScratch(scratch)
        return nil, openReason
    end
    local total = 0
    local failure: string
    while failure == nil do
        scratch:clear()
        local got <const>, reason = pump.readInto(reader, scratch, 0, CHUNK)
        if got == nil then
            failure = reason
        elseif got == 0 then
            break
        else
            total = total + got
        end
    end
    local closeReason <const> = closeReader(reader)
    releaseScratch(scratch)
    return failure == nil and closeReason == nil and total or nil, failure or closeReason
end

local function writeString(destination: WritableStream, text: string): integer, string
    if type(text) ~= "string" then
        error("tecs: writeAll needs a byte string", 3)
    end
    local writer <const>, openReason = destination:newWriter()
    if writer == nil then
        return nil, openReason
    end
    local ok <const>, reason = writer:write(text)
    local closeReason <const> = closeWriter(writer)
    if not ok then
        return nil, reason
    end
    if closeReason ~= nil then
        return nil, closeReason
    end
    return #text
end

local function writeBuffer(
    destination: WritableStream, sourceBuffer: IOBuffer, offset: integer, count: integer
): integer, string
    sourceBuffer = checkedBuffer(sourceBuffer, "writeBuffer", 3)
    offset, count = bufferRange(sourceBuffer, offset, count, 3)
    local writer <const>, openReason = destination:newWriter()
    if writer == nil then
        return nil, openReason
    end
    local finish <const> = offset + count
    local at = offset
    local failure: string
    while at < finish do
        local wrote <const>, reason = pump.writeFrom(writer, sourceBuffer, at, min(CHUNK, finish - at))
        if wrote == nil then
            failure = reason
            break
        end
        if wrote <= 0 then
            failure = "stream writer made no progress"
            break
        end
        at = at + wrote
    end
    local closeReason <const> = closeWriter(writer)
    return failure == nil and closeReason == nil and count or nil, failure or closeReason
end

local function writeView(
    destination: WritableStream, sourceView: ByteView, offset: integer, count: integer
): integer, string
    offset, count = viewRange(sourceView, offset, count, 3)
    local writer <const>, openReason = destination:newWriter()
    if writer == nil then
        return nil, openReason
    end
    local finish <const> = offset + count
    local at = offset
    local failure: string
    while at < finish do
        local requested <const> = min(CHUNK, finish - at)
        local wrote: integer
        local reason: string
        local dynamic <const> = writer as {string: any}
        local directWriteView <const> = dynamic.writeView
        if type(directWriteView) == "function" then
            wrote, reason = (directWriteView as function(any, ByteView, integer, integer): integer, string)(
                writer, sourceView, at, requested
            )
        else
            local piece <const> = loader.toBytes((sourceView:getFFIPointer() + at) as loader.CValue, requested)
            local ok <const>, writeReason = writer:write(piece)
            reason = writeReason
            if ok then
                wrote = requested
            end
        end
        if wrote == nil then
            failure = reason
            break
        end
        if wrote <= 0 then
            failure = "stream writer made no progress"
            break
        end
        at = at + wrote
    end
    local closeReason <const> = closeWriter(writer)
    return failure == nil and closeReason == nil and count or nil, failure or closeReason
end

-- String stream

function StringStream:contentLength(): integer | nil
    return #self._text
end
function StringStream:contentType(): string | nil
    return contentType(self)
end
function StringStream:isReadable(): boolean
    return true
end
function StringStream:isWritable(): boolean
    return false
end
function StringStream:isReplayable(): boolean
    return true
end
function StringStream:close(): boolean, string
    close(self)
    return true
end

function StringStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return newMemoryReader(self._text, nil, #self._text)
end

function StringStream:readAll(maxBytes?: integer): string, string
    maxBytes = maximum(maxBytes, 2)
    if unavailable(self) then
        return nil, "stream is closed"
    end
    if maxBytes ~= nil and #self._text > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end
    return self._text
end

function StringStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end

function StringStream:transferTo(destination: WritableStream): integer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return destination:writeAll(self._text)
end

function StringStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end

function StringStream:discard(): integer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return #self._text
end

-- Buffer stream

function BufferStream:contentLength(): integer | nil
    return self._buffer:isReleased() and nil or self._buffer:length()
end
function BufferStream:contentType(): string | nil
    return contentType(self)
end
function BufferStream:isReadable(): boolean
    return true
end
function BufferStream:isWritable(): boolean
    return true
end
function BufferStream:isReplayable(): boolean
    return true
end
function BufferStream:close(): boolean, string
    if not self._closed then
        self._closed = true
        if self._ownsBuffer then
            self._buffer:close()
        end
    end
    return true
end
function BufferStream:newReader(): Reader, string
    if unavailable(self) or self._buffer:isReleased() then
        return nil, "stream is closed or its buffer is released"
    end
    return self._buffer:newReader()
end

function BufferStream:newWriter(): Writer, string
    if unavailable(self) or self._buffer:isReleased() then
        return nil, "stream is closed or its buffer is released"
    end
    return self._buffer:newWriter()
end

function BufferStream:readAll(maxBytes?: integer): string, string
    maxBytes = maximum(maxBytes, 2)
    local length <const> = self:contentLength()
    if length == nil then
        return nil, "stream is closed or its buffer is released"
    end
    if maxBytes ~= nil and length > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end
    return self._buffer:getString()
end

function BufferStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    maxBytes = maximum(maxBytes, 2)
    local length <const> = self:contentLength()
    if length == nil then
        return nil, "stream is closed or its buffer is released"
    end
    if maxBytes ~= nil and length > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end
    return self._buffer
end

function BufferStream:transferTo(destination: WritableStream): integer, string
    if unavailable(self) or self._buffer:isReleased() then
        return nil, "stream is closed or its buffer is released"
    end
    if sharesBacking(self, destination) then
        return nil, "cannot transfer between streams sharing one backing"
    end
    return destination:writeBuffer(self._buffer)
end

function BufferStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end

function BufferStream:discard(): integer, string
    local length <const> = self:contentLength()
    if length == nil then
        return nil, "stream is closed or its buffer is released"
    end
    return length
end

function BufferStream:writeAll(text: string): integer, string
    return writeString(self, text)
end

function BufferStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): integer, string
    sourceBuffer = checkedBuffer(sourceBuffer, "writeBuffer", 2)
    if sourceBuffer == self._buffer then
        return nil, "cannot write a buffer into itself"
    end
    return writeBuffer(self, sourceBuffer, offset, count)
end
function BufferStream:writeView(sourceView: ByteView, offset?: integer, count?: integer): integer, string
    return writeView(self, sourceView, offset, count)
end

-- Borrowed byte stream

function ByteStream:contentLength(): integer | nil
    return self._length
end
function ByteStream:contentType(): string | nil
    return contentType(self)
end
function ByteStream:isReadable(): boolean
    return true
end
function ByteStream:isWritable(): boolean
    return false
end
function ByteStream:isReplayable(): boolean
    return true
end
function ByteStream:close(): boolean, string
    close(self)
    return true
end

function ByteStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return newMemoryReader(nil, self._pointer, self._length)
end

function ByteStream:readAll(maxBytes?: integer): string, string
    maxBytes = maximum(maxBytes, 2)
    if unavailable(self) then
        return nil, "stream is closed"
    end
    if maxBytes ~= nil and self._length > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end
    return loader.toBytes(self._pointer, self._length)
end

function ByteStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end

function ByteStream:transferTo(destination: WritableStream): integer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return transferTo(self, destination)
end

function ByteStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end

function ByteStream:discard(): integer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return self._length
end

-- Retained view stream

function ViewStream:contentLength(): integer | nil
    return not unavailable(self) and self._view ~= nil and not self._view:isReleased() and self._view:length() or nil
end
function ViewStream:contentType(): string | nil
    return contentType(self)
end
function ViewStream:isReadable(): boolean
    return true
end
function ViewStream:isWritable(): boolean
    return false
end
function ViewStream:isReplayable(): boolean
    return true
end
function ViewStream:close(): boolean, string
    if self._view ~= nil then
        self._view:close()
        self._view = nil
    end
    close(self)
    return true
end
function ViewStream:newReader(): Reader, string
    if unavailable(self) or self._view == nil or self._view:isReleased() then
        return nil, "stream is closed"
    end
    local retained <const> = self._view:view()
    return newMemoryReader(nil, nil, retained:length(), retained)
end
function ViewStream:readAll(maxBytes?: integer): string, string
    maxBytes = maximum(maxBytes, 2)
    local length <const> = self:contentLength()
    if length == nil then
        return nil, "stream is closed"
    end
    if maxBytes ~= nil and length > maxBytes then
        return nil, ("stream exceeds the %d byte limit"):format(maxBytes)
    end
    return self._view:getString()
end
function ViewStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end
function ViewStream:transferTo(destination: WritableStream): integer, string
    if unavailable(self) or self._view == nil or self._view:isReleased() then
        return nil, "stream is closed"
    end
    return destination:writeView(self._view)
end
function ViewStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end
function ViewStream:discard(): integer, string
    local length <const> = self:contentLength()
    if length == nil then
        return nil, "stream is closed"
    end
    return length
end

-- File stream

function FileStream:contentLength(): integer | nil
    local info <const> = getFiles().info(self._path)
    return info ~= nil and info.kind == "file" and info.size or nil
end
function FileStream:contentType(): string | nil
    return contentType(self)
end
function FileStream:isReadable(): boolean
    return true
end
function FileStream:isWritable(): boolean
    return true
end
function FileStream:isReplayable(): boolean
    return true
end
function FileStream:close(): boolean, string
    close(self)
    return true
end

function FileStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return getFiles().open(self._path, "r")
end

function FileStream:newWriter(): Writer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return getFiles().open(self._path, "w")
end

function FileStream:readAll(maxBytes?: integer): string, string
    return readAll(self, maxBytes)
end
function FileStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end
function FileStream:transferTo(destination: WritableStream): integer, string
    return transferTo(self, destination)
end
function FileStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end
function FileStream:discard(): integer, string
    return discard(self)
end
function FileStream:writeAll(text: string): integer, string
    return writeString(self, text)
end
function FileStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): integer, string
    return writeBuffer(self, sourceBuffer, offset, count)
end
function FileStream:writeView(sourceView: ByteView, offset?: integer, count?: integer): integer, string
    return writeView(self, sourceView, offset, count)
end

-- Handle stream

function HandleStream:contentLength(): integer | nil
    return self._state.length
end
function HandleStream:contentType(): string | nil
    return contentType(self)
end
function HandleStream:isReadable(): boolean
    return true
end
function HandleStream:isWritable(): boolean
    return true
end
function HandleStream:isReplayable(): boolean
    return false
end
function HandleStream:close(): boolean, string
    close(self)
    return true
end

function HandleStream:newReader(): Reader, string
    if unavailable(self) or self._state.consumed then
        return nil, "stream handle is no longer available"
    end
    self._state.consumed = true
    return rawSetMetatable(
        {
            _handle = self._state.handle,
            _closed = false,
        } as HandleReader,
        HandleReaderMT
    ) as Reader
end

function HandleStream:newWriter(): Writer, string
    if unavailable(self) or self._state.consumed then
        return nil, "stream handle is no longer available"
    end
    self._state.consumed = true
    return rawSetMetatable(
        {
            _handle = self._state.handle,
            _closed = false,
        } as HandleWriter,
        HandleWriterMT
    ) as Writer
end

function HandleStream:readAll(maxBytes?: integer): string, string
    return readAll(self, maxBytes)
end
function HandleStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end
function HandleStream:transferTo(destination: WritableStream): integer, string
    return transferTo(self, destination)
end
function HandleStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end
function HandleStream:discard(): integer, string
    return discard(self)
end
function HandleStream:writeAll(text: string): integer, string
    return writeString(self, text)
end
function HandleStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): integer, string
    return writeBuffer(self, sourceBuffer, offset, count)
end
function HandleStream:writeView(sourceView: ByteView, offset?: integer, count?: integer): integer, string
    return writeView(self, sourceView, offset, count)
end

-- Internal progressive reader stream

function ReaderStream:contentLength(): integer | nil
    return self._length
end
function ReaderStream:contentType(): string | nil
    return self._contentType
end
function ReaderStream:isReadable(): boolean
    return not self._closed
end
function ReaderStream:isWritable(): boolean
    return false
end
function ReaderStream:isReplayable(): boolean
    return false
end
function ReaderStream:newReader(): Reader, string
    if self._closed then
        return nil, "the stream is closed"
    end
    if self._opened or self._reader == nil then
        return nil, "the one-shot stream already opened its reader"
    end
    self._opened = true
    local reader <const> = self._reader
    self._reader = nil
    return reader
end
function ReaderStream:readAll(maxBytes?: integer): string, string
    return readAll(self, maxBytes)
end
function ReaderStream:transferToBuffer(maxBytes?: integer): IOBuffer, string
    return transferToBuffer(self, maxBytes)
end
function ReaderStream:transferTo(destination: WritableStream): integer, string
    return transferTo(self, destination)
end
function ReaderStream:transferToFile(path: string): integer, string
    return transferToFile(self, path)
end
function ReaderStream:discard(): integer, string
    return discard(self)
end
function ReaderStream:close(): boolean, string
    if self._closed then
        return true
    end
    self._closed = true
    if not self._opened and self._reader ~= nil then
        local reader <const> = self._reader
        self._reader = nil
        return reader:close()
    end
    return true
end

--- Creates a replayable readable empty source.
local function newEmptyStream(contentTypeValue?: string): ReadableStream
    return rawSetMetatable(
        {
            _text = "",
            _contentType = contentTypeValue,
            _closed = false,
        } as StringStream,
        StringStreamMT
    ) as ReadableStream
end

--- Creates a reader retaining `text` without copying it.
local function newStringReader(text: string): Reader
    if type(text) ~= "string" then
        error("tecs: io.newStringReader needs a byte string", 2)
    end
    return newMemoryReader(text, nil, #text)
end

--- Creates a reader borrowing FFI bytes.
local function newByteReader(pointer: loader.CValue, length: integer): Reader
    if pointer == nil then
        error("tecs: io.newByteReader needs an FFI pointer", 2)
    end
    length = nonNegative(length, "io.newByteReader length", 2)
    return newMemoryReader(nil, pointer, length)
end

--- Creates a read-only stream retaining `text` without copying it.
newStringStream = function(text: string, contentTypeValue?: string): ReadableStream
    if type(text) ~= "string" then
        error("tecs: io.newStringStream needs a byte string", 2)
    end
    return rawSetMetatable(
        {
            _text = text,
            _contentType = contentTypeValue,
            _closed = false,
        } as StringStream,
        StringStreamMT
    ) as ReadableStream
end

--- Creates a stream retaining the caller's buffer.
makeBufferStream = function(sourceBuffer: IOBuffer, contentTypeValue?: string, ownsBuffer?: boolean): ReadWriteStream
    sourceBuffer = checkedBuffer(sourceBuffer, "io.Buffer:newStream", 2)
    if sourceBuffer:isReleased() then
        error("tecs: io.Buffer:newStream needs an open buffer", 2)
    end
    return rawSetMetatable(
        {
            _buffer = sourceBuffer,
            _ownsBuffer = ownsBuffer or false,
            _contentType = contentTypeValue,
            _closed = false,
        } as BufferStream,
        BufferStreamMT
    ) as ReadWriteStream
end

--- Creates a read-only stream retaining an immutable byte view.
makeViewStream = function(sourceView: ByteView, contentTypeValue?: string): ReadableStream
    viewRange(sourceView, 0, nil, 2)
    return rawSetMetatable(
        {
            _view = sourceView:view(),
            _contentType = contentTypeValue,
            _closed = false,
        } as ViewStream,
        ViewStreamMT
    ) as ReadableStream
end

buffer.setStreamFactories(makeBufferStream, makeViewStream)

--- Creates a read-only stream borrowing FFI bytes.
local function newByteStream(pointer: loader.CValue, length: integer, contentTypeValue?: string): ReadableStream
    if pointer == nil then
        error("tecs: io.newByteStream needs an FFI pointer", 2)
    end
    length = nonNegative(length, "io.newByteStream length", 2)
    return rawSetMetatable(
        {
            _pointer = pointer,
            _length = length,
            _contentType = contentTypeValue,
            _closed = false,
        } as ByteStream,
        ByteStreamMT
    ) as ReadableStream
end

newFileStream = function(path: PathInput, contentTypeValue?: string): ReadWriteStream
    local rendered: string
    if type(path) == "string" then
        rendered = path as string
    elseif type(path) == "table" and type((path as {string: any}).toString) == "function" then
        rendered = (path as Path):toString()
    end
    if type(rendered) ~= "string" or rendered == "" then
        error("tecs: io.newFileStream needs a path", 2)
    end
    return rawSetMetatable(
        {
            _path = rendered,
            _contentType = contentTypeValue,
            _closed = false,
        } as FileStream,
        FileStreamMT
    ) as ReadWriteStream
end

--- Creates a one-shot stream borrowing a Lua file handle.
local function newHandleStream(handle: FILE, length?: integer, contentTypeValue?: string): ReadWriteStream
    if handle == nil then
        error("tecs: io.newHandleStream needs a handle", 2)
    end
    if length ~= nil then
        length = nonNegative(length, "io.newHandleStream length", 2)
    end
    return rawSetMetatable(
        {
            _state = {
                handle = handle,
                length = length,
                consumed = false,
            },
            _contentType = contentTypeValue,
            _closed = false,
        } as HandleStream,
        HandleStreamMT
    ) as ReadWriteStream
end

local function metadataContentType(self: MetadataState): string | nil
    return self._metadataContentType ~= nil and self._metadataContentType or self._source:contentType()
end

local function metadataContentLength(self: MetadataState): integer | nil
    return self._metadataLength ~= nil and self._metadataLength or self._source:contentLength()
end

local function metadataIsReadable(self: MetadataState): boolean
    return self._source:isReadable()
end

local function metadataIsWritable(self: MetadataState): boolean
    return self._source:isWritable()
end

local function metadataIsReplayable(self: MetadataState): boolean
    if self._metadataReplayable ~= nil then
        return self._metadataReplayable
    end
    return self._source:isReplayable()
end

local function metadataClose(self: MetadataState): boolean, string
    return self._source:close()
end

local function metadataNewReader(self: MetadataState): Reader, string
    return (self._source as ReadableStream):newReader()
end

local function metadataReadAll(self: MetadataState, maxBytes?: integer): string, string
    return (self._source as ReadableStream):readAll(maxBytes)
end

local function metadataTransferToBuffer(self: MetadataState, maxBytes?: integer): IOBuffer, string
    return (self._source as ReadableStream):transferToBuffer(maxBytes)
end

local function metadataTransferTo(self: MetadataState, destination: WritableStream): integer, string
    return (self._source as ReadableStream):transferTo(destination)
end

local function metadataTransferToFile(self: MetadataState, path: string): integer, string
    return (self._source as ReadableStream):transferToFile(path)
end

local function metadataDiscard(self: MetadataState): integer, string
    return (self._source as ReadableStream):discard()
end

local function metadataNewWriter(self: MetadataState): Writer, string
    return (self._source as WritableStream):newWriter()
end

local function metadataWriteAll(self: MetadataState, text: string): integer, string
    return (self._source as WritableStream):writeAll(text)
end

local function metadataWriteBuffer(
    self: MetadataState, source: IOBuffer, offset?: integer, count?: integer
): integer, string
    return (self._source as WritableStream):writeBuffer(source, offset, count)
end

local function metadataWriteView(
    self: MetadataState, source: ByteView, offset?: integer, count?: integer
): integer, string
    return (self._source as WritableStream):writeView(source, offset, count)
end

MetadataStream.contentType = metadataContentType
MetadataStream.contentLength = metadataContentLength
MetadataStream.isReadable = metadataIsReadable
MetadataStream.isWritable = metadataIsWritable
MetadataStream.isReplayable = metadataIsReplayable
MetadataStream.close = metadataClose

MetadataReadableStream.contentType = metadataContentType
MetadataReadableStream.contentLength = metadataContentLength
MetadataReadableStream.isReadable = metadataIsReadable
MetadataReadableStream.isWritable = metadataIsWritable
MetadataReadableStream.isReplayable = metadataIsReplayable
MetadataReadableStream.close = metadataClose
MetadataReadableStream.newReader = metadataNewReader
MetadataReadableStream.readAll = metadataReadAll
MetadataReadableStream.transferToBuffer = metadataTransferToBuffer
MetadataReadableStream.transferTo = metadataTransferTo
MetadataReadableStream.transferToFile = metadataTransferToFile
MetadataReadableStream.discard = metadataDiscard

MetadataWritableStream.contentType = metadataContentType
MetadataWritableStream.contentLength = metadataContentLength
MetadataWritableStream.isReadable = metadataIsReadable
MetadataWritableStream.isWritable = metadataIsWritable
MetadataWritableStream.isReplayable = metadataIsReplayable
MetadataWritableStream.close = metadataClose
MetadataWritableStream.newWriter = metadataNewWriter
MetadataWritableStream.writeAll = metadataWriteAll
MetadataWritableStream.writeBuffer = metadataWriteBuffer
MetadataWritableStream.writeView = metadataWriteView

MetadataReadWriteStream.contentType = metadataContentType
MetadataReadWriteStream.contentLength = metadataContentLength
MetadataReadWriteStream.isReadable = metadataIsReadable
MetadataReadWriteStream.isWritable = metadataIsWritable
MetadataReadWriteStream.isReplayable = metadataIsReplayable
MetadataReadWriteStream.close = metadataClose
MetadataReadWriteStream.newReader = metadataNewReader
MetadataReadWriteStream.readAll = metadataReadAll
MetadataReadWriteStream.transferToBuffer = metadataTransferToBuffer
MetadataReadWriteStream.transferTo = metadataTransferTo
MetadataReadWriteStream.transferToFile = metadataTransferToFile
MetadataReadWriteStream.discard = metadataDiscard
MetadataReadWriteStream.newWriter = metadataNewWriter
MetadataReadWriteStream.writeAll = metadataWriteAll
MetadataReadWriteStream.writeBuffer = metadataWriteBuffer
MetadataReadWriteStream.writeView = metadataWriteView

--- Returns a lazy metadata view preserving the source's concrete interface.
withMetadata = function<T is Stream>(
    source: T, contentTypeValue?: string, contentLengthValue?: integer, replayableValue?: boolean
): T
    source = checkedStream(source, "io.Stream:withMetadata", 2)
    if contentTypeValue ~= nil and type(contentTypeValue) ~= "string" then
        error("tecs: io.Stream:withMetadata content type must be a string", 2)
    end
    if replayableValue ~= nil and type(replayableValue) ~= "boolean" then
        error("tecs: io.Stream:withMetadata replayability must be boolean", 2)
    end
    if contentLengthValue ~= nil then
        contentLengthValue = nonNegative(contentLengthValue, "io.Stream:withMetadata content length", 2)
    end
    if
        (contentTypeValue == nil or contentTypeValue == source:contentType())
        and (contentLengthValue == nil or contentLengthValue == source:contentLength())
        and (replayableValue == nil or replayableValue == source:isReplayable())
    then
        return source
    end

    local fields <const> = {
        _source = source as Stream,
        _metadataContentType = contentTypeValue,
        _metadataLength = contentLengthValue,
        _metadataReplayable = replayableValue,
    }
    if source:isReadable() then
        if source:isWritable() then
            local view <const> = rawSetMetatable(
                fields as MetadataReadWriteStream, MetadataReadWriteStreamMT
            ) as MetadataReadWriteStream
            return view as T
        end
        local view <const> = rawSetMetatable(
            fields as MetadataReadableStream, MetadataReadableStreamMT
        ) as MetadataReadableStream
        return view as T
    elseif source:isWritable() then
        local view <const> = rawSetMetatable(
            fields as MetadataWritableStream, MetadataWritableStreamMT
        ) as MetadataWritableStream
        return view as T
    end
    local view <const> = rawSetMetatable(fields as MetadataStream, MetadataStreamMT) as MetadataStream
    return view as T
end

StringStream.withMetadata = withMetadata
BufferStream.withMetadata = withMetadata
ByteStream.withMetadata = withMetadata
ViewStream.withMetadata = withMetadata
FileStream.withMetadata = withMetadata
HandleStream.withMetadata = withMetadata
ReaderStream.withMetadata = withMetadata
MetadataStream.withMetadata = withMetadata
MetadataReadableStream.withMetadata = withMetadata
MetadataWritableStream.withMetadata = withMetadata
MetadataReadWriteStream.withMetadata = withMetadata

local record stream
    type Reader = Reader
    type Writer = Writer
    type Stream = Stream
    type ReadableStream = ReadableStream
    type WritableStream = WritableStream
    type ReadWriteStream = ReadWriteStream

    newBuffer: function(initial?: integer | string): IOBuffer
    newStringReader: function(text: string): Reader
    newByteReader: function(pointer: loader.CValue, length: integer): Reader
    newEmptyStream: function(contentType?: string): ReadableStream
    newStringStream: function(text: string, contentType?: string): ReadableStream
    newByteStream: function(pointer: loader.CValue, length: integer, contentType?: string): ReadableStream
    newFileStream: function(path: PathInput, contentType?: string): ReadWriteStream
    newHandleStream: function(handle: FILE, length?: integer, contentType?: string): ReadWriteStream
    withMetadata: function<T is Stream>(
        source: T, contentType?: string, contentLength?: integer, isReplayable?: boolean
    ): T
    _check: function<T is Stream>(value: T, what: string, level: integer): T
    _borrowBytes: function(source: ReadableStream): BorrowedBytes
    _nativeFilePath: function(source: ReadableStream): string
    _snapshot: function(source: Stream, what: string): {string: any}
    _restore: function(saved: {string: any}, what: string): Stream
    _newReaderStream: function(reader: Reader, contentType?: string, contentLength?: integer): ReadableStream
end

local function newReaderStream(reader: Reader, contentTypeValue?: string, contentLengthValue?: integer): ReadableStream
    if reader == nil then
        error("tecs: reader stream needs a Reader", 2)
    end
    if contentLengthValue ~= nil then
        contentLengthValue = nonNegative(contentLengthValue, "reader stream content length", 2)
    end
    return rawSetMetatable(
        {
            _reader = reader,
            _length = contentLengthValue,
            _contentType = contentTypeValue,
            _opened = false,
            _closed = false,
        } as ReaderStream,
        ReaderStreamMT
    ) as ReadableStream
end

return {
    newBuffer = buffer.new,
    newStringReader = newStringReader,
    newByteReader = newByteReader,
    newEmptyStream = newEmptyStream,
    newStringStream = newStringStream,
    newByteStream = newByteStream,
    newFileStream = newFileStream,
    newHandleStream = newHandleStream,
    withMetadata = withMetadata,
    _check = checkedStream,
    _borrowBytes = borrowedBytes,
    _nativeFilePath = nativeFilePath,
    _snapshot = snapshotStream,
    _restore = restoreStream,
    _newReaderStream = newReaderStream,
} as stream
