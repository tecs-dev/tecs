--- Render components.
---
--- These are FFI components on purpose. Their columns are contiguous C memory,
--- which is what lets the sync walk rows and write straight into mapped GPU
--- staging instead of reading fields one entity at a time through a table.

local ecs <const> = require("tecs.ecs")
local materials <const> = require("tecs.gpu.materials")

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
        {"x", "float"},
        {"y", "float"},
        {"rotation", "float"},
    },
    defaults = {0, 0, 0},
})

--- Base colour, and how much of what is behind the entity survives it.
---
--- The alpha is what decides which pass draws the entity. At one the entity is
--- opaque and goes through the G-buffer, where lighting resolves it once for
--- the whole scene however many things overlap. Below one it goes through the
--- forward pass instead, which runs after the frame has been composited, blends
--- straight alpha over it, and lights itself.
---
--- A value rather than a component, because a fade is the thing this is for and
--- a fade through a component would be a structural change per entity per
--- frame: adding and removing a tag moves a row between archetypes, which is
--- the most expensive thing here, while an alpha crossing one is a float
--- already being written. It also keeps the two answers to "how transparent is
--- this" from being able to disagree.
---
--- What crossing one costs is what the forward pass cannot do. A blended
--- entity writes no depth, so it hides nothing behind it and nothing reading
--- the G-buffer can see it, and the forward list is shorter than the instance
--- buffer, so a scene with more blended entities than it holds draws the ones
--- earliest in the buffer and drops the rest. An entity meant to be solid
--- should say so with an alpha of exactly one.
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
        {"r", "float"},
        {"g", "float"},
        {"b", "float"},
        {"a", "float"},
    },
    defaults = {1, 1, 1, 1},
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
        {"height", "float"},
        {"radius", "float"},
        {"r", "float"},
        {"g", "float"},
        {"b", "float"},
        {"intensity", "float"},
    },
    defaults = {64, 256, 1, 1, 1, 1},
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

--- The scheme a name may lead with, whose `//` is not a path separator: what
--- follows it is an authority rather than a directory.
local SCHEME_PREFIX <const> = "^(%a[%w+.-]*://)(.*)$"

--- One spelling of a path, so two of them cannot become two images.
---
--- The image array holds a fixed number of layers and reclaims none of them,
--- so `"a/b.png"` and `"a/./b.png"` arriving as two names costs a layer and
--- uploads the same pixels twice, with nothing to show for it and nothing
--- said. What this drops is the part of a spelling that carries no
--- information: repeated separators, `.` segments, and a trailing separator.
---
--- Lexical, and only lexical. Nothing here reads the filesystem, so a name
--- normalises the same before its file exists as after, and the same on a
--- platform whose asset root is not a directory at all. Three things are
--- deliberately left alone for that reason:
---
---   - `..`, because resolving it without the filesystem renames a path
---     across a symlink, which would merge two names that are two files.
---   - Letter case, because folding it merges two files that a case-sensitive
---     filesystem keeps apart.
---   - The asset root, because stripping `filesystem.assetRoot()` would make an
---     identity depend on process state that `TECS_ASSETS` and
---     `filesystem.setAssetRoot` move, and one name would then intern as two indices
---     at two moments, which is the defect this exists to prevent.
---
--- A leading run of separators is kept as it was written: one leads an
--- absolute path and two lead a UNC share.
local function normalisePath(name: string): string
    -- Nothing to drop is the common case, and it is answered without building
    -- a string. An interior `//` or `/./`, a leading `./` and a trailing
    -- separator are the whole of what the walk below removes.
    if name:find("/%.?/") == nil and name:sub(1, 2) ~= "./" and name:sub(-1) ~= "/" and name:sub(-2) ~= "/." then
        return name
    end

    local prefix, rest = name:match(SCHEME_PREFIX)
    if prefix == nil then
        prefix, rest = name:match("^(/*)(.*)$")
    end

    local segments <const>: {string} = {}
    for segment in rest:gmatch("[^/]+") do
        if segment ~= "." then
            segments[#segments + 1] = segment
        end
    end
    return prefix .. table.concat(segments, "/")
end

--- Index of the given image name, assigning one the first time it is seen.
---
--- The name is normalised first, so what an image is identified by is the path
--- it names rather than the spelling it was named with. Every way in goes
--- through here: registering an image, resolving a sprite by name, reloading
--- one, and reading a name back out of a snapshot.
---
--- Indices start at one, so zero is the index of no image at all and that is
--- what a Sprite carries until something names one.
local function imageId(name: string): integer
    if name == nil or name == "" then
        error("tecs: an image name cannot be empty", 2)
    end
    name = normalisePath(name)
    local id = imageIds[name]
    if id ~= nil then
        return id
    end
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
        {"image", "int32_t"},
        {"u0", "float"},
        {"v0", "float"},
        {"u1", "float"},
        {"v1", "float"},
        {"slot", "int32_t"},
    },
    defaults = {0, 0, 0, 1, 1, -1},
    serialize = function(instance: Sprite): {string: any}
        -- A negative first coordinate is not a rect. The four UV lanes carry a
        -- playback instead when an animation resolves on the GPU, and what
        -- they hold then is an index into this run's frame table and a count
        -- of this world's fixed steps, neither of which means anything in
        -- another run. `Animation` writes what is playing by name and the
        -- encoder derives these again on the first step after a load, so the
        -- whole image is what a saved sprite carries and the animation puts
        -- its own answer back.
        if instance.u0 < 0.0 then
            return {
                image = imageNames[instance.image as integer],
                u0 = 0.0,
                v0 = 0.0,
                u1 = 1.0,
                v1 = 1.0,
            }
        end
        return {
            image = imageNames[instance.image as integer],
            u0 = instance.u0,
            v0 = instance.v0,
            u1 = instance.u1,
            v1 = instance.v1,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sprite
        local name = data.image as string
        local image = 0
        if name ~= nil and name ~= "" then
            image = imageId(name)
        end
        return Sprite(image, data.u0 as number, data.v0 as number, data.u1 as number, data.v1 as number)
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
--- For the same reason only the name is written to a snapshot: an id is a
--- position in sorted order, and a saved one would name whichever material the
--- loading build happened to put there.
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
        {"id", "int32_t"},
        {"param", "float"},
    },
    defaults = {0, 0.25},
    serialize = function(instance: Material): {string: any}
        -- The name, the way a Sprite writes its image and an Animation its
        -- sheet. The id is this build's answer, and the file has to hold
        -- something that means the same in the next one.
        return {
            material = materials.name(instance.id as integer),
            param = instance.param,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Material
        local name = data.material as string
        local id = 0
        if name ~= nil and name ~= "" then
            id = materials.find(name)
            -- Neither the default nor a skipped component. Both of those load
            -- without a word and draw the entity through a shader nobody
            -- asked for, which is the failure a name is written to prevent;
            -- refusing is the only answer that is not a guess.
            if id == nil then
                error(
                    (
                        "loadSnapshot: snapshot references material '%s' " .. "which this build does not have; found %s"
                    ):format(name, table.concat(materials.names(), ", ")),
                    0
                )
            end
        end
        return Material(id, data.param as number)
    end,
})

