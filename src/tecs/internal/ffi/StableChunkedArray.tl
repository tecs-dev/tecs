--[=[
Stable-address FFI storage with chunked allocation.
Chunks are never moved while the array is alive, so element addresses stay
stable even when ids are recycled.
]=]

local ffi <const> = require("ffi")
local floor <const> = math.floor

local record ChunkedArray
    chunks: {ffi.CData}
    chunkSize: integer
    ffiType: string
    nextId: integer
    freeIds: {integer}
    alive: {integer: boolean}

    --- Allocate a new slot and return its 1-based id.
    alloc: function(self): integer

    --- Free a slot for reuse. No-op if id is invalid or already freed.
    free: function(self, id: integer)

    --- Get the live element stored at an id.
    --- Returns nil for dead or never-allocated ids.
    get: function(self, id: integer): any
end

local ChunkedArrayMT: metatable<ChunkedArray> = {__index = ChunkedArray}

local record module
    --- ChunkedArray type for annotations.
    type ChunkedArray = ChunkedArray

    --- Create a new chunked array for the given base FFI type name.
    new: function(ffiType: string, chunkSize?: integer): ChunkedArray
end

function module.new(ffiType: string, chunkSize?: integer): ChunkedArray
    local size = chunkSize or 256
    if size <= 0 then
        error("StableChunkedArray.new: chunkSize must be a positive integer, got " .. tostring(size))
    end
    local arr: ChunkedArray = {
        chunks = {},
        chunkSize = size,
        ffiType = ffiType .. "[?]",
        nextId = 1,
        freeIds = {},
        alive = {},
    }
    return setmetatable(arr, ChunkedArrayMT)
end

function ChunkedArray:alloc(): integer
    local id: integer
    local freeIds = self.freeIds
    local n = #freeIds
    if n > 0 then
        id = freeIds[n]
        freeIds[n] = nil
    else
        id = self.nextId
        self.nextId = id + 1
        local zero = id - 1
        local chunkIndex = floor(zero / self.chunkSize) + 1
        if not self.chunks[chunkIndex] then
            self.chunks[chunkIndex] = ffi.new(self.ffiType, self.chunkSize)
        end
    end
    self.alive[id] = true
    return id
end

function ChunkedArray:free(id: integer)
    if id < 1 or id >= self.nextId or not self.alive[id] then
        return
    end
    self.alive[id] = nil
    self.freeIds[#self.freeIds + 1] = id
end

function ChunkedArray:get(id: integer): any
    if not self.alive[id] then
        return nil
    end
    local zero = id - 1
    local chunkIndex = floor(zero / self.chunkSize) + 1
    local chunk = self.chunks[chunkIndex]
    local slot = zero % self.chunkSize
    return (chunk as {integer: any})[slot]
end

return module
