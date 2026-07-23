require("busted")

local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

describe("tecs2d.debug.internal.cmd.breakpoint", function()
    it("adds, lists, disables, enables, removes, and clears breakpoints",
        function()
            local reg = cmdharness.makeRegistry()
            local added = reg:execute(
                "breakpoint add has=DbgCmdPos lacks=DbgCmdTag")
            luassert.is_true(added.ok)
            luassert.equals(1, added.data.id)

            local listed = reg:execute("breakpoint list")
            luassert.is_true(listed.ok)
            luassert.equals(1, listed.data.count)

            local disabled = reg:execute("breakpoint disable 1")
            luassert.is_true(disabled.ok)
            luassert.is_false(disabled.data.enabled)

            local enabled = reg:execute("breakpoint enable 1")
            luassert.is_true(enabled.ok)
            luassert.is_true(enabled.data.enabled)

            luassert.is_true(reg:execute("breakpoint continue").ok)
            luassert.is_true(reg:execute("breakpoint remove 1").ok)
            luassert.equals(0, reg:execute("breakpoint list").data.count)

            reg:execute("breakpoint add life=spawn")
            reg:execute("breakpoint add popped=Pause")
            luassert.equals(2, reg:execute("breakpoint clear").data.count)
        end)

    it("reports selector errors and completes selector terms", function()
        local reg = cmdharness.makeRegistry()
        local invalid = reg:execute("breakpoint add has=MissingComponent")
        luassert.is_false(invalid.ok)
        luassert.equals("invalid_selector", invalid.code)

        local base, values = reg:complete("breakpoint add has=Dbg")
        luassert.equals("breakpoint add ", base)
        luassert.same({"has=DbgCmdPos", "has=DbgCmdTag"}, values)
    end)
end)