--- Which clip region a renderable's fragments are kept inside.
---
--- A component rather than a field on something every renderable has, because
--- presence is the opt-in and absence is the common case: an archetype without
--- this column is written by a loop that never mentions clipping, and the
--- fragments it produces never read the region table. A world that clips
--- nothing pays for this exactly nowhere.
---
--- The index names a rectangle set with `Renderer:setClipRegion`. Zero, which
--- is the default, means no clipping. Nesting is the caller's: a region is one
--- rectangle, so a panel inside a panel is set up as the intersection of the
--- two rather than as two regions an instance sits in at once.
local record Clip is Component
    index: number
end

ecs.newFFIComponent({
    name = "Clip",
    container = Clip,
    fields = {
        {"index", "int32_t"},
    },
    defaults = {0},
})

--- Stands between a light and what is behind it.
---
--- The silhouette goes into the occluder mask every light marches against, so
--- one entity blocks every light at the cost of one drawing of itself rather
--- than one per light. What is blocked is a light's own contribution, and
--- never the ambient term, because a mask inside the light loop has no way to
--- reach a term that is not in it. `DropShadow` is the other half of that.
---
--- Coverage is the silhouette, so a circle, a rounded box or a glyph casts the
--- shape it draws with no threshold of its own to set. A translucent entity
--- casts nothing: it is drawn forward over the composited image and never
--- reaches the G-buffer, so a hard silhouette of it would be a lie.
local record Occluder is Component
    height: number
end

ecs.newFFIComponent({
    name = "Occluder",
    container = Occluder,
    fields = {
        {"height", "float"},
    },
    defaults = {1.0},
})

--- Throws a stretched copy of itself along the ground, away from the light.
---
--- What this darkens is everything a light left, ambient included, which is
--- what `Occluder` cannot do and the reason both exist. It blocks no light in
--- return: a crowd of light-blocking silhouettes merges under the mask into
--- one flat mat of darkness, so the thing that wants a contact shadow is
--- exactly the thing that must not be an occluder. An entity carrying both is
--- an occluder, because dropping that half would silently unblock a light.
---
--- The copy is thrown by the nearest few lights by weight rather than by every
--- light, so adding a light somewhere else in the world does not move a shadow
--- that was already settled.
local record DropShadow is Component
    height: number
end

ecs.newFFIComponent({
    name = "DropShadow",
    container = DropShadow,
    fields = {
        {"height", "float"},
    },
    defaults = {1.0},
})

--- Marks an entity as contributing geometry. Without it a Transform is just
--- a position, which is what most entities in a world actually are.
local record Renderable is Component
end

