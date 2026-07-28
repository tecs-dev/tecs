--- The shape of one drawable instance, in one place.
---
--- Two things write this layout: the renderer, walking archetype columns, and
--- any producer drawing instances it owns rather than entities. Both write into
--- the same buffers and the GPU reads one description of them, so a second
--- statement of the shape is a second thing to keep in step with the shaders.
---
--- What the fields mean lives with the shader that reads them,
--- `assets/shaders/instance.vert.glsl`. What is here is what a writer needs to
--- place them and to size a buffer.

--- What the two signs of a cull bound say an instance is.
---
--- A half extent is a length, so neither of its signs carries anything, and the
--- two of them together say which of exactly four things the instance is. That
--- they are exclusive is the design rather than a limitation. A blended
--- instance never reaches the G-buffer, so a hard silhouette of it in the
--- occluder mask would be a lie; and an occluder and a drop-shadow caster are
--- disjoint by content, because a light-blocking silhouette per tree merges
--- under the mask's max blend into one mat of darkness, which is why the thing
--- that wants a drop shadow is exactly the thing that must not be an occluder.
local enum InstanceRole
    --- Drawn into the G-buffer, casting nothing.
    "opaque"
    --- Drawn by the forward pass over the composited image.
    "blended"
    --- Drawn into the G-buffer, and its silhouette into the occluder mask that
    --- every light marches against.
    "occluder"
    --- Drawn into the G-buffer, and a stretched copy of it along the ground
    --- away from each of the nearest lights, which darkens what it lands on and
    --- blocks nothing.
    "dropShadow"
end

--- The instance and cull-bound layouts, and the helpers that pack into them.
---
--- Constants and pure functions only: nothing here touches a device or holds
--- state. What a writer gets from it is the stride to advance by, the sentinel
--- values for a slot nothing owns, the packing rule for `origin.z`, and the
--- sign rule for a bound's two half extents.
local record instancelayout
    --- What a bound's two signs say an instance is.
    type InstanceRole = InstanceRole

    --- Floats per instance: four vec4s.
    FLOATS: integer
    --- Bytes per instance, which is the stride a writer advances by.
    BYTES: integer

    --- Floats per cull bound: centre xy and half extent xy.
    ---
    --- Kept apart from the instance because the cull reads it for every entity
    --- every frame, drawn or not, while the instance is only read for what
    --- survives. Sixteen bytes streamed beats sixty-four bytes gathered.
    BOUND_FLOATS: integer
    --- Bytes per cull bound, and the stride of the bound buffer.
    BOUND_BYTES: integer

    --- Half extent for something on a layer the view rectangle does not
    --- describe: screen space, virtual coordinates, parallax or ignored zoom.
    --- Big enough that no finite view is outside it, and finite so the
    --- comparison stays arithmetic rather than a special case.
    UNBOUNDED: number

    --- Centre for a slot nothing owns. No view overlaps a bound out here, so
    --- the cull drops it before the draw sees it.
    HIDDEN: number

    --- Depth for a slot nothing owns, at the back of the band it lands in.
    --- The bound is what removes it, and this is what keeps it harmless if a
    --- view ever reaches out to where the bound is: it occludes nothing.
    HIDDEN_DEPTH: number

    --- Texture-array layers `origin.z` addresses, and the stride the clip
    --- index sits above them at.
    ---
    --- The image array holds this many layers, so a layer number is a small
    --- integer with room above it in a float that carries nothing else.
    --- `LAYER_SLOTS` in `assets/shaders/instance.vert.glsl` is the same number
    --- and the pair only works while they agree.
    LAYER_SLOTS: integer

    --- Clip regions `origin.z` addresses, counting region zero.
    ---
    --- Region zero is no clipping at all, so the usable indices are one
    --- through `CLIPS - 1`. `CLIP_SLOTS` in
    --- `assets/shaders/instance.frag.glsl` is the same number.
    CLIPS: integer

    --- Steps the cast height `origin.z` addresses is quantised to.
    ---
    --- The third and last field the float has room for. The largest packed
    --- value is 255 * 16384 + 255 * 64 + 63, which is 4,194,303 and well
    --- inside the 16,777,216 a float32 represents integers exactly to, so all
    --- three come back out exactly. One part in 255 of a height is finer than
    --- anything a shadow's length shows.
    HEIGHTS: integer

    --- Entries the shadow lane emits per caster, and the number of lights a
    --- drop-shadow caster throws a copy of itself by.
    ---
    --- `CAST_FANOUT` in `assets/shaders/include/cull.glsl` is the same number,
    --- and the comparison network in `assets/shaders/instance.cast.comp.glsl`
    --- is that many wide. All three only work while they agree, and the lane's
    --- ten bits of rank hold this times 255 and no more.
    CAST_FANOUT: integer
end

