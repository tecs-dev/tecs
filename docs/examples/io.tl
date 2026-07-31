-- Checked examples attached to the tecs.io reference. Each region's canonical
-- API name is also its attachment target; tlconfig.lua derives the Tealdoc
-- configuration from these markers.

-- #region tecs.io.newBuffer
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("save data")
print(bytes:length())
bytes:release()
-- #endregion tecs.io.newBuffer

-- #region tecs.io.Buffer.length
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("four")
print(bytes:length())
bytes:release()
-- #endregion tecs.io.Buffer.length

-- #region tecs.io.Buffer.capacity
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("data")
assert(bytes:capacity() >= bytes:length())
bytes:release()
-- #endregion tecs.io.Buffer.capacity

-- #region tecs.io.Buffer.clear
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("reusable")
local capacity <const> = bytes:capacity()
bytes:clear()
assert(bytes:length() == 0)
assert(bytes:capacity() == capacity)
bytes:release()
-- #endregion tecs.io.Buffer.clear

-- #region tecs.io.Buffer.ensureCapacity
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("data")
bytes:ensureCapacity(1024)
assert(bytes:capacity() >= 1024)
assert(bytes:length() == 4)
bytes:release()
-- #endregion tecs.io.Buffer.ensureCapacity

-- #region tecs.io.Buffer.resize
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("data")
bytes:resize(6)
assert(bytes:getString() == "data\0\0")
bytes:resize(2)
assert(bytes:getString() == "da")
bytes:release()
-- #endregion tecs.io.Buffer.resize

-- #region tecs.io.Buffer.getString
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("headerpayload")
print(bytes:getString(6, 7))
bytes:release()
-- #endregion tecs.io.Buffer.getString

-- #region tecs.io.Buffer.setString
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("abcdefgh")
bytes:setString("XY", 3)
assert(bytes:getString() == "abcXYfgh")
bytes:setString("!", 10)
assert(bytes:getString(8, 3) == "\0\0!")
bytes:release()
-- #endregion tecs.io.Buffer.setString

-- #region tecs.io.Buffer.getFFIPointer
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("native bytes")
local pointer <const> = bytes:getFFIPointer()
print(pointer)
bytes:release()
-- #endregion tecs.io.Buffer.getFFIPointer

-- #region tecs.io.Buffer.isReleased
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer()
assert(not bytes:isReleased())
bytes:release()
assert(bytes:isReleased())
-- #endregion tecs.io.Buffer.isReleased

-- #region tecs.io.Buffer.release
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("secret")
bytes:release()
bytes:release()
-- #endregion tecs.io.Buffer.release

-- #region tecs.io.newEmptyStream
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newEmptyStream("application/octet-stream")
print(source:readAll().value)
source:close()
-- #endregion tecs.io.newEmptyStream

-- #region tecs.io.newStringStream
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("hello", "text/plain")
print(source:readAll().value)
source:close()
-- #endregion tecs.io.newStringStream

-- #region tecs.io.newBufferStream
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("old")
local stream <const> = tecsIO.newBufferStream(bytes)
assert(stream:writeAll("new").value)
print(bytes:getString())
stream:close()
bytes:release()
-- #endregion tecs.io.newBufferStream

