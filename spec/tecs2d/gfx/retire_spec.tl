require("busted")

local retire <const> = require("tecs2d.gfx.internal.gpu.retire")

local record FakeObject
    released: boolean
    release: function(self: FakeObject): boolean
end

local function newFake(): FakeObject
    local obj: FakeObject = { released = false }
    obj.release = function(self: FakeObject): boolean
        self.released = true
        return true
    end
    return obj
end

describe("gpu retire list", function()
    before_each(function()
        -- Drain anything left over from other specs.
        retire.tick()
        retire.tick()
    end)

    it("releases pushed objects two ticks later", function()
        local obj = newFake()
        retire.push(obj)
        assert.equals(1, retire.heldCount())

        retire.tick()
        assert.is_false(obj.released)
        assert.equals(1, retire.heldCount())

        retire.tick()
        assert.is_true(obj.released)
        assert.equals(0, retire.heldCount())
    end)

    it("staggers releases by push frame", function()
        local first = newFake()
        retire.push(first)
        retire.tick()

        local second = newFake()
        retire.push(second)
        retire.tick()

        assert.is_true(first.released)
        assert.is_false(second.released)

        retire.tick()
        assert.is_true(second.released)
    end)

    it("ignores nil pushes", function()
        retire.push(nil)
        assert.equals(0, retire.heldCount())
        retire.tick()
    end)
end)
