require("busted")

local tecs <const> = require("tecs")
local worldregistry <const> = require("tecs2d.gfx.internal.worldregistry")

describe("render world registry", function()
    it("uses generational IDs and rejects stale owner tokens after slot reuse", function()
        local first = tecs.newWorld({maxEntities = 8})
        local firstId = worldregistry.register(first)
        local firstEntity = first:spawn()
        local stale = worldregistry.ownerToken(first, firstEntity)
        worldregistry.release(firstId)

        local second = tecs.newWorld({maxEntities = 8})
        local secondId = worldregistry.register(second)
        local secondEntity = second:spawn()
        local staleWorld = worldregistry.resolveOwner(stale)

        assert.not_equals(firstId, secondId)
        assert.is_nil(staleWorld)
        assert.equals(second, worldregistry.resolve(secondId))
        assert.is_not_nil(worldregistry.resolveOwner(
            worldregistry.ownerToken(second, secondEntity)))
        worldregistry.release(secondId)
    end)
end)
