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

local record lightlayout
    --- Lights the lighting pass will consider in one frame. Past this the
    --- remainder is dropped rather than reported, because the alternative is a
    --- frame that raises over a light nobody would have picked out of the
    --- image.
    MAX: integer

    --- Floats per light: vec4 position and radius, vec4 colour and intensity.
    FLOATS: integer
    BYTES: integer
end

lightlayout.MAX = 256
lightlayout.FLOATS = 8
lightlayout.BYTES = lightlayout.FLOATS * 4

return lightlayout
