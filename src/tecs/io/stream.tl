--[=[
Binary storage descriptors and cooperative transfers.

A stream carries the recipe for opening bytes, not a cursor. Every reader and
writer owns its position. Replayable memory and file streams can therefore
open independent readers; a borrowed handle deliberately cannot.

High-level operations return [`Future`](tealdoc:tecs.Future) values. They move
bounded chunks when `tecs.io.poll` runs or when a wait advances the future.
No native callback enters LuaJIT.
]=]

local ffi <const> = require("ffi")
local Future <const> = require("tecs.Future")
local buffer <const> = require("tecs.io.buffer")
local loader <const> = require("tecs.ffi.loader")
local time <const> = require("tecs.platform.time")
local type types = require("tecs.io.types")
local type Files = require("tecs.io.files")

local type IOBuffer = types.Buffer
local type Reader = types.Reader
local type Writer = types.Writer
local type Stream = types.Stream
local type ReadableStream = types.ReadableStream
local type WritableStream = types.WritableStream
local type ReadWriteStream = types.ReadWriteStream
local type Source = Future.Source

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min

local record BorrowedBytes
    pointer: any
    length: integer
    owner: any
end

local newStringStream: function(text: string, contentType?: string): ReadableStream
local newBufferStream: function(sourceBuffer: IOBuffer, contentType?: string): ReadWriteStream
local newFileStream: function(path: string, contentType?: string): ReadWriteStream
local withMetadata: function<T is Stream>(
    source: T, contentType?: string, contentLength?: integer, isReplayable?: boolean
): T
local CHUNK <const> = 64 * 1024
-- Application polling shares this operation budget across every transfer.
-- A step reads or writes at most CHUNK bytes, so one call performs at most
-- about one MiB of aggregate copying regardless of the pending count.
local POLL_STEPS <const> = 16
local DEFAULT_WAIT_MS <const> = 5000
local WAIT_SLICE_MS <const> = 1
local MAX_INTEGER <const> = 9007199254740991

--- Fields shared by concrete descriptors.
local interface Backing
    _contentType: string
    _closed: boolean
end

--- A retained immutable Lua string.
local record StringStream is Backing, ReadableStream
    _text: string
end

--- A retained caller-owned growable buffer.
local record BufferStream is Backing, ReadWriteStream
    _buffer: IOBuffer
end

--- Borrowed FFI memory whose owner stays with the caller.
local record ByteStream is Backing, ReadableStream
    _pointer: loader.CValue
    _length: integer
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

local StringStreamMT <const>: metatable<StringStream> = {__index = StringStream}
local BufferStreamMT <const>: metatable<BufferStream> = {__index = BufferStream}
local ByteStreamMT <const>: metatable<ByteStream> = {__index = ByteStream}
local FileStreamMT <const>: metatable<FileStream> = {__index = FileStream}
local HandleStreamMT <const>: metatable<HandleStream> = {__index = HandleStream}

--- A cursor over a string, buffer, or borrowed pointer.
local record MemoryReader is Reader
    _text: string
    _buffer: IOBuffer
    _pointer: loader.CValue
    _length: integer
    _at: integer
    _closed: boolean
end

--- A cursor replacing a growable memory destination.
local record MemoryWriter is Writer
    _buffer: IOBuffer
    _at: integer
    _closed: boolean
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
local MemoryWriterMT <const>: metatable<MemoryWriter> = {__index = MemoryWriter}
local HandleReaderMT <const>: metatable<HandleReader> = {__index = HandleReader}
local HandleWriterMT <const>: metatable<HandleWriter> = {__index = HandleWriter}
local MetadataStreamMT <const>: metatable<MetadataStream> = {__index = MetadataStream}
local MetadataReadableStreamMT <const>: metatable<MetadataReadableStream> = {__index = MetadataReadableStream}
local MetadataWritableStreamMT <const>: metatable<MetadataWritableStream> = {__index = MetadataWritableStream}
local MetadataReadWriteStreamMT <const>: metatable<MetadataReadWriteStream> = {__index = MetadataReadWriteStream}
local rawSetMetatable <const> = setmetatable as function(any, any): any

local enum TransferKind
    "readString"
    "transferToBuffer"
    "copy"
    "discard"
    "writeBuffer"
    "writeString"
end

--- One cooperative transfer and its Future source.
local record Transfer
    kind: TransferKind
    reader: Reader
    writer: Writer
    buffer: IOBuffer
    scratch: IOBuffer
    text: string
    future: Future<any>
    maximum: integer
    total: integer
    sourceOffset: integer
    sourceFinish: integer
    pendingOffset: integer
    pendingCount: integer
    at: integer
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Transfer): integer
    advance: function(self: Transfer, ms: number): integer
    cancel: function(self: Transfer, future: Future<any>)
