--[=[
Defines the directional interfaces that move binary strings through Tecs.

A [`Reader`](tealdoc:tecs.io.Reader) is a source and a
[`Writer`](tealdoc:tecs.io.Writer) is a destination. The separation is
deliberate: a file opened for reading, an HTTP response destination and a
decoder input do not need optional methods for the direction they cannot use.

The module owns the contracts, while another module owns each resource and
constructs it. For example, `tecs.filesystem.openRead` returns a `Reader` and
`tecs.filesystem.openWrite` returns a `Writer`:

```teal
local reader <const> = assert(tecs.filesystem.openRead(source))
local writer <const> = assert(tecs.filesystem.openWrite(destination))

while true do
    local bytes, reason = reader:read(64 * 1024)
    if bytes == nil then
        reader:close()
        error(reason)
    end
    if #bytes == 0 then
        break
    end
    assert(writer:write(bytes))
end

reader:close()
assert(writer:close())
```

Reads and writes are synchronous. The returned Lua strings are binary-safe,
including embedded NUL bytes. The module does not attach path, network or
content-type policy to a stream; the module that constructs one owns those
concerns.
]=]

--- A caller-owned source of binary strings.
---
--- The module that constructs a reader owns its backing resource until
--- `close` releases it. A consumer reads forward until `read` returns an empty
--- string, then closes the reader. A failure returns nil and a reason instead
--- of raising.
local record Reader
    --- Caller-writable. Supplies the operation that reads the next bytes.
    ---
    --- @param self The reader whose cursor advances.
    --- @param count The maximum number of bytes to return. A non-positive
    ---     count may still return one byte so the reader can make progress.
    --- @return Returns up to `count` bytes, fewer at the end, or an empty
    ---     string after the source is exhausted.
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
--- individual write observed.
local record Writer
    --- Caller-writable. Supplies the operation that appends bytes.
    ---
    --- @param self The writer receiving the bytes.
    --- @param bytes The binary string to append, including any embedded NUL
    ---     bytes.
    --- @return Returns whether every byte reached the destination.
    --- @return Returns the destination's reason when the first return is
    ---     false.
    write: function(self: Writer, bytes: string): boolean, string

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

local record binaryIO
    --- `Reader` supplies bytes in order and releases its source on `close`.
    type Reader = Reader

    --- `Writer` accepts bytes in order and finishes its destination on
    --- `close`.
    type Writer = Writer
end

return binaryIO
