-- Rendering-domain infrastructure that does not need a GPU.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local timing = require("tecs.timing")
local domainmetrics = require("tecs.internal.render.domainmetrics")
local meshconstants = require("tecs.internal.render.meshconstants")
local renderprofile = require("tecs.internal.render.renderprofile")

local function stages()
    local byName = {}
    for _, row in ipairs(timing.report()) do
        byName[row.name] = row
    end
    return byName
end

describe("rendering domains", function()
    local wasEnabled

    before_each(function()
        wasEnabled = timing.enabled
        timing.enable()
        timing.reset()
    end)

    after_each(function()
        timing.reset()
        timing.enabled = wasEnabled
    end)

    it("publishes the common counters through one contract", function()
        local target = {
            count = 0,
            dropped = 0,
            rewritten = 0,
            extractSeconds = function() return 0 end,
        }

        domainmetrics.publish(target, { count = 17, dropped = 3, rewritten = 5 })

        assert.are.equal(17, target.count)
        assert.are.equal(3, target.dropped)
        assert.are.equal(5, target.rewritten)
    end)

    it("keeps mesh alpha identities in one CPU table", function()
        assert.are.equal(0, meshconstants.ALPHA_OPAQUE)
        assert.are.equal(1, meshconstants.ALPHA_MASK)
        assert.are.equal(2, meshconstants.ALPHA_BLEND)
    end)

    it("attributes domain extraction and one aggregate sample separately", function()
        timing.finish(renderprofile.sprites, timing.begin())
        timing.finish(renderprofile.meshes, timing.begin())
        timing.mark(renderprofile.total, 0.003)

        local report = stages()
        assert.are.equal(1, report.extractSprites.frames)
        assert.are.equal(1, report.extractMeshes.frames)
        assert.are.equal(1, report.extract.frames)
        assert.are.equal(3, report.extract.mean)
    end)
end)