end

local TransferMT <const>: metatable<Transfer> = {__index = Transfer}
local transfers: {Transfer} = {}
local pollCursor = 1
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
        or type(dynamic.isAvailable) ~= "function"
        or type(dynamic.close) ~= "function"
    then
        error(("tecs: %s needs a Stream implementation"):format(what), level)
    end
    if
        (dynamic.isReadable as function(any): boolean)(value)
        and (
            type(dynamic.hasBuffer) ~= "function"
            or type(dynamic.newReader) ~= "function"
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
    if source == nil or not source:isReadable() or not source:isAvailable() then
        return nil
    end
    local backing <const> = metadataBacking(source)
    local mt <const> = getmetatable(backing as any) as any
    if mt == (StringStreamMT as any) then
        local text <const> = (backing as StringStream)._text
        return {
            pointer = ffi.cast("const uint8_t *", text),
            length = #text,
            owner = text,
        }
    elseif mt == (BufferStreamMT as any) then
        local sourceBuffer <const> = (backing as BufferStream)._buffer
        if sourceBuffer:isReleased() then
            return nil
        end
        return {
            pointer = sourceBuffer:getFFIPointer(),
            length = sourceBuffer:length(),
            owner = sourceBuffer,
        }
    elseif mt == (ByteStreamMT as any) then
        local bytes <const> = backing as ByteStream
        return {
            pointer = bytes._pointer,
            length = bytes._length,
            owner = backing,
        }
    end
    return nil
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
        return restoredMetadata(newBufferStream(buffer.new(bytes), saved.contentType as string), saved)
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
    text: string, sourceBuffer: IOBuffer, pointer: loader.CValue, length: integer
): MemoryReader
    return rawSetMetatable(
        {
            _text = text,
            _buffer = sourceBuffer,
            _pointer = pointer,
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
        if self._buffer ~= nil then
            if self._buffer:isReleased() then
                return nil, "stream buffer is released"
            end
            pointer = self._buffer:getFFIPointer()
        end
        result = loader.toBytes((pointer + self._at) as loader.CValue, taking)
    end
    self._at = self._at + taking
    return result
end

function MemoryReader:readInto(destination: IOBuffer, count: integer, offset?: integer): integer, string
    if self._closed then
        return nil, "the reader is closed"
    end
    count = nonNegative(count, "Reader:readInto count", 2)
    offset = nonNegative(offset or 0, "Reader:readInto offset", 2)
    if self._buffer ~= nil and self._buffer == destination then
        return nil, "cannot read a buffer into itself"
    end
    if count == 0 or self._at >= self._length then
        return 0
    end
    local taking <const> = min(count, self._length - self._at)
    local source: loader.BytePointer
    if self._text ~= nil then
        source = ffi.cast("uint8_t *", self._text) as loader.BytePointer
    elseif self._buffer ~= nil then
        if self._buffer:isReleased() then
            return nil, "stream buffer is released"
        end
        source = self._buffer:getFFIPointer()
    else
        source = loader.bytePointer(self._pointer)
    end
    local output <const>, previousLength = buffer.prepareWrite(destination, offset, taking)
    ffi.copy(output as ffi.CData, (source + self._at) as ffi.CData, taking)
    buffer.commitWrite(destination, offset, taking, previousLength)
    self._at = self._at + taking
    return taking
end

function MemoryReader:close()
    self._closed = true
end

function MemoryWriter:write(bytes: string): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    if self._buffer:isReleased() then
        return false, "stream buffer is released"
    end
    self._buffer:setString(bytes, self._at)
    self._at = self._at + #bytes
    return true
end

function MemoryWriter:writeFrom(source: IOBuffer, offset?: integer, count?: integer): integer, string
    if self._closed then
        return nil, "the writer is closed"
    end
    if self._buffer:isReleased() then
        return nil, "stream buffer is released"
    end
    if source == self._buffer then
        return nil, "cannot write a buffer into itself"
    end
    offset, count = bufferRange(source, offset, count, 2)
    if count == 0 then
        return 0
    end
    local output <const>, previousLength = buffer.prepareWrite(self._buffer, self._at, count)
    ffi.copy(output as ffi.CData, (source:getFFIPointer() + offset) as ffi.CData, count)
    buffer.commitWrite(self._buffer, self._at, count, previousLength)
    self._at = self._at + count
    return count
end

function MemoryWriter:flush(): boolean, string
    if self._closed then
        return false, "the writer is closed"
    end
    if self._buffer:isReleased() then
        return false, "stream buffer is released"
    end
    return true
end

function MemoryWriter:close(): boolean, string
    if self._closed then
        return true
    end
    self._closed = true
    if self._buffer:isReleased() then
        return false, "stream buffer is released"
    end
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

function HandleReader:readInto(destination: IOBuffer, count: integer, offset?: integer): integer, string
    count = nonNegative(count, "Reader:readInto count", 2)
    offset = nonNegative(offset or 0, "Reader:readInto offset", 2)
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

function HandleReader:close()
    self._closed = true
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

local function remove(transfer: Transfer)
    if transfer.at == 0 then
        return
    end
    local at <const> = transfer.at
    local last <const> = #transfers
    local moved <const> = transfers[last]
    transfers[last] = nil
    if at < last then
        transfers[at] = moved
        moved.at = at
    end
    transfer.at = 0
end

local function closeEndpoints(transfer: Transfer): boolean, string
    local closed = true
    local reason: string
    if transfer.reader ~= nil then
        local reader <const> = transfer.reader
        transfer.reader = nil
        local called <const>, closeReason = pcall(reader.close, reader) as (boolean, any)
        if not called then
            closed = false
            reason = tostring(closeReason)
        end
    end
    if transfer.writer ~= nil then
        local writer <const> = transfer.writer
        transfer.writer = nil
        local called <const>, writerClosed, closeReason = pcall(writer.close, writer) as (boolean, boolean, string)
        if not called then
            if closed then
                reason = tostring(writerClosed)
            end
            closed = false
        elseif not writerClosed then
            if closed then
                reason = closeReason or "stream writer could not close"
            end
            closed = false
        end
    end
    return closed, reason
end

local function releaseScratch(transfer: Transfer)
    if transfer.scratch ~= nil then
        transfer.scratch:release()
        transfer.scratch = nil
    end
end

local function fail(transfer: Transfer, reason: string)
    remove(transfer)
    closeEndpoints(transfer)
    releaseScratch(transfer)
    if transfer.kind == "transferToBuffer" and transfer.buffer ~= nil then
        transfer.buffer:release()
        transfer.buffer = nil
    end
    transfer.future:fail(reason or "stream transfer failed")
end

local function finish(transfer: Transfer)
    remove(transfer)
    local closed <const>, reason = closeEndpoints(transfer)
    releaseScratch(transfer)
    if not closed then
        if transfer.kind == "transferToBuffer" and transfer.buffer ~= nil then
            transfer.buffer:release()
            transfer.buffer = nil
        end
        transfer.future:fail(reason)
        return
    end
    if transfer.kind == "readString" then
        local result <const> = transfer.buffer:getString()
        transfer.buffer:release()
        transfer.buffer = nil
        transfer.future:complete(result)
    elseif transfer.kind == "transferToBuffer" then
        local result <const> = transfer.buffer
        transfer.buffer = nil
        transfer.future:complete(result)
    else
        transfer.future:complete(transfer.total)
    end
end

local function readStep(transfer: Transfer)
    local count = CHUNK
    if transfer.maximum ~= nil then
        count = min(count, transfer.maximum - transfer.total + 1)
    end
    transfer.buffer:resize(transfer.total)
    local got <const>, reason = transfer.reader:readInto(transfer.buffer, count, transfer.total)
    if got == nil then
        fail(transfer, reason)
        return
    end
    if got == 0 then
        finish(transfer)
        return
    end
    transfer.total = transfer.total + got
    if transfer.maximum ~= nil and transfer.total > transfer.maximum then
        fail(transfer, ("stream exceeds the %d byte limit"):format(transfer.maximum))
    end
end

local function copyStep(transfer: Transfer)
    if transfer.pendingOffset < transfer.pendingCount then
        local wrote <const>, reason = transfer.writer:writeFrom(
            transfer.scratch, transfer.pendingOffset, transfer.pendingCount - transfer.pendingOffset
        )
        if wrote == nil then
            fail(transfer, reason)
            return
        end
        if wrote <= 0 then
            fail(transfer, "stream writer made no progress")
            return
        end
        transfer.pendingOffset = transfer.pendingOffset + wrote
        transfer.total = transfer.total + wrote
        return
    end

    transfer.scratch:clear()
    local got <const>, reason = transfer.reader:readInto(transfer.scratch, CHUNK)
    if got == nil then
        fail(transfer, reason)
        return
    end
    if got == 0 then
        finish(transfer)
        return
    end
    if transfer.kind == "discard" then
        transfer.total = transfer.total + got
    else
        transfer.pendingOffset = 0
        transfer.pendingCount = got
    end
end

local function writeStep(transfer: Transfer)
    if transfer.kind == "writeString" then
        if transfer.sourceOffset >= transfer.sourceFinish then
            finish(transfer)
            return
        end
        local nextOffset <const> = min(transfer.sourceOffset + CHUNK, transfer.sourceFinish)
        local piece = transfer.text
        if transfer.sourceOffset ~= 0 or nextOffset ~= transfer.sourceFinish then
            piece = transfer.text:sub(transfer.sourceOffset + 1, nextOffset)
        end
        local ok <const>, reason = transfer.writer:write(piece)
        if not ok then
            fail(transfer, reason)
            return
        end
        transfer.sourceOffset = nextOffset
        transfer.total = nextOffset
        if transfer.sourceOffset >= transfer.sourceFinish then
            finish(transfer)
        end
        return
    end
    if transfer.sourceOffset >= transfer.sourceFinish then
        finish(transfer)
        return
    end
    local requested <const> = min(CHUNK, transfer.sourceFinish - transfer.sourceOffset)
    local wrote <const>, reason = transfer.writer:writeFrom(transfer.buffer, transfer.sourceOffset, requested)
    if wrote == nil then
        fail(transfer, reason)
        return
    end
    if wrote <= 0 then
        fail(transfer, "stream writer made no progress")
        return
    end
    transfer.sourceOffset = transfer.sourceOffset + wrote
    transfer.total = transfer.total + wrote
    if transfer.sourceOffset >= transfer.sourceFinish then
        finish(transfer)
    end
end

local function step(transfer: Transfer)
    if transfer.kind == "readString" or transfer.kind == "transferToBuffer" then
        readStep(transfer)
    elseif transfer.kind == "copy" or transfer.kind == "discard" then
        copyStep(transfer)
    else
        writeStep(transfer)
    end
end

local function safelyStep(transfer: Transfer): integer
    if transfer.at == 0 then
        return 0
    end
    local ok <const>, reason = pcall(step, transfer) as (boolean, any)
    if not ok and transfer.at ~= 0 then
        fail(transfer, tostring(reason))
    end
    return transfer.at == 0 and 1 or 0
end

function Transfer:poll(): integer
    local settled = 0
    local stepCount = 0
    while self.at ~= 0 and stepCount < POLL_STEPS do
        settled = settled + safelyStep(self)
        stepCount = stepCount + 1
    end
    return settled
end

function Transfer:advance(ms: number): integer
    local deadline <const> = time.now() * 1000.0 + max(0, ms)
    local settled = safelyStep(self)
    while self.at ~= 0 and time.now() * 1000.0 < deadline do
        settled = settled + safelyStep(self)
    end
    return settled
end

function Transfer:cancel(future: Future<any>)
    if self.at == 0 or self.future ~= future then
        return
    end
    remove(self)
    closeEndpoints(self)
    releaseScratch(self)
    if self.kind == "transferToBuffer" and self.buffer ~= nil then
        self.buffer:release()
        self.buffer = nil
    end
end

local function newTransfer(kind: TransferKind): Transfer
    local transfer = setmetatable(
        {
            kind = kind,
            total = 0,
            sourceOffset = 0,
            sourceFinish = 0,
            pendingOffset = 0,
            pendingCount = 0,
            at = #transfers + 1,
            sliceMs = WAIT_SLICE_MS,
            defaultWaitMs = DEFAULT_WAIT_MS,
        } as Transfer,
        TransferMT
    )
    transfer.future = Future.pending(transfer as Source)
    transfers[transfer.at] = transfer
    return transfer
end

local function failed<T>(reason: string): Future<T>
    return Future.failed(reason)
end

local function beginRead(source: ReadableStream, kind: TransferKind, maxBytes: integer): Future<any>
    maxBytes = maximum(maxBytes, 3)
    local metadataOK <const>, known = pcall(source.contentLength, source) as (boolean, integer)
    if not metadataOK then
        return failed(tostring(known))
    end
    if maxBytes ~= nil and known ~= nil and known > maxBytes then
        return failed(("stream exceeds the %d byte limit"):format(maxBytes))
    end
    local allocated <const>, bufferOrReason = pcall(buffer.new) as (boolean, any)
    if not allocated then
        return failed(tostring(bufferOrReason))
    end
    local outputBuffer <const> = bufferOrReason as IOBuffer
    if known ~= nil and known > 0 then
        local reserved <const>, reserveReason = pcall(
            outputBuffer.ensureCapacity, outputBuffer, known
        ) as (boolean, any)
        if not reserved then
            outputBuffer:release()
            return failed(tostring(reserveReason))
        end
    end
    local reader <const>, reason = source:newReader()
    if reader == nil then
        outputBuffer:release()
        return failed(reason)
    end
    local transfer <const> = newTransfer(kind)
    transfer.reader = reader
    transfer.buffer = outputBuffer
    transfer.maximum = maxBytes
    return transfer.future
end

local function readAll(source: ReadableStream, maxBytes: integer): Future<string>
    return beginRead(source, "readString", maxBytes) as Future<string>
end

local function transferToBuffer(source: ReadableStream, maxBytes: integer): Future<IOBuffer>
    return beginRead(source, "transferToBuffer", maxBytes) as Future<IOBuffer>
end

local function transferTo(source: ReadableStream, destination: WritableStream): Future<integer>
    if sharesBacking(source, destination) then
        return failed("cannot transfer between streams sharing one backing")
    end
    local allocated <const>, scratchOrReason = pcall(buffer.new) as (boolean, any)
    if not allocated then
        return failed(tostring(scratchOrReason))
    end
    local scratch <const> = scratchOrReason as IOBuffer
    local reader <const>, readReason = source:newReader()
    if reader == nil then
        scratch:release()
        return failed(readReason)
    end
    local writer <const>, writeReason = destination:newWriter()
    if writer == nil then
        scratch:release()
        pcall(reader.close, reader)
        return failed(writeReason)
    end
    local transfer <const> = newTransfer("copy")
    transfer.reader = reader
    transfer.writer = writer
    transfer.scratch = scratch
    return transfer.future as Future<integer>
end

local function transferToFile(source: ReadableStream, path: string): Future<integer>
    if type(path) ~= "string" or path == "" then
        error("tecs: transferToFile needs a path", 3)
    end
    return source:transferTo(newFileStream(path))
end

local function discard(source: ReadableStream): Future<integer>
    local allocated <const>, scratchOrReason = pcall(buffer.new) as (boolean, any)
    if not allocated then
        return failed(tostring(scratchOrReason))
    end
    local scratch <const> = scratchOrReason as IOBuffer
    local reader <const>, reason = source:newReader()
    if reader == nil then
        scratch:release()
        return failed(reason)
    end
    local transfer <const> = newTransfer("discard")
    transfer.reader = reader
    transfer.scratch = scratch
    return transfer.future as Future<integer>
end

local function writeString(destination: WritableStream, text: string): Future<integer>
    if type(text) ~= "string" then
        error("tecs: writeAll needs a byte string", 3)
    end
    local writer <const>, reason = destination:newWriter()
    if writer == nil then
        return failed(reason)
    end
    local transfer <const> = newTransfer("writeString")
    transfer.writer = writer
    transfer.text = text
    transfer.sourceFinish = #text
    return transfer.future as Future<integer>
end

local function writeBuffer(
    destination: WritableStream, sourceBuffer: IOBuffer, offset: integer, count: integer
): Future<integer>
    sourceBuffer = checkedBuffer(sourceBuffer, "writeBuffer", 3)
    offset, count = bufferRange(sourceBuffer, offset, count, 3)
    local writer <const>, reason = destination:newWriter()
    if writer == nil then
        return failed(reason)
    end
    local transfer <const> = newTransfer("writeBuffer")
    transfer.writer = writer
    transfer.buffer = sourceBuffer
    transfer.sourceOffset = offset
    transfer.sourceFinish = offset + count
    return transfer.future as Future<integer>
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
function StringStream:isAvailable(): boolean
    return not unavailable(self)
end
function StringStream:close()
    close(self)
end
function StringStream:hasBuffer(): boolean
    return false
end

function StringStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return newMemoryReader(self._text, nil, nil, #self._text)
end

function StringStream:readAll(maxBytes?: integer): Future<string>
    maxBytes = maximum(maxBytes, 2)
    if unavailable(self) then
        return failed("stream is closed")
    end
    if maxBytes ~= nil and #self._text > maxBytes then
        return failed(("stream exceeds the %d byte limit"):format(maxBytes))
    end
    return Future.settled(self._text)
end

function StringStream:transferToBuffer(maxBytes?: integer): Future<IOBuffer>
    return transferToBuffer(self, maxBytes)
end

function StringStream:transferTo(destination: WritableStream): Future<integer>
    if unavailable(self) then
        return failed("stream is closed")
    end
    return destination:writeAll(self._text)
end

function StringStream:transferToFile(path: string): Future<integer>
    return transferToFile(self, path)
end

function StringStream:discard(): Future<integer>
    if unavailable(self) then
        return failed("stream is closed")
    end
    return Future.settled(#self._text)
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
function BufferStream:isAvailable(): boolean
    return not unavailable(self) and not self._buffer:isReleased()
end
function BufferStream:close()
    close(self)
end
function BufferStream:hasBuffer(): boolean
    return self:isAvailable()
end

function BufferStream:newReader(): Reader, string
    if not self:isAvailable() then
        return nil, "stream is closed or its buffer is released"
    end
    return newMemoryReader(nil, self._buffer, nil, self._buffer:length())
end

function BufferStream:newWriter(): Writer, string
    if not self:isAvailable() then
        return nil, "stream is closed or its buffer is released"
    end
    self._buffer:clear()
    return rawSetMetatable(
        {
            _buffer = self._buffer,
            _at = 0,
            _closed = false,
        } as MemoryWriter,
        MemoryWriterMT
    ) as Writer
end

function BufferStream:readAll(maxBytes?: integer): Future<string>
    maxBytes = maximum(maxBytes, 2)
    local length <const> = self:contentLength()
    if length == nil then
        return failed("stream is closed or its buffer is released")
    end
    if maxBytes ~= nil and length > maxBytes then
        return failed(("stream exceeds the %d byte limit"):format(maxBytes))
    end
    return Future.settled(self._buffer:getString())
end

function BufferStream:transferToBuffer(maxBytes?: integer): Future<IOBuffer>
    maxBytes = maximum(maxBytes, 2)
    local length <const> = self:contentLength()
    if length == nil then
        return failed("stream is closed or its buffer is released")
    end
    if maxBytes ~= nil and length > maxBytes then
        return failed(("stream exceeds the %d byte limit"):format(maxBytes))
    end
    return Future.settled(self._buffer)
end

function BufferStream:transferTo(destination: WritableStream): Future<integer>
    if not self:isAvailable() then
        return failed("stream is closed or its buffer is released")
    end
    if sharesBacking(self, destination) then
        return failed("cannot transfer between streams sharing one backing")
    end
    return destination:writeBuffer(self._buffer)
end

function BufferStream:transferToFile(path: string): Future<integer>
    return transferToFile(self, path)
end

function BufferStream:discard(): Future<integer>
    local length <const> = self:contentLength()
    if length == nil then
        return failed("stream is closed or its buffer is released")
    end
    return Future.settled(length)
end

function BufferStream:writeAll(text: string): Future<integer>
    return writeString(self, text)
end

function BufferStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): Future<integer>
    sourceBuffer = checkedBuffer(sourceBuffer, "writeBuffer", 2)
    if sourceBuffer == self._buffer then
        return failed("cannot write a buffer into itself")
    end
    return writeBuffer(self, sourceBuffer, offset, count)
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
function ByteStream:isAvailable(): boolean
    return not unavailable(self)
end
function ByteStream:close()
    close(self)
end
function ByteStream:hasBuffer(): boolean
    return false
end

function ByteStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return newMemoryReader(nil, nil, self._pointer, self._length)
end

function ByteStream:readAll(maxBytes?: integer): Future<string>
    maxBytes = maximum(maxBytes, 2)
    if unavailable(self) then
        return failed("stream is closed")
    end
    if maxBytes ~= nil and self._length > maxBytes then
        return failed(("stream exceeds the %d byte limit"):format(maxBytes))
    end
    return Future.settled(loader.toBytes(self._pointer, self._length))
end

function ByteStream:transferToBuffer(maxBytes?: integer): Future<IOBuffer>
    return transferToBuffer(self, maxBytes)
end

function ByteStream:transferTo(destination: WritableStream): Future<integer>
    if unavailable(self) then
        return failed("stream is closed")
    end
    return transferTo(self, destination)
end

function ByteStream:transferToFile(path: string): Future<integer>
    return transferToFile(self, path)
end

function ByteStream:discard(): Future<integer>
    if unavailable(self) then
        return failed("stream is closed")
    end
    return Future.settled(self._length)
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
function FileStream:isAvailable(): boolean
    return not unavailable(self)
end
function FileStream:close()
    close(self)
end
function FileStream:hasBuffer(): boolean
    return false
end

function FileStream:newReader(): Reader, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return getFiles().openRead(self._path)
end

function FileStream:newWriter(): Writer, string
    if unavailable(self) then
        return nil, "stream is closed"
    end
    return getFiles().openWrite(self._path)
end

function FileStream:readAll(maxBytes?: integer): Future<string>
    return readAll(self, maxBytes)
end
function FileStream:transferToBuffer(maxBytes?: integer): Future<IOBuffer>
    return transferToBuffer(self, maxBytes)
end
function FileStream:transferTo(destination: WritableStream): Future<integer>
    return transferTo(self, destination)
end
function FileStream:transferToFile(path: string): Future<integer>
    return transferToFile(self, path)
end
function FileStream:discard(): Future<integer>
    return discard(self)
end
function FileStream:writeAll(text: string): Future<integer>
    return writeString(self, text)
end
function FileStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): Future<integer>
    return writeBuffer(self, sourceBuffer, offset, count)
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
function HandleStream:isAvailable(): boolean
    return not unavailable(self) and not self._state.consumed
end
function HandleStream:close()
    close(self)
end
function HandleStream:hasBuffer(): boolean
    return false
end

function HandleStream:newReader(): Reader, string
    if not self:isAvailable() then
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
    if not self:isAvailable() then
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

function HandleStream:readAll(maxBytes?: integer): Future<string>
    return readAll(self, maxBytes)
end
function HandleStream:transferToBuffer(maxBytes?: integer): Future<IOBuffer>
    return transferToBuffer(self, maxBytes)
end
function HandleStream:transferTo(destination: WritableStream): Future<integer>
    return transferTo(self, destination)
end
function HandleStream:transferToFile(path: string): Future<integer>
    return transferToFile(self, path)
end
function HandleStream:discard(): Future<integer>
    return discard(self)
end
function HandleStream:writeAll(text: string): Future<integer>
    return writeString(self, text)
end
function HandleStream:writeBuffer(sourceBuffer: IOBuffer, offset?: integer, count?: integer): Future<integer>
    return writeBuffer(self, sourceBuffer, offset, count)
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
newBufferStream = function(sourceBuffer: IOBuffer, contentTypeValue?: string): ReadWriteStream
    sourceBuffer = checkedBuffer(sourceBuffer, "io.newBufferStream", 2)
    if sourceBuffer:isReleased() then
        error("tecs: io.newBufferStream needs an open buffer", 2)
    end
    return rawSetMetatable(
        {
            _buffer = sourceBuffer,
            _contentType = contentTypeValue,
            _closed = false,
        } as BufferStream,
        BufferStreamMT
    ) as ReadWriteStream
end

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

newFileStream = function(path: string, contentTypeValue?: string): ReadWriteStream
    if type(path) ~= "string" or path == "" then
        error("tecs: io.newFileStream needs a path", 2)
    end
    return rawSetMetatable(
        {
            _path = path,
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

local function metadataIsAvailable(self: MetadataState): boolean
    return self._source:isAvailable()
end

local function metadataClose(self: MetadataState)
    self._source:close()
end

local function metadataHasBuffer(self: MetadataState): boolean
    return (self._source as ReadableStream):hasBuffer()
end

local function metadataNewReader(self: MetadataState): Reader, string
    return (self._source as ReadableStream):newReader()
end

local function metadataReadAll(self: MetadataState, maxBytes?: integer): Future<string>
    return (self._source as ReadableStream):readAll(maxBytes)
end

local function metadataTransferToBuffer(self: MetadataState, maxBytes?: integer): Future<IOBuffer>
    return (self._source as ReadableStream):transferToBuffer(maxBytes)
end

local function metadataTransferTo(self: MetadataState, destination: WritableStream): Future<integer>
    return (self._source as ReadableStream):transferTo(destination)
end

local function metadataTransferToFile(self: MetadataState, path: string): Future<integer>
    return (self._source as ReadableStream):transferToFile(path)
end

local function metadataDiscard(self: MetadataState): Future<integer>
    return (self._source as ReadableStream):discard()
end

local function metadataNewWriter(self: MetadataState): Writer, string
    return (self._source as WritableStream):newWriter()
end

local function metadataWriteAll(self: MetadataState, text: string): Future<integer>
    return (self._source as WritableStream):writeAll(text)
end

local function metadataWriteBuffer(
    self: MetadataState, source: IOBuffer, offset?: integer, count?: integer
): Future<integer>
    return (self._source as WritableStream):writeBuffer(source, offset, count)
end

MetadataStream.contentType = metadataContentType
MetadataStream.contentLength = metadataContentLength
MetadataStream.isReadable = metadataIsReadable
MetadataStream.isWritable = metadataIsWritable
MetadataStream.isReplayable = metadataIsReplayable
MetadataStream.isAvailable = metadataIsAvailable
MetadataStream.close = metadataClose

MetadataReadableStream.contentType = metadataContentType
MetadataReadableStream.contentLength = metadataContentLength
MetadataReadableStream.isReadable = metadataIsReadable
MetadataReadableStream.isWritable = metadataIsWritable
MetadataReadableStream.isReplayable = metadataIsReplayable
MetadataReadableStream.isAvailable = metadataIsAvailable
MetadataReadableStream.close = metadataClose
MetadataReadableStream.hasBuffer = metadataHasBuffer
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
MetadataWritableStream.isAvailable = metadataIsAvailable
MetadataWritableStream.close = metadataClose
MetadataWritableStream.newWriter = metadataNewWriter
MetadataWritableStream.writeAll = metadataWriteAll
MetadataWritableStream.writeBuffer = metadataWriteBuffer

MetadataReadWriteStream.contentType = metadataContentType
MetadataReadWriteStream.contentLength = metadataContentLength
MetadataReadWriteStream.isReadable = metadataIsReadable
MetadataReadWriteStream.isWritable = metadataIsWritable
MetadataReadWriteStream.isReplayable = metadataIsReplayable
MetadataReadWriteStream.isAvailable = metadataIsAvailable
MetadataReadWriteStream.close = metadataClose
MetadataReadWriteStream.hasBuffer = metadataHasBuffer
MetadataReadWriteStream.newReader = metadataNewReader
MetadataReadWriteStream.readAll = metadataReadAll
MetadataReadWriteStream.transferToBuffer = metadataTransferToBuffer
MetadataReadWriteStream.transferTo = metadataTransferTo
MetadataReadWriteStream.transferToFile = metadataTransferToFile
MetadataReadWriteStream.discard = metadataDiscard
MetadataReadWriteStream.newWriter = metadataNewWriter
MetadataReadWriteStream.writeAll = metadataWriteAll
MetadataReadWriteStream.writeBuffer = metadataWriteBuffer

--- Returns a lazy metadata view preserving the source's concrete interface.
withMetadata = function<T is Stream>(
    source: T, contentTypeValue?: string, contentLengthValue?: integer, replayableValue?: boolean
): T
    source = checkedStream(source, "io.withMetadata", 2)
    if contentTypeValue ~= nil and type(contentTypeValue) ~= "string" then
        error("tecs: io.withMetadata content type must be a string", 2)
    end
    if replayableValue ~= nil and type(replayableValue) ~= "boolean" then
        error("tecs: io.withMetadata replayability must be boolean", 2)
    end
    if contentLengthValue ~= nil then
        contentLengthValue = nonNegative(contentLengthValue, "io.withMetadata content length", 2)
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

--- Advances pending stream transfers within one shared bounded budget.
local function poll(): integer
    local settled = 0
    local stepCount = 0
    while #transfers > 0 and stepCount < POLL_STEPS do
        if pollCursor > #transfers then
            pollCursor = 1
        end
        local transfer <const> = transfers[pollCursor]
        settled = settled + safelyStep(transfer)
        stepCount = stepCount + 1
        if transfer.at ~= 0 then
            pollCursor = pollCursor + 1
        end
    end
    return settled
end

--- Returns the number of pending stream transfers.
local function pending(): integer
    return #transfers
end

local record stream
    type Reader = Reader
    type Writer = Writer
    type Stream = Stream
    type ReadableStream = ReadableStream
    type WritableStream = WritableStream
    type ReadWriteStream = ReadWriteStream

    newBuffer: function(initial?: integer | string): IOBuffer
    newEmptyStream: function(contentType?: string): ReadableStream
    newStringStream: function(text: string, contentType?: string): ReadableStream
    newBufferStream: function(buffer: IOBuffer, contentType?: string): ReadWriteStream
    newByteStream: function(pointer: loader.CValue, length: integer, contentType?: string): ReadableStream
    newFileStream: function(path: string, contentType?: string): ReadWriteStream
    newHandleStream: function(handle: FILE, length?: integer, contentType?: string): ReadWriteStream
    withMetadata: function<T is Stream>(
        source: T, contentType?: string, contentLength?: integer, isReplayable?: boolean
    ): T
    poll: function(): integer
    pending: function(): integer
    _check: function<T is Stream>(value: T, what: string, level: integer): T
    _borrowBytes: function(source: ReadableStream): BorrowedBytes
    _snapshot: function(source: Stream, what: string): {string: any}
    _restore: function(saved: {string: any}, what: string): Stream
end

return {
    newBuffer = buffer.new,
    newEmptyStream = newEmptyStream,
    newStringStream = newStringStream,
    newBufferStream = newBufferStream,
    newByteStream = newByteStream,
    newFileStream = newFileStream,
    newHandleStream = newHandleStream,
    withMetadata = withMetadata,
    poll = poll,
    pending = pending,
    _check = checkedStream,
    _borrowBytes = borrowedBytes,
    _snapshot = snapshotStream,
    _restore = restoreStream,
} as stream
