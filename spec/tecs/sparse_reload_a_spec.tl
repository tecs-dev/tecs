local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Keep this in a separate file from sparse_reload_b_spec: Busted's default
-- insulation reloads Lua modules between the files while LuaJIT retains FFI
-- cdefs and metatypes for the life of the process.
describe(
    "sparse relationship module reload setup",
    function()
        it(
            "commits an unrelated world",
            function()
                local w = tecs.newWorld()
                w:spawn(tecs.builtins.Name("first"))
                w:commit()
                luassert.is_true(true)
            end
        )
    end
)
