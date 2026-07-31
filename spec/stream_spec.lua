-- Owned buffers, directional stream descriptors, and cooperative transfers.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local tecs = require("tecs")
local adapter = require("tecs.platform.adapter")

local ioModule = tecs.io
local paths = {}
local min = math.min

local function temporary()
    local path = os.tmpname()
    paths[#paths + 1] = path
    return path
end

after_each(function()
    for _, path in ipairs(paths) do
        os.remove(path)
    end
    paths = {}
end)

describe("tecs.io buffers", function()
    it("constructs buffers without exposing implementation methods", function()
        local buffer = ioModule.newBuffer()
        assert.is_nil(buffer.prepareWrite)
        assert.is_nil(buffer.commitWrite)
        assert.is_nil(buffer.release)
        buffer:close()
    end)

    it("reuses capacity and invalidates borrowed pointers only on growth", function()
        local buffer = ioModule.newBuffer("abcd")
        local first = buffer:getFFIPointer()
        local address = tonumber(ffi.cast("uintptr_t", first))

        buffer:clear()
        buffer:ensureCapacity(4)
        buffer:resize(4)
        assert.are.equal(address, tonumber(ffi.cast("uintptr_t", buffer:getFFIPointer())))

        buffer:ensureCapacity(128)
        assert.is_true(buffer:capacity() >= 128)
        assert.are_not.equal(address, tonumber(ffi.cast("uintptr_t", buffer:getFFIPointer())))

        buffer:close()
        assert.is_true(buffer:isReleased())
        assert.has_error(function()
            buffer:getFFIPointer()
        end, "tecs: io.Buffer is released")
    end)

    it("zero-fills gaps and newly exposed bytes", function()
        local buffer = ioModule.newBuffer("secret")
        buffer:resize(2)
        buffer:resize(6)
        assert.are.equal("se\0\0\0\0", buffer:getString())

        buffer:setString("x", 8)
        assert.are.equal("se\0\0\0\0\0\0x", buffer:getString())
    end)

    it("checks ranges, integer arguments, and close", function()
        local buffer = ioModule.newBuffer("abcd")
        assert.has_error(function()
            buffer:getString(5)
        end)
        assert.has_error(function()
            buffer:getString(2, 3)
        end)
        assert.has_error(function()
            buffer:ensureCapacity(-1)
        end)
        assert.has_error(function()
            buffer:resize(1.5)
        end)
        buffer:close()
        buffer:close()
        assert.has_error(function()
            buffer:length()
        end, "tecs: io.Buffer is released")
    end)

    it("retains zero-copy views while the source detaches on write", function()
        local buffer = ioModule.newBuffer("abcdef")
        local view = buffer:view(1, 3)
        assert.is_nil(view.release)
        local address = tonumber(ffi.cast("uintptr_t", view:getFFIPointer()))

        buffer:setString("XYZ", 1)
        assert.are.equal("bcd", view:getString())
        assert.are.equal("aXYZef", buffer:getString())
        assert.are.equal(address, tonumber(ffi.cast("uintptr_t", view:getFFIPointer())))

        buffer:close()
        assert.are.equal("bcd", view:getString())
        view:close()
    end)

    it("commits native writes through an exclusive range", function()
        local buffer = ioModule.newBuffer()
        local range = buffer:reserveRange(2, 4)
        assert.is_nil(range.release)
        ffi.copy(range:getFFIPointer(), "ok", 2)
        range:commit(2)
        assert.are.equal("\0\0ok", buffer:getString())
        buffer:close()
    end)
end)

describe("tecs.io stream endpoints", function()
    it("keeps independent reader cursors and reports partial reads", function()
        local stream = ioModule.newStringStream("abcd", "application/octet-stream")
        assert.is_nil(stream.hasKnownLength)
        local first = assert(stream:newReader())
        local second = assert(stream:newReader())
        local buffer = ioModule.newBuffer()

        assert.are.equal("ab", first:read(2))
        assert.are.equal("abcd", second:read(10))
        assert.are.equal(2, first:readInto(buffer, 10))
        assert.are.equal("cd", buffer:getString())
        assert.are.equal(0, first:readInto(buffer, 10))

        first:close()
        second:close()
        buffer:close()
    end)

    it("rejects reading a retained buffer into itself", function()
        local buffer = ioModule.newBuffer("same")
        local reader = assert(ioModule.newBufferStream(buffer):newReader())
        local count, reason = reader:readInto(buffer, 4)
        assert.is_nil(count)
        assert.are.equal("cannot read a buffer into itself", reason)
        reader:close()
        buffer:close()
    end)

    it("does not prepare a destination after its source is released", function()
        local source = ioModule.newBuffer("gone")
        local reader = assert(ioModule.newBufferStream(source):newReader())
        local destination = ioModule.newBuffer("kept")
        source:close()

        local count, reason = reader:readInto(destination, 4, 20)
        assert.is_nil(count)
        assert.are.equal("stream buffer is released", reason)
        assert.are.equal("kept", destination:getString())
        assert.are.equal(4, destination:capacity())
        reader:close()
        destination:close()
    end)

    it("commits only bytes read into a structural buffer", function()
        local path = temporary()
        assert.is_true(tecs.io.files.write(path, "x"))
        local owned = ioModule.newBuffer("ab")
        local proxy = {
            length = function()
                return owned:length()
            end,
            capacity = function()
                return owned:capacity()
            end,
            clear = function()
                owned:clear()
            end,
            ensureCapacity = function(_, minimum)
                owned:ensureCapacity(minimum)
            end,
            resize = function(_, length)
                owned:resize(length)
            end,
            getString = function(_, offset, count)
                return owned:getString(offset, count)
            end,
            setString = function(_, bytes, offset)
                owned:setString(bytes, offset)
            end,
            getFFIPointer = function()
                return owned:getFFIPointer()
            end,
            isReleased = function()
                return owned:isReleased()
            end,
            close = function()
                owned:close()
            end,
        }
        local reader = assert(tecs.io.files.openRead(path))
        assert.are.equal(1, reader:readInto(proxy, 10, 4))
        assert.are.equal(5, proxy:length())
        assert.are.equal("ab\0\0x", proxy:getString())
        assert.are.equal(0, reader:readInto(proxy, 10, 9))
        assert.are.equal(5, proxy:length())
        assert.are.equal("ab\0\0x", proxy:getString())
        reader:close()
        proxy:close()
    end)

    it("rejects aliased and closed memory writers", function()
        local buffer = ioModule.newBuffer("same")
        local writer = assert(ioModule.newBufferStream(buffer):newWriter())
        local wrote, aliasReason = writer:writeFrom(buffer)
        assert.is_nil(wrote)
        assert.are.equal("cannot write a buffer into itself", aliasReason)

        buffer:close()
        local ok, writeReason = writer:write("x")
        assert.is_false(ok)
        assert.are.equal("stream buffer is released", writeReason)
        assert.is_false(writer:flush())
        local closed, closeReason = writer:close()
        assert.is_false(closed)
        assert.are.equal("stream buffer is released", closeReason)
        assert.is_true(writer:close())
    end)

    it("rejects a BufferStream writing its own backing", function()
        local buffer = ioModule.newBuffer("same")
        local wrote = ioModule.newBufferStream(buffer):writeBuffer(buffer)
        assert.are.equal("failed", wrote.status)
        assert.are.equal("cannot write a buffer into itself", wrote.error)
        assert.are.equal("same", buffer:getString())
        buffer:close()
    end)

    it("distinguishes zero-copy buffers and source-only empty streams", function()
        local buffer = ioModule.newBuffer("owned")
        local buffered = ioModule.newBufferStream(buffer)
        assert.is_true(buffered:hasBuffer())
        assert.is_true(rawequal(buffer, buffered:transferToBuffer().value))

        local empty = ioModule.newEmptyStream()
        assert.is_false(empty:hasBuffer())
        assert.is_false(empty:isWritable())
        assert.is_nil(rawget(empty, "newWriter"))
        assert.are.equal("", empty:readAll().value)
        buffer:close()
    end)

    it("makes borrowed handles one-shot without closing them", function()
        local path = temporary()
        local handle = assert(io.open(path, "w+b"))
        assert(handle:write("handle"))
        assert(handle:seek("set", 0))

        local stream = ioModule.newHandleStream(handle, 6)
        assert.is_true(stream:isAvailable())
        local reader = assert(stream:newReader())
        assert.is_false(stream:isAvailable())
        assert.is_nil(stream:newReader())
        assert.are.equal("handle", reader:read(20))
        reader:close()

        assert(handle:seek("set", 0))
        assert.are.equal("handle", handle:read("*a"))
        handle:close()
    end)

    it("keeps metadata lazy and preserves false replayability", function()
        local source = ioModule.newStringStream("four", "text/plain")
        assert.is_true(rawequal(source, ioModule.withMetadata(source)))

        local view = ioModule.withMetadata(source, "custom/type", 9, false)
        assert.are.equal("custom/type", view:contentType())
        assert.are.equal(9, view:contentLength())
        assert.is_false(view:isReplayable())
        assert.is_function(view.newReader)
        assert.is_nil(view.newWriter)

        view:close()
        assert.is_false(source:isAvailable())
        assert.has_error(function()
            ioModule.withMetadata({}, nil, 1)
        end)
    end)

    it("delegates metadata views through the original stream identity", function()
        local source
        source = {
            contentLength = function(self)
                assert.is_true(rawequal(source, self))
                return 4
            end,
            contentType = function(self)
                assert.is_true(rawequal(source, self))
                return "text/plain"
            end,
            isReadable = function(self)
                assert.is_true(rawequal(source, self))
                return false
            end,
            isWritable = function(self)
                assert.is_true(rawequal(source, self))
                return false
            end,
            isReplayable = function(self)
                assert.is_true(rawequal(source, self))
                return true
            end,
            isAvailable = function(self)
                assert.is_true(rawequal(source, self))
                return true
            end,
            close = function(self)
                assert.is_true(rawequal(source, self))
            end,
        }
        local view = ioModule.withMetadata(source, "custom/type")
        assert.is_nil(view.hasKnownLength)
        assert.are.equal("custom/type", view:contentType())
        assert.are.equal(4, view:contentLength())
        assert.is_true(view:isAvailable())
        assert.is_nil(view.newReader)
        assert.is_nil(view.newWriter)
        view:close()
    end)

    it("rejects streams that claim unsupported directions", function()
        local source = {
            contentLength = function()
                return nil
            end,
            contentType = function()
                return nil
            end,
            isReadable = function()
                return true
            end,
            isWritable = function()
                return false
            end,
            isReplayable = function()
                return false
            end,
            isAvailable = function()
                return true
            end,
            close = function() end,
        }
        assert.has_error(function()
            ioModule.withMetadata(source, "custom/type")
        end, "tecs: io.withMetadata claims ReadableStream without its methods")
    end)

    it("rejects transfers between metadata views of one shared buffer", function()
        local buffer = ioModule.newBuffer("shared")
        local source = ioModule.withMetadata(ioModule.newBufferStream(buffer), "application/source")
        local destination = ioModule.withMetadata(ioModule.newBufferStream(buffer), "application/destination")
        local copied = source:transferTo(destination)

        assert.are.equal("failed", copied.status)
        assert.are.equal("cannot transfer between streams sharing one backing", copied.error)
        assert.are.equal("shared", buffer:getString())
        buffer:close()
    end)

    it("rejects exact file paths and borrowed handles sharing one backing", function()
        local path = temporary()
        assert.is_true(tecs.io.files.write(path, "kept"))
        local fileCopy = ioModule.newFileStream(path):transferTo(ioModule.newFileStream(path))
        assert.are.equal("failed", fileCopy.status)
        assert.are.equal("cannot transfer between streams sharing one backing", fileCopy.error)
        assert.are.equal("kept", tecs.io.files.read(path))

        local handle = assert(io.open(path, "r+b"))
        local handleCopy = ioModule.newHandleStream(handle):transferTo(ioModule.newHandleStream(handle))
        assert.are.equal("failed", handleCopy.status)
        assert.are.equal("cannot transfer between streams sharing one backing", handleCopy.error)
        assert.are.equal(0, assert(handle:seek()))
        handle:close()
    end)
end)

describe("tecs.io transfers", function()
    it("persists fallback writer flushes and accepts later writes", function()
        local backend = adapter.storage()
        local originalOpenWrite = backend.openWrite
        local originalWrite = backend.write
        local writes = {}
        backend.openWrite = nil
        backend.write = function(_, bytes)
            writes[#writes + 1] = bytes
            return true
        end

        local ran, reason = pcall(function()
            local writer = assert(tecs.io.files.openWrite("/virtual/flush"))
            assert.is_true(writer:write("a"))
            assert.is_true(writer:flush())
            assert.is_true(writer:write("b"))
            assert.is_true(writer:flush())
            assert.is_true(writer:close())
        end)
        backend.openWrite = originalOpenWrite
        backend.write = originalWrite
        assert.is_true(ran, reason)
        assert.are.same({ "a", "ab", "ab" }, writes)
    end)

    it("attempts every endpoint close and fails normal completion", function()
        local files = tecs.io.files
        local originalOpenRead = files.openRead
        local readerClosed = false
        local writerClosed = false
        local read = false
        files.openRead = function()
            return {
                read = function()
                    return ""
                end,
                readInto = function(_, buffer)
                    if read then
                        return 0
                    end
                    read = true
                    buffer:setString("x")
                    return 1
                end,
                close = function()
                    readerClosed = true
                    error("reader close exploded")
                end,
            }
        end
        local destination = {
            newWriter = function()
                return {
                    write = function()
                        return true
                    end,
                    writeFrom = function(_, _, _, count)
                        return count
                    end,
                    flush = function()
                        return true
                    end,
                    close = function()
                        writerClosed = true
                        error("writer close exploded")
                    end,
                }
            end,
        }

        local opened, copied = pcall(function()
            return ioModule.newFileStream("/virtual/source"):transferTo(destination)
        end)
        files.openRead = originalOpenRead
        assert.is_true(opened, copied)
        copied:wait(1000)
        assert.are.equal("failed", copied.status)
        assert.matches("reader close exploded", copied.error, 1, true)
        assert.is_true(readerClosed)
        assert.is_true(writerClosed)
        assert.are.equal(0, ioModule.pending())
    end)

    it("preserves transfer failure through throwing cleanup and cancellation", function()
        local payload = ffi.new("uint8_t[1]", 1)
        local closed = 0
        local destination = {
            newWriter = function()
                return {
                    write = function()
                        return false, "write failed"
                    end,
                    writeFrom = function()
                        return nil, "write failed"
                    end,
                    flush = function()
                        return true
                    end,
                    close = function()
                        closed = closed + 1
                        error("close exploded")
                    end,
                }
            end,
        }

        local failed = ioModule.newByteStream(payload, 1):transferTo(destination)
        failed:wait(1000)
        assert.are.equal("failed", failed.status)
        assert.are.equal("write failed", failed.error)
        assert.are.equal(0, ioModule.pending())

        local canceled = ioModule.newByteStream(payload, 1):transferTo(destination)
        assert.has_no.errors(function()
            canceled:cancel()
        end)
        assert.are.equal("canceled", canceled.status)
        assert.are.equal(2, closed)
    end)

    it("cleans up read setup failures before registering work", function()
        local files = tecs.io.files
        local originalInfo = files.info
        local originalOpenRead = files.openRead
        local opened = false
        files.info = function()
            return {
                kind = "file",
                size = 9007199254740991,
                createdAt = 0,
                modifiedAt = 0,
                accessedAt = 0,
            }
        end
        files.openRead = function()
            opened = true
            return {
                read = function()
                    return ""
                end,
                readInto = function()
                    return 0
                end,
                close = function() end,
            }
        end
        local before = ioModule.pending()
        local started, reading = pcall(function()
            return ioModule.newFileStream("/virtual/huge"):transferToBuffer()
        end)
        files.info = originalInfo
        files.openRead = originalOpenRead

        assert.is_true(started, reading)
        assert.are.equal("failed", reading.status)
        assert.is_false(opened)
        assert.are.equal(before, ioModule.pending())
    end)

    it("writes direct buffer ranges and returns exact byte counts", function()
        local source = ioModule.newBuffer("0123456789")
        local destination = ioModule.newBuffer()
        local stream = ioModule.newBufferStream(destination)
        local wrote = stream:writeBuffer(source, 2, 5)
        wrote:wait(1000)

        assert.are.equal("ready", wrote.status, wrote.error)
        assert.are.equal(5, wrote.value)
        assert.are.equal("23456", destination:getString())
        source:close()
        destination:close()
    end)

    it("handles partial writers until the whole range lands", function()
        local pieces = {}
        local destination = {
            contentLength = function()
                return nil
            end,
            contentType = function()
                return nil
            end,
            isReadable = function()
                return false
            end,
            isWritable = function()
                return true
            end,
            isReplayable = function()
                return false
            end,
            isAvailable = function()
                return true
            end,
            close = function() end,
            newWriter = function()
                return {
                    write = function(_, bytes)
                        pieces[#pieces + 1] = bytes
                        return true
                    end,
                    writeFrom = function(_, buffer, offset, count)
                        local taking = min(3, count)
                        pieces[#pieces + 1] = buffer:getString(offset, taking)
                        return taking
                    end,
                    flush = function()
                        return true
                    end,
                    close = function()
                        return true
                    end,
                }
            end,
            writeAll = function()
                error("unexpected string fast path")
            end,
            writeBuffer = function(self, buffer, offset, count)
                local writer = self:newWriter()
                local total = 0
                offset = offset or 0
                count = count or buffer:length() - offset
                while total < count do
                    total = total + writer:writeFrom(buffer, offset + total, count - total)
                end
                writer:close()
                return require("tecs.Future").settled(total)
            end,
        }
        local payload = "partial-write"
        local source = ffi.new("uint8_t[?]", #payload)
        ffi.copy(source, payload, #payload)
        local result = ioModule.newByteStream(source, #payload):transferTo(destination)
        result:wait(1000)

        assert.are.equal("ready", result.status, result.error)
        assert.are.equal(#payload, result.value)
        assert.are.equal(payload, table.concat(pieces))
    end)

    it("copies files with matching byte counts and hashes", function()
        local sourcePath = temporary()
        local destination = ioModule.newBuffer()
        local payload = string.rep("a\0bc", 300000)
        assert.is_true(tecs.io.files.write(sourcePath, payload))

        local copied = ioModule.newFileStream(sourcePath):transferTo(ioModule.newBufferStream(destination))
        copied:wait(5000)

        assert.are.equal("ready", copied.status, copied.error)
        assert.are.equal(#payload, copied.value)
        local actual = destination:getString()
        assert.are.equal(tecs.data.fnv1a64(payload), tecs.data.fnv1a64(actual))
        destination:close()
    end)

    it("shares its bounded poll budget fairly across transfers", function()
        local payload = string.rep("x", 1024 * 1024)
        local first = ioModule.newStringStream(payload):transferToBuffer()
        local second = ioModule.newStringStream(payload):transferToBuffer()
        assert.are.equal("pending", first.status)
        assert.are.equal("pending", second.status)

        ioModule.poll()
        assert.are.equal("pending", first.status)
        assert.are.equal("pending", second.status)

        ioModule.poll()
        assert.are.equal("pending", first.status)
        assert.are.equal("pending", second.status)

        ioModule.poll()
        assert.are.equal("ready", first.status, first.error)
        assert.are.equal("ready", second.status, second.error)
        assert.are.equal(#payload, first.value:length())
        assert.are.equal(#payload, second.value:length())
        first.value:close()
        second.value:close()
    end)

    it("bounds oversized string and buffer writes by bytes", function()
        local payload = string.rep("w", 2 * 1024 * 1024)
        local destination = ioModule.newBuffer()
        local stream = ioModule.newBufferStream(destination)

        local stringWrite = stream:writeAll(payload)
        ioModule.poll()
        assert.are.equal("pending", stringWrite.status)
        assert.are.equal(1024 * 1024, destination:length())
        ioModule.poll()
        assert.are.equal("ready", stringWrite.status, stringWrite.error)
        assert.are.equal(#payload, stringWrite.value)

        local source = ioModule.newBuffer(payload)
        local bufferWrite = stream:writeBuffer(source)
        ioModule.poll()
        assert.are.equal("pending", bufferWrite.status)
        assert.are.equal(1024 * 1024, destination:length())
        ioModule.poll()
        assert.are.equal("ready", bufferWrite.status, bufferWrite.error)
        assert.are.equal(#payload, bufferWrite.value)

        source:close()
        destination:close()
    end)

    it("retains views through direct writes and replayable transfers", function()
        local source = ioModule.newBuffer("before:payload:after")
        local view = source:view(7, 7)
        local directDestination = ioModule.newBuffer()
        local direct = ioModule.newBufferStream(directDestination):writeView(view)

        source:setString("changed", 7)
        view:close()
        source:close()
        ioModule.poll()

        assert.are.equal("ready", direct.status, direct.error)
        assert.are.equal(7, direct.value)
        assert.are.equal("payload", directDestination:getString())

        local streamSource = ioModule.newBuffer("streamed")
        local streamView = streamSource:view()
        local retained = ioModule.newViewStream(streamView, "application/octet-stream")
        local streamDestination = ioModule.newBuffer()
        local transferred = retained:transferTo(ioModule.newBufferStream(streamDestination))

        streamView:close()
        streamSource:setString("changed")
        streamSource:close()
        retained:close()
        ioModule.poll()

        assert.are.equal("ready", transferred.status, transferred.error)
        assert.are.equal(8, transferred.value)
        assert.are.equal("streamed", streamDestination:getString())

        directDestination:close()
        streamDestination:close()
    end)
end)
