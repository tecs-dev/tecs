local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")
local docgen <const> = require("tecs2d.debug.internal.docgen")

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

    it("labels MCP projection and safety annotations", function()
        local reg = makeRegistry()
        local md = docgen.markdown(reg)
        luassert.is_truthy(md:find("MCP tool: `debug_despawn` (destructive)", 1, true))
        luassert.is_truthy(md:find("MCP tool: `debug_mark_list` (read-only, idempotent)", 1, true))
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
end)
