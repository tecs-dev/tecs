-- Rendering-domain timing stages, registered once and shared by every caller.

local timing <const> = require("tecs.timing")

local record renderprofile
    total: timing.Stage
    sprites: timing.Stage
    meshes: timing.Stage
end

renderprofile.total = timing.stage("extract")
renderprofile.sprites = timing.stage("extractSprites")
renderprofile.meshes = timing.stage("extractMeshes")

return renderprofile