instancelayout.FLOATS = 16
instancelayout.BYTES = instancelayout.FLOATS * 4
instancelayout.BOUND_FLOATS = 4
instancelayout.BOUND_BYTES = instancelayout.BOUND_FLOATS * 4
instancelayout.UNBOUNDED = 1e30
instancelayout.HIDDEN = 1e30
instancelayout.HIDDEN_DEPTH = 0.999
--- Hoisted, because `packSlot` runs once per instance written and a field
--- lookup per row is a lookup too many.
local LAYER_SLOTS <const> = 64
instancelayout.LAYER_SLOTS = LAYER_SLOTS
local CLIPS <const> = 256
instancelayout.CLIPS = CLIPS
instancelayout.HEIGHTS = 256
instancelayout.CAST_FANOUT = 4

--- Stride the cast height sits above the clip index at, hoisted for the same
--- reason `LAYER_SLOTS` is.
local HEIGHT_STRIDE <const> = CLIPS * LAYER_SLOTS

--- The `origin.z` an instance on this texture-array layer, in this clip
--- region, at this cast height, carries.
---
--- One float says all three because growing the instance to hold them would
--- cost every instance sixteen bytes to say something almost all of them have
--- nothing to say about. The shader recovers each with a division and a modulo,
--- and every one is exact for every value this produces.
---
--- Region zero and height zero pack to the layer itself, so a writer that
--- mentions neither writes what it always wrote.
--- @param clip Zero to `CLIPS - 1`, zero being no clipping.
--- @param layer Zero to `LAYER_SLOTS - 1`. Unchecked: a layer at or above the
---     stride lands in the next clip region rather than raising.
--- @param height Zero to `HEIGHTS - 1`, and what an occluder's silhouette is
---     written into the mask at and a drop shadow's length is taken from.
---     Optional, and zero for an instance that casts nothing: a caster left at
---     zero throws a shadow of no length, which is what a thing lying flat on
---     the ground does.
--- @return The float to write into `origin.z`, exact in float32 for every
---     value in range.
function instancelayout.packSlot(clip: integer, layer: number, height?: integer): number
    if height == nil then
        return clip * LAYER_SLOTS + layer
    end
    return height * HEIGHT_STRIDE + clip * LAYER_SLOTS + layer
end

--- What to multiply a bound's two half extents by so it says this role.
---
--- The signs rather than the bound, because the caller has already worked the
--- extents out through `extentOf` and this is the one thing it cannot get from
--- the geometry. Applied as multipliers rather than returned as a bound, so a
--- writer with a rotated extent and a writer with a per-axis one both take the
--- same two numbers.
--- @param role Anything outside the four raises: a bound written with a role
---     nothing recognises would be culled or drawn as some other role rather
---     than reported.
--- @return Sign for the first half extent, which is negative for a blended
---     instance and for a drop-shadow caster.
--- @return Sign for the second, which is negative for anything that casts.
function instancelayout.signsOf(role: InstanceRole): number, number
    if role == "opaque" then
        return 1.0, 1.0
    elseif role == "blended" then
        return -1.0, 1.0
    elseif role == "occluder" then
        return 1.0, -1.0
    elseif role == "dropShadow" then
        return -1.0, -1.0
    end
    error(("tecs: '%s' is not an instance role"):format(tostring(role)), 2)
end

--- Half extents covering a quad of this scale at this rotation.
---
--- Unrotated, each axis is its own scale. Rotated, half the sum of both scales
--- covers every angle: looser than the true extent and never smaller, so the
--- cull can only keep something it might have dropped, never drop something it
--- should have kept.
---
--- These are half extents about the quad's middle, so the centre written
--- beside them has to be the quad's middle too. That is not always the
--- entity's position: a pivoted quad hangs off some other point of itself, and
--- the writer moves the centre with it rather than growing these to cover
--- where the geometry went.
--- @param rotation Radians. Exactly zero takes the tight per-axis answer;
---     anything else, however small, takes the looser rotation-proof one.
--- @param scaleX Quad width in world units. Negative is mirrored, and the
---     extent is taken from its magnitude.
--- @param scaleY Quad height in world units, under the same rule.
--- @return Half extent along X in world units.
--- @return Half extent along Y in world units, equal to the first whenever the
---     quad is rotated at all.
function instancelayout.extentOf(rotation: number, scaleX: number, scaleY: number): number, number
    local ex: number
    local ey: number
    if rotation == 0.0 then
        ex = 0.5 * (scaleX < 0.0 and -scaleX or scaleX)
        ey = 0.5 * (scaleY < 0.0 and -scaleY or scaleY)
    else
        ex = 0.5 * ((scaleX < 0.0 and -scaleX or scaleX) + (scaleY < 0.0 and -scaleY or scaleY))
        ey = ex
    end
    return ex, ey
end

return instancelayout
