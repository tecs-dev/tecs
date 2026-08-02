-- Checked examples attached to the tecs.io reference. Each region's canonical
-- API name is its attachment target; Tealdoc discovers these source regions.

-- #region tecs.io.newBuffer
local bytes <const> = tecs.io.newBuffer("save data")
print(bytes:length())

bytes:close()
-- #endregion tecs.io.newBuffer

-- #region tecs.io.newStringReader
local reader <const> = tecs.io.newStringReader("snapshot bytes")

assert(reader:read(1024) == "snapshot bytes")

reader:close()
-- #endregion tecs.io.newStringReader

-- #region tecs.io.newByteReader
local ffi <const> = require("ffi")

local bytes <const> = "borrowed bytes"
local pointer <const> = ffi.cast("const uint8_t *", bytes)
local reader <const> = tecs.io.newByteReader(pointer as any, #bytes)

assert(reader:read(1024) == bytes)

reader:close()
-- #endregion tecs.io.newByteReader

-- #region tecs.io.Buffer.length
local bytes <const> = tecs.io.newBuffer("four")
print(bytes:length())

bytes:close()
-- #endregion tecs.io.Buffer.length

-- #region tecs.io.Buffer.capacity
local bytes <const> = tecs.io.newBuffer("data")

assert(bytes:capacity() >= bytes:length())

bytes:close()
-- #endregion tecs.io.Buffer.capacity

-- #region tecs.io.Buffer.clear
local bytes <const> = tecs.io.newBuffer("reusable")
local capacity <const> = bytes:capacity()
bytes:clear()

assert(bytes:length() == 0)
assert(bytes:capacity() == capacity)

bytes:close()
-- #endregion tecs.io.Buffer.clear

-- #region tecs.io.Buffer.ensureCapacity
local bytes <const> = tecs.io.newBuffer("data")
bytes:ensureCapacity(1024)

assert(bytes:capacity() >= 1024)
assert(bytes:length() == 4)

bytes:close()
-- #endregion tecs.io.Buffer.ensureCapacity

-- #region tecs.io.Buffer.resize
local bytes <const> = tecs.io.newBuffer("data")
bytes:resize(6)

assert(bytes:getString() == "data\0\0")
bytes:resize(2)

assert(bytes:getString() == "da")

bytes:close()
-- #endregion tecs.io.Buffer.resize

-- #region tecs.io.Buffer.getString
local bytes <const> = tecs.io.newBuffer("headerpayload")
print(bytes:getString(6, 7))

bytes:close()
-- #endregion tecs.io.Buffer.getString

-- #region tecs.io.Buffer.setString
local bytes <const> = tecs.io.newBuffer("abcdefgh")
bytes:setString("XY", 3)

assert(bytes:getString() == "abcXYfgh")
bytes:setString("!", 10)

assert(bytes:getString(8, 3) == "\0\0!")

bytes:close()
-- #endregion tecs.io.Buffer.setString

-- #region tecs.io.Buffer.getFFIPointer
local bytes <const> = tecs.io.newBuffer("native bytes")
local pointer <const> = bytes:getFFIPointer()
print(pointer)

bytes:close()
-- #endregion tecs.io.Buffer.getFFIPointer

-- #region tecs.io.Buffer.isReleased
local bytes <const> = tecs.io.newBuffer()

assert(not bytes:isReleased())

bytes:close()

assert(bytes:isReleased())
-- #endregion tecs.io.Buffer.isReleased

-- #region tecs.io.Buffer.newReader
local bytes <const> = tecs.io.newBuffer("snapshot")
local reader <const> = bytes:newReader()

bytes:close()

assert(reader:read(1024) == "snapshot")

reader:close()
-- #endregion tecs.io.Buffer.newReader

-- #region tecs.io.Buffer.newWriter
local bytes <const> = tecs.io.newBuffer("old")
local writer <const> = bytes:newWriter()

assert(writer:write("new"))
assert(writer:close())
assert(bytes:getString() == "new")

bytes:close()
-- #endregion tecs.io.Buffer.newWriter

-- #region tecs.io.ByteView.newReader
local bytes <const> = tecs.io.newBuffer("headerpayload")
local payload <const> = bytes:view(6)
local reader <const> = payload:newReader()

payload:close()
bytes:close()

assert(reader:read(1024) == "payload")

reader:close()
-- #endregion tecs.io.ByteView.newReader

-- #region tecs.io.ByteView.newStream
local bytes <const> = tecs.io.newBuffer("headerpayload")
local payload <const> = bytes:view(6)
local source <const> = payload:newStream("application/octet-stream")

payload:close()
bytes:close()

assert(source:readAll() == "payload")

source:close()
-- #endregion tecs.io.ByteView.newStream

-- #region tecs.io.newEmptyStream
local source <const> = tecs.io.newEmptyStream("application/octet-stream")
print(source:readAll())

source:close()
-- #endregion tecs.io.newEmptyStream

-- #region tecs.io.newStringStream
local source <const> = tecs.io.newStringStream("hello", "text/plain")
print(source:readAll())

source:close()
-- #endregion tecs.io.newStringStream

-- #region tecs.io.Buffer.newStream
local bytes <const> = tecs.io.newBuffer("old")
local stream <const> = bytes:newStream()

assert(stream:writeAll("new"))
print(bytes:getString())

stream:close()
bytes:close()
-- #endregion tecs.io.Buffer.newStream

-- #region tecs.io.newByteStream
local ffi <const> = require("ffi")

local bytes <const> = "borrowed bytes"
local pointer <const> = ffi.cast("const uint8_t *", bytes)
local source <const> = tecs.io.newByteStream(pointer as any, #bytes)
print(source:readAll())

source:close()
-- #endregion tecs.io.newByteStream

-- #region tecs.io.newFileStream
local path <const> = tecs.io.Path.new("save.bin")
local save <const> = tecs.io.newFileStream(path, "application/octet-stream")

assert(save:writeAll("save data"))
print(save:readAll())

save:close()
-- #endregion tecs.io.newFileStream

-- #region tecs.io.newHandleStream
local handle <const> = assert(io.open("save.bin", "rb"))
local source <const> = tecs.io.newHandleStream(handle)
print(source:readAll())

source:close()
handle:close()
-- #endregion tecs.io.newHandleStream

-- #region tecs.io.newInflateReader
tecs.scoped(function(scope: tecs.Scope)
    local compressed <const> = scope:own(tecs.io.newBuffer())
    local restored <const> = scope:own(tecs.io.newBuffer())
    local compressor <const> = scope:own(tecs.io.newDeflateWriter(compressed:newWriter()))

    assert(compressor:write("snapshot bytes"))
    assert(compressor:close())

    local reader <const> = scope:own(tecs.io.newInflateReader(compressed:newReader()))
    local sink <const> = scope:own(restored:newWriter())
    local count <const>, reason = tecs.io.transfer(reader, sink)

    assert(count, reason)
    assert(restored:getString() == "snapshot bytes")
end)
-- #endregion tecs.io.newInflateReader

-- #region tecs.io.newDeflateWriter
tecs.scoped(function(scope: tecs.Scope)
    local compressed <const> = scope:own(tecs.io.newBuffer())
    local writer <const> = scope:own(tecs.io.newDeflateWriter(compressed:newWriter()))

    assert(writer:write("snapshot "))
    assert(writer:write("bytes"))
    assert(writer:close())
    assert(compressed:length() > 0)
end)
-- #endregion tecs.io.newDeflateWriter

-- #region tecs.io.newBase64DecodeReader
tecs.scoped(function(scope: tecs.Scope)
    local reader <const> = scope:own(tecs.io.newBase64DecodeReader(tecs.io.newStringReader("c25hcHNob3QgYnl0ZXM=")))
    local decoded <const>, reason = reader:read(1024)

    assert(decoded, reason)
    assert(decoded == "snapshot bytes")
end)
-- #endregion tecs.io.newBase64DecodeReader

-- #region tecs.io.newBase64EncodeWriter
tecs.scoped(function(scope: tecs.Scope)
    local encoded <const> = scope:own(tecs.io.newBuffer())
    local writer <const> = scope:own(tecs.io.newBase64EncodeWriter(encoded:newWriter()))

    assert(writer:write("snapshot bytes"))
    assert(writer:close())
    assert(encoded:getString() == "c25hcHNob3QgYnl0ZXM=")
end)
-- #endregion tecs.io.newBase64EncodeWriter

-- #region tecs.io.newHexDecodeReader
tecs.scoped(function(scope: tecs.Scope)
    local reader <const> = scope:own(tecs.io.newHexDecodeReader(tecs.io.newStringReader("73617665")))
    local decoded <const>, reason = reader:read(1024)

    assert(decoded, reason)
    assert(decoded == "save")
end)
-- #endregion tecs.io.newHexDecodeReader

-- #region tecs.io.newHexEncodeWriter
tecs.scoped(function(scope: tecs.Scope)
    local encoded <const> = scope:own(tecs.io.newBuffer())
    local writer <const> = scope:own(tecs.io.newHexEncodeWriter(encoded:newWriter()))

    assert(writer:write("save"))
    assert(writer:close())
    assert(encoded:getString() == "73617665")
end)
-- #endregion tecs.io.newHexEncodeWriter

-- #region tecs.io.newTranscodeReader
tecs.scoped(function(scope: tecs.Scope)
    local reader <const> = scope:own(
        tecs.io.newTranscodeReader(tecs.io.newStringReader("A\0\233\0"), "UTF-16LE", "UTF-8")
    )
    local utf8 <const>, reason = reader:read(1024)

    assert(utf8, reason)
    assert(utf8 == "A\195\169")
end)
-- #endregion tecs.io.newTranscodeReader

-- #region tecs.io.newTranscodeWriter
tecs.scoped(function(scope: tecs.Scope)
    local utf16 <const> = scope:own(tecs.io.newBuffer())
    local writer <const> = scope:own(tecs.io.newTranscodeWriter(utf16:newWriter(), "UTF-8", "UTF-16LE"))

    assert(writer:write("A\195"))
    assert(writer:write("\169"))
    assert(writer:close())
    assert(utf16:getString() == "A\0\233\0")
end)
-- #endregion tecs.io.newTranscodeWriter

-- #region tecs.io.Stream.withMetadata
local source <const> = tecs.io.newStringStream("{}")
local json <const> = source:withMetadata("application/json")
print(json:contentType())

json:close()
-- #endregion tecs.io.Stream.withMetadata

-- #region tecs.io.Reader.read
local source <const> = tecs.io.newStringStream("abcdefgh")
local reader <const> = assert(source:newReader())
local chunk <const>, reason = reader:read(4)

assert(chunk, reason)
print(chunk)

reader:close()
source:close()
-- #endregion tecs.io.Reader.read

-- #region tecs.io.Reader.readInto
local source <const> = tecs.io.newStringStream("abcdefgh")
local reader <const> = assert(source:newReader())
local bytes <const> = tecs.io.newBuffer("prefix:")
local count <const>, reason = reader:readInto(bytes, bytes:length(), 4)

assert(count, reason)
print(bytes:getString())

reader:close()
source:close()
bytes:close()
-- #endregion tecs.io.Reader.readInto

-- #region tecs.io.transfer
local source <const> = assert(tecs.io.files.open("save.bin"))
local destination <const> = assert(tecs.io.files.open("save.copy", "w"))
local count <const>, reason = tecs.io.transfer(source, destination)

assert(count, reason)

source:close()
destination:close()
-- #endregion tecs.io.transfer

-- #region tecs.io.Writer.write
local bytes <const> = tecs.io.newBuffer()
local writer <const> = bytes:newWriter()
local wrote <const>, reason = writer:write("data")

assert(wrote, reason)
assert(writer:close())
print(bytes:getString())

bytes:close()
-- #endregion tecs.io.Writer.write

-- #region tecs.io.Writer.writeFrom
local source <const> = tecs.io.newBuffer("header:data")
local destination <const> = tecs.io.newBuffer()
local writer <const> = destination:newWriter()
local count <const>, reason = writer:writeFrom(source, 7, 4)

assert(count, reason)
assert(writer:close())
print(destination:getString())

source:close()
destination:close()
-- #endregion tecs.io.Writer.writeFrom

-- #region tecs.io.Writer.writeView
local source <const> = tecs.io.newBuffer("header:data")
local view <const> = source:view(7, 4)
local destination <const> = tecs.io.newBuffer()
local writer <const> = destination:newWriter()
local count <const>, reason = writer:writeView(view)

assert(count, reason)
assert(writer:close())
print(destination:getString())

view:close()
source:close()
destination:close()
-- #endregion tecs.io.Writer.writeView

-- #region tecs.io.Writer.flush
local destination <const> = tecs.io.newFileStream("save.bin")
local writer <const> = assert(destination:newWriter())

assert(writer:write("checkpoint"))
assert(writer:flush())
assert(writer:close())
destination:close()
-- #endregion tecs.io.Writer.flush

-- #region tecs.Closeable.close
local destination <const> = tecs.io.newFileStream("save.bin")
local writer <const> = assert(destination:newWriter())

assert(writer:write("complete"))
assert(writer:close())
destination:close()
-- #endregion tecs.Closeable.close

-- #region tecs.io.Stream.contentLength
local source <const> = tecs.io.newStringStream("four")
local length <const> = source:contentLength()
if length ~= nil then
    print(length)
end

source:close()
-- #endregion tecs.io.Stream.contentLength

-- #region tecs.io.Stream.contentType
local source <const> = tecs.io.newStringStream("{}", "application/json")
print(source:contentType())

source:close()
-- #endregion tecs.io.Stream.contentType

-- #region tecs.io.Stream.isReadable
local source <const> = tecs.io.newStringStream("data")
print(source:isReadable())

source:close()
-- #endregion tecs.io.Stream.isReadable

-- #region tecs.io.Stream.isWritable
local save <const> = tecs.io.newFileStream("save.bin")
print(save:isWritable())

save:close()
-- #endregion tecs.io.Stream.isWritable

-- #region tecs.io.Stream.isReplayable
local source <const> = tecs.io.newStringStream("data")
print(source:isReplayable())

source:close()
-- #endregion tecs.io.Stream.isReplayable

-- #region tecs.io.ReadableStream.newReader
local source <const> = tecs.io.newStringStream("data")
local reader <const> = assert(source:newReader())
print(reader:read(4))

reader:close()
source:close()
-- #endregion tecs.io.ReadableStream.newReader

-- #region tecs.io.ReadableStream.readAll
local source <const> = tecs.io.newStringStream("data")
local bytes <const> = source:readAll(1024)
print(bytes)

source:close()
-- #endregion tecs.io.ReadableStream.readAll

-- #region tecs.io.ReadableStream.transferToBuffer
local source <const> = tecs.io.newFileStream("save.bin")
local bytes <const> = source:transferToBuffer(1024 * 1024)
print(bytes:length())

bytes:close()
source:close()
-- #endregion tecs.io.ReadableStream.transferToBuffer

-- #region tecs.io.ReadableStream.transferTo
local source <const> = tecs.io.newStringStream("data")
local output <const> = tecs.io.newBuffer()
local destination <const> = output:newStream()
local count <const> = source:transferTo(destination)
print(count, output:getString())

source:close()
destination:close()
output:close()
-- #endregion tecs.io.ReadableStream.transferTo

-- #region tecs.io.ReadableStream.transferToFile
local source <const> = tecs.io.newStringStream("save data")
local count <const> = source:transferToFile("save.bin")
print(count)

source:close()
-- #endregion tecs.io.ReadableStream.transferToFile

-- #region tecs.io.ReadableStream.discard
local source <const> = tecs.io.newFileStream("download.tmp")
local count <const> = source:discard()
print(count)

source:close()
-- #endregion tecs.io.ReadableStream.discard

-- #region tecs.io.WritableStream.newWriter
local bytes <const> = tecs.io.newBuffer()
local destination <const> = bytes:newStream()
local writer <const> = assert(destination:newWriter())

assert(writer:write("data"))
assert(writer:close())
destination:close()
bytes:close()
-- #endregion tecs.io.WritableStream.newWriter

-- #region tecs.io.WritableStream.writeAll
local destination <const> = tecs.io.newFileStream("save.bin")
local count <const> = destination:writeAll("save data")
print(count)

destination:close()
-- #endregion tecs.io.WritableStream.writeAll

-- #region tecs.io.WritableStream.writeBuffer
local bytes <const> = tecs.io.newBuffer("save data")
local destination <const> = tecs.io.newFileStream("save.bin")
local count <const> = destination:writeBuffer(bytes)
print(count)

destination:close()
bytes:close()
-- #endregion tecs.io.WritableStream.writeBuffer

-- #region tecs.io.poll
while tecs.io.pending() > 0 do
    tecs.io.poll()
end
-- #endregion tecs.io.poll

-- #region tecs.io.listen
local listener <const>, listenReason = tecs.io.listen(8080)

assert(listener, listenReason)
local client: tecs.io.TCPSocket = nil
local request = ""

-- Call this once per frame. It serves one HTTP/1.1 request at a time; a real
-- server keeps one request buffer per connected socket.
local function pollWebServer()
    if client == nil then
        client = listener:accept()
        return
    end

    local chunk <const>, readReason = client:read()
    if readReason ~= nil then
        client:close()
        client = nil
        request = ""
        return
    end
    if chunk == nil then
        return
    end
    request = request .. chunk
    if request:find("\r\n\r\n", 1, true) == nil then
        return
    end

    local body <const> = "Hello from Tecs\n"
    local response <const> = (
        "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n" .. "Content-Type: text/plain\r\nConnection: close\r\n\r\n%s"
    ):format(#body, body)
    local sent <const>, sendReason = client:write(response)
    assert(sent, sendReason)
    assert(client:drain(1000))
    client:close()
    client = nil
    request = ""
end

pollWebServer()

listener:close()
-- #endregion tecs.io.listen

-- #region tecs.io.http.newClient
local http <const> = tecs.io.http
local endpoint, reason = tecs.io.URI.new("https://example.com/status")
if endpoint == nil then
    error(reason)
end
local client <const> = http.newClient({
    userAgent = "mygame/1.0",
    timeoutMs = 10000,
    maxBytes = 1024 * 1024,
})
local response <const> = client:send({url = endpoint})
print(response.status, response.url:host())
response.body:close()
client:close()
-- #endregion tecs.io.http.newClient

-- #region tecs.io.watcher.poll
local watcher <const> = tecs.io.watcher

local function runHeadlessWatcher(keepRunning: function(): boolean)
    watcher.install({intervalSeconds = 0.25})
    while keepRunning() do
        watcher.poll()
    end
    watcher.uninstall()
end
-- #endregion tecs.io.watcher.poll
