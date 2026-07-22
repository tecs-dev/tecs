require("busted")
local luassert <const> = require("luassert")
local Popup <const> = require("tecs2d.debug.internal.Popup")

describe("debugger Popup", function()
    it("applies presentation options per document", function()
        local popup = Popup.new()
        local blocks: {{string}} = {{"A = true"}}
        popup:show({
            lines = {"body"},
            title = "command help",
            modal = true,
            closable = true,
            language = "lua",
            blocks = blocks,
            maxColumns = 2,
        })

        luassert.is_true(popup.shown)
        luassert.equals("command help", popup.title)
        luassert.is_true(popup.modal)
        luassert.is_true(popup.closable)
        luassert.equals("lua", popup.language)
        luassert.equals(blocks, popup.semanticBlocks)
        luassert.equals(2, popup.maxColumns)
    end)

    it("only dismisses through an opted-in close control", function()
        local popup = Popup.new()
        popup:show({lines = {"body"}, title = "title"})
        popup.closeX, popup.closeY, popup.closeRadius = 20, 20, 8
        luassert.is_false(popup:pressClose(20, 20))
        luassert.is_true(popup.shown)

        popup:show({lines = {"body"}, title = "title", closable = true})
        popup.closeX, popup.closeY, popup.closeRadius = 20, 20, 8
        luassert.is_false(popup:pressClose(40, 40))
        luassert.is_true(popup:pressClose(20, 20))
        luassert.is_false(popup.shown)
    end)
end)
