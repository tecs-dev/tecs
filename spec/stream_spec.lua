-- Owned buffers, directional stream descriptors, and synchronous transfers.

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

    it("opens readers that retain immutable snapshots", function()
        local buffer = ioModule.newBuffer("before")
        local view = buffer:view(1, 4)
        local bufferReader = buffer:newReader()
        local viewReader = view:newReader()

        buffer:setString("after!")
        buffer:close()
        view:close()

        assert.are.equal("before", bufferReader:read(64))
        assert.are.equal("efor", viewReader:read(64))

        bufferReader:close()
        viewReader:close()
    end)

    it("opens a writer that replaces bytes and reuses capacity", function()
        local buffer = ioModule.newBuffer("before")
        local capacity = buffer:capacity()
        local writer = buffer:newWriter()

        assert.is_true(writer:write("after"))
        assert.is_true(writer:close())
        assert.are.equal("after", buffer:getString())
        assert.are.equal(capacity, buffer:capacity())

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
        assert.are.equal(2, first:readInto(buffer, 0, 10))
        assert.are.equal("cd", buffer:getString())
        assert.are.equal(0, first:readInto(buffer, 0, 10))

        first:close()
        second:close()
        buffer:close()
    end)

    it("reads a retained snapshot back into its source buffer", function()
        local buffer = ioModule.newBuffer("same")
        local reader = buffer:newReader()

        assert.are.equal(4, reader:readInto(buffer, 0, 4))
        assert.are.equal("same", buffer:getString())

        reader:close()
        buffer:close()
    end)

    it("keeps a buffer reader alive after its source handle closes", function()
        local source = ioModule.newBuffer("gone")
        local reader = source:newReader()
        local destination = ioModule.newBuffer("kept")
        source:close()

        assert.are.equal(4, reader:readInto(destination, 4, 4))
        assert.are.equal("keptgone", destination:getString())

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
        assert.are.equal(1, reader:readInto(proxy, 4, 10))
        assert.are.equal(5, proxy:length())
        assert.are.equal("ab\0\0x", proxy:getString())
        assert.are.equal(0, reader:readInto(proxy, 9, 10))
        assert.are.equal(5, proxy:length())
        assert.are.equal("ab\0\0x", proxy:getString())
        reader:close()
        proxy:close()
    end)

    it("rejects aliased and closed memory writers", function()
        local buffer = ioModule.newBuffer("same")
        local writer = buffer:newWriter()
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
        local wrote, reason = buffer:newStream():writeBuffer(buffer)

        assert.is_nil(wrote)
        assert.are.equal("cannot write a buffer into itself", reason)
        assert.are.equal("same", buffer:getString())

        buffer:close()
    end)

    it("returns buffer stream backing without copying", function()
        local buffer = ioModule.newBuffer("owned")
        local buffered = buffer:newStream()
        assert.is_true(rawequal(buffer, buffered:transferToBuffer()))

        local empty = ioModule.newEmptyStream()
        assert.is_false(empty:isWritable())
        assert.is_nil(rawget(empty, "newWriter"))
        assert.are.equal("", empty:readAll())
        buffer:close()
    end)

    it("makes borrowed handles one-shot without closing them", function()
        local path = temporary()
        local handle = assert(io.open(path, "w+b"))
        assert(handle:write("handle"))
        assert(handle:seek("set", 0))

        local stream = ioModule.newHandleStream(handle, 6)
        local reader = assert(stream:newReader())
        assert.is_nil(stream:newReader())
        assert.are.equal("handle", reader:read(20))
        reader:close()

        assert(handle:seek("set", 0))
        assert.are.equal("handle", handle:read("*a"))
        handle:close()
    end)

    it("keeps metadata lazy and preserves false replayability", function()
        local source = ioModule.newStringStream("four", "text/plain")
        assert.is_nil(ioModule.withMetadata)
        assert.is_true(rawequal(source, ioModule.newStreamWithMetadata(source)))

        local view = ioModule.newStreamWithMetadata(source, "custom/type", 9, false)
        assert.are.equal("custom/type", view:contentType())
        assert.are.equal(9, view:contentLength())
        assert.is_false(view:isReplayable())
        assert.is_function(view.newReader)
        assert.is_nil(view.newWriter)

        view:close()
        assert.is_nil(source:newReader())
        assert.has_error(function()
            ioModule.newStreamWithMetadata({}, nil, 1)
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
            close = function(self)
                assert.is_true(rawequal(source, self))
            end,
        }
        local view = ioModule.newStreamWithMetadata(source, "custom/type")
        assert.is_nil(view.hasKnownLength)
        assert.are.equal("custom/type", view:contentType())
        assert.are.equal(4, view:contentLength())
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
            close = function() end,
        }
        assert.has_error(function()
            ioModule.newStreamWithMetadata(source, "custom/type")
        end, "tecs: io.newStreamWithMetadata claims ReadableStream without its methods")
    end)

    it("rejects transfers between metadata views of one shared buffer", function()
        local buffer = ioModule.newBuffer("shared")
        local source = ioModule.newStreamWithMetadata(buffer:newStream(), "application/source")
        local destination = ioModule.newStreamWithMetadata(buffer:newStream(), "application/destination")
        local copied, reason = source:transferTo(destination)

        assert.is_nil(copied)
        assert.are.equal("cannot transfer between streams sharing one backing", reason)
        assert.are.equal("shared", buffer:getString())

        buffer:close()
    end)

    it("rejects exact file paths and borrowed handles sharing one backing", function()
        local path = temporary()
        assert.is_true(tecs.io.files.write(path, "kept"))
        local fileCopy, fileReason = ioModule.newFileStream(path):transferTo(ioModule.newFileStream(path))

        assert.is_nil(fileCopy)
        assert.are.equal("cannot transfer between streams sharing one backing", fileReason)
        assert.are.equal("kept", tecs.io.files.read(path))

        local handle = assert(io.open(path, "r+b"))
        local handleCopy, handleReason = ioModule.newHandleStream(handle):transferTo(ioModule.newHandleStream(handle))

        assert.is_nil(handleCopy)
        assert.are.equal("cannot transfer between streams sharing one backing", handleReason)
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

    it("appends only new fallback writer bytes after each flush", function()
        local backend = adapter.storage()
        local originalOpenWrite = backend.openWrite
        local originalAppend = backend.append
        local appends = {}
        backend.openWrite = nil
        backend.append = function(_, bytes)
            appends[#appends + 1] = bytes
            return true
        end

        local ran, reason = pcall(function()
            local writer = assert(tecs.io.files.openWrite("/virtual/append", "append"))
            assert.is_true(writer:write("a"))
            assert.is_true(writer:flush())
            assert.is_true(writer:write("b"))
            assert.is_true(writer:flush())
            assert.is_true(writer:close())
        end)
        backend.openWrite = originalOpenWrite
        backend.append = originalAppend

        assert.is_true(ran, reason)
        assert.are.same({ "a", "b" }, appends)
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
                transferTo = function(self, destination)
                    local scratch = ioModule.newBuffer()
                    local got, readReason = self:readInto(scratch, 0, 1)
                    if got == nil then
                        scratch:close()
                        return nil, readReason
                    end
                    local wrote, writeReason = destination:writeFrom(scratch, 0, got)
                    scratch:close()
                    return wrote, writeReason
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

        local copied, reason = ioModule.newFileStream("/virtual/source"):transferTo(destination)
        files.openRead = originalOpenRead

        assert.is_nil(copied)
        assert.matches("reader close exploded", reason, 1, true)
        assert.is_true(readerClosed)
        assert.is_true(writerClosed)
    end)

    it("preserves transfer failure through throwing cleanup", function()
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

        local copied, reason = ioModule.newByteStream(payload, 1):transferTo(destination)

        assert.is_nil(copied)
        assert.are.equal("write failed", reason)
        assert.are.equal(1, closed)
    end)

    it("rejects oversized known sources before opening them", function()
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
        local reading, reason = ioModule.newFileStream("/virtual/huge"):transferToBuffer()
        files.info = originalInfo
        files.openRead = originalOpenRead

        assert.is_nil(reading)
        assert.is_string(reason)
        assert.is_false(opened)
    end)

    it("writes direct buffer ranges and returns exact byte counts", function()
        local source = ioModule.newBuffer("0123456789")
        local destination = ioModule.newBuffer()
        local stream = destination:newStream()
        local wrote, reason = stream:writeBuffer(source, 2, 5)

        assert.are.equal(5, wrote, reason)
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
                return total
            end,
        }
        local payload = "partial-write"
        local source = ffi.new("uint8_t[?]", #payload)
        ffi.copy(source, payload, #payload)
        local result, reason = ioModule.newByteStream(source, #payload):transferTo(destination)

        assert.are.equal(#payload, result, reason)
        assert.are.equal(payload, table.concat(pieces))
    end)

    it("reuses bounded scratch storage between synchronous transfers", function()
        local payload = ffi.new("uint8_t[4]", { 1, 2, 3, 4 })
        local source = ioModule.newByteStream(payload, 4)
        local seen = {}
        local destination = {
            newWriter = function()
                return {
                    write = function()
                        return true
                    end,
                    writeFrom = function(_, bytes, _, count)
                        seen[#seen + 1] = bytes
                        return count
                    end,
                    flush = function()
                        return true
                    end,
                    close = function()
                        return true
                    end,
                }
            end,
        }

        assert.are.equal(4, source:transferTo(destination))
        assert.are.equal(4, source:transferTo(destination))
        assert.is_true(rawequal(seen[1], seen[2]))

        source:close()
    end)

    it("copies files with matching byte counts and hashes", function()
        local sourcePath = temporary()
        local destination = ioModule.newBuffer()
        local payload = string.rep("a\0bc", 300000)
        assert.is_true(tecs.io.files.write(sourcePath, payload))

        local copied, reason = ioModule.newFileStream(sourcePath):transferTo(destination:newStream())

        assert.are.equal(#payload, copied, reason)
        local actual = destination:getString()
        assert.are.equal(tecs.data.fnv1a64(payload), tecs.data.fnv1a64(actual))

        destination:close()
    end)

    it("completes whole-source transfers before returning", function()
        local payload = string.rep("x", 1024 * 1024)
        local first = ioModule.newStringStream(payload):transferToBuffer()
        local second = ioModule.newStringStream(payload):transferToBuffer()

        assert.are.equal(#payload, first:length())
        assert.are.equal(#payload, second:length())

        first:close()
        second:close()
    end)

    it("writes complete strings and buffers before returning", function()
        local payload = string.rep("w", 2 * 1024 * 1024)
        local destination = ioModule.newBuffer()
        local stream = destination:newStream()

        local stringWrite, stringReason = stream:writeAll(payload)

        assert.are.equal(#payload, stringWrite, stringReason)
        assert.are.equal(#payload, destination:length())

        local source = ioModule.newBuffer(payload)
        local bufferWrite, bufferReason = stream:writeBuffer(source)

        assert.are.equal(#payload, bufferWrite, bufferReason)
        assert.are.equal(#payload, destination:length())

        source:close()
        destination:close()
    end)

    it("retains views through direct writes and replayable transfers", function()
        local source = ioModule.newBuffer("before:payload:after")
        local view = source:view(7, 7)
        local directDestination = ioModule.newBuffer()
        local direct, directReason = directDestination:newStream():writeView(view)

        source:setString("changed", 7)
        view:close()
        source:close()

        assert.are.equal(7, direct, directReason)
        assert.are.equal("payload", directDestination:getString())

        local streamSource = ioModule.newBuffer("streamed")
        local streamView = streamSource:view()
        local retained = streamView:newStream("application/octet-stream")
        local streamDestination = ioModule.newBuffer()
        local transferred, transferReason = retained:transferTo(streamDestination:newStream())

        streamView:close()
        streamSource:setString("changed")
        streamSource:close()
        retained:close()

        assert.are.equal(8, transferred, transferReason)
        assert.are.equal("streamed", streamDestination:getString())

        directDestination:close()
        streamDestination:close()
    end)
end)
