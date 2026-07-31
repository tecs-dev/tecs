--[=[
Declares the directional binary interfaces published by `tecs.io`.

This module is the cycle-safe home of `Reader`, `Writer`, and the stream
descriptor interfaces. It is not a second public namespace: `tecs.io`
re-exports the contracts, while resource modules require them without
requiring their public parent.
]=]

local type loader = require("tecs.ffi.loader")
local type coretypes = require("tecs.types")
local type Closeable = coretypes.Closeable

--- An immutable, zero-copy range retained from a [`Buffer`](tealdoc:tecs.io.Buffer).
---
--- A view is a snapshot: changing its source buffer first detaches that
--- buffer's allocation, so the view keeps seeing the bytes it was created
--- from. `getString` is the explicit copying boundary.
local interface ByteView is Closeable
    --- Creates a replayable read-only stream retaining this view.
    ---
    --- The stream retains its own view, so the caller may close this view
    --- immediately after construction. Closing the stream closes its retained
    --- view after already-open readers close theirs.
    --- @param self The open immutable byte view.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a caller-owned readable stream.
    newStream: function(self: ByteView, contentType?: string): ReadableStream

    --- Opens a reader over this immutable range.
    ---
    --- The reader retains the allocation independently, so the caller may
    --- close this view immediately after the call. Its cursor starts at zero.
    --- @param self The open source view.
    --- @return Returns a caller-owned reader.
    newReader: function(self: ByteView): Reader

    --- Returns the retained range's byte length.
    ---
    --- @param self The open view to inspect.
    --- @return Returns the number of readable bytes.
    length: function(self: ByteView): integer

    --- Copies the retained range into a Lua string.
    ---
    --- @param self The open view to copy.
    --- @return Returns a fresh binary string.
    getString: function(self: ByteView): string

    --- Borrows the retained range's read-only address.
    ---
    --- LuaJIT FFI cannot enforce constness. Writing through a cast pointer is
    --- unsafe and breaks the snapshot guarantee.
    --- @param self The open view whose storage to borrow.
    --- @return Returns a pointer valid until `close`.
    getFFIPointer: function(self: ByteView): loader.BytePointer

    --- Retains a zero-copy subrange.
    ---
    --- @param self The open source view.
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns a caller-owned view retaining the same allocation.
    view: function(self: ByteView, offset?: integer, count?: integer): ByteView

    --- Returns whether the view has released its retained allocation.
    ---
    --- @param self The view to inspect.
    --- @return Returns true after `close`.
    isReleased: function(self: ByteView): boolean

    --- Releases this view's reference to the retained allocation.
    ---
    --- Repeated calls are safe. Every method except `isReleased` and
    --- `close` raises afterwards.
    --- @param self The view to close.
    close: function(self: ByteView)
end

--- An exclusive, zero-copy writable range reserved from a [`Buffer`](tealdoc:tecs.io.Buffer).
local interface WriteRange is Closeable
    --- Borrows the reserved range's writable address.
    ---
    --- @param self The open range whose storage to borrow.
    --- @return Returns a pointer valid until `commit` or `close`.
    getFFIPointer: function(self: WriteRange): loader.BytePointer

    --- Returns the maximum byte count the native writer may fill.
    ---
    --- @param self The open range to inspect.
    --- @return Returns the reserved byte capacity.
    capacity: function(self: WriteRange): integer

    --- Commits bytes written through the borrowed pointer.
    ---
    --- The call closes the range. A gap before the committed bytes is
    --- zero-filled.
    --- @param self The open range to commit.
    --- @param used The caller supplies the written count up to `capacity`.
    commit: function(self: WriteRange, used: integer)

    --- Closes the range without changing the buffer's logical length.
    ---
    --- @param self The range to close.
    close: function(self: WriteRange)
end

