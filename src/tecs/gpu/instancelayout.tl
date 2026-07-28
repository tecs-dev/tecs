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

--- The instance and cull-bound layouts, and the two helpers that pack into
--- them.
---
--- Constants and pure functions only: nothing here touches a device or holds
--- state. What a writer gets from it is the stride to advance by, the sentinel
--- values for a slot nothing owns, and the packing rule for `origin.z`.
local record instancelayout
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
    --- through `CLIPS - 1`. The ceiling is what keeps the packing exact: the
    --- largest packed value is 255 * 64 + 63, which is 16383, well inside the
    --- 16,777,216 a float32 represents integers exactly to. `CLIP_SLOTS` in
    --- `assets/shaders/instance.frag.glsl` is the same number.
    CLIPS: integer
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
instancelayout.CLIPS = 256

--- The `origin.z` an instance on this texture-array layer, in this clip
--- region, carries.
---
--- One float says both because there is exactly one spare place for the clip
--- index and growing the instance to hold it would cost every instance sixteen
--- bytes to say something almost all of them have nothing to say about. The
--- shader recovers the layer with a modulo and the region with a division, and
--- both are exact for every value this produces.
---
--- Region zero packs to the layer itself, so a writer that never mentions a
--- clip writes what it always wrote.
--- @param clip Zero to `CLIPS - 1`, zero being no clipping.
--- @param layer Zero to `LAYER_SLOTS - 1`. Unchecked: a layer at or above the
---     stride lands in the next clip region rather than raising.
--- @return The float to write into `origin.z`, exact in float32 for every
---     value in range.
function instancelayout.packSlot(clip: integer, layer: number): number
    return clip * LAYER_SLOTS + layer
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
