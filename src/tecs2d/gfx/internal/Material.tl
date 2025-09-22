local tecs <const> = require("tecs")

--- Material component for GPU fragment shader injection.
--- Entities with a Material stay fully GPU-batched and participate in deferred lighting.
--- The materialId links to a registered material definition in the material registry.
--- Per-entity variation is controlled by 4 float params (p0-p3).
---
--- Usage:
---   local lava = gfx.newMaterial("lava", { fragment = "shaders/lava.glsl" })
---   world:spawn(Transform(0, 0), Rectangle({w=32, h=32}), lava)
---   world:spawn(Transform(0, 0), Rectangle({w=32, h=32}), lava:withParams(0.5, 1.0, 0, 0))
local record Material is tecs.Component
    --- Material definition ID (1-255, 0 = no material)
    materialId: integer
    --- Per-entity parameter 0
    p0: number
    --- Per-entity parameter 1
    p1: number
    --- Per-entity parameter 2
    p2: number
    --- Per-entity parameter 3
    p3: number

    --- Create a new Material component.
    --- @param materialId The material definition ID
    --- @param p0 Per-entity parameter 0
    --- @param p1 Per-entity parameter 1
    --- @param p2 Per-entity parameter 2
    --- @param p3 Per-entity parameter 3
    metamethod __call: function(self, materialId: integer, p0?: number, p1?: number, p2?: number, p3?: number): Material

    --- Return a new Material value with the same materialId but different params.
    withParams: function(self: Material, p0: number, p1?: number, p2?: number, p3?: number): Material
end

tecs.newFFIComponent({
    name = "Material",
    container = Material,
    fields = {
        {"materialId", "int32_t"},
        {"p0", "float"},
        {"p1", "float"},
        {"p2", "float"},
        {"p3", "float"},
    },
    metatable = {
        __index = {
            withParams = function(self: Material, p0: number, p1?: number, p2?: number, p3?: number): Material
                return Material(self.materialId, p0 or 0, p1 or 0, p2 or 0, p3 or 0)
            end,
        }
    },
    defaults = {0, 0, 0, 0, 0},
})

return Material
