--- What `tecs test` runs.
---
--- Every file under `spec/` ending in `_spec.tl` is compiled and run. A spec
--- gets a whole engine: worlds, components, queries, workers and physics all
--- work with no window open, so most of what a game needs to test is testable
--- here rather than by launching it.

local testing <const> = require("tecscli.testing")
local describe <const>, it <const>, check <const> = testing.describe, testing.it, testing.check

describe(
    "{{name}}",
    function()
        it(
            "spawns an entity with a transform",
            function()
                local world <const> = tecs.ecs.newWorld()
                local Transform <const> = tecs.Transform
                local entity <const> = world:spawn(Transform(10, 20))
                world:update(1 / 60)

                local transform <const> = world:get(entity, Transform)
                check.equal(10, transform.x)
                check.equal(20, transform.y)
            end
        )

        it(
            "matches what a query asks for",
            function()
                local world <const> = tecs.ecs.newWorld()
                local Transform <const> = tecs.Transform
                local Marker <const> = tecs.ecs.newTagComponent({name = "Marker"})

                world:spawn(Transform(0, 0), Marker)
                world:spawn(Transform(1, 1))
                world:update(1 / 60)

                local matched = 0
                for _, length in world:query({include = {Transform, Marker}}):iter() do
                    matched = matched + length
                end
                check.equal(1, matched)
            end
        )
    end
)
