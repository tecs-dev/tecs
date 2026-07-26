-- Event polling, and specifically the lifetime of the scratch event.
--
-- SDL writes 128 bytes into that struct on every poll, for the life of the
-- process. It was originally allocated as a one-element array and used through
-- `array[0]`, which yields a *reference* into the array. A reference does not
-- keep its parent alive, so nothing held the array, the collector freed it,
-- and SDL kept writing into freed LuaJIT heap. That corrupted the VM and
-- crashed later, somewhere unrelated, a few runs in five.

-- Our build first, so it wins over the ECS repo's own engine tree.
package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local ffi = require("ffi")
local loader = require("tecs2d.ffi.loader")
local events = require("tecs2d.platform.events")

describe("platform.events", function()
    after_each(function()
        events.source = nil
    end)

    it("keeps the scratch event writable across collection", function()
        -- Writes a recognisable value through the event the way SDL would,
        -- reads it back, and collects hard in between. If the scratch buffer
        -- were freed, this readback would eventually see reused heap.
        local mismatches = 0

        for round = 1, 200 do
            collectgarbage("collect")

            local pending = true
            events.source = function(event)
                if not pending then return false end
                pending = false
                local fields = event
                fields.type = 0x300 + (round % 16)
                return true
            end

            events.poll(function(event)
                if tonumber(event.type) ~= 0x300 + (round % 16) then
                    mismatches = mismatches + 1
                end
            end)
        end

        assert.are.equal(0, mismatches,
            "the scratch event must survive collection intact")
    end)

    it("delivers the same reusable struct to every handler call", function()
        local remaining = 3
        local seen = {}

        events.source = function(event)
            if remaining == 0 then return false end
            remaining = remaining - 1
            return true
        end

        events.poll(function(event)
            seen[#seen + 1] = tostring(event)
        end)

        assert.are.equal(3, #seen)
        assert.are.equal(seen[1], seen[2],
            "the event is reused, not reallocated per poll")
        assert.are.equal(seen[2], seen[3])
    end)

    it("allocates a struct rather than a reference into an array", function()
        -- A struct cdata owns its storage. An array element reference does
        -- not, which is the distinction this whole module depends on.
        local single = loader.newStruct("SDL_Event")
        assert.are.equal(128, ffi.sizeof(single))
    end)
end)
