local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local defineShape <const> = require("tecs2d.gfx.internal.gpu.define_shape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Occluder <const> = require("tecs2d.gfx.internal.Occluder")
local Material <const> = require("tecs2d.gfx.internal.Material")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")

-- Circle uses the renderer-owned shadow-column path: per-archetype
-- dispatch, std430 source SSBOs read directly by the cull shader, no
-- slot management. Wiring is provided by `shadow_plugin`.
local shaders <const> = defineShape.loadShaders({
    name = "circle",
    dir = "tecs2d/gfx/internal/circle/",
    shadowMask = "circle",
})

local record circle
    record Circle is tecs.Component, types.Rect
        radius: number
        lineWidth: number  -- 0 = filled, >0 = outline with this width

        metamethod __call: function(self, radius: number, lineWidth?: number): Circle
    end

    plugin: function(world: tecs.World)
end

local Circle <const> = circle.Circle

tecs.newFFIComponent({
    name = "Circle",
    container = Circle,
    fields = {
        {"radius", "float"},
        {"lineWidth", "float"},
    },
    metatable = {
        __index = {
            getRect = function(self: Circle): number, number, number, number
                local r = self.radius
                local size = r * 2
                return -r, -r, size, size
            end
        }
    },
    defaults = {nil, 0},
    init = function(instance: Circle)
        assert(instance.radius, "Missing Circle radius")
    end
})

function circle.plugin(world: tecs.World)
    defineShape.register(world, {
        name = "Circle",
        component = Circle as tecs.Component,
        render = shaders.render,
        cull = shaders.cull,
        shadowMask = shaders.shadowMask,
        modifiers = {ColorComponent, ClipBounds, Occluder, Material, LayoutBox},
        tags = {Unlit},
        alphaBlendFilter = true,
    })
end

return circle
