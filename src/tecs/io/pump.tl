local bufferpool <const> = require("tecs.io.bufferpool")
local type types = require("tecs.io.types")

local type Reader = types.Reader
local type Writer = types.Writer

local CHUNK <const> = 64 * 1024

local record pump
    readInto: function(
        source: Reader | FILE, destination: types.Buffer, offset?: integer, count?: integer
    ): integer, string
    writeFrom: function(
        destination: Writer | FILE, source: types.Buffer, offset?: integer, count?: integer
    ): integer, string
    transfer: function(source: Reader | FILE, destination: Writer | FILE): integer, string
    transferBuffered: function(source: Reader | FILE, destination: Writer | FILE): integer, string
end

function pump.readInto(
    source: Reader | FILE, destination: types.Buffer, offset?: integer, count?: integer
): integer, string
    offset = offset or 0
    count = count or CHUNK
    if count == 0 then
        return 0
    end
    local dynamic <const> = source as {string: any}
    if type(dynamic.readInto) == "function" then
        return (dynamic.readInto as function(any, types.Buffer, integer, integer): integer, string)(
            source, destination, offset, count
        )
    end
    local piece <const>, reason = (dynamic.read as function(any, integer): string, string)(source, count)
    if piece == nil then
        return reason == nil and 0 or nil, reason
    end
    destination:setString(piece, offset)
    return #piece
end

function pump.writeFrom(
    destination: Writer | FILE, source: types.Buffer, offset?: integer, count?: integer
): integer, string
    offset = offset or 0
    count = count == nil and source:length() - offset or count
    if count == 0 then
        return 0
    end
    local dynamic <const> = destination as {string: any}
    if type(dynamic.writeFrom) == "function" then
        return (dynamic.writeFrom as function(any, types.Buffer, integer, integer): integer, string)(
            destination, source, offset, count
        )
    end
    local wrote <const>, reason = (dynamic.write as function(any, string): any, string)(
        destination, source:getString(offset, count)
    )
    if wrote == nil or wrote == false then
        return nil, reason or "the destination rejected the bytes"
    end
    return count
end

function pump.transfer(source: Reader | FILE, destination: Writer | FILE): integer, string
    local transferTo <const> = (source as {string: any}).transferTo
    if type(transferTo) == "function" then
        return (transferTo as function(any, Writer | FILE): integer, string)(source, destination)
    end
    return pump.transferBuffered(source, destination)
end

-- Holds the copy loop so `transferBuffered` releases its scratch buffer on the
-- normal path and on an unwinding one. A cooperative read raises out of this
-- loop when its system is canceled, and a buffer lost there would leave the
-- pool short of an entry for the rest of the process.
local function copyThrough(source: Reader | FILE, destination: Writer | FILE, scratch: types.Buffer): integer, string
    local total = 0
    local failure: string
    while failure == nil do
        scratch:clear()
        local got <const>, readReason = pump.readInto(source, scratch, 0, CHUNK)
        if got == nil then
            failure = readReason
            break
        end
        if got == 0 then
            break
        end
        local offset = 0
        while offset < got do
            local wrote <const>, writeReason = pump.writeFrom(destination, scratch, offset, got - offset)
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
    return total, failure
end

function pump.transferBuffered(source: Reader | FILE, destination: Writer | FILE): integer, string
    local scratch <const> = bufferpool.acquire(CHUNK)
    local ok <const>, copied, reason = pcall(copyThrough, source, destination, scratch) as (boolean, any, any)
    bufferpool.release(scratch)
    if not ok then
        error(copied, 0)
    end
    local total <const> = copied as integer
    local failure <const> = reason as string
    return failure == nil and total or nil, failure
end

return pump
