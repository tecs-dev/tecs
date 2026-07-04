--- Tecs Example Template
--- Copy this directory and rename it to create a new example.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")

local lg <const> = love.graphics

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local record Position is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x: number, y: number): Position
end

tecs.newComponent({
    name = "Position",
    container = Position,
    fields = {"x", "y"},
    init = function(instance: Position, x: number, y: number)
        instance.x = x
        instance.y = y
    end
})

-------------------------------------------------------------------------------
-- Game
-------------------------------------------------------------------------------

local function examplePlugin(world: tecs.World)
    -- Spawn an entity
    world:spawn(Position(400, 300))

    local query = world:query({ name = "Positions", include = {Position} })

    -- Render system
    world:addSystem({
        name = "Render",
        phase = tecs.phases.Render,
        run = function()
            lg.setColor(1, 1, 1)
            for archetype, len in query:iter() do
                local positions = archetype:get(Position)
                for i = 1, len do
                    local pos = positions[i]
                    lg.circle("fill", pos.x, pos.y, 20)
                end
            end
        end
    })

end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        examplePlugin(world)
    end,
})