-- #region tecs.io.newByteStream
local ffi <const> = require("ffi")
local tecsIO <const> = require("tecs.io")
local bytes <const> = "borrowed bytes"
local pointer <const> = ffi.cast("const uint8_t *", bytes)
local source <const> = tecsIO.newByteStream(pointer as any, #bytes)
print(source:readAll().value)
source:close()
-- #endregion tecs.io.newByteStream

-- #region tecs.io.newFileStream
local tecsIO <const> = require("tecs.io")
local save <const> = tecsIO.newFileStream("save.bin", "application/octet-stream")
assert(save:writeAll("save data").value)
print(save:readAll().value)
save:close()
-- #endregion tecs.io.newFileStream

-- #region tecs.io.newHandleStream
local tecsIO <const> = require("tecs.io")
local handle <const> = assert(io.open("save.bin", "rb"))
local source <const> = tecsIO.newHandleStream(handle)
print(source:readAll().value)
source:close()
handle:close()
-- #endregion tecs.io.newHandleStream

-- #region tecs.io.withMetadata
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("{}")
local json <const> = tecsIO.withMetadata(source, "application/json")
print(json:contentType())
json:close()
-- #endregion tecs.io.withMetadata

-- #region tecs.io.Reader.read
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("abcdefgh")
local reader <const> = assert(source:newReader())
local chunk <const>, reason = reader:read(4)
assert(chunk, reason)
print(chunk)
reader:close()
source:close()
-- #endregion tecs.io.Reader.read

-- #region tecs.io.Reader.readInto
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("abcdefgh")
local reader <const> = assert(source:newReader())
local bytes <const> = tecsIO.newBuffer()
local count <const>, reason = reader:readInto(bytes, 4)
assert(count, reason)
print(bytes:getString())
reader:close()
source:close()
bytes:release()
-- #endregion tecs.io.Reader.readInto

-- #region tecs.io.Reader.close
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
local reader <const> = assert(source:newReader())
reader:close()
source:close()
-- #endregion tecs.io.Reader.close

-- #region tecs.io.Writer.write
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer()
local destination <const> = tecsIO.newBufferStream(bytes)
local writer <const> = assert(destination:newWriter())
local wrote <const>, reason = writer:write("data")
assert(wrote, reason)
assert(writer:close())
print(bytes:getString())
destination:close()
bytes:release()
-- #endregion tecs.io.Writer.write

-- #region tecs.io.Writer.writeFrom
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newBuffer("data")
local output <const> = tecsIO.newBuffer()
local destination <const> = tecsIO.newBufferStream(output)
local writer <const> = assert(destination:newWriter())
local count <const>, reason = writer:writeFrom(source)
assert(count, reason)
assert(writer:close())
destination:close()
source:release()
output:release()
-- #endregion tecs.io.Writer.writeFrom

-- #region tecs.io.Writer.flush
local tecsIO <const> = require("tecs.io")
local destination <const> = tecsIO.newFileStream("save.bin")
local writer <const> = assert(destination:newWriter())
assert(writer:write("checkpoint"))
assert(writer:flush())
assert(writer:close())
destination:close()
-- #endregion tecs.io.Writer.flush

-- #region tecs.io.Writer.close
local tecsIO <const> = require("tecs.io")
local destination <const> = tecsIO.newFileStream("save.bin")
local writer <const> = assert(destination:newWriter())
assert(writer:write("complete"))
assert(writer:close())
destination:close()
-- #endregion tecs.io.Writer.close

-- #region tecs.io.Stream.contentLength
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("four")
local length <const> = source:contentLength()
if length ~= nil then
    print(length)
end
source:close()
-- #endregion tecs.io.Stream.contentLength

-- #region tecs.io.Stream.contentType
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("{}", "application/json")
print(source:contentType())
source:close()
-- #endregion tecs.io.Stream.contentType

-- #region tecs.io.Stream.isReadable
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
print(source:isReadable())
source:close()
-- #endregion tecs.io.Stream.isReadable

-- #region tecs.io.Stream.isWritable
local tecsIO <const> = require("tecs.io")
local save <const> = tecsIO.newFileStream("save.bin")
print(save:isWritable())
save:close()
-- #endregion tecs.io.Stream.isWritable

-- #region tecs.io.Stream.isReplayable
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
print(source:isReplayable())
source:close()
-- #endregion tecs.io.Stream.isReplayable

-- #region tecs.io.Stream.isAvailable
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
print(source:isAvailable())
source:close()
print(source:isAvailable())
-- #endregion tecs.io.Stream.isAvailable

-- #region tecs.io.Stream.close
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
source:close()
-- #endregion tecs.io.Stream.close

-- #region tecs.io.ReadableStream.hasBuffer
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("data")
local source <const> = tecsIO.newBufferStream(bytes)
print(source:hasBuffer())
source:close()
bytes:release()
-- #endregion tecs.io.ReadableStream.hasBuffer

-- #region tecs.io.ReadableStream.newReader
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
local reader <const> = assert(source:newReader())
print(reader:read(4))
reader:close()
source:close()
-- #endregion tecs.io.ReadableStream.newReader

-- #region tecs.io.ReadableStream.readAll
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
local bytes <const> = source:readAll(1024).value
print(bytes)
source:close()
-- #endregion tecs.io.ReadableStream.readAll

-- #region tecs.io.ReadableStream.transferToBuffer
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newFileStream("save.bin")
local bytes <const> = source:transferToBuffer(1024 * 1024).value
print(bytes:length())
bytes:release()
source:close()
-- #endregion tecs.io.ReadableStream.transferToBuffer

-- #region tecs.io.ReadableStream.transferTo
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("data")
local output <const> = tecsIO.newBuffer()
local destination <const> = tecsIO.newBufferStream(output)
local count <const> = source:transferTo(destination).value
print(count, output:getString())
source:close()
destination:close()
output:release()
-- #endregion tecs.io.ReadableStream.transferTo

-- #region tecs.io.ReadableStream.transferToFile
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newStringStream("save data")
local count <const> = source:transferToFile("save.bin").value
print(count)
source:close()
-- #endregion tecs.io.ReadableStream.transferToFile

-- #region tecs.io.ReadableStream.discard
local tecsIO <const> = require("tecs.io")
local source <const> = tecsIO.newFileStream("download.tmp")
local count <const> = source:discard().value
print(count)
source:close()
-- #endregion tecs.io.ReadableStream.discard

-- #region tecs.io.WritableStream.newWriter
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer()
local destination <const> = tecsIO.newBufferStream(bytes)
local writer <const> = assert(destination:newWriter())
assert(writer:write("data"))
assert(writer:close())
destination:close()
bytes:release()
-- #endregion tecs.io.WritableStream.newWriter

-- #region tecs.io.WritableStream.writeAll
local tecsIO <const> = require("tecs.io")
local destination <const> = tecsIO.newFileStream("save.bin")
local count <const> = destination:writeAll("save data").value
print(count)
destination:close()
-- #endregion tecs.io.WritableStream.writeAll

-- #region tecs.io.WritableStream.writeBuffer
local tecsIO <const> = require("tecs.io")
local bytes <const> = tecsIO.newBuffer("save data")
local destination <const> = tecsIO.newFileStream("save.bin")
local count <const> = destination:writeBuffer(bytes).value
print(count)
destination:close()
bytes:release()
-- #endregion tecs.io.WritableStream.writeBuffer

-- #region tecs.io.poll
local tecsIO <const> = require("tecs.io")
while tecsIO.pending() > 0 do
    tecsIO.poll()
end
-- #endregion tecs.io.poll

-- #region tecs.io.listen
local tecsIO <const> = require("tecs.io")
local listener <const>, listenReason = tecsIO.listen(8080)
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

-- #region tecs.io.http.newURI
local http <const> = require("tecs.io.http")
local endpoint <const>, reason = http.newURI("https://user@example.com:8443/assets/list.json?page=2")
assert(endpoint, reason)
print(endpoint.scheme, endpoint.host, endpoint.port)
print(endpoint.path, endpoint.query)
-- #endregion tecs.io.http.newURI

-- #region tecs.io.http.newClient
local http <const> = require("tecs.io.http")
local endpoint <const> = assert(http.newURI("https://example.com/status"))
local client <const> = http.newClient({
    userAgent = "mygame/1.0",
    timeoutMs = 10000,
    maxBytes = 1024 * 1024,
})
local response <const> = client:send({url = endpoint}).value
print(response.status, response.url.host)
response.body:close()
client:close()
-- #endregion tecs.io.http.newClient
