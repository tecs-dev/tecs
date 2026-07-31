local bufferpool <const> = require("tecs.io.bufferpool")
local type types = require("tecs.io.types")

local type Reader = types.Reader
local type Writer = types.Writer

local CHUNK <const> = 64 * 1024

local record pump
    transfer: function(source: Reader, destination: Writer): integer, string
end

function pump.transfer(source: Reader, destination: Writer): integer, string
    local scratch <const> = bufferpool.acquire(CHUNK)
    local total = 0
    local failure: string
    while failure == nil do
        scratch:clear()
        local got <const>, readReason = source:readInto(scratch, CHUNK)
        if got == nil then
            failure = readReason
            break
        end
        if got == 0 then
            break
        end
        local offset = 0
        while offset < got do
            local wrote <const>, writeReason = destination:writeFrom(scratch, offset, got - offset)
            if wrote == nil then
                failure = writeReason
                break
            end
            if wrote <= 0 then
                failure = "stream writer made no progress"
                break
            end
            offset = offset + wrote
            total = total + wrote
        end
    end
    bufferpool.release(scratch)
    return failure == nil and total or nil, failure
end

return pump
