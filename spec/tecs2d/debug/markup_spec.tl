require("busted")
local luassert <const> = require("luassert")
local markup <const> = require("tecs2d.debug.internal.markup")

describe("debugger popup markup", function()
    it("parses named blocks and inline styles", function()
        local document, err = markup.parse([[
@title select [arg]<target>[/arg]
@text Add an entity to the selection.
@def replace
Replace the current selection.
@endDef
@code lua
world:spawn(Transform(10, 20))
@endCode
@columns auto
@column
@code console
select 42
@endCode
@column
@code console
select boss replace=true
@endCode
@endColumns]])
        luassert.is_nil(err)
        luassert.equals("select <target>", document.title.text)
        luassert.equals("arg", document.title.spans[2].style)
        luassert.equals("flow", document.blocks[1].kind)
        luassert.equals("definitionTerm", document.blocks[1].lines[2].style)
        luassert.equals("lua", document.blocks[1].lines[4].language)
        luassert.equals("columns", document.blocks[2].kind)
        luassert.equals(2, #document.blocks[2].columns)
        luassert.equals("console", document.blocks[2].columns[1][1].language)
    end)

    it("reports a mismatched named terminator", function()
        local document, err = markup.parse([[
@code lua
return true
@endColumns]])
        luassert.is_nil(document)
        luassert.matches("expected @endCode, found @endColumns", err, 1, true)
    end)

    it("requires explicit column boundaries and terminators", function()
        local document, err = markup.parse([[
@columns auto
plain text
@endColumns]])
        luassert.is_nil(document)
        luassert.matches("expected @column", err, 1, true)
    end)

    it("treats bracketed code as literal text", function()
        local document = markup.new("code")
        markup.code(document, "lua", "values[key] = rows[arg]")
        local line = document.blocks[1].lines[1]
        luassert.equals("values[key] = rows[arg]", line.text)
        luassert.equals(1, #line.spans)
        luassert.equals("code", line.spans[1].style)
    end)
end)
