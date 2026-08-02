local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local process = require("tecs.internal.runtime")
local runtime = process

local NAMES = {
    "spec.runtime.first",
    "spec.runtime.second",
    "spec.runtime.later",
    "spec.runtime.new",
    "spec.runtime.unowned",
}

local function clear()
    for _, name in ipairs(NAMES) do
        process.unregister(name)
    end
end

describe("the internal process runtime", function()
    before_each(clear)
    after_each(clear)

    it("does nothing when no process-wide source is active", function()
        assert.are.equal(0, runtime.poll())
    end)

    it("polls active sources in deterministic order and sums their work", function()
        local called = {}
        process.register("spec.runtime.second", 20, function()
            called[#called + 1] = "second"
            return 2
        end, nil)
        process.register("spec.runtime.first", 10, function()
            called[#called + 1] = "first"
            return 1
        end, nil)

        assert.are.equal(3, runtime.poll())
        assert.are.same({ "first", "second" }, called)
    end)

    it("uses a stable turn when a listener changes registration", function()
        local called = {}
        process.register("spec.runtime.first", 10, function()
            called[#called + 1] = "first"
            process.unregister("spec.runtime.later")
            process.unregister("spec.runtime.first")
            process.register("spec.runtime.new", 15, function()
                called[#called + 1] = "new"
                return 1
            end, nil)
            return 1
        end, nil)
        process.register("spec.runtime.later", 20, function()
            called[#called + 1] = "later"
            return 1
        end, nil)

        assert.are.equal(1, runtime.poll())
        assert.are.same({ "first" }, called)

        assert.are.equal(1, runtime.poll())
        assert.are.same({ "first", "new" }, called)
    end)

    it("rejects two active sources with the same name", function()
        process.register("spec.runtime.first", 10, function()
            return 0
        end, nil)

        assert.has_error(function()
            process.register("spec.runtime.first", 20, function()
                return 0
            end, nil)
        end, "tecs: runtime source spec.runtime.first is already registered")
    end)

    it("shuts active sources down in reverse pump order", function()
        local order = {}
        process.register("spec.runtime.first", 10, function()
            return 0
        end, function()
            order[#order + 1] = "first"
            process.unregister("spec.runtime.first")
        end)
        process.register("spec.runtime.second", 20, function()
            return 0
        end, function()
            order[#order + 1] = "second"
            process.unregister("spec.runtime.second")
        end)

        local ok, reason = runtime.shutdown()
        assert.is_true(ok, reason)
        assert.same({ "second", "first" }, order)
    end)

    it("reports an active source without a shutdown owner", function()
        process.register("spec.runtime.unowned", 10, function()
            return 0
        end, nil)

        local ok, reason = runtime.shutdown()
        assert.is_false(ok)
        assert.is_truthy(reason:find("spec.runtime.unowned", 1, true))
    end)
end)
