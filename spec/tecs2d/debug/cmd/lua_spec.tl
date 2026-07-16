require("busted")

local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local makeRegistry <const> = cmdharness.makeRegistry

describe("tecs2d.debug.internal.cmd.lua", function()
    it("lists loaded modules, with substring filtering", function()
        local reg = makeRegistry()
        local r = reg:execute("lua modules tecs.utils")
        luassert.is_true(r.ok, tostring(r.message))
        local found = false
        for _, m in ipairs(r.data.modules as {string}) do
            if m == "tecs.utils.json" then found = true end
        end
        luassert.is_true(found, "tecs.utils.json should be listed as loaded")
        luassert.is_true((r.data.count as integer) >= 1)
    end)

    it("dumps a module's exports as inert data", function()
        local reg = makeRegistry()
        local r = reg:execute("lua exports tecs.utils.json")
        luassert.is_true(r.ok, tostring(r.message))
        luassert.equals("tecs.utils.json", r.data.module)
        luassert.equals("table", r.data.type)
        local exports = r.data.exports as {string: any}
        luassert.equals("string", type(exports.serialize),
            "functions must come back as tostring text, never callable")
    end)

    it("fails cleanly on a module that is not loaded", function()
        local reg = makeRegistry()
        local missing = reg:execute("lua exports spec.no.such.module")
        luassert.is_false(missing.ok)
        luassert.equals("unknown_module", missing.code)
    end)
end)
