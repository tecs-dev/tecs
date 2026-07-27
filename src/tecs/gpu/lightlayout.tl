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
--- Position, height and radius are in world units. The lighting pass is handed
--- the view through `Deferred:setView` and takes each fragment back out to the
--- world rather than bringing the lights in, because everything that comes
--- after wants a world-space ray: an occluder mask is built with a world
--- projection and a shadow march is a march through the world.

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

    --- Tiles the view is divided into on each axis, so a fragment consults
    --- the lights that reach its tile rather than every light in the scene.
    ---
    --- A count rather than a size in pixels, so the two buffers below are
    --- allocated once and never replaced while a frame in flight is reading
    --- them. `LIGHT_TILES` in `assets/shaders/include/lighting.glsl` is the
    --- same number and the pair only works while they agree.
    TILES: integer

    --- Lights one tile holds. `LIGHT_TILE_SLOTS` in the same include is the
    --- same number. A tile reached by more than this keeps the ones earliest
    --- in the light buffer, which is a stated choice rather than whichever
    --- the device happened to write first.
    TILE_SLOTS: integer

    --- Tiles in the whole grid, which is what sizes the count buffer.
    TILE_COUNT: integer
end

lightlayout.MAX = 256
lightlayout.FLOATS = 8
lightlayout.BYTES = lightlayout.FLOATS * 4
lightlayout.TILES = 32
lightlayout.TILE_SLOTS = 64
lightlayout.TILE_COUNT = lightlayout.TILES * lightlayout.TILES

return lightlayout
