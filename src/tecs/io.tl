--[=[
Defines the directional interfaces that move binary strings through Tecs.

A [`Reader`](tealdoc:tecs.io.Reader) is a source and a
[`Writer`](tealdoc:tecs.io.Writer) is a destination. The separation is
deliberate: a file opened for reading, an HTTP response destination and a
decoder input do not need optional methods for the direction they cannot use.

The module owns the contracts, while another module owns each resource and
constructs it. For example, `tecs.io.filesystem.openRead` returns a `Reader`
and `tecs.io.filesystem.openWrite` returns a `Writer`:

```teal
local reader <const> = assert(tecs.io.filesystem.openRead(source))
local writer <const> = assert(tecs.io.filesystem.openWrite(destination))

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

The module is also the lazy parent of
[`filesystem`](/modules/io/filesystem/) and
[`watcher`](/modules/io/watcher/). Naming `tecs.io` loads neither child, and
reading one child does not load the other.
]=]

local type iotypes = require("tecs.io.types")
local type filesystem = require("tecs.io.filesystem")
local type watcher = require("tecs.io.watcher")

local record binaryIO
    --- Read-only. Exposes path resolution and synchronous file operations.
    filesystem: filesystem

    --- Read-only. Exposes loaded-content polling and reload notifications.
    watcher: watcher

    --- `Reader` supplies bytes in order and releases its source on `close`.
    type Reader = iotypes.Reader

    --- `Writer` accepts bytes in order and finishes its destination on
    --- `close`.
    type Writer = iotypes.Writer
end

return binaryIO
