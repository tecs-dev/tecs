--[=[
Bytes, wherever they happen to be.

A body is a string, or a buffer, or a file, or a handle something else
opened. Spelling each of those as its own field is how an HTTP API ends up
with `body`, `bodyBytes`, `bodyLength`, `into` and a response whose `body`
is nil whenever its `path` is not. This is the one value all of them
become: it knows where its bytes are, it reports a length when it can know
one, and a response destination receives pieces without first becoming one
large Lua string.

    tecs.io.http.newClient():send({
        url = "https://example.com/upload",
        method = "PUT",
        body = tecs.io.http.newFileStream("save.bin"),
        into = tecs.io.http.newFileStream("reply.bin"),
    })

## One value, two directions

The same stream is a source in `Request.body` and a destination in
`Request.into`, and its kind decides which it can be: a file and a handle
are both, a string and a buffer are only a source. Position says which is
meant, so there is one set of constructors rather than two mirrored ones,
and asking a string to be a destination raises where it is written.

A `Response` carries one of these too, so the answer to "where is the body"
is one field whatever was asked for. `text()` is how it becomes a string,
which for a body that was never written anywhere costs nothing: the string
is already what is behind it.

## Request and response memory

An `into` file or handle is written as response pieces arrive. A request body
is different today: `send` reads the complete source into one Lua string before
starting the native transfer. A file or handle used as a request source is
therefore not a bounded-memory upload.

`length` reports the number of bytes when the source can know it: a string
knows, a buffer is given one, and a file is asked for its size. A handle does
not unless whoever opened it supplies the value. The HTTP client does not use
this field to choose chunked transfer or a `Content-Length`; the native
transport receives the materialized request string and sends its actual size.

## Files go through the storage seam and handles do not

`newFileStream` reads and writes through `tecs.io.files`, so a port that
replaced storage gets it. A response destination uses `openWrite`, while a
request source uses the whole-file `read` operation described above.
`newHandleStream` is the other case on purpose: a caller that opened its own
file is already outside the storage abstraction and has said so.
]=]

local loader <const> = require("tecs.ffi.loader")
local files <const> = require("tecs.io.files")

--- Bytes asked for in one directional read when nothing says otherwise.
local CHUNK <const> = 64 * 1024

local record datastream
    --- Stores bytes in memory, a borrowed buffer, a path, or a caller-owned
    --- handle for use as an HTTP request source or response destination.
    record DataStream
        --- Where the bytes are.
        enum Kind
            --- A Lua string, already in memory.
            "string"
            --- An FFI buffer and a length, borrowed for as long as the send takes.
            "bytes"
            --- A path, read and written through `tecs.io.files`.
            "file"
            --- A handle the caller opened and still owns.
            "handle"
        end

        --- Read-only. Reports which of the four storage kinds this is.
        kind: Kind
        --- Read-only. Reports the byte length, or nil when it is not known before
        --- the bytes are read.
        length: integer
        --- Read-only. Reports what the bytes are when their producer supplied a
        --- type. Requests send it as `Content-Type`; responses copy that header.
        contentType: string
        --- Read-only. Reports the path on a `"file"` and nil for every other kind.
        path: string
        --- Read-only. Reports the handle on a `"handle"` and nil for every other
        --- kind.
        handle: FILE

        --- The string, on a "string".
        _text: string
        --- The buffer, on a "bytes".
        _pointer: loader.CValue
        --- How far a read has got, on a "string" or a "bytes".
        _at: integer
        --- The reader or the writer a "file" is being streamed through, held only
        --- between the calls below that open and close it.
        _reader: files.Reader
        _writer: files.Writer

        --- Whether `value` is one of these.
        ---
        --- For a caller reached from Lua, where a field typed as a string or a
        --- stream was checked by nothing.
        ---
        --- @param value Anything at all, nil included, which answers false rather
        ---     than raising.
        --- @return Whether it was built by one of the four constructors here. A
        ---     table shaped like one but built elsewhere is false: the test is the
        ---     metatable, not the fields.
        is: function(value: any): boolean

        --- The whole thing as a string.
        ---
        --- Free for a "string", a read for a "file", and the rest of a "handle",
        --- which it consumes. Nil and a reason when the bytes cannot be had.
        ---
        --- @return Every byte, in memory at once, so this is the call that undoes
        ---     the point of streaming and is meant for bodies small enough not to
        ---     care. A "handle" is read from wherever it sits and is left at its
        ---     end, so a second call answers an empty string rather than the same
        ---     bytes. Nil on failure.
        --- @return The reason, when the first return is nil.
        text: function(self: DataStream): string, string

        --- Whether this can be written into. False for a "string" and a "bytes".
        ---
        --- @return Whether the kind can be a destination, which is a fact about the
        ---     kind rather than about whether the path is writable: a "file" whose
        ---     directory refuses it still answers true here and fails when the
        ---     transfer opens it.
        writable: function(self: DataStream): boolean

        ---------------------------------------------------------------------------
        -- The transfer's half
        ---------------------------------------------------------------------------

        --- Opens this as a source. Nil and a reason when it cannot be read.
        _beginRead: function(self: DataStream): boolean, string
        --- Up to `count` bytes, and an empty string once there are none left.
        _read: function(self: DataStream, count: integer): string, string
        --- Opens this as a destination.
        _beginWrite: function(self: DataStream): boolean, string
        --- Appends bytes to the destination.
        _write: function(self: DataStream, bytes: string): boolean, string
        --- Releases whatever was opened, in either direction. Answers false and a
        --- reason when a destination's last bytes did not land.
        _finish: function(self: DataStream): boolean, string
    end

    newStringStream: function(text: string, contentType?: string): DataStream
    newBytesStream: function(pointer: loader.CValue, length: integer, contentType?: string): DataStream
    newFileStream: function(path: string, contentType?: string): DataStream
    newHandleStream: function(handle: FILE, length?: integer, contentType?: string): DataStream
