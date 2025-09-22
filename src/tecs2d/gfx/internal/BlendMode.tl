local tecs <const> = require("tecs")

local type lg_BlendMode = love.graphics.BlendMode
local type lg_BlendAlphaMode = love.graphics.BlendAlphaMode

--- A BlendMode component that applies Love2D blend modes to sprites during rendering.
--- In GPU rendering, entities with different blend modes are batched separately.
local record BlendMode is tecs.Component
    --- Blend mode (e.g., "alpha", "add", "multiply")
    mode: lg_BlendMode

    --- Alpha mode (e.g., "alphamultiply", "premultiplied")
    alphaMode: lg_BlendAlphaMode

    --- Plugin that registers the BlendMode component.
    plugin: function(world: tecs.World)

    metamethod __call: function(self, mode: lg_BlendMode, alphaMode?: lg_BlendAlphaMode): BlendMode
end

--- Plugin is a no-op for GPU rendering.
--- Drawable components handle blend mode when syncing to GPU buffers.
BlendMode.plugin = function(_world: tecs.World)
    -- No OnDraw observers needed - GPU handles blend mode via separate batches or instance flags
end

tecs.newComponent({
    name = "BlendMode",
    container = BlendMode,
    fields = {"mode", "alphaMode"},
    defaults = {nil, "alphamultiply"},
})

return BlendMode
