local tecs <const> = require("tecs")
local pipeline <const> = require("tecs_render.internal.pipeline")
local camera <const> = require("tecs_render.internal.camera")
local types <const> = require("tecs_render.types")

local record tecs_render
    --- The render pipeline context key.
    PIPELINE: tecs.Key<pipeline.Pipeline>

    --- Create a new camera.
    --- @param config Camera configuration.
    --- @return A new camera instance.
    newCamera: function(config: camera.CameraConfig): types.Camera

    --- Create a new render pipeline, automatically register it with the world, and return it.
    --- @param config Pipeline configuration including world.
    --- @return The created pipeline instance.
    newPipeline: function(config: pipeline.RenderConfig): types.Pipeline

    -- Type re-exports from internal modules
    type Camera = types.Camera
    type Pipeline = types.Pipeline
    type LayerDecorator = types.LayerDecorator
    type Layer = types.Layer
    type CameraConfig = camera.CameraConfig
    type ScaleMode = camera.ScaleMode
    type RenderConfig = pipeline.RenderConfig
    type OnDraw = pipeline.OnDraw

    -- Constant re-exports
    UNLIT_FLAG: integer
    LIGHT_FLAG: integer
    ABSOLUTE_FLAG: integer
    UNLIT_OBSERVER: function(event: pipeline.OnDraw)
end

tecs_render.PIPELINE = pipeline.PIPELINE

tecs_render.newCamera = camera.newCamera

-- Create a new render pipeline, automatically register it with the world, and return it
function tecs_render.newPipeline(config: pipeline.RenderConfig): types.Pipeline
    return pipeline.newPipeline(config)
end

tecs_render.UNLIT_FLAG = pipeline.UNLIT_FLAG
tecs_render.LIGHT_FLAG = pipeline.LIGHT_FLAG
tecs_render.ABSOLUTE_FLAG = pipeline.ABSOLUTE_FLAG
tecs_render.UNLIT_OBSERVER = pipeline.UNLIT_OBSERVER

return tecs_render