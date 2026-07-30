--[=[
Declares the directional binary interfaces published by `tecs.io`.

This module is the cycle-safe home of `Reader` and `Writer`. It is not a
second public namespace: `tecs.io` re-exports both contracts, while filesystem
and network modules require them without requiring their public parent.
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

local record types
    type Reader = Reader
    type Writer = Writer
end

return types
