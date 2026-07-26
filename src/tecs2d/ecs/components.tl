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
    PointLight: PointLight
    Renderable: Renderable
end

components.Transform2D = Transform2D
components.Tint = Tint
components.PointLight = PointLight
components.Renderable = Renderable

return components
