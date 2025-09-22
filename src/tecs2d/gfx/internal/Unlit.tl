local tecs <const> = require("tecs")

--- Tag component that opts an entity out of dynamic lighting.
--- Entities with `Unlit` are rendered at full brightness, skipping the
--- deferred lighting pass. Composes with the per-layer unlit mask
--- (pipeline:setLayerUnlit): either makes the entity unlit.
local Unlit <const> = tecs.newTagComponent({
    name = "Unlit",
})

return Unlit