--- An owned, growable sequence of bytes.
---
--- Its logical length is separate from capacity. Offsets are zero-based, and
--- `clear` retains the allocation for reuse. Readers retain immutable
--- snapshots independently. Writers borrow the buffer and never close it.
local interface Buffer is Closeable
    type WriteRange = WriteRange

    --- Creates a stream sharing this buffer.
    ---
    --- The stream borrows this buffer. The caller keeps it open while using
    --- the stream and closes it separately. Closing the stream never closes
    --- the buffer. `transferToBuffer` returns this same borrowed object
    --- without transferring ownership.
    --- @param self The open buffer the stream borrows.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a caller-owned readable and writable stream.
    newStream: function(self: Buffer, contentType?: string): ReadWriteStream

    --- Opens a reader over an immutable snapshot of the current bytes.
    ---
    --- The reader retains the allocation independently, so the caller may
    --- close or mutate the buffer after this call. Its cursor starts at zero.
    --- @param self The open source buffer.
    --- @return Returns a caller-owned reader.
    newReader: function(self: Buffer): Reader

    --- Opens a writer that replaces the current bytes.
    ---
    --- The call clears the logical length while retaining capacity. The
    --- caller keeps the buffer open until the writer closes.
    --- @param self The open destination buffer.
    --- @return Returns a caller-owned writer.
    newWriter: function(self: Buffer): Writer

    --- Returns the number of logical bytes.
    ---
    --- @param self The buffer to inspect.
    --- @return Returns the bytes visible to `getString`.
    length: function(self: Buffer): integer

    --- Returns the allocated byte capacity.
    ---
    --- @param self The buffer to inspect.
    --- @return Returns the byte count available without reallocating.
    capacity: function(self: Buffer): integer

    --- Removes every logical byte without releasing the allocation.
    ---
    --- @param self The buffer to clear.
    clear: function(self: Buffer)

    --- Ensures at least `minimum` bytes fit without another allocation.
    ---
    --- Growth is geometric. A call at or below the current capacity leaves
    --- pointers returned by `getFFIPointer` valid.
    --- @param self The buffer to grow.
    --- @param minimum The caller supplies a non-negative byte count.
    ensureCapacity: function(self: Buffer, minimum: integer)

    --- Changes the logical length.
    ---
    --- Expansion fills every newly visible byte with zero. Shrinking keeps
    --- the allocation for reuse.
    --- @param self The buffer to resize.
    --- @param length The caller supplies a non-negative byte count.
    resize: function(self: Buffer, length: integer)

    --- Copies a range into a Lua string.
    ---
    --- @param self The source buffer.
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns a fresh binary string.
    getString: function(self: Buffer, offset?: integer, count?: integer): string

    --- Copies a Lua string into the buffer.
    ---
    --- The write extends the logical length as needed. A gap between the old
    --- end and `offset` is zero-filled.
    --- @param self The destination buffer.
    --- @param bytes The caller supplies a binary string.
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    setString: function(self: Buffer, bytes: string, offset?: integer)

    --- Returns a zero-copy immutable snapshot of a byte range.
    ---
    --- @param self The open buffer to retain.
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns a caller-owned retained view.
    view: function(self: Buffer, offset?: integer, count?: integer): ByteView

    --- Reserves an exclusive range for a native writer without an intermediate string.
    ---
    --- The buffer detaches from retained views before exposing mutable
    --- storage.
    --- @param self The open buffer to reserve.
    --- @param offset The caller supplies a zero-based write offset.
    --- @param minimum The caller supplies the minimum writable capacity.
    --- @return Returns a caller-owned exclusive range.
    reserveRange: function(self: Buffer, offset: integer, minimum: integer): WriteRange

    --- Borrows the address of the first byte.
    ---
    --- The pointer is invalid after capacity grows or `close` runs. The
    --- buffer must remain reachable for the whole native call that uses it.
    --- @param self The buffer whose storage to borrow.
    --- @return Returns a mutable FFI byte pointer.
    getFFIPointer: function(self: Buffer): loader.BytePointer

    --- Returns whether `close` has given up the allocation.
    ---
    --- @param self The buffer to inspect.
    --- @return Returns true after `close`.
    isReleased: function(self: Buffer): boolean

    --- Closes the buffer, gives up its allocation, and makes it unusable.
    ---
    --- Repeated calls are safe. Every method except `isReleased` and
    --- `close` raises afterwards.
    --- @param self The buffer to close.
    close: function(self: Buffer)
end

--- A caller-owned source of binary strings.
---
--- The constructor documents whether the reader owns retained state or
--- borrows externally owned storage. A consumer reads forward until `read`
--- returns an empty string, then closes the reader. A failure returns nil and
--- a reason instead of raising. Implementations may provide direct-buffer
--- accelerators which `tecs.io.transfer` selects without making them part of
--- this basic protocol.
local interface Reader is Closeable
    --- Caller-writable. Supplies the operation that reads the next bytes.
    ---
    --- @param self The reader whose cursor advances.
    --- @param count The maximum number of bytes to return when positive.
    ---     Zero and negative counts are treated as one so the reader makes
    ---     progress.
    --- @return Returns up to `max(1, count)` bytes, fewer at the end, or an
    ---     empty string after the source is exhausted.
    --- @return Returns the source's reason when the first return is nil.
    read: function(self: Reader, count: integer): string, string

    --- Caller-writable. Supplies the operation that releases the source.
    ---
    --- Closing more than once must be a no-op.
    ---
    --- @param self The reader to close.
    close: function(self: Reader)
