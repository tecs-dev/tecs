--- Leaf resource key for the optional debugger render world.

local tecs <const> = require("tecs")

local record toolworldkey
    record PipelineRef
        getWorldId: function(self: PipelineRef): integer
    end

    record State
        world: tecs.World
        pipeline: PipelineRef
        cursorAlphaEntity: integer
    end

    KEY: tecs.Key<State>
end

toolworldkey.KEY = tecs.newKey("tecs2d.debug.toolWorld")

return toolworldkey