ecs.newComponent({
    name = "Renderable",
    container = Renderable,
})

--- The components a game spawns to put something on screen.
---
--- All but `Renderable` are FFI components, so their columns are contiguous C
--- memory the sync walks row by row into mapped GPU staging. Writing one
--- through `world:get` therefore needs an explicit
--- `world:markComponentDirty(entity, Component)`; only `getMut` marks the
--- column on its own.
local record components
    --- Position, rotation and scale, in world units, which are pixels with
    --- the origin at the top left and y increasing downwards. Also carries
    --- `z` and `layer`. This is the ECS builtin, so the hierarchy, the
    --- tweens and the renderer all move the same transform.
    Transform: Transform

    --- The transform as it stood before the current fixed step. Presence is
    --- the opt-in to interpolation: an entity carrying it is drawn between
    --- this and its current transform, so physics does not step visibly.
    --- Carries `x`, `y` and `rotation` (radians) only, because scale and
    --- layer change by assignment rather than by integration.
    PreviousTransform: PreviousTransform

    --- Base colour and coverage, each channel 0 to 1, defaulting to opaque
    --- white. The alpha decides which pass draws the entity: exactly 1 goes
    --- through the G-buffer and is lit once for the whole scene, anything
    --- below 1 goes through the forward pass instead, writes no depth, and
    --- is dropped when the forward list is full. Say 1 exactly for anything
    --- meant to be solid.
    Tint: Tint

    --- Samples a texture instead of drawing flat colour. `image` is an
    --- `imageId` index, and 0 means no image; `u0, v0, u1, v1` select the
    --- region, defaulting to the whole of it, so an atlas entry and a whole
    --- image are the same thing. `slot` is the texture-array layer the
    --- renderer resolved `image` to, and a negative value means unresolved:
    --- pointing a live Sprite at another image means writing a negative slot
    --- along with the new `image`, or the row keeps drawing the old layer.
    --- Only the image name survives a snapshot.
    Sprite: Sprite

    --- Selects one of the materials found under `materials/`. Absent means
    --- the default, which samples the image array over the whole quad, so an
    --- entity with neither this nor a Sprite still draws. Take `id` from
    --- `materials.id(name)` rather than writing a number: ids are positions
    --- in sorted order and move when a material file is added. `param` is 0
    --- to 1 and means whatever the material says it does.
    Material: Material

    --- A light the deferred lighting pass resolves, positioned by the
    --- entity's Transform and in the same world units. `height` is above the
    --- surface plane and at 0 the light contributes nothing at all;
    --- `radius` is its reach in world units; `r`, `g`, `b` and `intensity`
    --- default to white at 1.
    PointLight: PointLight

    --- Keeps a renderable's fragments inside one rectangle. `index` names a
    --- region set with `Renderer:setClipRegion`, and 0, the default, means
    --- no clipping. A region is a single rectangle, so nesting is the
    --- caller's job: intersect the two and set that.
    Clip: Clip

    --- Blocks every light with the shape the entity draws. `height` is 0 to
    --- 1 of the world height `Deferred.shadowHeight` sets, so 1 is a full
    --- wall and 0 is something lying flat that blocks nothing. Needs
    --- `shadows` on the renderer; without it the entity draws and casts
    --- nothing.
    Occluder: Occluder

    --- Darkens the ground away from each of the nearest lights, ambient
    --- included, and blocks no light. `height` is 0 to 1 and decides how far
    --- the copy is thrown, under the same reading as `Occluder.height`. An
    --- entity carrying both is an occluder.
    DropShadow: DropShadow

    --- Marks an entity as contributing geometry. A tag, so it costs a
    --- column of nothing; without it a Transform is only a position, which
    --- is what most entities in a world are.
    Renderable: Renderable

    --- Index of an image name, assigning one the first time it is seen.
    ---
    --- The name is normalised lexically first, so `"a/b.png"` and
    --- `"a/./b.png"` are one image. Case, `..` and the asset root are
    --- deliberately left alone, and nothing here touches the filesystem.
    ---
    --- @param name Must be non-empty; an empty or nil name errors rather
    ---     than interning.
    --- @return An index from 1 upwards, stable for the life of the process
    ---     and meaningless outside it. 0 is never returned and is what a
    ---     Sprite carries until something names an image.
    imageId: function(name: string): integer

    --- Name an image index stands for.
    ---
    --- @param id An index previously handed out by `imageId`.
    --- @return The normalised name, or nil when the index names nothing.
    imageName: function(id: integer): string
end

components.Transform = Transform
components.PreviousTransform = PreviousTransform
components.Tint = Tint
components.Sprite = Sprite
components.Material = Material
components.PointLight = PointLight
components.Clip = Clip
components.Occluder = Occluder
components.DropShadow = DropShadow
components.Renderable = Renderable
components.imageId = imageId
components.imageName = imageName

return components