end

--- A caller-owned destination for binary strings.
---
--- A consumer writes pieces in order and closes the writer even after the last
--- `write` succeeds. The close can report a delayed flush failure that no
--- individual write observed. The constructor documents whether closing the
--- writer also closes or merely releases its destination. Implementations may
--- provide direct-buffer accelerators which `tecs.io.transfer` selects without
--- making them part of this basic protocol.
local interface Writer is Closeable
    --- Caller-writable. Supplies the operation that appends bytes.
    ---
    --- @param self The writer receiving the bytes.
    --- @param bytes The binary string to append, including any embedded NUL
    ---     bytes.
    --- @return Returns whether every byte reached the destination.
    --- @return Returns the destination's reason when the first return is
    ---     false.
    write: function(self: Writer, bytes: string): boolean, string

    --- Flushes buffered bytes without closing the destination.
    ---
    --- @param self The writer to flush.
    --- @return Returns whether buffered bytes reached the destination.
    --- @return Returns the destination's reason when the first return is
    ---     false.
    flush: function(self: Writer): boolean, string

    --- Caller-writable. Supplies the operation that finishes the destination.
    ---
    --- Closing more than once must succeed.
    ---
    --- @param self The writer to finish and close.
    --- @return Returns whether buffered bytes reached the destination and its
    ---     resources were released.
    --- @return Returns the destination's reason when the first return is
    ---     false.
    close: function(self: Writer): boolean, string
end

--- Describes reopenable or one-shot binary storage.
---
--- A stream carries no cursor. `newReader` and `newWriter` create directional
--- endpoints that own their cursor and must be closed. Metadata is queried
--- through methods because a file may change between calls.
local interface Stream is Closeable
    --- Returns the byte length when it is known.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns the current byte length, or nil when it cannot be
    ---     known before reading.
    contentLength: function(self: Stream): integer | nil

    --- Returns the media type supplied at construction.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns the media type, or nil when none was supplied.
    contentType: function(self: Stream): string | nil

    --- Returns whether the descriptor can open a reader.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns true when `newReader` is supported.
    isReadable: function(self: Stream): boolean

    --- Returns whether the descriptor can open a writer.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns true when `newWriter` is supported.
    isWritable: function(self: Stream): boolean

    --- Returns whether each reader starts from the beginning.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns true when opening a later reader replays all bytes.
    isReplayable: function(self: Stream): boolean

    --- Returns whether the descriptor can currently open an endpoint.
    ---
    --- @param self The descriptor to inspect.
    --- @return Returns false after `close`, after a backing buffer is
    ---     released, or after a one-shot endpoint has been claimed.
    isAvailable: function(self: Stream): boolean

    --- Closes the descriptor.
    ---
    --- Closing a descriptor never closes endpoints already opened from it.
    --- Each constructor documents whether those endpoints retain or borrow
    --- separately owned backing storage.
    --- Repeated calls are safe.
    --- @param self The descriptor to close.
    close: function(self: Stream)
end

