--[[
Drift check for the generated API-signature reference pages.

For every module in scripts/apidocs.lua's MODULES table this re-renders the
page from the live Teal type API and asserts it matches the committed file
byte-for-byte, so a source change that alters a public signature (or a missing
`make docs-api`) turns the suite red -- exactly like the debug docgen spec.

The renderer is a plain-Lua build tool that drives the Teal compiler, so it is
loaded through an aliased `require` (which the Teal checker leaves untyped)
after putting scripts/ on the package path. Tests run from the repo root, the
same working directory `make docs-api` uses.
]]

local luassert <const> = require("luassert")

package.path = "scripts/?.lua;" .. package.path
local req <const> = require
local apidocs <const> = req("apidocs")

describe("tecs2d.api.docgen", function()
    local mods = apidocs.MODULES as {{string:any}}

    it("documents the priority modules (gfx, world, input, events)", function()
        local outs: {string:boolean} = {}
        for _, entry in ipairs(mods) do
            outs[entry.out as string] = true
        end
        luassert.is_truthy(outs["docs/tecs2d/api/gfx.md"])
        luassert.is_truthy(outs["docs/tecs2d/api/world.md"])
        luassert.is_truthy(outs["docs/tecs2d/api/input.md"])
        luassert.is_truthy(outs["docs/tecs2d/api/events.md"])
    end)

    for _, entry in ipairs(mods) do
        local out = entry.out as string
        it("matches the committed " .. out .. " (run `make docs-api` after API changes)", function()
            local f = io.open(out, "r")
            luassert.is_truthy(f, out .. " is missing; run `make docs-api`")
            local committed = (f as FILE):read("*a")
            (f as FILE):close()
            local fresh = (apidocs.render(entry) as string) .. "\n"
            luassert.equals(fresh, committed,
                out .. " is stale; run `make docs-api` and commit the result")
        end)
    end
end)
