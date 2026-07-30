--[=[
Bytes, wherever they happen to be.

A body is a string, or a buffer, or a file, or a handle something else
opened. Spelling each of those as its own field is how an HTTP API ends up
with `body`, `bodyBytes`, `bodyLength`, `into` and a response whose `body`
is nil whenever its `path` is not. This is the one value all of them
become: it knows where its bytes are, it reports a length when it can know
one, and it is read a piece at a time so a 500 MB download is never also a
500 MB string.

    tecs.net.http.newClient():send({
        url = "https://example.com/upload",
        method = "PUT",
        body = tecs.net.http.DataStream.ofFile("save.bin"),
        into = tecs.net.http.DataStream.ofFile("reply.bin"),
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

## Length is a claim, not a promise

`length` is the number of bytes when something knows it before they are
read: a string knows, a buffer was given one, a file is asked for its size.
A handle does not, unless whoever opened it says so. That is what decides
whether a request carries a `Content-Length` or is sent chunked, which is
why it is a field a caller can set rather than something inferred at the
last moment.

## Files go through the storage seam and handles do not

`ofFile` reads and writes through `tecs.filesystem`, so a port that
replaced storage gets it, and it streams wherever the backend supplies
`openRead` and `openWrite`. `ofHandle` is the other case on purpose: a
caller that opened its own file is already outside the storage abstraction
and has said so, and it streams everywhere because nothing between it and
the bytes has an opinion.
]=]

local loader <const> = require("tecs.ffi.loader")
local filesystem <const> = require("tecs.platform.filesystem")

--- Bytes asked for in one read when nothing says otherwise. Large enough that
--- a file of any size is a small number of turns, small enough that a body
--- being uploaded is not resident.
local CHUNK <const> = 64 * 1024

local record DataStream
    --- Where the bytes are.
    enum Kind
        --- A Lua string, already in memory.
        "string"
        --- An FFI buffer and a length, borrowed for as long as the send takes.
        "bytes"
        --- A path, read and written through `tecs.filesystem`.
        "file"
        --- A handle the caller opened and still owns.
        "handle"
    end

    --- Which of the four this is.
    kind: Kind
    --- Bytes long, or nil when nothing can know before they are read.
    length: integer
    --- What the bytes are, when whoever built this said. Sent as
    --- `Content-Type`, and set from one on a response.
    contentType: string
    --- The path, on a "file". Nil on every other kind.
    path: string
    --- The handle, on a "handle". Nil on every other kind.
    handle: FILE

    --- The string, on a "string".
    _text: string
    --- The buffer, on a "bytes".
    _pointer: loader.CValue
    --- How far a read has got, on a "string" or a "bytes".
    _at: integer
    --- The reader or the writer a "file" is being streamed through, held only
    --- between the calls below that open and close it.
    _reader: filesystem.Reader
    _writer: filesystem.Writer

    --- A stream over a string already in memory.
    ---
    --- @param text Held by reference, and Lua strings are immutable, so this is
    ---     the one kind whose bytes cannot change under a transfer. Anything
    ---     that is not a string raises.
    --- @param contentType Optional. Nil sends no `Content-Type` rather than
    ---     guessing one.
    --- @return A source only. `length` is known here, so a request carrying it
    ---     is sent with a `Content-Length`.
    ofString: function(text: string, contentType?: string): DataStream

    --- A stream over an FFI buffer, which the caller keeps alive for the send.
    ---
    --- @param pointer Borrowed, not copied and not pinned: nothing here keeps it
    ---     from being collected, so the caller holds a reference until the
    ---     transfer ends or the send reads freed memory. Nil raises.
    --- @param length Bytes readable from the pointer. Nil or negative raises.
    ---     Nothing checks it against the allocation, so an over-long length is
    ---     a read past the end.
    --- @param contentType Optional, as `ofString` takes it.
    --- @return A source only.
    ofBytes: function(pointer: loader.CValue, length: integer, contentType?: string): DataStream

    --- A stream over a path, read and written through `tecs.filesystem`.
    ---
    --- The file is not opened here. A source is opened when the transfer
    --- starts and a destination when the first byte arrives, so naming one
    --- costs nothing until it is used and a request that never leaves the
    --- ground leaves no handle behind.
    ---
    --- @param path Empty or not a string raises. A path that does not exist is
    ---     not an error here: that is what a destination looks like before it
    ---     is written.
    --- @param contentType Optional, as `ofString` takes it.
    --- @return A source and a destination both. `length` is filled in only when
    ---     the path already names a file, so a destination has none until it
    ---     has been written, and a file that changes size afterwards leaves it
    ---     stale.
    ofFile: function(path: string, contentType?: string): DataStream

    --- A stream over a handle the caller opened and still owns.
    ---
    --- Nothing here closes it: whoever opened it decides when it is done with,
    --- which is the whole difference between this and `ofFile`. Give `length`
    --- when it is known, or the request is sent chunked.
    ---
    --- A `tecs.net.http.plugin.Request` cannot snapshot this stream. The live
    --- handle has no stable ownership or position to restore, so both snapshot
    --- formats raise. Use `ofFile` for a request that must survive a save.
    ---
    --- @param handle An open file handle. Nil raises. Reading starts wherever it
    ---     is positioned rather than at the beginning.
    --- @param length Optional, and nothing verifies it. Left out, a request is
    ---     sent chunked rather than with a `Content-Length`.
    --- @param contentType Optional, as `ofString` takes it.
    --- @return A source and a destination both, streaming on every platform
    ---     because nothing between it and the bytes has an opinion.
    ofHandle: function(handle: FILE, length?: integer, contentType?: string): DataStream

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

local type Kind = DataStream.Kind

local DataStreamMT <const>: metatable<DataStream> = {__index = DataStream}

local function newStream(kind: Kind, contentType: string): DataStream
    local self <const> = setmetatable({} as DataStream, DataStreamMT)
    self.kind = kind
    self.contentType = contentType
    return self
end

function DataStream.ofString(text: string, contentType?: string): DataStream
    if type(text) ~= "string" then
        error("tecs: DataStream.ofString needs a string", 2)
    end
    local self <const> = newStream("string", contentType)
    self._text = text
    self.length = #text
    return self
end

function DataStream.ofBytes(pointer: loader.CValue, length: integer, contentType?: string): DataStream
    if pointer == nil then
        error("tecs: DataStream.ofBytes needs a buffer", 2)
    end
    if length == nil or length < 0 then
        error("tecs: DataStream.ofBytes needs a length", 2)
    end
    local self <const> = newStream("bytes", contentType)
    self._pointer = pointer
    self.length = length
    return self
end

function DataStream.ofFile(path: string, contentType?: string): DataStream
    if type(path) ~= "string" or path == "" then
        error("tecs: DataStream.ofFile needs a path", 2)
    end
    local self <const> = newStream("file", contentType)
    self.path = path
    -- Asked for rather than assumed: a path that is not there yet is a
    -- destination, and a destination has no length until it has been written.
    local info <const> = filesystem.info(path)
    if info ~= nil and info.kind == "file" then
        self.length = info.size
    end
    return self
end

function DataStream.ofHandle(handle: FILE, length?: integer, contentType?: string): DataStream
    if handle == nil then
        error("tecs: DataStream.ofHandle needs a handle", 2)
    end
    local self <const> = newStream("handle", contentType)
    self.handle = handle
    self.length = length
    return self
end

function DataStream.is(value: any): boolean
    return type(value) == "table" and getmetatable(value as DataStream) == DataStreamMT
end

function DataStream:writable(): boolean
    return self.kind == "file" or self.kind == "handle"
end

function DataStream:text(): string, string
    local kind <const> = self.kind
    if kind == "string" then
        return self._text
    end
    if kind == "bytes" then
        return loader.toBytes(self._pointer, self.length)
    end
    if kind == "file" then
        local bytes <const> = filesystem.read(self.path)
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

function DataStream:_beginRead(): boolean, string
    self._at = 0
    if self.kind ~= "file" then
        return true
    end
    local reader <const>, failure = filesystem.openRead(self.path)
    if reader == nil then
        return false, ("tecs: cannot read %s: %s"):format(self.path, failure or "unknown")
    end
    self._reader = reader
    return true
end

function DataStream:_read(count: integer): string, string
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

function DataStream:_beginWrite(): boolean, string
    self.length = 0
    if self.kind == "handle" then
        return true
    end
    if self.kind ~= "file" then
        return false, ("tecs: a %s stream cannot be written into"):format(self.kind)
    end
    local writer <const>, failure = filesystem.openWrite(self.path)
    if writer == nil then
        return false, ("tecs: cannot write %s: %s"):format(self.path, failure or "unknown")
    end
    self._writer = writer
    return true
end

function DataStream:_write(bytes: string): boolean, string
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

function DataStream:_finish(): boolean, string
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

return DataStream
