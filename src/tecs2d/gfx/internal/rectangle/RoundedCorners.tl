local tecs <const> = require("tecs")

--- RoundedCorners component for adding rounded corners to rectangles.
--- This component requires a Rectangle component on the same entity.
--- Entities with this component will have rounded corners with the specified radii.
local record RoundedCorners is tecs.Component
    --- Corner radius X (horizontal radius for rounded corners).
    rx: number

    --- Corner radius Y (vertical radius for rounded corners).
    --- If not specified, defaults to rx for uniform rounding.
    ry: number

    --- Create a new RoundedCorners component.
    --- @param rx Corner radius X (required).
    --- @param ry Corner radius Y (optional, defaults to rx).
    metamethod __call: function(
        self,
        rx: number,
        ry?: number
    ): RoundedCorners
end

tecs.newFFIComponent({
    name = "RoundedCorners",
    container = RoundedCorners,
    fields = {
        {"rx", "float"},
        {"ry", "float"}
    },
    init = function(instance: RoundedCorners, _rx: number, ry?: number)
        local rxVal = assert(instance.rx, "RoundedCorners requires rx (corner radius)")
        local ryVal = ry or rxVal
        -- SDF math assumes non-negative radii; clamp to keep behavior sane.
        if rxVal < 0 then rxVal = 0 end
        if ryVal < 0 then ryVal = 0 end
        instance.rx = rxVal
        instance.ry = ryVal
    end,
    -- RoundedCorners requires a Rectangle component on the same entity.
    -- The framework does not yet have declarative component requirements,
    -- so this stays as a convention for now.
})

return RoundedCorners
