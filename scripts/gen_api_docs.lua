--[[
Generate the API-signature reference pages under docs/tecs2d/api/, one page
per public module, from the Teal *type* API (not by text-parsing source).

For each module in scripts/apidocs.lua's MODULES table this renders every
exported symbol's real signature (argument types, return types, optionality)
and its `---` doc comment, following Teal re-exports back to the record that
actually defines a component's constructor and methods.

Run via `make docs-api`. A spec (spec/tecs2d/api/docgen_spec.tl) compares each
committed page against a fresh render, so forgetting to rerun this fails
`make test`.
]]

-- Make `require("apidocs")` resolvable regardless of cwd nuance (the Makefile
-- target runs this from the repo root).
package.path = "scripts/?.lua;" .. package.path

local apidocs = require("apidocs")

for _, entry in ipairs(apidocs.MODULES) do
   local content = apidocs.render(entry) .. "\n"
   local f = assert(io.open(entry.out, "w"))
   f:write(content)
   f:close()
   print(("Wrote %s (%d bytes)"):format(entry.out, #content))
end
