--[[
Generate the debugger docs from the command registry:

 - docs/tecs2d/debug-reference.md, the full command reference
 - the debug_* tool index in docs/tecs2d/mcp/tools.md, spliced between
   the GENERATED markers

Run via `make docs-debug`. Builds the same mock-backed registry the unit
specs use (spec/tecs2d/debug/cmdharness) and renders it with
tecs2d.debug.internal.docgen. A spec asserts both committed outputs match a
fresh render, so forgetting to rerun this fails `make test`.
]]

local REFERENCE = "docs/tecs2d/debug-reference.md"
local TOOLS_DOC = "docs/tecs2d/mcp/tools.md"
local BEGIN_MARK = "<!-- BEGIN GENERATED debug-tools-index (make docs-debug) -->"
local END_MARK = "<!-- END GENERATED debug-tools-index -->"

local cmdharness = require("spec.tecs2d.debug.cmdharness")
local docgen = require("tecs2d.debug.internal.docgen")

local reg = cmdharness.makeRegistry()

local md = docgen.markdown(reg) .. "\n"
local f = assert(io.open(REFERENCE, "w"))
f:write(md)
f:close()
print(("Wrote %s (%d bytes, %d commands)"):format(REFERENCE, #md, #reg.names))

local rf = assert(io.open(TOOLS_DOC, "r"))
local tools = rf:read("*a")
rf:close()
local head = tools:find(BEGIN_MARK, 1, true)
local tail = tools:find(END_MARK, 1, true)
assert(head and tail, TOOLS_DOC .. " is missing the GENERATED debug-tools-index markers")
local spliced = tools:sub(1, head + #BEGIN_MARK - 1) .. "\n" ..
    docgen.toolIndex(reg) .. "\n" .. tools:sub(tail)
local wf = assert(io.open(TOOLS_DOC, "w"))
wf:write(spliced)
wf:close()
print(("Spliced the debug tool index into %s"):format(TOOLS_DOC))
