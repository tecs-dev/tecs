--- Render components.
---
--- These are FFI components on purpose. Their columns are contiguous C memory,
--- which is what lets the sync walk rows and write straight into mapped GPU
--- staging instead of reading fields one entity at a time through a table.

local ecs <const> = require("tecs.ecs")

local type Component = ecs.Component

--- Position, rotation and scale in world units, which are pixels with the
--- origin at the top left. Lighting works in the same units, so a light's
--- position needs no conversion.
---
--- The ECS builtin rather than a component declared here. It is a superset,
--- carrying `z` and `layer` besides, and it is what the hierarchy and the
--- authoring systems already move: a renderer reading its own transform would
--- draw an entity that a parent transform or a tween had moved somewhere else.
local Transform <const> = ecs.builtins.Transform

--- The transform as it stood before the current fixed step.
---
--- Presence is the opt-in: an entity carrying it is drawn somewhere between
--- this and its current transform, according to how far through the step the
--- frame falls. Simulation advances in fixed jumps and frames arrive whenever
--- the display asks for one, so without this an entity moved by physics steps
--- visibly rather than moving.
---
--- Only the fields that move continuously are here. Scale and layer change by
--- assignment rather than by integration, and a half-applied assignment is not
--- a value anything asked for.
local record PreviousTransform is Component
    x: number
    y: number
    --- Radians.
    rotation: number
end

ecs.newFFIComponent({
    name = "PreviousTransform",
    container = PreviousTransform,
    fields = {
        { "x", "float" }, { "y", "float" }, { "rotation", "float" },
    },
    defaults = { 0, 0, 0 },
})

--- Base colour written into the G-buffer's albedo target.
local record Tint is Component
    r: number
    g: number
    b: number
    a: number
end

ecs.newFFIComponent({
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

ecs.newFFIComponent({
    name = "PointLight",
    container = PointLight,
    fields = {
        { "height", "float" }, { "radius", "float" },
        { "r", "float" }, { "g", "float" }, { "b", "float" },
        { "intensity", "float" },
    },
    defaults = { 64, 256, 1, 1, 1, 1 },
})

--- Interned image names.
---
--- An image's name is its identity. A texture-array slot is not: slots are
--- handed out in registration order, so slot seven means whichever image
--- registered seventh, and a number that depends on load order cannot survive
--- being written to a snapshot and read back by a run that loads its assets
--- in a different order.
---
--- A component is plain C memory and a string does not fit there, so what a
--- Sprite carries is the name's intern index. The index is process-local and
--- never leaves the process: `Sprite.serialize` writes the name and
--- `deserialize` interns it again, so what a saved Sprite refers to is decided
--- by the name on both sides.
local imageIds: {string: integer} = {}
local imageNames: {integer: string} = {}
local imageCount = 0

--- Index of the given image name, assigning one the first time it is seen.
---
--- Indices start at one, so zero is the index of no image at all and that is
--- what a Sprite carries until something names one.
local function imageId(name: string): integer
    if name == nil or name == "" then
        error("tecs: an image name cannot be empty", 2)
    end
    local id = imageIds[name]
    if id ~= nil then return id end
    imageCount = imageCount + 1
    imageIds[name] = imageCount
    imageNames[imageCount] = name
    return imageCount
end

--- Name an index stands for, or nil when the index names nothing.
local function imageName(id: integer): string
    return imageNames[id]
end

--- Samples a texture instead of drawing flat colour.
---
--- `image` is an index from `imageId`, which names the image; `slot` is the
--- texture-array layer the renderer resolved that name to. Both are here
--- because extraction reads the slot for every row it writes and wants a
--- field, not a lookup, while a snapshot needs something a slot cannot give
--- it. Only the name is written to a snapshot.
---
--- A negative slot means unresolved. The renderer fills it in the first time
--- it writes the row, so a Sprite restored from a snapshot or built by hand
--- resolves once rather than once per frame. Pointing a live Sprite at another
--- image therefore means writing a negative slot along with the new `image`,
--- or the row keeps drawing the layer the old name resolved to.
---
--- The UV rect selects a region, so an atlas is the same thing as a whole
--- image with the rect set to the full range.
local record Sprite is Component
    image: number
    u0: number
    v0: number
    u1: number
    v1: number
    slot: number
end

ecs.newFFIComponent({
    name = "Sprite",
    container = Sprite,
    fields = {
        { "image", "int32_t" },
        { "u0", "float" }, { "v0", "float" },
        { "u1", "float" }, { "v1", "float" },
        { "slot", "int32_t" },
    },
    defaults = { 0, 0, 0, 1, 1, -1 },
    serialize = function(instance: Sprite): {string: any}
        return {
            image = imageNames[instance.image as integer],
            u0 = instance.u0, v0 = instance.v0,
            u1 = instance.u1, v1 = instance.v1,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sprite
        local name = data.image as string
        local image = 0
        if name ~= nil and name ~= "" then image = imageId(name) end
        return Sprite(image, data.u0 as number, data.v0 as number,
            data.u1 as number, data.v1 as number)
    end,
})

--- Which material shades a renderable's quad.
---
--- Absent means the default, which samples the image array and covers the whole
--- quad, so an entity with neither a Sprite nor a Material still draws. Present
--- selects one of the materials found under `materials/`.
---
--- The id comes from `materials.id(name)` rather than being written as a
--- number, because the numbering depends on which material files exist and a
--- literal would break the moment one was added ahead of it alphabetically.
---
--- One instance format either way: the batch, the cull and the draw do not know
--- which material an entity uses, which is what keeps the whole scene one draw.
local record Material is Component
    id: number
    --- Passed to the material, 0 to 1. What it means is the material's
    --- business; the rounded rectangle reads it as a corner radius.
    param: number
end

ecs.newFFIComponent({
    name = "Material",
    container = Material,
    fields = {
        { "id", "int32_t" },
        { "param", "float" },
    },
    defaults = { 0, 0.25 },
})

--- Marks an entity as contributing geometry. Without it a Transform is just
--- a position, which is what most entities in a world actually are.
local record Renderable is Component end

ecs.newComponent({
    name = "Renderable",
    container = Renderable,
})

local record components
    Transform: Transform
    PreviousTransform: PreviousTransform
    Tint: Tint
    Sprite: Sprite
    Material: Material
    PointLight: PointLight
    Renderable: Renderable

    --- Index of an image name, assigning one the first time it is seen.
    imageId: function(name: string): integer

    --- Name an image index stands for, or nil when it names nothing.
    imageName: function(id: integer): string
end

components.Transform = Transform
components.PreviousTransform = PreviousTransform
components.Tint = Tint
components.Sprite = Sprite
components.Material = Material
components.PointLight = PointLight
components.Renderable = Renderable
components.imageId = imageId
components.imageName = imageName

return components