--- Describes binary storage that can create readers.
local interface ReadableStream is Stream
    --- Returns whether `transferToBuffer` can return stable backing storage.
    ---
    --- True is a zero-copy guarantee: `transferToBuffer` returns the same
    --- borrowed buffer whose `newStream` method created the stream. The
    --- stream and caller share that object; the caller retains ownership and
    --- closes it.
    --- @param self The readable descriptor.
    --- @return Returns true only for a buffer-backed stream.
    hasBuffer: function(self: ReadableStream): boolean

    --- Opens a reader with a new cursor.
    ---
    --- @param self The readable descriptor.
    --- @return Returns a caller-owned reader, or nil when unavailable.
    --- @return Returns the reason when the first return is nil.
    newReader: function(self: ReadableStream): Reader, string

    --- Reads the complete source into a Lua string.
    ---
    --- @param self The readable descriptor.
    --- @param maxBytes The caller supplies a non-negative limit or omits it
    ---     for no explicit limit.
    --- @return Returns the complete bytes.
    --- @return Returns the source's reason when the first return is nil.
    readAll: function(self: ReadableStream, maxBytes?: integer): string, string

    --- Transfers the complete source into an owned buffer.
    ---
    --- When `hasBuffer` is true, this returns the same borrowed buffer rather
    --- than a copy and does not transfer ownership. Otherwise it returns a
    --- newly allocated buffer owned by the caller.
    --- @param self The readable descriptor.
    --- @param maxBytes The caller supplies a non-negative limit or omits it
    ---     for no explicit limit.
    --- @return Returns a caller-owned buffer.
    --- @return Returns the source's reason when the first return is nil.
    transferToBuffer: function(self: ReadableStream, maxBytes?: integer): Buffer, string

    --- Copies every source byte into `destination`.
    ---
    --- @param self The readable descriptor.
    --- @param destination The caller supplies an available writable stream.
    --- @return Returns the bytes written.
    --- @return Returns the source or destination reason when the first return
    ---     is nil.
    transferTo: function(self: ReadableStream, destination: WritableStream): integer, string

    --- Copies every source byte into a file.
    ---
    --- @param self The readable descriptor.
    --- @param path The caller supplies the destination path to replace.
    --- @return Returns the bytes written.
    --- @return Returns the source or file reason when the first return is nil.
    transferToFile: function(self: ReadableStream, path: string): integer, string

    --- Reads and discards every source byte.
    ---
    --- @param self The readable descriptor.
    --- @return Returns the bytes discarded.
    --- @return Returns the source's reason when the first return is nil.
    discard: function(self: ReadableStream): integer, string
end

--- Describes binary storage that can create writers.
local interface WritableStream is Stream
    --- Opens a writer with a new cursor.
    ---
    --- Opening replaces the destination's previous bytes.
    --- @param self The writable descriptor.
    --- @return Returns a caller-owned writer, or nil when unavailable.
    --- @return Returns the reason when the first return is nil.
    newWriter: function(self: WritableStream): Writer, string

    --- Replaces the destination with a Lua string.
    ---
    --- @param self The writable descriptor.
    --- @param bytes The caller supplies the complete binary contents.
    --- @return Returns the bytes written.
    --- @return Returns the destination's reason when the first return is nil.
    writeAll: function(self: WritableStream, bytes: string): integer, string

    --- Replaces the destination with a buffer range.
    ---
    --- @param self The writable descriptor.
    --- @param buffer The caller keeps the source buffer open and unchanged
    ---     through the call.
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns the bytes written.
    --- @return Returns the destination's reason when the first return is nil.
    writeBuffer: function(self: WritableStream, buffer: Buffer, offset?: integer, count?: integer): integer, string

    --- Replaces the destination with a retained immutable byte range.
    ---
    --- The caller keeps `view` open through the call.
    --- @param self The writable descriptor.
    --- @param view The caller supplies an open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView).
    --- @param offset The caller supplies a zero-based offset or omits it for
    ---     zero.
    --- @param count The caller supplies a byte count or omits it for the
    ---     remainder.
    --- @return Returns the bytes written.
    --- @return Returns the destination's reason when the first return is nil.
    writeView: function(self: WritableStream, view: ByteView, offset?: integer, count?: integer): integer, string
end

--- Describes storage that supports both directions.
local interface ReadWriteStream is ReadableStream, WritableStream
end

--- Options controlling an incremental inflate reader.
local record InflateReaderOptions
    --- Caller-writable. Selects raw DEFLATE when true and zlib framing when
    --- false or omitted.
    raw: boolean

    --- Caller-writable. Sets the hard decompressed-byte ceiling or uses
    --- 268,435,456 bytes when omitted.
    maxBytes: integer
end

--- Options controlling an incremental deflate writer.
local record DeflateWriterOptions
    --- Caller-writable. Selects raw DEFLATE when true and zlib framing when
    --- false or omitted.
    raw: boolean

    --- Caller-writable. Sets zlib's compression level from minus one through
    --- nine or uses its default when omitted.
    level: integer
end

local record types
    type Buffer = Buffer
    type ByteView = ByteView
    type WriteRange = WriteRange
    type Reader = Reader
    type Writer = Writer
    type Stream = Stream
    type ReadableStream = ReadableStream
    type WritableStream = WritableStream
    type ReadWriteStream = ReadWriteStream
    type InflateReaderOptions = InflateReaderOptions
    type DeflateWriterOptions = DeflateWriterOptions
end

return types