end

local type DataStream = datastream.DataStream
local type Kind = DataStream.Kind

local DataStreamMT <const>: metatable<DataStream> = {__index = datastream.DataStream}

local function newStream(kind: Kind, contentType: string): DataStream
    local self <const> = setmetatable({} as DataStream, DataStreamMT)
    self.kind = kind
    self.contentType = contentType
    return self
end

function datastream.newStringStream(text: string, contentType?: string): DataStream
    if type(text) ~= "string" then
        error("tecs: io.http.newStringStream needs a string", 2)
    end
    local self <const> = newStream("string", contentType)
    self._text = text
    self.length = #text
    return self
end

function datastream.newBytesStream(pointer: loader.CValue, length: integer, contentType?: string): DataStream
    if pointer == nil then
        error("tecs: io.http.newBytesStream needs a buffer", 2)
    end
    if length == nil or length < 0 then
        error("tecs: io.http.newBytesStream needs a length", 2)
    end
    local self <const> = newStream("bytes", contentType)
    self._pointer = pointer
    self.length = length
    return self
end

function datastream.newFileStream(path: string, contentType?: string): DataStream
    if type(path) ~= "string" or path == "" then
        error("tecs: io.http.newFileStream needs a path", 2)
    end
    local self <const> = newStream("file", contentType)
    self.path = path
    -- Asked for rather than assumed: a path that is not there yet is a
    -- destination, and a destination has no length until it has been written.
    local info <const> = files.info(path)
    if info ~= nil and info.kind == "file" then
        self.length = info.size
    end
    return self
end

function datastream.newHandleStream(handle: FILE, length?: integer, contentType?: string): DataStream
    if handle == nil then
        error("tecs: io.http.newHandleStream needs a handle", 2)
    end
    local self <const> = newStream("handle", contentType)
    self.handle = handle
    self.length = length
    return self
end

function datastream.DataStream.is(value: any): boolean
    return type(value) == "table" and getmetatable(value as DataStream) == DataStreamMT
end

function datastream.DataStream:writable(): boolean
    return self.kind == "file" or self.kind == "handle"
end

function datastream.DataStream:text(): string, string
    local kind <const> = self.kind
    if kind == "string" then
        return self._text
    end
    if kind == "bytes" then
        return loader.toBytes(self._pointer, self.length)
    end
    if kind == "file" then
        local bytes <const> = files.read(self.path)
        if bytes == nil then
            return nil, ("tecs: cannot read %s"):format(self.path)
        end
        return bytes
    end
    local rest <const>, failure = self.handle:read("*a")
    if rest == nil then
        return nil, failure or "tecs: cannot read the handle"
    end
    return rest
end

-------------------------------------------------------------------------------
-- Being read
-------------------------------------------------------------------------------

function datastream.DataStream:_beginRead(): boolean, string
    self._at = 0
    if self.kind ~= "file" then
        return true
    end
    local reader <const>, failure = files.openRead(self.path)
    if reader == nil then
        return false, ("tecs: cannot read %s: %s"):format(self.path, failure or "unknown")
    end
    self._reader = reader
    return true
end

function datastream.DataStream:_read(count: integer): string, string
    local wanted <const> = count ~= nil and count > 0 and count or CHUNK
    local kind <const> = self.kind

    if kind == "string" or kind == "bytes" then
        local length <const> = self.length
        local at <const> = self._at
        if at >= length then
            return ""
        end
        local taking <const> = math.min(wanted, length - at)
        self._at = at + taking
        if kind == "string" then
            return self._text:sub(at + 1, at + taking)
        end
        local from <const> = loader.bytePointer(self._pointer) + at
        return loader.toBytes(from as loader.CValue, taking)
    end

    if kind == "file" then
        if self._reader == nil then
            return ""
        end
        return self._reader:read(wanted)
    end

    -- A handle answers nil at the end of the file, which is an empty read here
    -- rather than a failure: there is nothing wrong with a body that ended.
    local piece <const>, failure = self.handle:read(wanted)
    if piece == nil then
        if failure ~= nil then
            return nil, failure
        end
        return ""
    end
    return piece
end

-------------------------------------------------------------------------------
-- Being written
-------------------------------------------------------------------------------

function datastream.DataStream:_beginWrite(): boolean, string
    self.length = 0
    if self.kind == "handle" then
        return true
    end
    if self.kind ~= "file" then
        return false, ("tecs: a %s stream cannot be written into"):format(self.kind)
    end
    local writer <const>, failure = files.openWrite(self.path)
    if writer == nil then
        return false, ("tecs: cannot write %s: %s"):format(self.path, failure or "unknown")
    end
    self._writer = writer
    return true
end

function datastream.DataStream:_write(bytes: string): boolean, string
    self.length = self.length + #bytes
    if self.kind == "handle" then
        local ok <const>, failure = self.handle:write(bytes)
        if ok == nil then
            return false, failure or "tecs: cannot write the handle"
        end
        return true
    end
    if self._writer == nil then
        return false, "tecs: this stream is not open for writing"
    end
    return self._writer:write(bytes)
end

function datastream.DataStream:_finish(): boolean, string
    local reader <const> = self._reader
    if reader ~= nil then
        self._reader = nil
        reader:close()
    end
    local writer <const> = self._writer
    if writer ~= nil then
        self._writer = nil
        return writer:close()
    end
    return true
end

return datastream
