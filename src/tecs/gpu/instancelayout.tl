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

local record instancelayout
    --- Floats per instance: four vec4s.
    FLOATS: integer
    BYTES: integer

    --- Floats per cull bound: centre xy and half extent xy.
    ---
    --- Kept apart from the instance because the cull reads it for every entity
    --- every frame, drawn or not, while the instance is only read for what
    --- survives. Sixteen bytes streamed beats sixty-four bytes gathered.
    BOUND_FLOATS: integer
    BOUND_BYTES: integer

    --- Half extent for something on a layer the view rectangle does not
    --- describe: screen space, virtual coordinates, parallax or ignored zoom.
    --- Big enough that no finite view is outside it, and finite so the
    --- comparison stays arithmetic rather than a special case.
    UNBOUNDED: number

    --- Centre for a slot nothing owns. No view overlaps a bound out here, so
    --- the cull drops it before the draw sees it.
    HIDDEN: number
end

instancelayout.FLOATS = 16
instancelayout.BYTES = instancelayout.FLOATS * 4
instancelayout.BOUND_FLOATS = 4
instancelayout.BOUND_BYTES = instancelayout.BOUND_FLOATS * 4
instancelayout.UNBOUNDED = 1e30
instancelayout.HIDDEN = 1e30

--- Half extents covering a quad of this scale at this rotation.
---
--- Unrotated, each axis is its own scale. Rotated, half the sum of both scales
--- covers every angle: looser than the true extent and never smaller, so the
--- cull can only keep something it might have dropped, never drop something it
--- should have kept.
function instancelayout.extentOf(rotation: number, scaleX: number,
                                 scaleY: number): number, number
    local ex: number
    local ey: number
    if rotation == 0.0 then
        ex = 0.5 * (scaleX < 0.0 and -scaleX or scaleX)
        ey = 0.5 * (scaleY < 0.0 and -scaleY or scaleY)
    else
        ex = 0.5 * ((scaleX < 0.0 and -scaleX or scaleX)
            + (scaleY < 0.0 and -scaleY or scaleY))
        ey = ex
    end
    return ex, ey
end

return instancelayout
