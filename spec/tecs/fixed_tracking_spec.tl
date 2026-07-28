require("busted")

local tecs <const> = require("tecs")
local fixedtracking <const> = require("tecs.internal.fixedtracking")

local Position = tecs.newFFIComponent({
    name = "FixedTrackingSpecPosition",
    container = {},
    fields = {{"x", "float"}},
    defaults = {0},
})

local function findArchetype(world: tecs.World): tecs.Archetype
    local match: tecs.Archetype = nil
    world:forEachArchetype(function(arch: tecs.Archetype)
        if arch:get(Position) ~= nil and ((arch as {string: any}).entities as {integer})[0] > 0 then
            match = arch
        end
    end)
    return match
end

describe(
    "fixed iteration tracking",
    function()
        it(
            "reports tracked writes separately for every catch-up iteration",
            function()
                local world = tecs.newWorld({timestep = 0.01})
                fixedtracking.track(world, Position)
                world:spawn(Position(0))
                local arch = findArchetype(world)

                local samples: {{number}} = {}
                fixedtracking.afterStep(
                    world,
                    function()
                        samples[#samples + 1] = {
                            fixedtracking.currentStep(world),
                            fixedtracking.version(arch, Position),
                            arch:get(Position)[1].x,
                            fixedtracking.wroteThisStep(world, arch, Position) and 1 or 0,
                        }
                    end
                )

                world:addSystem({
                    phase = tecs.phases.FixedUpdate,
                    run = function() local positions = arch:getMut(Position); positions[1].x = positions[1].x + 1 end,
                })

                world:update(0.025)

                assert.equals(2, #samples)
                assert.same({1, 2, 1, 1}, samples[1])
                assert.same({2, 3, 2, 1}, samples[2])
            end
        )

        it(
            "does not replay a write in a later fixed iteration",
            function()
                local world = tecs.newWorld({timestep = 0.01})
                fixedtracking.track(world, Position)
                world:spawn(Position(0))
                local arch = findArchetype(world)
                local shouldWrite = true
                local wrote: {boolean} = {}

                fixedtracking.afterStep(
                    world, function() wrote[#wrote + 1] = fixedtracking.wroteThisStep(world, arch, Position) end
                )
                world:addSystem({
                    phase = tecs.phases.FixedUpdate,
                    run = function()
                        if not shouldWrite then
                            return
                        end
                        arch:getMut(Position)[1].x = 1
                    end,
                })

                world:update(0.01)
                shouldWrite = false
                world:update(0.01)

                assert.same({true, false}, wrote)
            end
        )

        it(
            "lets a later variable-rate write supersede the fixed marker",
            function()
                local world = tecs.newWorld({timestep = 0.01})
                fixedtracking.track(world, Position)
                world:spawn(Position(0))
                local arch = findArchetype(world)

                world:addSystem({
                    phase = tecs.phases.FixedUpdate,
                    run = function() arch:getMut(Position)[1].x = 1 end,
                })
                world:addSystem({
                    phase = tecs.phases.Update,
                    run = function() arch:getMut(Position)[1].x = 2 end,
                })

                world:update(0.01)

                assert.is_false(fixedtracking.wroteThisStep(world, arch, Position))
                assert.equals(2, arch:get(Position)[1].x)
            end
        )
    end
)
