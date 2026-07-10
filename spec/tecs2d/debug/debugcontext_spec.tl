require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

describe("tecs2d.debug.internal.debugcontext", function()
    describe("encodeGroups", function()
        it("coalesces contiguous ids into ranges per value", function()
            local out = debugcontext.encodeGroups({
                [8] = "boss", [9] = "boss", [10] = "boss", [12] = "boss",
                [3] = "crew",
            })
            luassert.equals("8-10,12", out.boss)
            luassert.equals("3", out.crew)
        end)

        it("sorts unsorted ids before coalescing", function()
            local out = debugcontext.encodeGroups({[5] = "a", [3] = "a", [4] = "a"})
            luassert.equals("3-5", out.a)
        end)

        it("returns an empty map for an empty input", function()
            local out = debugcontext.encodeGroups({})
            luassert.is_nil(next(out))
        end)

        it("keeps two-id runs as a range and lone ids as singles", function()
            local out = debugcontext.encodeGroups({[1] = "x", [2] = "x", [9] = "x"})
            luassert.equals("1-2,9", out.x)
        end)
    end)

    describe("event feed", function()
        it("logs one key=value line per action to tecs2d.debug.events", function()
            local logging = require("tecs.utils.logging")
            local lines: {string} = {}
            local oldSink = logging.sink
            logging.setSink({
                write = function(self: any, ...: string): any
                    lines[#lines + 1] = table.concat({...})
                    return self
                end,
            } as FILE)

            local ctx = debugcontext.new()
            debugcontext.pushEvent(ctx, "selection", {selected = 2, clicked = 42})
            debugcontext.pushEvent(ctx, "open")

            logging.setSink(oldSink)
            luassert.equals(2, #lines)
            luassert.matches("tecs2d%.debug%.events INFO: selection clicked=42 selected=2", lines[1])
            luassert.matches("tecs2d%.debug%.events INFO: open", lines[2])
        end)
    end)

    describe("selection helpers", function()
        it("adds unique ids, ignores 0, and removes in place", function()
            local ctx = debugcontext.new()
            debugcontext.addSelected(ctx, 5)
            debugcontext.addSelected(ctx, 5)
            debugcontext.addSelected(ctx, 0)
            debugcontext.addSelected(ctx, 7)
            luassert.same({5, 7}, ctx.selected)
            luassert.is_true(debugcontext.isSelected(ctx, 5))
            luassert.is_false(debugcontext.isSelected(ctx, 6))

            debugcontext.removeSelected(ctx, 5)
            luassert.same({7}, ctx.selected)
            debugcontext.removeSelected(ctx, 42)
            luassert.same({7}, ctx.selected)
        end)
    end)
end)
