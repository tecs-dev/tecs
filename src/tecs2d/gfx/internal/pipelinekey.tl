--- Shared key for accessing the render pipeline from world.resources.
--- This module avoids circular dependencies between render.init and sprite.init.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")

local record pipeline_key
    --- Resource key for accessing the render pipeline
    PIPELINE: tecs.Key<types.Pipeline>
end

pipeline_key.PIPELINE = tecs.newKey()

return pipeline_key
