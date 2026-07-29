--[=[
Entity components that describe a rendered scene.

[`Transform`](/modules/ecs/#tecs.ecs.Transform) places an entity, graphics components
describe its appearance, and [`Renderable`](tealdoc:tecs.components.Renderable)
admits it to rendering. [`Transform`](/modules/ecs/#tecs.ecs.Transform),
[`Tint`](tealdoc:tecs.components.Tint), and
[`Renderable`](tealdoc:tecs.components.Renderable) form the minimum drawable set:

```teal
local player <const> = world:spawn(
    tecs.Transform(120, 80, 0, 1, 0, 32, 32),
    app.renderer:sprite("player.png"),
    tecs.gfx.Tint(1.0, 1.0, 1.0, 1.0),
    tecs.gfx.Renderable()
)

local tint <const> = world:getMut(player, tecs.gfx.Tint)
tint.a = 0.5
```

[`Sprite`](tealdoc:tecs.components.Sprite) selects an image region.
[`Material`](tealdoc:tecs.components.Material) selects fragment coverage and lighting.
[`Clip`](tealdoc:tecs.components.Clip) selects a target-pixel clip region.
[`PointLight`](tealdoc:tecs.components.PointLight),
[`Occluder`](tealdoc:tecs.components.Occluder), and
[`DropShadow`](tealdoc:tecs.components.DropShadow) describe deferred lighting and
shadows.

[`Transform`](/modules/ecs/#tecs.ecs.Transform) remains at `tecs.Transform` because
physics, hierarchy, sequencing, and graphics share it. Other render components
live under `tecs.gfx`.

Use `world:getMut` for authored changes. A direct cdata write through
`world:get` must call `world:markComponentDirty`, or rendering keeps the old
value. `batchSpawn` skips FFI defaults, so its callback must initialize every
field.

[`PreviousTransform`](tealdoc:tecs.components.PreviousTransform) stores the pose
before the current fixed step. The renderer interpolates it toward
[`Transform`](/modules/ecs/#tecs.ecs.Transform) for presentation without changing
simulation state.
]=]
-- Implementation details:
-- Render data uses FFI columns so extraction can copy contiguous component
-- ranges into mapped frame buffers. Dirty columns gate those copies, and
-- contiguous archetype runs map directly to GPU staging.
--
-- Each registered component name is a compatibility surface because snapshots
-- store it as a string. Names such as "Sprite" and "Renderable" remain stable
-- even if their Lua namespace changes.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local materials <const> = require("tecs.gpu.materials")

local type Component = ecs.Component

--- Stores the transform as it stood before the current fixed step.
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
    --- Engine-owned. Stores the previous horizontal position for frame
    --- interpolation. Ordinary game code should ignore this field.
    x: number
    --- Engine-owned. Stores the previous vertical position for frame
    --- interpolation. Ordinary game code should ignore this field.
    y: number
    --- Engine-owned. Stores the previous rotation in radians for frame
    --- interpolation. Ordinary game code should ignore this field.
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

--- Controls base color and how much of the background remains visible.
---
--- Alpha selects the drawing pass. At one, the opaque entity enters the
--- G-buffer and participates in deferred lighting. Below one, the forward pass
--- draws it after compositing, blends straight alpha, and lights it.
---
--- A value rather than a component, because a fade is the thing this is for and
--- a fade through a component would cause a structural change per entity per
--- frame: adding and removing a tag moves a row between archetypes, which is
--- the most expensive thing here. Alpha already changes as a float. One value
--- also prevents conflicting transparency state.
---
--- What crossing one costs is what the forward pass cannot do. A blended
--- entity writes no depth, so it hides nothing behind it and nothing reading
--- the G-buffer can see it, and the forward list is shorter than the instance
--- buffer, so a scene with more blended entities than it holds draws the ones
--- earliest in the buffer and drops the rest. An entity meant to be solid
--- should say so with an alpha of exactly one.
local record Tint is Component
    --- Caller-writable. Sets the red channel from zero to one.
    r: number
    --- Caller-writable. Sets the green channel from zero to one.
    g: number
    --- Caller-writable. Sets the blue channel from zero to one.
    b: number
    --- Caller-writable. Sets coverage from transparent at zero to opaque at
    --- one.
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

--- Represents a light resolved by the deferred lighting pass.
local record PointLight is Component
    --- Caller-writable. Sets the height above the surface plane. At zero, the
    --- Lambert term vanishes and the light contributes nothing.
    height: number
    --- Caller-writable. Sets the light's reach in world units.
    radius: number
    --- Caller-writable. Sets the red channel from zero to one.
    r: number
    --- Caller-writable. Sets the green channel from zero to one.
    g: number
    --- Caller-writable. Sets the blue channel from zero to one.
    b: number
    --- Caller-writable. Scales the light's contribution.
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
--- An image's name is its identity. Registration order assigns texture-array
--- slots, so a snapshot stores the name instead of a load-order-dependent slot.
---
--- [`Sprite`](tealdoc:tecs.components.Sprite) carries the name's process-local intern
--- index. `Sprite.serialize` writes the name, and `deserialize` interns it again
--- on load.
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
--- normalizes the same before its file exists as after, and the same on a
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
local function normalizePath(name: string): string
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
--- The function normalizes each name before interning it. Registration, sprite
--- lookup, reload, and snapshot loading all use this path.
---
--- Indices start at one, so zero is the index of no image at all and that is
--- what a Sprite carries until something names one.
local function imageId(name: string): integer
    if name == nil or name == "" then
        error("tecs: an image name cannot be empty", 2)
    end
    name = normalizePath(name)
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

--- Samples a texture instead of drawing flat color.
---
--- `image` is an index from `imageId`, which names the image; `slot` is the
--- texture-array layer the renderer resolved that name to. Both are here
--- because extraction reads the slot for every row it writes and wants a
--- field, not a lookup, while a snapshot needs something a slot cannot give
--- it. Snapshots store only the name.
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
    --- Caller-writable. Selects an image by its `imageId` index. Zero selects
    --- no image.
    image: number
    --- Caller-writable. Sets the left edge of the sampled UV rectangle.
    u0: number
    --- Caller-writable. Sets the top edge of the sampled UV rectangle.
    v0: number
    --- Caller-writable. Sets the right edge of the sampled UV rectangle.
    u1: number
    --- Caller-writable. Sets the bottom edge of the sampled UV rectangle.
    v1: number
    --- Engine-owned. Stores the resolved texture-array slot. Set it to a
    --- negative value when changing `image`; otherwise ordinary game code
    --- should ignore this field.
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
    deserialize = function(_world: types.World, data: {string: any}): Sprite
        local name = data.image as string
        local image = 0
        if name ~= nil and name ~= "" then
            image = imageId(name)
        end
        return Sprite(image, data.u0 as number, data.v0 as number, data.u1 as number, data.v1 as number)
    end,
})

--- Selects the material that shades a renderable's quad.
---
--- Absent means the default, which samples the image array and covers the whole
--- quad, so an entity with neither a Sprite nor a Material still draws. Present
--- selects one of the materials found under `materials/`.
---
--- Use `materials.id(name)` instead of writing an id. Sorted material names
--- determine ids, so adding a file may renumber them. Snapshots therefore store
--- only the material name.
---
--- One instance format either way: the batch, the cull and the draw do not know
--- which material an entity uses, which is what keeps the whole scene one draw.
local record Material is Component
    --- Caller-writable. Selects a material by the id returned from
    --- `materials.id`.
    id: number
    --- Caller-writable. Passes a value from zero to one to the material. The material's
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
    deserialize = function(_world: types.World, data: {string: any}): Material
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

--- Restricts a renderable's fragments to a clip region.
---
--- A component rather than a field on something every renderable has, because
--- presence is the opt-in and absence is the common case. Archetypes without
--- this column skip clipping, and their fragments never read the region table.
---
--- The index names a rectangle set with `Renderer:setClipRegion`. Zero, which
--- is the default, means no clipping. Nesting is the caller's: a region is one
--- rectangle, so a panel inside a panel is set up as the intersection of the
--- two rather than as two regions an instance sits in at once.
local record Clip is Component
    --- Caller-writable. Selects a clip region configured with
    --- `Renderer:setClipRegion`. Zero disables clipping.
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

--- Blocks light from reaching what lies behind the entity.
---
--- The renderer adds the silhouette to the occluder mask every light samples, so
--- one entity blocks every light at the cost of one drawing of itself rather
--- than one per light. It blocks each light's contribution, not ambient light.
--- [`DropShadow`](tealdoc:tecs.components.DropShadow) handles ambient darkening.
---
--- Coverage is the silhouette, so a circle, a rounded box or a glyph casts the
--- shape it draws with no threshold of its own to set. A translucent entity
--- casts nothing: it is drawn forward over the composited image and never
--- reaches the G-buffer, so a hard silhouette of it would be a lie.
local record Occluder is Component
    --- Caller-writable. Sets the occluder height from zero to one of the
    --- world's configured shadow height.
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

--- Casts a stretched copy of the entity along the ground, away from light.
---
--- This darkens everything a light left, including ambient light, which
--- [`Occluder`](tealdoc:tecs.components.Occluder) cannot do. It blocks no light in
--- return: a crowd of light-blocking silhouettes merges under the mask into
--- one flat mat of darkness, so the thing that wants a contact shadow is
--- exactly the thing that must not be an occluder. An entity carrying both is
--- an occluder, because dropping that half would silently unblock a light.
---
--- The nearest few lights by weight throw the copy. Adding a distant light does
--- not move an established shadow.
local record DropShadow is Component
    --- Caller-writable. Sets how far lights throw the shadow, from zero to one
    --- of the world's configured shadow height.
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

--- Marks an entity as contributing geometry. Without it, a
--- [`Transform`](/modules/ecs/#tecs.ecs.Transform) represents only a position.
local record Renderable is Component
end

ecs.newComponent({
    name = "Renderable",
    container = Renderable,
})

-- Implementation details:
-- All render components except Renderable use FFI columns. Transform remains
-- an ECS builtin because every subsystem shares it.
local record components
    --- Read-only. Exposes the transform component used for frame interpolation.
    --- Presence is
    --- the opt-in to interpolation: an entity carrying it is drawn between
    --- this and its current transform, so physics does not step visibly.
    --- Carries `x`, `y` and `rotation` (radians) only, because scale and
    --- layer change by assignment rather than by integration.
    PreviousTransform: PreviousTransform

    --- Read-only. Exposes the base-color component. Each channel ranges from
    --- 0 to 1 and defaults to opaque
    --- white. The alpha decides which pass draws the entity: exactly 1 goes
    --- through the G-buffer and is lit once for the whole scene, anything
    --- below 1 goes through the forward pass instead and writes no depth. When
    --- the forward list fills, the renderer drops later entries. Use exactly 1
    --- for solid content.
    Tint: Tint

    --- Read-only. Exposes the sprite component, which samples a texture instead
    --- of drawing flat color. `image` is an
    --- `imageId` index, and 0 means no image; `u0, v0, u1, v1` select the
    --- region, defaulting to the whole of it, so an atlas entry and a whole
    --- image are the same thing. `slot` is the texture-array layer the
    --- renderer resolved `image` to, and a negative value means unresolved:
    --- pointing a live [`Sprite`](tealdoc:tecs.components.Sprite) at another image
    --- means writing a negative slot
    --- along with the new `image`, or the row keeps drawing the old layer.
    --- Only the image name survives a snapshot.
    Sprite: Sprite

    --- Read-only. Exposes the material component, which selects one of the
    --- materials found under `materials/`. Absent means
    --- the default, which samples the image array over the whole quad, so an
    --- entity with neither this nor a
    --- [`Sprite`](tealdoc:tecs.components.Sprite) still draws. Take `id` from
    --- `materials.id(name)` rather than writing a number: ids are positions
    --- in sorted order and may move when a material file appears. `param` is 0
    --- to 1 and means whatever the material says it does.
    Material: Material

    --- Read-only. Exposes the point-light component resolved by deferred
    --- lighting and positioned by the entity's
    --- [`Transform`](/modules/ecs/#tecs.ecs.Transform). `height` is above the
    --- surface plane and at 0 the light contributes nothing at all;
    --- `radius` is its reach in world units; `r`, `g`, `b` and `intensity`
    --- default to white at 1.
    PointLight: PointLight

    --- Read-only. Exposes the clip component, which keeps a renderable's
    --- fragments inside one rectangle. `index` names a region set with
    --- `Renderer:setClipRegion`, and 0, the default, means no clipping. A
    --- region is a single rectangle, so the caller intersects nested regions.
    Clip: Clip

    --- Read-only. Exposes the occluder component, which blocks every light with
    --- the entity's shape. `height` is 0 to 1 of the world height
    --- `Deferred.shadowHeight` sets, so 1 is a full wall and 0 blocks nothing.
    --- This component requires renderer `shadows`.
    Occluder: Occluder

    --- Read-only. Exposes the drop-shadow component, which darkens the ground
    --- away from each nearby light, including ambient light, without blocking
    --- light. `height` is 0 to 1 and controls the copy's travel under the same
    --- interpretation as `Occluder.height`.
    DropShadow: DropShadow

    --- Read-only. Exposes the renderable tag, which marks an entity as
    --- contributing geometry. The tag costs a column of nothing; without it a
    --- [`Transform`](/modules/ecs/#tecs.ecs.Transform) is only a position, which
    --- is what most entities in a world are.
    Renderable: Renderable

    --- Returns the index of an image name and assigns one on first use.
    ---
    --- The function normalizes names lexically, so `"a/b.png"` and
    --- `"a/./b.png"` identify one image. It preserves case and `..` and does not
    --- touch the filesystem.
    ---
    --- @param name Must be non-empty; an empty or nil name errors rather
    ---     than interning.
    --- @return An index from 1 upwards, stable for the life of the process
    ---     and meaningless outside it. 0 is never returned and is what a
    ---     [`Sprite`](tealdoc:tecs.components.Sprite) carries until something names an
    ---     image.
    imageId: function(name: string): integer

    --- Returns the name represented by an image index.
    ---
    --- @param id An index previously handed out by `imageId`.
    --- @return The normalized name, or nil when the index names nothing.
    imageName: function(id: integer): string
end

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
