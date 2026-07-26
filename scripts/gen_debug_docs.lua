--[[
Generate the MCP and debugger docs from the tool definitions and the
command registry:

 - docs/tecs/debug-reference.md, the full command reference
 - docs/tecs/mcp/tools.md, the MCP tools page: kernel tools rendered
   from tecs.mcp.tools plus the projected cmd_* tool index

Run via `make docs-debug`. Builds the same mock-backed registry the unit
specs use (spec/tecs/debug/cmdharness) and renders it with
tecs.debug.internal.docgen. A spec asserts both committed outputs match a
fresh render, so forgetting to rerun this fails `make test`.
]]

local REFERENCE = "docs/tecs/debug-reference.md"
local TOOLS_DOC = "docs/tecs/mcp/tools.md"
local MANIFEST = "docs/tecs/mcp/default-tools.json"

local cmdharness = require("spec.tecs.debug.cmdharness")
local docgen = require("tecs.debug.internal.docgen")

local reg = cmdharness.makeRegistry()

local md = docgen.markdown(reg) .. "\n"
local f = assert(io.open(REFERENCE, "w"))
f:write(md)
f:close()
print(("Wrote %s (%d bytes, %d commands)"):format(REFERENCE, #md, #reg.names))

local tools = docgen.toolsPage(reg) .. "\n"
local tf = assert(io.open(TOOLS_DOC, "w"))
tf:write(tools)
tf:close()
print(("Wrote %s (%d bytes)"):format(TOOLS_DOC, #tools))

local manifest = docgen.mcpToolManifest(reg) .. "\n"
local mf = assert(io.open(MANIFEST, "w"))
mf:write(manifest)
mf:close()
print(("Wrote %s (%d bytes)"):format(MANIFEST, #manifest))
