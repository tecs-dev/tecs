--- Optional deterministic ordering for children of a Flow container.

local tecs <const> = require("tecs")

local FlowOrder: tecs.ScalarComponent<number> = tecs.newScalarComponent({
    name = "FlowOrder",
    kind = "number",
    default = 0,
})

return FlowOrder
