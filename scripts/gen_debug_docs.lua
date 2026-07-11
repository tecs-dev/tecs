--[[
Generate docs/tecs2d/debug-reference.md from the debugger command registry.

Run via `make docs-debug`. Builds the same mock-backed registry the unit
specs use (spec/tecs2d/debug/cmdharness), renders it with
tecs2d.debug.internal.docgen, and writes the page. A spec asserts the
committed page matches a fresh render, so forgetting to rerun this fails
`make test`.
]]

local OUT = "docs/tecs2d/debug-reference.md"

local cmdharness = require("spec.tecs2d.debug.cmdharness")
local docgen = require("tecs2d.debug.internal.docgen")

local reg = cmdharness.makeRegistry()
local md = docgen.markdown(reg) .. "\n"

local f = assert(io.open(OUT, "w"))
f:write(md)
f:close()
print(("Wrote %s (%d bytes, %d commands)"):format(OUT, #md, #reg.names))
