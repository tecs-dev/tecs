--- Shared orthographic view transform builder.
---
--- Builds the camera view transform used by the Camera, the GPU renderer,
--- and the forward blend pass. All three must apply the identical
--- translate/rotate/scale order or world->screen math diverges between
--- the CPU and GPU paths.

local record ortho
    setOrthographic: function(t: love.math.Transform, camX: number, camY: number,
        zoom: number, rotation: number, w: number, h: number, spX: number, spY: number)
end

function ortho.setOrthographic(t: love.math.Transform, camX: number, camY: number,
        zoom: number, rotation: number, w: number, h: number, spX: number, spY: number)
    t:reset()
    t:translate(w / 2 + spX, h / 2 + spY)
    t:rotate(rotation)
    t:scale(zoom, zoom)
    t:translate(-camX, -camY)
end

return ortho
