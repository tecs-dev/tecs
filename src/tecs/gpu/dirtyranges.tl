--- A list of byte ranges that were written, coalesced as it grows.
---
--- Two things record ranges: a buffer's staging slot, which flushes them, and
--- a frame packet, which carries them from whoever wrote the bytes to whoever
--- owns the device. Both want the same merging and the same ceiling, and a
--- second implementation of either is free to drift into a partial upload,
--- which reads as a producer bug three subsystems later.
---
--- Storage is a C array rather than a Lua table because a range is recorded for
--- every run an extraction touches, and because this list is one of the values
--- that crosses between states once rendering owns its own.

local loader <const> = require("tecs.ffi.loader")

--- Distinct ranges tracked before they are collapsed into one span.
--- Collapsing costs bandwidth; tracking costs nothing until it is exceeded.
local MAX_RANGES <const> = 64

--- A coalescing list of written byte ranges, and the type `create` returns.
---
--- Ranges go in through `mark`, come back out through `at` over `count`
--- entries, and are forgotten by `clear`. Offsets and sizes are bytes
--- throughout; nothing here knows which buffer they describe or how long it is.
local record dirtyranges
    --- Ranges tracked before the list collapses to a single span.
    MAX: integer

    --- Offset and size pairs, flat: entry n occupies indices 2n and 2n+1.
    ---
    --- `uint32_t`, so an offset or a size a buffer could not hold anyway wraps
    --- here rather than being rejected. Read through `at`, which is the only
    --- thing that knows the pairing.
    entries: loader.CArray
    --- Pairs recorded, not indices used. Zero is a list with nothing to flush.
    count: integer
    --- True once the list collapsed into the single span at index 0. Every
    --- later mark widens that span instead of adding an entry.
    collapsed: boolean
    --- Bytes marked since the last clear, summed as marked. Overlapping writes
    --- count twice, so this sizes the work a writer did rather than the bytes
    --- a flush will copy.
    bytes: integer

    --- Builds an empty list.
    --- @return A list whose storage is allocated once and reused across every
    ---     mark and clear it sees.
    create: function(): dirtyranges

    --- Records that `size` bytes at `offset` were written.
    ---
    --- Adjacent and overlapping writes merge, which is the common case when a
    --- writer walks runs in order. Beyond `MAX` distinct spans the whole region
    --- collapses to one, trading bandwidth for bounded bookkeeping.
    ---
    --- Only the last recorded range is tested for a merge, so writes that
    --- arrive out of order fill the list faster and collapse sooner. That costs
    --- bandwidth and nothing else: the collapsed span still covers every write.
    --- @param offset Bytes from the start of the buffer. Nothing checks it
    ---     against the buffer's length, which is the flusher's business.
    --- @param size Bytes written from `offset`. Zero or less records nothing,
    ---     not even against `bytes`.
    mark: function(self, offset: integer, size: integer)

    --- Offset and size of the range at `index`, which runs from zero.
    --- @param index Zero to `count - 1`. Unchecked: between `count` and `MAX`
    ---     this reads spans a previous, longer generation of the list left
    ---     behind, and past `MAX` it reads off the end of the array.
    --- @return The range's offset in bytes.
    --- @return Its size in bytes.
    at: function(self, index: integer): integer, integer

    --- Forgets every range. The storage is kept, since the next frame needs it.
    ---
    --- The entries themselves are left as they were, so a reader that walks
    --- past `count` sees stale spans rather than nothing.
    clear: function(self)
end

dirtyranges.MAX = MAX_RANGES

local dirtyrangesMT <const>: metatable<dirtyranges> = {__index = dirtyranges}

local min <const>, max <const> = math.min, math.max

function dirtyranges.create(): dirtyranges
    local self = setmetatable({} as dirtyranges, dirtyrangesMT)
    self.entries = loader.newArray("uint32_t[?]", MAX_RANGES * 2)
    self.count = 0
    self.collapsed = false
    self.bytes = 0
    return self
end

function dirtyranges:mark(offset: integer, size: integer)
    if size <= 0 then
        return
    end
    self.bytes = self.bytes + size

    local entries = self.entries
    if self.collapsed then
        local start = min(entries[0] as integer, offset)
        local finish = max((entries[0] as integer) + (entries[1] as integer), offset + size)
        entries[0] = start
        entries[1] = finish - start
        return
    end

    local count = self.count

    if count > 0 then
        local lastOffset = entries[(count - 1) * 2] as integer
        local lastSize = entries[(count - 1) * 2 + 1] as integer
        if offset <= lastOffset + lastSize and offset + size >= lastOffset then
            local start = min(lastOffset, offset)
            local finish = max(lastOffset + lastSize, offset + size)
            entries[(count - 1) * 2] = start
            entries[(count - 1) * 2 + 1] = finish - start
            return
        end
    end

    if count >= MAX_RANGES then
        local start = entries[0] as integer
        local finish = start
        for entry = 0, count - 1 do
            local rangeEnd = (entries[entry * 2] as integer) + (entries[entry * 2 + 1] as integer)
            start = min(start, entries[entry * 2] as integer)
            finish = max(finish, rangeEnd)
        end
        start = min(start, offset)
        finish = max(finish, offset + size)
        entries[0] = start
        entries[1] = finish - start
        self.count = 1
        self.collapsed = true
        return
    end

    entries[count * 2] = offset
    entries[count * 2 + 1] = size
    self.count = count + 1
end

function dirtyranges:at(index: integer): integer, integer
    return self.entries[index * 2] as integer, self.entries[index * 2 + 1] as integer
end

function dirtyranges:clear()
    self.count = 0
    self.collapsed = false
    self.bytes = 0
end

return dirtyranges
