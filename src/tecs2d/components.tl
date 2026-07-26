--- Render components.
---
--- These are FFI components on purpose. Their columns are contiguous C memory,
--- which is what lets the sync walk rows and write straight into mapped GPU
--- staging instead of reading fields one entity at a time through a table.

local tecs <const> = require("tecs")

local type Component = tecs.Component

--- Position, rotation, and scale in world units, which are pixels with the
--- origin at the top left. Lighting works in the same units, so a light's
--- position needs no conversion.
local record Transform2D is Component
    x: number
    y: number
    --- Radians.
    rotation: number
    scaleX: number
    scaleY: number
end

tecs.newFFIComponent({
    name = "Transform2D",
    container = Transform2D,
    fields = {
        { "x", "float" }, { "y", "float" },
        { "rotation", "float" },
        { "scaleX", "float" }, { "scaleY", "float" },
    },
    defaults = { 0, 0, 0, 1, 1 },
})

--- Base colour written into the G-buffer's albedo target.
local record Tint is Component
    r: number
    g: number
    b: number
    a: number
end

tecs.newFFIComponent({
    name = "Tint",
    container = Tint,
    fields = {
        { "r", "float" }, { "g", "float" },
        { "b", "float" }, { "a", "float" },
    },
    defaults = { 1, 1, 1, 1 },
})

--- A light resolved by the deferred lighting pass.
local record PointLight is Component
    --- Height above the surface plane. At zero the Lambert term vanishes and
    --- the light contributes nothing, which reads as the light being broken
    --- rather than as a value being wrong.
    height: number
    radius: number
    r: number
    g: number
    b: number
    intensity: number
end

tecs.newFFIComponent({
    name = "PointLight",
    container = PointLight,
    fields = {
        { "height", "float" }, { "radius", "float" },
        { "r", "float" }, { "g", "float" }, { "b", "float" },
        { "intensity", "float" },
    },
    defaults = { 64, 256, 1, 1, 1, 1 },
})

--- Samples a texture instead of drawing flat colour.
---
--- `slot` indexes the renderer's texture registry rather than holding a
--- texture directly: components are plain C memory, and a registry index is
--- what fits there. The UV rect selects a region, so an atlas is the same
--- thing as a whole image with the rect set to the full range.
local record Sprite is Component
    slot: number
    u0: number
    v0: number
    u1: number
    v1: number
end

tecs.newFFIComponent({
    name = "Sprite",
    container = Sprite,
    fields = {
        { "slot", "int32_t" },
        { "u0", "float" }, { "v0", "float" },
        { "u1", "float" }, { "v1", "float" },
    },
    defaults = { 0, 0, 0, 1, 1 },
})

--- How a renderable's quad is shaded.
---
--- Absent means a textured quad, which is what a Sprite produces and what an
--- untextured entity gets by sampling the white layer. Present means the
--- fragment shader evaluates a distance field over the quad instead, so a
--- circle stays a circle at any scale rather than becoming a texture that
--- pixelates. One instance format either way: the batch, the cull and the draw
--- do not know the difference, which is what keeps the whole scene one draw.
local record Shape is Component
    --- 1 circle, 2 rounded rectangle. Zero is the textured quad and is what
    --- absence already means, so it is not spelled here.
    kind: number
    --- Corner radius for a rounded rectangle, in local units where the quad
    --- spans one. Ignored by a circle.
    radius: number
end

tecs.newFFIComponent({
    name = "Shape",
    container = Shape,
    fields = {
        { "kind", "int32_t" },
        { "radius", "float" },
    },
    defaults = { 1, 0.25 },
})

--- Marks an entity as contributing geometry. Without it a Transform2D is just
--- a position, which is what most entities in a world actually are.
local record Renderable is Component end

tecs.newComponent({
    name = "Renderable",
    container = Renderable,
})

local record components
    Transform2D: Transform2D
    Tint: Tint
    Sprite: Sprite
    Shape: Shape
    PointLight: PointLight
    Renderable: Renderable
end

components.Transform2D = Transform2D
components.Tint = Tint
components.Sprite = Sprite
components.Shape = Shape
components.PointLight = PointLight
components.Renderable = Renderable

return components
