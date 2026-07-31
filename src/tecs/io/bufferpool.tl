local buffer <const> = require("tecs.io.buffer")
local type types = require("tecs.io.types")

local type IOBuffer = types.Buffer

local MAX_FREE <const> = 8
local MAX_RETAINED_CAPACITY <const> = 256 * 1024
local free: {IOBuffer} = {}
local freeCount = 0

local record bufferpool
    acquire: function(minimum?: integer): IOBuffer
    release: function(value: IOBuffer)
end

function bufferpool.acquire(minimum?: integer): IOBuffer
    minimum = minimum or 0
    local selected = 0
    for index = freeCount, 1, -1 do
        if free[index]:capacity() >= minimum then
            selected = index
            break
        end
    end
    local value: IOBuffer
    if selected > 0 then
        value = free[selected]
        free[selected] = free[freeCount]
        free[freeCount] = nil
        freeCount = freeCount - 1
    else
        value = buffer.new()
        value:ensureCapacity(minimum)
    end
    return value
end

function bufferpool.release(value: IOBuffer)
    value:clear()
    if value:capacity() > MAX_RETAINED_CAPACITY or freeCount >= MAX_FREE then
        value:close()
        return
    end
    freeCount = freeCount + 1
    free[freeCount] = value
end

return bufferpool
