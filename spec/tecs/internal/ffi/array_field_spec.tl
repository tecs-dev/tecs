require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

local record ArrHolder is tecs.Component
    vals: {number}
end

local Holder = tecs.ecs.newFFIComponent({
    name = "FFIArrayFieldHolder",
    container = ArrHolder,
    fields = {{"vals", "float[3]"}},
})

describe(
    "FFI array fields",
    function()
        it(
            "copies a 1-based table into all elements",
            function()
                local inst = Holder({vals = {10, 20, 30}}) as {string: {integer: number}}
                luassert.equals(10, inst.vals[0])
                luassert.equals(20, inst.vals[1])
                luassert.equals(30, inst.vals[2])
            end
        )

        it(
            "copies a 0-based table into all elements",
            function()
                local inst = Holder({vals = {[0] = 1, [1] = 2, [2] = 3}}) as {string: {integer: number}}
                luassert.equals(1, inst.vals[0])
                luassert.equals(2, inst.vals[1])
                luassert.equals(3, inst.vals[2])
            end
        )

        it(
            "round-trips through a table snapshot",
            function()
                local world = tecs.ecs.newWorld()
                local id = world:spawn(Holder({vals = {7, 8, 9}}))
                world:commit()

                local snap = world:saveSnapshot({format = "table"})
                world:loadSnapshot(snap)

                local inst = world:get(id, Holder) as {string: {integer: number}}
                luassert.equals(7, inst.vals[0])
                luassert.equals(8, inst.vals[1])
                luassert.equals(9, inst.vals[2])
            end
        )
    end
)
