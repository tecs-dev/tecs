require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local framecapture <const> = require("tecs2d.debug.internal.framecapture")

-- A minimal love.thread.Channel backed by a FIFO queue.
local function makeChannel(): any
    local q: {any} = {}
    return {
        push = function(_self: any, v: any) q[#q + 1] = v end,
        pop = function(_self: any): any return table.remove(q, 1) end,
        demand = function(_self: any): any return table.remove(q, 1) end,
        clear = function(_self: any) for i = #q, 1, -1 do q[i] = nil end end,
        getCount = function(_self: any): number return #q end,
    }
end

describe("tecs2d.debug.internal.framecapture", function()
    local oldFs: any
    local oldThread: any
    local channels: {string: any}
    local frameName: string
    local doneName: string
    local threadWaited: boolean

    before_each(function()
        oldFs = love.filesystem
        oldThread = love.thread
        channels = {}
        frameName = ""
        doneName = ""
        threadWaited = false

        love.filesystem = {
            createDirectory = function(_path: string): boolean return true end,
        } as any
        love.thread = {
            getChannel = function(name: string): any
                if not channels[name] then channels[name] = makeChannel() end
                return channels[name]
            end,
            newThread = function(_src: string): any
                return {
                    start = function(_self: any, a: string, b: string)
                        frameName = a
                        doneName = b
                    end,
                    wait = function(_self: any) threadWaited = true end,
                }
            end,
        } as any
    end)

    after_each(function()
        love.filesystem = oldFs
        love.thread = oldThread
    end)

    local function newEncoder(ringSize?: integer): framecapture.Encoder
        return framecapture.new({
            dir = "rec/clip.frames",
            format = "png",
            ringSize = ringSize or 3,
            token = "spec",
        })
    end

    it("submits frames with contiguous indices and paths under dir", function()
        local enc = newEncoder()
        luassert.is_true(enc:submit({} as any))
        luassert.is_true(enc:submit({} as any))
        local fc = channels[frameName] as any
        local first = fc:pop() as {string: any}
        local second = fc:pop() as {string: any}
        luassert.equals(0, first.i)
        luassert.equals(1, second.i)
        luassert.equals("rec/clip.frames/frame_000000.png", first.path)
        luassert.equals("rec/clip.frames/frame_%06d.png", enc:pattern())
    end)

    it("drops frames when the ring is full and after finish", function()
        local enc = newEncoder(2)
        luassert.is_true(enc:submit({} as any))
        luassert.is_true(enc:submit({} as any))
        luassert.is_false(enc:submit({} as any))
        luassert.equals(1, enc.dropped)
        luassert.equals(2, enc.inFlight)

        enc:finish()
        luassert.is_false(enc:submit({} as any))
    end)

    it("drains acknowledgements into written and inFlight", function()
        local enc = newEncoder()
        enc:submit({} as any)
        enc:submit({} as any)
        local dc = channels[doneName] as any
        dc:push({i = 0})
        dc:push({i = 1})
        enc:drain()
        luassert.equals(2, enc.written)
        luassert.equals(0, enc.inFlight)
    end)

    it("records a worker encode error and keeps counting", function()
        local enc = newEncoder()
        enc:submit({} as any)
        local dc = channels[doneName] as any
        dc:push({i = 0, err = "boom"})
        enc:drain()
        luassert.equals("boom", enc.error)
        luassert.equals(0, enc.inFlight)
        luassert.equals(0, enc.written)
    end)

    it("finish sends one stop sentinel and isDone follows the done ack", function()
        local enc = newEncoder()
        enc:finish()
        enc:finish()
        local fc = channels[frameName] as any
        local sentinel = fc:pop() as {string: any}
        luassert.is_true(sentinel.stop as boolean)
        luassert.is_nil(fc:pop())

        luassert.is_false(enc:isDone())
        local dc = channels[doneName] as any
        dc:push({done = true, written = 0})
        enc:drain()
        luassert.is_true(enc:isDone())
    end)

    it("shutdown pushes stop when needed and waits for the worker", function()
        local enc = newEncoder()
        enc:shutdown()
        local fc = channels[frameName] as any
        local sentinel = fc:pop() as {string: any}
        luassert.is_true(sentinel.stop as boolean)
        luassert.is_true(threadWaited)
        luassert.is_true(enc.finishing)
    end)
end)
