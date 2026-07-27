--- The shape of one light, in one place.
---
--- Two things write this layout: the extractor, collecting light entities into
--- a frame packet, and the deferred pipeline, filling the buffer its lighting
--- pass reads. Both write the same eight floats, so a second statement of the
--- shape is a second thing to keep in step with the shader.
---
--- What the fields mean lives with `Deferred.Light`, which is the record form
--- of exactly these floats. What is here is what a writer needs to place them
--- and to size an array.
---
--- The order is fixed by `assets/shaders/deferred.lighting.frag.glsl`: x, y and
--- z of the position, then the radius, then red, green, blue and the intensity.
--- Position and colour are a `vec4` each in the shader's `Light` struct, which
--- is what makes the stride exactly eight floats with nothing padding it out.
--- Position is in the lighting target's own pixels rather than world units,
--- since by that pass whatever put geometry on a pixel has already settled.

local record lightlayout
    --- Lights the lighting pass will consider in one frame. Past this the
    --- remainder is dropped rather than reported, because the alternative is a
    --- frame that raises over a light nobody would have picked out of the
    --- image.
    ---
    --- Purely a host-side ceiling, unlike the layer and clip counts: it sizes
    --- the light buffer and the staging that fills it, and the shader loops to
    --- a count handed over per frame rather than to a constant of its own.
    --- Raising it costs buffer bytes and shader time, and needs no shader edit.
    MAX: integer

    --- Floats per light: vec4 position and radius, vec4 colour and intensity.
    FLOATS: integer
    BYTES: integer
end

lightlayout.MAX = 256
lightlayout.FLOATS = 8
lightlayout.BYTES = lightlayout.FLOATS * 4

return lightlayout
