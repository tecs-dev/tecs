require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe(
    "FFI component archetype transitions",
    function()
        describe(
            "single entity transitions",
            function()
                it(
                    "should preserve FFI data when adding a component",
                    function()
                        local record Position is tecs.ecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): Position
                        end
                        local PositionComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_Position1",
                                container = Position,
                                fields = {{"x", "float"}, {"y", "float"}},
                            }
                        )

                        local record Tag is tecs.ecs.Component
                        end
                        local TagComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_Tag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(PositionComponent(100.5, 200.5))
                        world:update(1 / 60)

                        local pos1 = world:get(id, PositionComponent) as Position
                        luassert.are.equal(100.5, pos1.x)
                        luassert.are.equal(200.5, pos1.y)

                        world:set(id, TagComponent())
                        world:update(1 / 60)

                        local pos2 = world:get(id, PositionComponent) as Position
                        luassert.is_not_nil(pos2)
                        luassert.are.equal(100.5, pos2.x)
                        luassert.are.equal(200.5, pos2.y)
                    end
                )

                it(
                    "should preserve FFI data when removing a component",
                    function()
                        local record Circle is tecs.ecs.Component
                            radius: number
                            metamethod __call: function(self, radius: number): Circle
                        end
                        local CircleComponent = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_Circle1", container = Circle, fields = {{"radius", "float"}}}
                        )

                        local record Marker is tecs.ecs.Component
                        end
                        local MarkerComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_Marker1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(CircleComponent(25.5), MarkerComponent())
                        world:update(1 / 60)

                        local circle1 = world:get(id, CircleComponent) as Circle
                        luassert.are.equal(25.5, circle1.radius)

                        world:remove(id, MarkerComponent)
                        world:update(1 / 60)

                        local circle2 = world:get(id, CircleComponent) as Circle
                        luassert.is_not_nil(circle2)
                        luassert.are.equal(25.5, circle2.radius)
                    end
                )

                it(
                    "should preserve multiple FFI components through transitions",
                    function()
                        local record Vec2 is tecs.ecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): Vec2
                        end
                        local TransformComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_Transform1",
                                container = Vec2,
                                fields = {{"x", "float"}, {"y", "float"}},
                            }
                        )

                        local record Color is tecs.ecs.Component
                            r: number
                            g: number
                            b: number
                            a: number
                            metamethod __call: function(self, r: number, g: number, b: number, a: number): Color
                        end
                        local ColorComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_Color1",
                                container = Color,
                                fields = {{"r", "float"}, {"g", "float"}, {"b", "float"}, {"a", "float"}},
                            }
                        )

                        local record Physics is tecs.ecs.Component
                            mass: number
                        end
                        local PhysicsComponent = tecs.ecs.newComponent(
                            {
                                name = "FFITransitionTest_Physics1",
                                container = Physics,
                                fields = {"mass"},
                                init = function(instance: Physics, mass: number) instance.mass = mass or 1.0 end,
                            }
                        )

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(TransformComponent(50.0, 75.0), ColorComponent(1.0, 0.5, 0.25, 0.8))
                        world:update(1 / 60)

                        world:set(id, PhysicsComponent(10.0))
                        world:update(1 / 60)

                        local transform = world:get(id, TransformComponent) as Vec2
                        local color = world:get(id, ColorComponent) as Color
                        luassert.are.equal(50.0, transform.x)
                        luassert.are.equal(75.0, transform.y)
                        luassert.are.near(1.0, color.r, 0.01)
                        luassert.are.near(0.5, color.g, 0.01)

                        world:remove(id, PhysicsComponent)
                        world:update(1 / 60)

                        transform = world:get(id, TransformComponent) as Vec2
                        color = world:get(id, ColorComponent) as Color
                        luassert.are.near(50.0, transform.x, 0.01)
                        luassert.are.near(75.0, transform.y, 0.01)
                    end
                )

                it(
                    "should set new FFI component during transition",
                    function()
                        local record TestFFI is tecs.ecs.Component
                            value: number
                            metamethod __call: function(self, v: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_MutatedFFI1", container = TestFFI, fields = {{"value", "float"}}}
                        )

                        local record TestTag is tecs.ecs.Component
                        end
                        local Tag = tecs.ecs.newTagComponent({name = "FFITransitionTest_MutatedTag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(Tag())
                        world:update(1 / 60)

                        world:set(id, FFI(777.7))
                        world:update(1 / 60)

                        local ffi = world:get(id, FFI) as TestFFI
                        luassert.is_not_nil(ffi)
                        luassert.are.near(777.7, ffi.value, 0.01)
                    end
                )

                it(
                    "should update FFI component while also adding another component",
                    function()
                        local record TestFFI is tecs.ecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_MutatedFFI2",
                                container = TestFFI,
                                fields = {{"x", "float"}, {"y", "float"}},
                            }
                        )

                        local record TagA is tecs.ecs.Component
                        end
                        local TagAComp = tecs.ecs.newTagComponent({name = "FFITransitionTest_MutatedTagA"})

                        local record TagB is tecs.ecs.Component
                        end
                        local TagBComp = tecs.ecs.newTagComponent({name = "FFITransitionTest_MutatedTagB"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(FFI(10, 20), TagAComp())
                        world:update(1 / 60)

                        world:set(id, FFI(100, 200))
                        world:set(id, TagBComp())
                        world:update(1 / 60)

                        local ffi = world:get(id, FFI) as TestFFI
                        luassert.are.equal(100, ffi.x)
                        luassert.are.equal(200, ffi.y)
                    end
                )
            end
        )

        describe(
            "multiple entity transitions",
            function()
                it(
                    "should preserve FFI data when multiple entities transition simultaneously",
                    function()
                        local record Pos is tecs.ecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): Pos
                        end
                        local PosComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_MultiPos1",
                                container = Pos,
                                fields = {{"x", "float"}, {"y", "float"}},
                            }
                        )

                        local record Velocity is tecs.ecs.Component
                            vx: number
                            vy: number
                            metamethod __call: function(self, vx: number, vy: number): Velocity
                        end
                        local VelocityComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_MultiVel1",
                                container = Velocity,
                                fields = {{"vx", "float"}, {"vy", "float"}},
                            }
                        )

                        local world = tecs.ecs.newWorld()

                        local ids: {integer} = {}
                        for i = 1, 100 do
                            local id = world:spawn(PosComponent(i as number * 10.0, i as number * 20.0))
                            ids[#ids + 1] = id
                        end
                        world:update(1 / 60)

                        for i, id in ipairs(ids) do
                            world:set(id, VelocityComponent(i as number * 5.0, i as number * 7.0))
                        end
                        world:update(1 / 60)

                        for i, id in ipairs(ids) do
                            local pos = world:get(id, PosComponent) as Pos
                            local vel = world:get(id, VelocityComponent) as Velocity
                            luassert.are.equal(i * 10.0, pos.x)
                            luassert.are.equal(i * 20.0, pos.y)
                            luassert.are.equal(i * 5.0, vel.vx)
                            luassert.are.equal(i * 7.0, vel.vy)
                        end
                    end
                )

                it(
                    "should handle interleaved add and remove transitions",
                    function()
                        local record Data is tecs.ecs.Component
                            value: number
                            metamethod __call: function(self, value: number): Data
                        end
                        local DataComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_InterleavedData1",
                                container = Data,
                                fields = {{"value", "float"}},
                            }
                        )

                        local record TagA is tecs.ecs.Component
                        end
                        local TagAComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_TagA1"})

                        local record TagB is tecs.ecs.Component
                        end
                        local TagBComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_TagB1"})

                        local world = tecs.ecs.newWorld()

                        local id1 = world:spawn(DataComponent(111.0), TagAComponent())
                        local id2 = world:spawn(DataComponent(222.0), TagBComponent())
                        local id3 = world:spawn(DataComponent(333.0), TagAComponent(), TagBComponent())
                        world:update(1 / 60)

                        world:remove(id1, TagAComponent)
                        world:set(id2, TagAComponent())
                        world:remove(id3, TagBComponent)
                        world:update(1 / 60)

                        local data1 = world:get(id1, DataComponent) as Data
                        local data2 = world:get(id2, DataComponent) as Data
                        local data3 = world:get(id3, DataComponent) as Data

                        luassert.are.equal(111.0, data1.value)
                        luassert.are.equal(222.0, data2.value)
                        luassert.are.equal(333.0, data3.value)
                    end
                )
            end
        )

        describe(
            "despawn with tag components",
            function()
                it(
                    "should not crash when despawning entity with tag",
                    function()
                        local record TestTag is tecs.ecs.Component
                        end
                        local Tag = tecs.ecs.newTagComponent({name = "FFITransitionTest_DespawnTag1"})

                        local record TestFFI is tecs.ecs.Component
                            value: number
                            metamethod __call: function(self, v: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_DespawnFFI1", container = TestFFI, fields = {{"value", "float"}}}
                        )

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(FFI(42), Tag())
                        world:update(1 / 60)

                        world:despawn(id)
                        luassert.has_no.errors(function() world:update(1 / 60) end)
                    end
                )

                it(
                    "should not crash when despawning non-last entity with tag",
                    function()
                        local record TestTag is tecs.ecs.Component
                        end
                        local Tag = tecs.ecs.newTagComponent({name = "FFITransitionTest_DespawnTag2"})

                        local record TestFFI is tecs.ecs.Component
                            value: number
                            metamethod __call: function(self, v: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_DespawnFFI2", container = TestFFI, fields = {{"value", "float"}}}
                        )

                        local world = tecs.ecs.newWorld()
                        local id1 = world:spawn(FFI(1), Tag())
                        local id2 = world:spawn(FFI(2), Tag())
                        local id3 = world:spawn(FFI(3), Tag())
                        world:update(1 / 60)

                        world:despawn(id1)
                        luassert.has_no.errors(function() world:update(1 / 60) end)

                        local ffi2 = world:get(id2, FFI) as TestFFI
                        local ffi3 = world:get(id3, FFI) as TestFFI
                        luassert.are.equal(2, ffi2.value)
                        luassert.are.equal(3, ffi3.value)
                    end
                )
            end
        )

        describe(
            "column capacity growth",
            function()
                it(
                    "should access correct data via query after capacity grows",
                    function()
                        local record TestFFI is tecs.ecs.Component
                            id: number
                            metamethod __call: function(self, id: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_GrowthFFI1", container = TestFFI, fields = {{"id", "float"}}}
                        )

                        local record TestTag is tecs.ecs.Component
                        end
                        local Tag = tecs.ecs.newTagComponent({name = "FFITransitionTest_GrowthTag1"})

                        local world = tecs.ecs.newWorld()

                        local firstId = world:spawn(FFI(1), Tag())
                        world:update(1 / 60)

                        local ids: {integer} = {firstId}
                        for i = 2, 100 do
                            local id = world:spawn(FFI(i as number), Tag())
                            ids[#ids + 1] = id
                        end
                        world:update(1 / 60)

                        local query = world:query({include = {FFI, Tag}})

                        local foundCount = 0
                        for archetype, len in query:iter() do
                            local ffis = archetype:get(FFI)
                            for i = 1, len do
                                local ffi = ffis[i] as TestFFI
                                luassert.is_not_nil(ffi)
                                luassert.is_true(ffi.id >= 1 and ffi.id <= 100)
                                foundCount = foundCount + 1
                            end
                        end

                        luassert.are.equal(100, foundCount)
                    end
                )

                it(
                    "should access correct data after transition causes growth",
                    function()
                        local record TestFFI is tecs.ecs.Component
                            value: number
                            metamethod __call: function(self, v: number): TestFFI
                        end
                        local FFI = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_GrowthFFI2", container = TestFFI, fields = {{"value", "float"}}}
                        )

                        local record TagA is tecs.ecs.Component
                        end
                        local TagAComp = tecs.ecs.newTagComponent({name = "FFITransitionTest_GrowthTagA"})

                        local record TagB is tecs.ecs.Component
                        end
                        local TagBComp = tecs.ecs.newTagComponent({name = "FFITransitionTest_GrowthTagB"})

                        local world = tecs.ecs.newWorld()

                        local ids: {integer} = {}
                        for i = 1, 100 do
                            local id = world:spawn(FFI(i as number), TagAComp())
                            ids[#ids + 1] = id
                        end
                        world:update(1 / 60)

                        for _, id in ipairs(ids) do
                            world:set(id, TagBComp())
                        end
                        world:update(1 / 60)

                        local query = world:query({include = {FFI, TagAComp, TagBComp}})

                        local foundCount = 0
                        for archetype, len in query:iter() do
                            local ffis = archetype:get(FFI)
                            for i = 1, len do
                                local ffi = ffis[i] as TestFFI
                                luassert.is_not_nil(ffi)
                                luassert.is_true(ffi.value >= 1 and ffi.value <= 100)
                                foundCount = foundCount + 1
                            end
                        end

                        luassert.are.equal(100, foundCount)
                    end
                )
            end
        )

        describe(
            "mixed table and FFI components",
            function()
                it(
                    "should preserve both through transitions",
                    function()
                        local record FFIData is tecs.ecs.Component
                            x: number
                            y: number
                            z: number
                            metamethod __call: function(self, x: number, y: number, z: number): FFIData
                        end
                        local FFIDataComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_MixedFFI1",
                                container = FFIData,
                                fields = {{"x", "float"}, {"y", "float"}, {"z", "float"}},
                            }
                        )

                        local record TableData is tecs.ecs.Component
                            name: string
                            values: {number}
                        end
                        local TableDataComponent = tecs.ecs.newComponent(
                            {
                                name = "FFITransitionTest_MixedTable1",
                                container = TableData,
                                fields = {"name", "values"},
                                init = function(instance: TableData, name: string, values: {number})
                                    instance.name = name
                                    instance.values = values
                                end,
                            }
                        )

                        local record TransitionTag is tecs.ecs.Component
                        end
                        local TransitionTagComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_MixedTag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(
                            FFIDataComponent(1.5, 2.5, 3.5), TableDataComponent("test", {10, 20, 30})
                        )
                        world:update(1 / 60)

                        world:set(id, TransitionTagComponent())
                        world:update(1 / 60)

                        local ffiData = world:get(id, FFIDataComponent) as FFIData
                        local tableData = world:get(id, TableDataComponent) as TableData

                        luassert.are.equal(1.5, ffiData.x)
                        luassert.are.equal(2.5, ffiData.y)
                        luassert.are.equal(3.5, ffiData.z)
                        luassert.are.equal("test", tableData.name)
                        luassert.are.equal(10, tableData.values[1])

                        world:remove(id, TransitionTagComponent)
                        world:update(1 / 60)

                        ffiData = world:get(id, FFIDataComponent) as FFIData
                        tableData = world:get(id, TableDataComponent) as TableData

                        luassert.are.equal(1.5, ffiData.x)
                        luassert.are.equal("test", tableData.name)
                    end
                )
            end
        )

        describe(
            "edge cases",
            function()
                it(
                    "should handle zero values",
                    function()
                        local record ZeroData is tecs.ecs.Component
                            a: number
                            b: number
                            metamethod __call: function(self, a: number, b: number): ZeroData
                        end
                        local ZeroDataComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_Zero1",
                                container = ZeroData,
                                fields = {{"a", "float"}, {"b", "float"}},
                            }
                        )

                        local record ZeroTag is tecs.ecs.Component
                        end
                        local ZeroTagComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_ZeroTag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(ZeroDataComponent(0.0, 0.0))
                        world:update(1 / 60)

                        world:set(id, ZeroTagComponent())
                        world:update(1 / 60)

                        local data = world:get(id, ZeroDataComponent) as ZeroData
                        luassert.are.equal(0.0, data.a)
                        luassert.are.equal(0.0, data.b)
                    end
                )

                it(
                    "should handle negative values",
                    function()
                        local record NegData is tecs.ecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): NegData
                        end
                        local NegDataComponent = tecs.ecs.newFFIComponent(
                            {
                                name = "FFITransitionTest_Neg1",
                                container = NegData,
                                fields = {{"x", "float"}, {"y", "float"}},
                            }
                        )

                        local record NegTag is tecs.ecs.Component
                        end
                        local NegTagComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_NegTag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(NegDataComponent(-100.5, -999.9))
                        world:update(1 / 60)

                        world:set(id, NegTagComponent())
                        world:update(1 / 60)

                        local data = world:get(id, NegDataComponent) as NegData
                        luassert.are.near(-100.5, data.x, 0.01)
                        luassert.are.near(-999.9, data.y, 0.01)
                    end
                )

                it(
                    "should handle very large values",
                    function()
                        local record LargeData is tecs.ecs.Component
                            big: number
                            metamethod __call: function(self, big: number): LargeData
                        end
                        local LargeDataComponent = tecs.ecs.newFFIComponent(
                            {name = "FFITransitionTest_Large1", container = LargeData, fields = {{"big", "double"}}}
                        )

                        local record LargeTag is tecs.ecs.Component
                        end
                        local LargeTagComponent = tecs.ecs.newTagComponent({name = "FFITransitionTest_LargeTag1"})

                        local world = tecs.ecs.newWorld()
                        local id = world:spawn(LargeDataComponent(1e15))
                        world:update(1 / 60)

                        world:set(id, LargeTagComponent())
                        world:update(1 / 60)

                        local data = world:get(id, LargeDataComponent) as LargeData
                        luassert.are.equal(1e15, data.big)
                    end
                )
            end
        )
    end
)
