local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local ChildOf <const> = tecs.ecs.ChildOf
local Name <const> = tecs.ecs.Name

describe(
    "sparse relationship module reload",
    function()
        it(
            "reads a committed ChildOf through the public API",
            function()
                local w = tecs.ecs.newWorld()
                local parent = w:spawn(Name("parent"))
                local child = w:spawn(Name("child"), ChildOf(parent))
                w:enqueueCommit()

                luassert.is_not_nil(w:get(child, ChildOf))
                luassert.is_true(w:has(child, ChildOf))
                luassert.is_not_nil(w:getFirstRelationship(child, ChildOf))
                luassert.is_not_nil(w:get(child, ChildOf(parent)))
            end
        )
    end
)
