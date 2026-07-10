require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local annotations <const> = require("tecs2d.debug.internal.annotations")

local function rect(over: {string: any}): annotations.Annotation
    local a: {string: any} = {
        kind = "rect", x = 0, y = 0, w = 10, h = 10, radius = 0, x2 = 0, y2 = 0,
        text = "", r = 1, g = 1, b = 0, a = 0.8, lineWidth = 4, fontSize = 14,
        entity = 0,
    }
    for k, v in pairs(over or {}) do a[k] = v end
    return a as annotations.Annotation
end

describe("tecs2d.debug.internal.annotations store", function()
    it("assigns increasing ids", function()
        local store = annotations.newStore()
        luassert.equals(1, store:add(rect({})))
        luassert.equals(2, store:add(rect({})))
        luassert.equals(2, #store.list)
    end)

    it("clears by id, by tag, or everything", function()
        local store = annotations.newStore()
        local a = store:add(rect({tag = "path"}))
        store:add(rect({tag = "path"}))
        store:add(rect({}))

        luassert.equals(1, store:clear(nil, a))
        luassert.equals(1, store:clear("path", nil))
        luassert.equals(1, store:clear())
        luassert.equals(0, #store.list)
    end)

    it("sweeps expired annotations and dead-entity pins", function()
        local store = annotations.newStore()
        store:add(rect({expiresAt = 5}))
        store:add(rect({entity = 42}))
        store:add(rect({}))

        local alive: {integer: boolean} = {[42] = true}
        store:sweep(1, function(eid: integer): boolean return alive[eid] == true end)
        luassert.equals(3, #store.list, "nothing should expire yet")

        store:sweep(6, function(eid: integer): boolean return alive[eid] == true end)
        luassert.equals(2, #store.list, "timed annotation should expire")

        alive[42] = nil
        store:sweep(6, function(eid: integer): boolean return alive[eid] == true end)
        luassert.equals(1, #store.list, "dead-entity pin should be removed")
    end)
end)
