require("busted")

local luassert <const> = require("luassert")
local wakeheap <const> = require("tecs2d.internal.wakeheap")

-- Draining a heap into a list of its values, earliest first.
local function drain(heap: wakeheap.Heap): {string}
    local out: {string} = {}
    while wakeheap.peek(heap) do
        local _, _, value = wakeheap.pop(heap)
        out[#out + 1] = value as string
    end
    return out
end

describe("tecs2d.internal.wakeheap", function()
    it("is empty to start with", function()
        local heap = wakeheap.new()
        luassert.equals(0, heap.size)
        luassert.is_nil(wakeheap.peek(heap))
        local key, seq, value = wakeheap.pop(heap)
        luassert.is_nil(key)
        luassert.is_nil(seq)
        luassert.is_nil(value)
    end)

    it("returns entries in key order regardless of push order", function()
        local heap = wakeheap.new()
        wakeheap.push(heap, 30, 1, "c")
        wakeheap.push(heap, 10, 2, "a")
        wakeheap.push(heap, 20, 3, "b")

        luassert.equals(10, wakeheap.peek(heap))
        luassert.same({"a", "b", "c"}, drain(heap))
        luassert.equals(0, heap.size)
    end)

    it("breaks ties on seq, not push order", function()
        local heap = wakeheap.new()
        wakeheap.push(heap, 5, 3, "third")
        wakeheap.push(heap, 5, 1, "first")
        wakeheap.push(heap, 5, 2, "second")

        luassert.same({"first", "second", "third"}, drain(heap))
    end)

    it("orders a mixed population deterministically", function()
        local heap = wakeheap.new()
        -- Interleaved keys and seqs, pushed in an order that matches neither.
        local pushes: {{integer, integer, string}} = {
            {2, 7, "2:7"}, {1, 9, "1:9"}, {2, 3, "2:3"},
            {1, 4, "1:4"}, {3, 1, "3:1"}, {1, 6, "1:6"},
        }
        for i = 1, #pushes do
            wakeheap.push(heap, pushes[i][1], pushes[i][2], pushes[i][3])
        end
        luassert.same({"1:4", "1:6", "1:9", "2:3", "2:7", "3:1"}, drain(heap))
    end)

    it("keeps ordering across interleaved pushes and pops", function()
        local heap = wakeheap.new()
        wakeheap.push(heap, 10, 1, "a")
        wakeheap.push(heap, 30, 2, "c")

        local _, _, first = wakeheap.pop(heap)
        luassert.equals("a", first)

        -- Something scheduled earlier than what is already queued.
        wakeheap.push(heap, 20, 3, "b")
        wakeheap.push(heap, 5, 4, "sooner")
        luassert.same({"sooner", "b", "c"}, drain(heap))
    end)

    it("survives a churn of pushes and pops", function()
        local heap = wakeheap.new()
        local seq = 0
        local expected: {integer} = {}
        -- Deterministic pseudo-random keys: a fixed multiplicative sequence.
        local x = 7
        for _ = 1, 400 do
            x = (x * 37 + 11) % 251
            seq = seq + 1
            wakeheap.push(heap, x, seq, x)
            expected[#expected + 1] = x
            if seq % 3 == 0 then
                local _, _, value = wakeheap.pop(heap)
                -- The smallest outstanding key comes out.
                local smallest = math.huge
                for i = 1, #expected do
                    if expected[i] < smallest then smallest = expected[i] end
                end
                luassert.equals(smallest, value as number)
                for i = 1, #expected do
                    if expected[i] == smallest then
                        table.remove(expected, i)
                        break
                    end
                end
            end
        end
        luassert.equals(#expected, heap.size)
    end)

    it("clears without leaving entries behind", function()
        local heap = wakeheap.new()
        for i = 1, 10 do wakeheap.push(heap, i, i, "v" .. tostring(i)) end
        wakeheap.clear(heap)

        luassert.equals(0, heap.size)
        luassert.is_nil(wakeheap.peek(heap))
        luassert.is_nil(heap.keys[1])
        luassert.is_nil(heap.values[1])

        wakeheap.push(heap, 3, 1, "fresh")
        luassert.same({"fresh"}, drain(heap))
    end)

    it("carries any value, not just numbers", function()
        local heap = wakeheap.new()
        local row = {event = "keypressed"}
        wakeheap.push(heap, 1, 1, row)
        local _, _, value = wakeheap.pop(heap)
        luassert.equals(row, value)
    end)

    it("reports the key and seq it was given", function()
        local heap = wakeheap.new()
        wakeheap.push(heap, 42, 7, "x")
        local key, seq, value = wakeheap.pop(heap)
        luassert.equals(42, key)
        luassert.equals(7, seq)
        luassert.equals("x", value)
    end)
end)
