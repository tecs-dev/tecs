local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")
local commands <const> = require("tecs2d.debug.commands")
local docgen <const> = require("tecs2d.debug.internal.docgen")
local mcptools <const> = require("tecs2d.mcp.tools")

local makeRegistry <const> = cmdharness.makeRegistry

describe("tecs2d.debug.internal.docgen", function()
    it("renders every registered command grouped by section", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        for _, name in ipairs(reg.names) do
            luassert.is_truthy(md:find("### `" .. name, 1, true),
                "missing a section for command '" .. name .. "'")
        end
        for _, section in ipairs({"Select", "Edit", "Render", "Engine", "Capture", "Session"}) do
            luassert.is_truthy(md:find("\n## " .. section .. "\n", 1, true),
                "missing section heading '" .. section .. "'")
        end
    end)

    it("anchors every heading and deepens the outline", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        luassert.equals(1, md:find("---\noutline: [2, 3]\n---", 1, true))
        luassert.is_truthy(md:find("{#cmd-select}", 1, true))
        luassert.is_truthy(md:find("{#cmd-mark-list}", 1, true))
    end)

    it("renders declared output schemas in a details block", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        luassert.is_truthy(md:find("::: details Result data schema", 1, true))
        luassert.is_truthy(md:find('"modified": {', 1, true))
    end)

    it("renders metadata screenshots opted into docs", function()
        local reg = makeRegistry()
        reg:add({
            name = "shotcmd",
            shortHelp = "a command with screenshots",
            metadata = {screenshots = {
                {file = "./assets/debug/shot.png", alt = "the overlay", docs = true},
                {file = "./assets/debug/hidden.png", alt = "not for docs"},
            }},
            run = function(_v: {string: any}, _p: {string}): commands.Result
                return {ok = true}
            end,
        })
        local md = docgen.markdown(reg)
        luassert.is_truthy(md:find("![the overlay](./assets/debug/shot.png)", 1, true))
        luassert.is_nil(md:find("hidden.png", 1, true))
    end)

    it("indexes every projected tool with a reference link", function()
        local reg = makeRegistry()
        local index = docgen.toolIndex(reg)
        luassert.is_truthy(index:find("| [`cmd_modify`](../debug-reference#cmd-modify) |", 1, true))
        luassert.is_truthy(index:find("| [`cmd_mark_list`](../debug-reference#cmd-mark-list) |", 1, true))
        luassert.is_nil(index:find("cmd_help", 1, true), "mcp = false commands must not be indexed")
    end)

    it("labels MCP projection and safety annotations", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        luassert.is_truthy(md:find("MCP tool: `cmd_despawn` (destructive)", 1, true))
        luassert.is_truthy(md:find("MCP tool: `cmd_mark_list` (read-only, idempotent)", 1, true))
        luassert.is_truthy(md:find("Overlay only; not projected over MCP.", 1, true))
    end)

    it("escapes markdown hazards outside code spans", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        for line in md:gmatch("[^\n]+") do
            if line:sub(1, 1) == "|" then
                -- Three columns means exactly four unescaped pipes; a stray
                -- pipe from an unescaped help string would add a fifth.
                local _, pipes = (" " .. line):gsub("[^\\]|", "")
                luassert.equals(4, pipes, "table row with stray pipe: " .. line)
            end
        end
    end)

    it("matches the committed docs page (run `make docs-debug` after command changes)", function()
        local f = io.open("docs/tecs2d/debug-reference.md", "r")
        luassert.is_truthy(f, "docs/tecs2d/debug-reference.md is missing; run `make docs-debug`")
        local committed = f:read("*a")
        f:close()
        local fresh = docgen.markdown(makeRegistry()) .. "\n"
        luassert.equals(fresh, committed,
            "debug-reference.md is stale; run `make docs-debug` and commit the result")
    end)

    it("renders every kernel tool from the MCP tool definitions", function()
        local page = docgen.toolsPage(makeRegistry())
        for _, tool in ipairs(mcptools.list) do
            luassert.is_truthy(page:find("### `" .. tool.name .. "` {#" .. tool.name .. "}", 1, true),
                "missing a kernel section for tool '" .. tool.name .. "'")
        end
        luassert.is_truthy(page:find("Annotations: read-only, idempotent.", 1, true))
        luassert.is_truthy(page:find("Annotations: destructive.", 1, true))
        -- Array item objects recurse one level into the arguments table.
        luassert.is_truthy(page:find("| `points[].x` |", 1, true))
        luassert.is_truthy(page:find("| `points` | object[] | yes |", 1, true))
    end)

    it("folds the projected tool index into the tools page", function()
        local page = docgen.toolsPage(makeRegistry())
        luassert.is_truthy(page:find("Do not edit by hand", 1, true))
        luassert.is_truthy(page:find("\n## Command tools\n", 1, true))
        luassert.is_truthy(page:find("| [`cmd_modify`](../debug-reference#cmd-modify) |", 1, true))
        luassert.is_nil(page:find("cmd_help", 1, true), "mcp = false commands must not be indexed")
    end)

    it("matches the committed mcp/tools.md (run `make docs-debug` after tool or command changes)", function()
        local f = io.open("docs/tecs2d/mcp/tools.md", "r")
        luassert.is_truthy(f, "docs/tecs2d/mcp/tools.md is missing; run `make docs-debug`")
        local committed = f:read("*a")
        f:close()
        local fresh = docgen.toolsPage(makeRegistry()) .. "\n"
        luassert.equals(fresh, committed,
            "mcp/tools.md is stale; run `make docs-debug` and commit the result")
    end)
end)
