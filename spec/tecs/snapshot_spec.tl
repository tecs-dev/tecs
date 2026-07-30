require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local StringBuffer <const> = require("string.buffer")

local function saveTableSnapshot(world: tecs.World, opts?: tecs.ecs.SnapshotOptions): tecs.ecs.Snapshot
    local actualOpts: tecs.ecs.SnapshotOptions
    if opts then
        actualOpts = opts
        actualOpts.format = "table"
    else
        actualOpts = {format = "table"}
    end
    local out = world:saveSnapshot(actualOpts)
    if out.snapshot == nil then
        error("saveSnapshot(format=table) returned no snapshot")
    end
    return out.snapshot
end

local function saveBinarySnapshot(world: tecs.World, opts?: tecs.ecs.SnapshotOptions): StringBuffer
    local out = world:saveSnapshot(opts)
    if out.buffer == nil then
        error("saveSnapshot(binary) returned no buffer")
    end
    return out.buffer
end

describe(
    "snapshot save/load",
    function()
        local record Position is tecs.ecs.Component
            x: number
            y: number
            metamethod __call: function(self, x: number, y: number): Position
        end

        local record Health is tecs.ecs.Component
            hp: integer
            metamethod __call: function(self, hp: integer): Health
        end

        local PositionComp: Position
        local HealthComp: Health

        before_each(function()
            local testId = math.random(1, 1000000)
            local posContainer: Position = {}
            PositionComp = tecs.ecs.newComponent({
                name = "SnapPosition" .. testId,
                container = posContainer,
                fields = {"x", "y"},
            })
            local hpContainer: Health = {}
            HealthComp = tecs.ecs.newComponent({
                name = "SnapHealth" .. testId,
                container = hpContainer,
                fields = {"hp"},
            })
        end)

        it(
            "round-trips components with preserved entity IDs",
            function()
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(10, 20), HealthComp(100))
                local b = world:spawn(PositionComp(30, 40))
                world:commit()

                local snap = saveTableSnapshot(world)
                luassert.equals(2, snap.version)
                luassert.is_table(snap.archetypes)

                world:loadSnapshot(snap)

                luassert.is_true(world:isAlive(a))
                luassert.is_true(world:isAlive(b))
                local aPos = world:get(a, PositionComp)
                luassert.equals(10, aPos.x)
                luassert.equals(20, aPos.y)
                local aHp = world:get(a, HealthComp)
                luassert.equals(100, aHp.hp)
                local bPos = world:get(b, PositionComp)
                luassert.equals(30, bPos.x)
            end
        )

        it(
            "can be called a second time to restore the same snapshot",
            function()
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(1, 2))
                world:commit()
                local snap = saveTableSnapshot(world)

                -- Simulate gameplay drift.
                world:get(a, PositionComp).x = 999
                world:spawn(PositionComp(7, 8))
                world:commit()

                -- Restore twice: catches state not being cleaned between loads.
                world:loadSnapshot(snap)
                world:loadSnapshot(snap)

                luassert.is_true(world:isAlive(a))
                luassert.equals(1, world:get(a, PositionComp).x)

                -- After restore, new spawns should not collide with restored IDs.
                local fresh = world:spawn(PositionComp(0, 0))
                world:commit()
                luassert.is_true(fresh > a)
            end
        )

        it(
            "round-trips FFI + table components through JSON",
            function()
                -- Mirrors the save-game paint demo: one FFI component (Transform-ish)
                -- plus one table component (Cell-ish) on the same entity, through the
                -- full save -> serialize -> parse -> load pipeline.
                local data <const> = require("tecs.data")
                local testId = math.random(1, 1000000)

                local record FFIStruct is tecs.ecs.Component
                    x: number
                    y: number
                    layer: integer
                    gpuSlot: integer
                    metamethod __call: function(self, x: number, y: number, layer: integer): FFIStruct
                end
                local ffiContainer: FFIStruct = {}
                local FFIComp: FFIStruct = tecs.ecs.newFFIComponent({
                    name = "SnapFFI" .. testId,
                    container = ffiContainer,
                    fields = {
                        {"x", "float"},
                        {"y", "float"},
                        {"layer", "int32_t"},
                        {"gpuSlot", "int32_t"},
                    },
                    defaults = {0, 0, 1, -1},
                })

                local record Cell is tecs.ecs.Component
                    col: integer
                    row: integer
                    colorIdx: integer
                    metamethod __call: function(self, c: integer, r: integer, k: integer): Cell
                end
                local cellContainer: Cell = {}
                local CellComp: Cell = tecs.ecs.newComponent({
                    name = "SnapCell" .. testId,
                    container = cellContainer,
                    fields = {"col", "row", "colorIdx"},
                })

                local world = tecs.ecs.newWorld()
                local a = world:spawn(FFIComp(100, 200, 3), CellComp(4, 5, 7))
                local b = world:spawn(FFIComp(-10, -20, 1), CellComp(0, 0, 1))
                world:commit()

                local snap = saveTableSnapshot(world)
                local jsonStr = data.encodeJSON(snap as {string: any})
                local parsed = data.decodeJSON(jsonStr) as tecs.ecs.Snapshot

                world:loadSnapshot(parsed)

                luassert.is_true(world:isAlive(a), "entity a should be restored")
                luassert.is_true(world:isAlive(b), "entity b should be restored")
                local aCell = world:get(a, CellComp)
                luassert.equals(4, aCell.col)
                luassert.equals(5, aCell.row)
                luassert.equals(7, aCell.colorIdx)
                local aFFI = world:get(a, FFIComp)
                luassert.equals(100, aFFI.x)
                luassert.equals(3, aFFI.layer)
            end
        )

        it(
            "preserves FFI component metatable methods across save/load",
            function()
                -- Metatables are attached to the FFI ctype, not to individual cdata
                -- instances. Whether a struct comes from `C.new(t)` or from indexing
                -- an array of t (which is what archetype columns use), the same
                -- metatable applies. This test exercises that invariant end-to-end:
                -- spawn an entity holding an FFI component with a custom method,
                -- snapshot, load into a fresh world, and call the method on the
                -- restored cdata. If the metatable were bound per-instance instead
                -- of per-ctype, the method call would fail after load.
                local buffer = require("string.buffer")
                local testId = math.random(1, 1000000)

                local record Vec3 is tecs.ecs.Component
                    x: number
                    y: number
                    z: number
                    length: function(self): number
                    metamethod __call: function(self, x: number, y: number, z: number): Vec3
                end
                local vec3Container: Vec3 = {}
                local Vec3Comp: Vec3 = tecs.ecs.newFFIComponent({
                    name = "SnapMetaVec3" .. testId,
                    container = vec3Container,
                    fields = {
                        {"x", "double"},
                        {"y", "double"},
                        {"z", "double"},
                    },
                    metatable = {
                        __index = {
                            length = function(self: Vec3): number
                                return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
                            end,
                        },
                    },
                })

                local world = tecs.ecs.newWorld()
                local id = world:spawn(Vec3Comp(3, 4, 12))
                world:commit()

                -- Method works before save (sanity check the metatable wiring itself).
                luassert.equals(13, world:get(id, Vec3Comp):length())

                local buf = saveBinarySnapshot(world)

                -- Load into a brand-new world so we exercise the cold path: fresh
                -- archetype creation, fresh column allocation, fresh cdata slots.
                local fresh = tecs.ecs.newWorld()
                fresh:loadSnapshot(buf)

                luassert.is_true(fresh:isAlive(id), "entity should restore at original id")
                local restored = fresh:get(id, Vec3Comp)
                luassert.equals(3, restored.x)
                luassert.equals(4, restored.y)
                luassert.equals(12, restored.z)
                -- The actual assertion: metatable method still resolves.
                luassert.equals(
                    13,
                    restored:length(),
                    "metatable :length() should work on cdata loaded into a fresh archetype column"
                )
            end
        )

        it(
            "round-trips through JSON serialization",
            function()
                local data <const> = require("tecs.data")
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(10, 20), HealthComp(100))
                local b = world:spawn(PositionComp(30, 40))
                world:commit()

                local snap = saveTableSnapshot(world)
                local jsonStr = data.encodeJSON(snap as {string: any})
                local parsed = data.decodeJSON(jsonStr) as tecs.ecs.Snapshot

                world:loadSnapshot(parsed)

                luassert.is_true(world:isAlive(a))
                luassert.is_true(world:isAlive(b))
                luassert.equals(10, world:get(a, PositionComp).x)
                luassert.equals(100, world:get(a, HealthComp).hp)
            end
        )

        it(
            "survives repeated load-then-mutate cycles without orphans",
            function()
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(1, 1), HealthComp(10))
                world:spawn(PositionComp(2, 2), HealthComp(20))
                world:spawn(PositionComp(3, 3), HealthComp(30))
                world:commit()

                local snap = saveTableSnapshot(world)
                -- All 3 entities share the same archetype, so one group of 3 entities.
                luassert.equals(1, #snap.archetypes)
                luassert.equals(3, #(snap.archetypes[1].entities))

                local posQuery = world:query({name = "Pos", include = {PositionComp}})
                local function count(): integer
                    local n = 0
                    for _, len in posQuery:iter() do
                        n = n + len
                    end
                    return n
                end

                for iter = 1, 4 do
                    world:loadSnapshot(snap)
                    luassert.equals(3, count(), "iter " .. iter .. ": cell count after load")
                    luassert.is_true(world:isAlive(a), "iter " .. iter .. ": a alive after load")

                    local ids: {integer} = {}
                    for archetype, len in posQuery:iter() do
                        local entities = archetype.entities as {integer}
                        for i = 1, len do
                            ids[#ids + 1] = entities[i]
                        end
                    end
                    for i = 1, #ids do
                        world:despawn(ids[i])
                    end
                    world:commit()
                    luassert.equals(0, count(), "iter " .. iter .. ": cell count after clear")
                end
            end
        )

        it(
            "opts.layers filters Transform-bearing entities; non-Transform entities pass through",
            function()
                -- Lenient semantics: `layers` only filters entities that carry a
                -- Transform. Entities without a Transform (singletons, config)
                -- are never touched by the layer allow-list.
                local world = tecs.ecs.newWorld()
                local onLayer2 = world:spawn(tecs.Transform(0, 0, 0, 2))
                local onLayer5 = world:spawn(tecs.Transform(0, 0, 0, 5))
                local noTransform = world:spawn(PositionComp(1, 1))
                world:commit()

                local snap = saveTableSnapshot(world, {layers = {2}})
                world:loadSnapshot(snap)

                luassert.is_true(world:isAlive(onLayer2), "layer-2 entity kept")
                luassert.is_false(world:isAlive(onLayer5), "layer-5 entity filtered out")
                luassert.is_true(world:isAlive(noTransform), "non-Transform entity passes through")
            end
        )

        it(
            "filters entities via opts.filterQuery",
            function()
                -- The previous "decorate writer to filter" pattern doesn't fit the
                -- column-major data layout cleanly (writeEntity isn't called for
                -- dense archetypes). Use opts.filterQuery instead -- it builds
                -- a temp query that limits which archetypes get walked at all.
                local world = tecs.ecs.newWorld()
                local keeper = world:spawn(PositionComp(1, 1), HealthComp(10))
                local skipper = world:spawn(PositionComp(2, 2))
                world:commit()

                local snap = saveTableSnapshot(
                    world,
                    {
                        filterQuery = {include = {PositionComp, HealthComp}},
                    }
                )

                world:loadSnapshot(snap)
                luassert.is_true(world:isAlive(keeper))
                luassert.is_false(world:isAlive(skipper))
            end
        )

        it(
            "does not mutate opts.filterQuery descriptors",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1), HealthComp(10))
                world:commit()

                world:observe(
                    0, tecs.ecs.OnSnapshotSave, function(ev: tecs.ecs.OnSnapshotSave) ev:exclude(HealthComp) end
                )

                local descriptor: tecs.Query.Descriptor = {
                    include = {PositionComp},
                }

                local _snap = saveTableSnapshot(
                    world,
                    {
                        filterQuery = descriptor,
                    }
                )

                luassert.is_nil(descriptor.temp, "saveSnapshot should not set temp on the caller descriptor")
                luassert.is_nil(descriptor.exclude, "saveSnapshot should not append excludes to the caller descriptor")
            end
        )

        it(
            "leaves a reused opts table untouched across saves",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1), HealthComp(10))
                world:commit()

                world:observe(
                    0, tecs.ecs.OnSnapshotSave, function(ev: tecs.ecs.OnSnapshotSave) ev:exclude(HealthComp) end
                )

                local descriptor: tecs.Query.Descriptor = {
                    include = {PositionComp},
                }
                local opts: tecs.ecs.SnapshotOptions = {
                    format = "table",
                    filterQuery = descriptor,
                }

                saveTableSnapshot(world, opts)
                saveTableSnapshot(world, opts)

                luassert.equals(
                    descriptor, opts.filterQuery, "opts.filterQuery must keep the caller's descriptor reference"
                )
                luassert.is_nil(descriptor.exclude, "repeated saves must not accumulate excludes")
            end
        )

        it(
            "keeps table columns aligned when a serialize hook returns nil",
            function()
                local testId = math.random(1, 1000000)
                local record Skippy is tecs.ecs.Component
                    v: number
                    skip: number
                end
                local SkippyComp: Skippy
                SkippyComp = tecs.ecs.newComponent({
                    name = "SnapSkippy" .. testId,
                    container = {} as Skippy,
                    fields = {"v", "skip"},
                    serialize = function(value: Skippy): {string: any}
                        if value.skip == 1 then
                            return nil
                        end
                        return {v = value.v, skip = value.skip}
                    end,
                    deserialize = function(_world: tecs.World, data: {string: any}): Skippy
                        return SkippyComp(data.v as number, data.skip as number)
                    end,
                })

                local world = tecs.ecs.newWorld()
                local e1 = world:spawn(SkippyComp(111, 1), HealthComp(10))
                local e2 = world:spawn(SkippyComp(222, 0), HealthComp(20))
                world:commit()

                local snap = saveTableSnapshot(world)
                world:loadSnapshot(snap)

                local s2 = world:get(e2, SkippyComp) as Skippy
                luassert.is_not_nil(s2)
                luassert.equals(222, s2.v, "the nil hole must not shift later entities' values")
                local s1 = world:get(e1, SkippyComp) as Skippy
                if s1 then
                    luassert.not_equals(222, s1.v, "e1 must not inherit e2's serialized value")
                end
                luassert.equals(10, (world:get(e1, HealthComp) as Health).hp)
                luassert.equals(20, (world:get(e2, HealthComp) as Health).hp)
            end
        )

        it(
            "round-trips a binary snapshot with a custom-serialize-only FFI component",
            function()
                local testId = math.random(1, 1000000)
                local record HalfCustom is tecs.ecs.Component
                    a: number
                    metamethod __call: function(self, a: number): HalfCustom
                end
                local HalfCustomComp: HalfCustom = tecs.ecs.newFFIComponent({
                    name = "SnapHalfCustom" .. testId,
                    container = {} as HalfCustom,
                    fields = {{"a", "float"}},
                    -- Custom serialize only: the raw byte codec must disengage in
                    -- BOTH directions or the binary stream desyncs.
                    serialize = function(value: HalfCustom): {string: any} return {a = value.a} end,
                })
                local record PlainFFI is tecs.ecs.Component
                    b: number
                    metamethod __call: function(self, b: number): PlainFFI
                end
                local PlainFFIComp: PlainFFI = tecs.ecs.newFFIComponent({
                    name = "SnapPlainFFI" .. testId,
                    container = {} as PlainFFI,
                    fields = {{"b", "float"}},
                })

                local world = tecs.ecs.newWorld()
                local ids: {integer} = {}
                for i = 1, 8 do
                    ids[i] = world:spawn(HalfCustomComp(i), PlainFFIComp(i * 100))
                end
                world:commit()

                local buffer = saveBinarySnapshot(world)
                world:loadSnapshot(buffer)

                for i = 1, 8 do
                    luassert.equals(i, (world:get(ids[i], HalfCustomComp) as HalfCustom).a)
                    luassert.equals(i * 100, (world:get(ids[i], PlainFFIComp) as PlainFFI).b)
                end
            end
        )

        it(
            "rebuilds the allocator free stack on load",
            function()
                local world = tecs.ecs.newWorld()
                local ids: {integer} = {}
                for i = 1, 20 do
                    ids[i] = world:spawn(PositionComp(i, i))
                end
                world:commit()
                local maxSlot = 0
                for i = 1, 20 do
                    local slot = ids[i] % 2 ^ 22
                    if slot > maxSlot then
                        maxSlot = slot
                    end
                end
                for i = 1, 10 do
                    world:despawn(ids[i])
                end
                world:commit()

                local buffer = saveBinarySnapshot(world)
                world:loadSnapshot(buffer)

                -- The ten dead slots must be reusable; a fresh spawn draws from
                -- the recycled range instead of pushing the watermark.
                local fresh = world:spawn(PositionComp(99, 99))
                world:commit()
                luassert.is_true(
                    fresh % 2 ^ 22 <= maxSlot, "post-load spawns must reuse slots that were dead at save time"
                )
                for i = 11, 20 do
                    luassert.is_true(world:isAlive(ids[i]))
                end
            end
        )

        it(
            "round-trips through a LuaJIT string.buffer",
            function()
                local buffer = require("string.buffer")
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(11, 22), HealthComp(77))
                local b = world:spawn(PositionComp(33, 44))
                world:commit()

                local buf = saveBinarySnapshot(world)

                world:loadSnapshot(buf)

                luassert.is_true(world:isAlive(a))
                luassert.is_true(world:isAlive(b))
                luassert.equals(11, world:get(a, PositionComp).x)
                luassert.equals(22, world:get(a, PositionComp).y)
                luassert.equals(77, world:get(a, HealthComp).hp)
                luassert.equals(33, world:get(b, PositionComp).x)
            end
        )

        it(
            "loadSnapshot accepts a Lua string source",
            function()
                local world = tecs.ecs.newWorld()
                local a = world:spawn(PositionComp(7, 8))
                world:commit()

                local buf = saveBinarySnapshot(world)
                local bytes = tostring(buf) -- what filesystem.read hands back

                world:loadSnapshot(bytes)
                luassert.is_true(world:isAlive(a))
                luassert.equals(7, world:get(a, PositionComp).x)
            end
        )

        it(
            "binary sparse loads pass world into deserialize",
            function()
                local testId = math.random(1, 1000000)

                local record NeedsWorld is tecs.ecs.Component
                    value: integer
                    metamethod __call: function(self, value: integer): NeedsWorld
                end
                local NeedsWorldComp: NeedsWorld

                local needsWorldContainer: NeedsWorld = {}
                NeedsWorldComp = tecs.ecs.newComponent({
                    name = "SparseSnapNeedsWorld" .. testId,
                    container = needsWorldContainer,
                    fields = {"value"},
                    deserialize = function(worldArg: tecs.World, data: {string: any}): NeedsWorld
                        luassert.is_not_nil(worldArg, "binary sparse deserialize should receive world")
                        return NeedsWorldComp(data.value as integer)
                    end,
                })

                local SparseTagRel = tecs.ecs.newRelationship({
                    name = "SparseSnapDeserialize" .. testId,
                    sparse = true,
                    exclusive = true,
                })

                local world = tecs.ecs.newWorld()
                local target = world:spawn()
                local owner = world:spawn(NeedsWorldComp(7), SparseTagRel(target) as tecs.ecs.Component)
                world:commit()

                local buf = saveBinarySnapshot(world)
                local fresh = tecs.ecs.newWorld()

                fresh:loadSnapshot(buf)
                luassert.is_true(fresh:isAlive(owner))
                local restoredComp = fresh:get(owner, NeedsWorldComp) as NeedsWorld
                luassert.equals(7, restoredComp.value)
                luassert.is_not_nil(fresh:get(owner, SparseTagRel as tecs.ecs.Component))
            end
        )

        it(
            "binary sparse row-major snapshots handle missing sparse values per entity",
            function()
                local testId = math.random(1, 1000000)

                local SparseMaybeRel = tecs.ecs.newRelationship({
                    name = "SparseSnapMissingValue" .. testId,
                    sparse = true,
                    exclusive = true,
                })

                local world = tecs.ecs.newWorld()
                local target = world:spawn()
                local wildcardOnly = world:spawn(PositionComp(1, 2), SparseMaybeRel as tecs.ecs.Component)
                local withValue = world:spawn(PositionComp(3, 4), SparseMaybeRel(target) as tecs.ecs.Component)
                world:commit()

                local buf = saveBinarySnapshot(world)
                local fresh = tecs.ecs.newWorld()

                fresh:loadSnapshot(buf)
                luassert.is_true(fresh:isAlive(wildcardOnly))
                luassert.is_true(fresh:isAlive(withValue))
                luassert.equals(1, fresh:get(wildcardOnly, PositionComp).x)
                luassert.equals(3, fresh:get(withValue, PositionComp).x)
                luassert.is_nil(fresh:get(wildcardOnly, SparseMaybeRel as tecs.ecs.Component))
                luassert.is_not_nil(fresh:get(withValue, SparseMaybeRel as tecs.ecs.Component))
            end
        )

        it(
            "delivers opts.customData entries via StartSnapshotLoad:onData",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local buf = saveBinarySnapshot(
                    world,
                    {
                        customData = {
                            build = "v0.1.2-alpha",
                            score = 42,
                            checkpoint = {level = "intro"},
                        },
                    }
                )

                local seen: {string: any} = {}
                world:observe(
                    0,
                    tecs.ecs.StartSnapshotLoad,
                    function(ev: tecs.ecs.StartSnapshotLoad)
                        ev:onData("build", function(v: any) seen.build = v end)
                        ev:onData("score", function(v: any) seen.score = v end)
                        ev:onData("checkpoint", function(v: any) seen.checkpoint = v end)
                    end
                )

                world:loadSnapshot(buf)
                luassert.equals("v0.1.2-alpha", seen.build)
                luassert.equals(42, seen.score)
                luassert.equals("intro", (seen.checkpoint as {string: string}).level)
            end
        )

        it(
            "OnSnapshotSave listeners can attach data via addData",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                world:observe(
                    0,
                    tecs.ecs.OnSnapshotSave,
                    function(ev: tecs.ecs.OnSnapshotSave)
                        ev:addData("plugin.physics", "snapshot-bytes")
                        ev:addData("plugin.extra", {a = 1, b = 2})
                    end
                )

                local buf = saveBinarySnapshot(world)

                local seen: {string: any} = {}
                world:observe(
                    0,
                    tecs.ecs.StartSnapshotLoad,
                    function(ev: tecs.ecs.StartSnapshotLoad)
                        ev:onData("plugin.physics", function(v: any) seen["plugin.physics"] = v end)
                        ev:onData("plugin.extra", function(v: any) seen["plugin.extra"] = v end)
                    end
                )

                world:loadSnapshot(buf)
                luassert.equals("snapshot-bytes", seen["plugin.physics"])
                luassert.equals(1, (seen["plugin.extra"] as {string: integer}).a)
                luassert.equals(2, (seen["plugin.extra"] as {string: integer}).b)
            end
        )

        it(
            "addSnapshotHandler saves loads and finishes named data",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local sourceValue = 7
                local loadedValue = 0
                local order: {string} = {}
                local finishPrelude: tecs.ecs.SnapshotPrelude | nil

                world:addSnapshotHandler({
                    name = "spec.snapshotHandler",
                    save = function(_world: tecs.World): any
                        table.insert(order, "save")
                        return {value = sourceValue}
                    end,
                    load = function(_world: tecs.World, value: any)
                        table.insert(order, "load")
                        loadedValue = (value as {string: integer}).value
                    end,
                    finish = function(_world: tecs.World, prelude: tecs.ecs.SnapshotPrelude)
                        table.insert(order, "finish")
                        finishPrelude = prelude
                    end,
                })

                local snap = saveTableSnapshot(world)
                sourceValue = 99
                world:loadSnapshot(snap)

                luassert.equals(7, loadedValue)
                luassert.equals("save", order[1])
                luassert.equals("load", order[2])
                luassert.equals("finish", order[3])
                luassert.is_not_nil(finishPrelude)
                luassert.equals(2, (finishPrelude as tecs.ecs.SnapshotPrelude).version)
            end
        )

        it(
            "addSnapshotHandler omits nil save results",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local loaded = false
                world:addSnapshotHandler({
                    name = "spec.nilSnapshotHandler",
                    save = function(_world: tecs.World): any return nil end,
                    load = function(_world: tecs.World, _value: any) loaded = true end,
                })

                world:loadSnapshot(saveTableSnapshot(world))
                luassert.is_false(loaded)
            end
        )

        it(
            "addSnapshotHandler requires a non-empty name",
            function()
                local world = tecs.ecs.newWorld()

                luassert.has_error(
                    function()
                        world:addSnapshotHandler({
                            name = "",
                            save = function(_world: tecs.World): any return true end,
                        })
                    end,
                    "snapshot handler requires a non-empty name"
                )
            end
        )

        it(
            "transient components are omitted without excluding entities",
            function()
                local testId = math.random(1, 1000000)

                local record RuntimeData is tecs.ecs.Component
                    slot: integer
                    metamethod __call: function(self, slot: integer): RuntimeData
                end

                local record DurableData is tecs.ecs.Component
                    value: integer
                    metamethod __call: function(self, value: integer): DurableData
                end

                local RuntimeComp = tecs.ecs.newComponent({
                    name = "SnapRuntime" .. testId,
                    container = {} as RuntimeData,
                    fields = {"slot"},
                    defaults = {0},
                    transient = true,
                })

                local DurableComp = tecs.ecs.newComponent({
                    name = "SnapDurable" .. testId,
                    container = {} as DurableData,
                    fields = {"value"},
                    requires = {RuntimeComp},
                })

                local world = tecs.ecs.newWorld()
                local id = world:spawn(DurableComp(42), RuntimeComp(99))
                world:commit()

                local snap = saveTableSnapshot(world)
                local componentNames: {string: boolean} = {}
                for i = 1, #snap.componentTable do
                    componentNames[snap.componentTable[i].name] = true
                end
                luassert.is_true(componentNames[DurableComp.componentName])
                luassert.is_nil(componentNames[RuntimeComp.componentName])

                world:loadSnapshot(snap)

                luassert.is_true(world:isAlive(id))
                luassert.equals(42, world:get(id, DurableComp).value)
                luassert.is_true(world:has(id, RuntimeComp))
                luassert.equals(0, world:get(id, RuntimeComp).slot)
            end
        )

        it(
            "transient tag scalar and FFI components are omitted from snapshots",
            function()
                local testId = math.random(1, 1000000)

                local TransientTag = tecs.ecs.newTagComponent({
                    name = "SnapTransientTag" .. testId,
                    transient = true,
                })

                local TransientScalar = tecs.ecs.newScalarComponent({
                    name = "SnapTransientScalar" .. testId,
                    kind = "number",
                    default = 0,
                    transient = true,
                })

                local record TransientFFI is tecs.ecs.Component
                    value: integer
                    metamethod __call: function(self, value: integer): TransientFFI
                end

                local TransientFFIComp = tecs.ecs.newFFIComponent({
                    name = "SnapTransientFFI" .. testId,
                    container = {} as TransientFFI,
                    fields = {{"value", "int32_t"}},
                    transient = true,
                })

                local world = tecs.ecs.newWorld()
                local id = world:spawn(PositionComp(1, 1), TransientTag, TransientScalar(12), TransientFFIComp(34))
                world:commit()

                local snap = saveTableSnapshot(world)
                local componentNames: {string: boolean} = {}
                for i = 1, #snap.componentTable do
                    componentNames[snap.componentTable[i].name] = true
                end
                luassert.is_true(componentNames[PositionComp.componentName])
                luassert.is_nil(componentNames[TransientTag.componentName])
                luassert.is_nil(componentNames[TransientScalar.componentName])
                luassert.is_nil(componentNames[TransientFFIComp.componentName])

                world:loadSnapshot(snap)
                luassert.is_true(world:isAlive(id))
                luassert.is_false(world:has(id, TransientTag))
                luassert.is_false(world:has(id, TransientScalar))
                luassert.is_false(world:has(id, TransientFFIComp))
            end
        )

        it(
            "transient relationships are omitted from snapshots",
            function()
                local testId = math.random(1, 1000000)

                local record Link is tecs.ecs.Relationship
                    weight: integer
                    metamethod __call: function(self, target: integer, weight: integer): Link
                end

                local LinkRel = tecs.ecs.newRelationship({
                    name = "SnapTransientLink" .. testId,
                    container = {} as Link,
                    fields = {"weight"},
                    transient = true,
                })

                local world = tecs.ecs.newWorld()
                local target = world:spawn(PositionComp(1, 1))
                local source = world:spawn(PositionComp(2, 2), LinkRel(target, 7))
                world:commit()

                local snap = saveTableSnapshot(world)
                local componentNames: {string: boolean} = {}
                for i = 1, #snap.componentTable do
                    componentNames[snap.componentTable[i].name] = true
                end
                luassert.is_nil(componentNames[LinkRel(target).componentName])

                world:loadSnapshot(snap)
                luassert.is_true(world:isAlive(source))
                luassert.is_false(world:has(source, LinkRel(target)))
            end
        )

        it(
            "rejects transient components that define custom serializers",
            function()
                local testId = math.random(1, 1000000)

                local record BadTable is tecs.ecs.Component
                    value: integer
                    metamethod __call: function(self, value: integer): BadTable
                end

                local okTable = pcall(function()
                    tecs.ecs.newComponent({
                        name = "BadTransientTable" .. testId,
                        container = {} as BadTable,
                        fields = {"value"},
                        transient = true,
                        serialize = function(_inst: BadTable): {string: any} return {value = 1} end,
                    })
                end)
                luassert.is_false(okTable)

                local record BadFFI is tecs.ecs.Component
                    value: integer
                    metamethod __call: function(self, value: integer): BadFFI
                end

                local okFFI = pcall(function()
                    tecs.ecs.newFFIComponent({
                        name = "BadTransientFFI" .. testId,
                        container = {} as BadFFI,
                        fields = {{"value", "int32_t"}},
                        transient = true,
                        serialize = function(_inst: BadFFI): {string: any} return {value = 1} end,
                    })
                end)
                luassert.is_false(okFFI)

                local record BadRel is tecs.ecs.Relationship
                    value: integer
                    metamethod __call: function(self, target: integer, value: integer): BadRel
                end

                local okRel = pcall(function()
                    tecs.ecs.newRelationship({
                        name = "BadTransientRel" .. testId,
                        container = {} as BadRel,
                        fields = {"value"},
                        transient = true,
                        serialize = function(_inst: BadRel): {string: any} return {value = 1} end,
                    })
                end)
                luassert.is_false(okRel)
            end
        )

        it(
            "restores the state stack",
            function()
                local world = tecs.ecs.newWorld()
                world:createState("base")
                world:createState("ready")
                world:createState("game")
                world:pushState("base")
                world:pushState("game")
                world:spawn(PositionComp(1, 1))
                world:commit()

                local snap = saveTableSnapshot(world)

                world:popState()
                world:pushState("ready")
                luassert.equals("ready", world:peekState())

                world:loadSnapshot(snap)

                luassert.equals("game", world:peekState())
            end
        )

        it(
            "errors when a saved state stack references an unregistered state",
            function()
                local world = tecs.ecs.newWorld()
                world:createState("game")
                world:pushState("game")
                world:spawn(PositionComp(1, 1))
                world:commit()

                local snap = saveTableSnapshot(world)
                local fresh = tecs.ecs.newWorld()

                luassert.error_matches(function() fresh:loadSnapshot(snap) end, "saved state 'game' is not registered")
            end
        )

        it(
            "restores pipeline accumulator and phase enabled state",
            function()
                local world = tecs.ecs.newWorld({timestep = 0.1})
                world:disablePhase(tecs.ecs.phases.Update)
                world:update(0.05)

                local savedAccumulator = world.pipeline.fixedAccumulator
                local snap = saveTableSnapshot(world)

                world:enablePhase(tecs.ecs.phases.Update)
                (world.pipeline as {string: any}).fixedAccumulator = 0

                world:loadSnapshot(snap)

                luassert.is_near(savedAccumulator, world.pipeline.fixedAccumulator, 1e-9)
                local phaseStates = (world.pipeline as {string: any}).phaseStates as {boolean}
                luassert.is_false(phaseStates[tecs.ecs.phases.Update.position])
            end
        )

        it(
            "rebuilds runtime entity handles from Key after loading a snapshot",
            function()
                local world = tecs.ecs.newWorld()
                local player = world:spawn(tecs.ecs.EntityKey("player"), PositionComp(1, 1))
                world:commit()

                local snap = saveTableSnapshot(world)

                world:clearEntities()
                luassert.is_nil(world:byKey("player"))

                local playerHandle = 0
                local finishSawPlayer = false
                world:observe(
                    0,
                    tecs.ecs.FinishSnapshotLoad,
                    function(_ev: tecs.ecs.FinishSnapshotLoad)
                        playerHandle = world:requireKey("player")
                        finishSawPlayer = playerHandle == player
                    end
                )

                world:loadSnapshot(snap)
                luassert.equals(player, world:byKey("player"))
                luassert.equals(player, world:requireKey("player"))
                luassert.equals(player, playerHandle)
                luassert.is_true(finishSawPlayer)
            end
        )

        it(
            "rebuilds the Key index after binary snapshot load",
            function()
                local world = tecs.ecs.newWorld()
                local player = world:spawn(tecs.ecs.EntityKey("player"), PositionComp(1, 1))
                world:commit()

                local bytes = tostring(saveBinarySnapshot(world))

                world:clearEntities()
                luassert.is_nil(world:byKey("player"))

                world:loadSnapshot(bytes)
                luassert.equals(player, world:byKey("player"))
                luassert.equals(player, world:requireKey("player"))
            end
        )

        it(
            "FinishSnapshotLoad fires once after the load completes",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local buf = saveBinarySnapshot(world)

                local fired = 0
                local seenPrelude: any
                world:observe(
                    0,
                    tecs.ecs.FinishSnapshotLoad,
                    function(ev: tecs.ecs.FinishSnapshotLoad) fired = fired + 1; seenPrelude = ev.prelude end
                )

                world:loadSnapshot(buf)
                luassert.equals(1, fired)
                luassert.is_not_nil(seenPrelude)
                luassert.equals(2, (seenPrelude as {string: integer}).version)
            end
        )

        it(
            "handles nil customData (no user metadata)",
            function()
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local buf = saveBinarySnapshot(world)

                local fired = 0
                world:observe(
                    0,
                    tecs.ecs.StartSnapshotLoad,
                    function(ev: tecs.ecs.StartSnapshotLoad)
                        ev:onData("anything", function(_v: any) fired = fired + 1 end)
                    end
                )

                local prelude = world:loadSnapshot(buf)
                luassert.equals(0, fired, "no data entries should fire any onData callback")
                luassert.equals(2, prelude.version)
            end
        )

        it(
            "reuses an existing buffer when opts.buffer is provided",
            function()
                local buffer = require("string.buffer")
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(1, 1))
                world:commit()

                local sharedBuf = buffer.new()
                local returned = world:saveSnapshot({buffer = sharedBuf})
                luassert.equals("binary", returned.format)
                luassert.equals(sharedBuf, returned.buffer, "save returns the same buffer that was passed in")

                -- A second save reuses the same buffer (it gets reset automatically).
                world:spawn(PositionComp(2, 2))
                world:commit()
                local returned2 = world:saveSnapshot({buffer = sharedBuf})
                luassert.equals(sharedBuf, returned2.buffer)
            end
        )

        it(
            "FFI schema drift: saved has fewer fields than current (new fields zero-default)",
            function()
                -- Simulates loading an old save into new code that added a field.
                -- FFI struct names are global, so we register the current schema
                -- once, then hand-craft a buffer whose prelude claims an older
                -- fingerprint. The migrator reads the old-size bytes and projects
                -- same-named fields into the current struct.
                local testId = math.random(1, 1000000)
                local compName = "SchemaDriftAdd" .. testId

                local record V3 is tecs.ecs.Component
                    x: number
                    y: number
                    z: number
                    metamethod __call: function(self, x: number, y: number, z: number): V3
                end
                local v3Container: V3 = {}
                local Comp: V3 = tecs.ecs.newFFIComponent({
                    name = compName,
                    container = v3Container,
                    fields = {{"x", "double"}, {"y", "double"}, {"z", "double"}},
                })

                -- Craft a synthetic buffer that claims fingerprint "x:double,y:double|16"
                -- (no z), with one entity carrying x=3.14 y=2.71.
                local buffer = require("string.buffer")
                local ffi = require("ffi")
                local buf = buffer.new()
                buf:encode(2) -- version
                buf:encode(2) -- nextEntityId
                buf:encode(1) -- entityCount
                buf:encode(1) -- archetypeCount
                buf:encode(1) -- componentCount
                buf:encode(compName)
                buf:encode("x:double,y:double|16") -- SAVED schema (2 fields)
                -- Archetype frame
                buf:encode(1) -- columnCount
                buf:encode(1) -- entityCount
                buf:encode(1) -- columnIndex
                buf:encode(0) -- column-major mode
                -- IDs array: double[1] = {1} (entity IDs live in double[] so the
                -- 53-bit packed id survives without truncation).
                local idsRaw = ffi.new("double[?]", 1)
                local ids = idsRaw as {number}
                ids[0] = 1
                buf:putcdata(idsRaw, 8)
                -- Column bytes: 2 doubles = 16 bytes
                local valsRaw = ffi.new("double[?]", 2)
                local vals = valsRaw as {number}
                vals[0] = 3.14
                vals[1] = 2.71
                buf:putcdata(valsRaw, 16)
                -- Data section: empty
                buf:encode(nil)

                local world = tecs.ecs.newWorld()
                world:loadSnapshot(buf)

                luassert.is_true(world:isAlive(1))
                local v = world:get(1, Comp)
                luassert.is_true(math.abs(v.x - 3.14) < 1e-9)
                luassert.is_true(math.abs(v.y - 2.71) < 1e-9)
                luassert.equals(0, v.z, "new field z defaults to zero on migrated load")
            end
        )

        it(
            "FFI schema drift: saved has extra fields than current (extras discarded)",
            function()
                local testId = math.random(1, 1000000)
                local compName = "SchemaDriftRemove" .. testId

                -- Current schema: one field x.
                local record V1 is tecs.ecs.Component
                    x: number
                    metamethod __call: function(self, x: number): V1
                end
                local v1Container: V1 = {}
                local Comp: V1 = tecs.ecs.newFFIComponent({
                    name = compName,
                    container = v1Container,
                    fields = {{"x", "double"}},
                })

                -- Synthetic buffer claiming saved schema "x:double,y:double|16".
                local buffer = require("string.buffer")
                local ffi = require("ffi")
                local buf = buffer.new()
                buf:encode(2)
                buf:encode(2)
                buf:encode(1)
                buf:encode(1)
                buf:encode(1)
                buf:encode(compName)
                buf:encode("x:double,y:double|16")
                buf:encode(1)
                buf:encode(1)
                buf:encode(1)
                buf:encode(0)
                local idsRaw = ffi.new("double[?]", 1)
                local ids = idsRaw as {number}
                ids[0] = 1
                buf:putcdata(idsRaw, 8)
                local valsRaw = ffi.new("double[?]", 2)
                local vals = valsRaw as {number}
                vals[0] = 100
                vals[1] = 999
                buf:putcdata(valsRaw, 16)
                buf:encode(nil)

                local world = tecs.ecs.newWorld()
                world:loadSnapshot(buf)

                luassert.is_true(world:isAlive(1))
                local v = world:get(1, Comp)
                luassert.equals(100, v.x)
                -- y was saved but has no corresponding field on the current
                -- component; migrator silently drops it.
            end
        )

        it(
            "FFI schema drift with custom hooks routes payloads to deserialize",
            function()
                local testId = math.random(1, 1000000)
                local compName = "SchemaDriftCustom" .. testId

                -- Current schema has two fields, the crafted save claims one.
                -- Custom hooks mean the saved column holds STRUCTURED payloads,
                -- so the byte migrator must not engage; the deserialize hook is
                -- the manual-migration path and fills the new field itself.
                local record CV is tecs.ecs.Component
                    a: number
                    b: number
                    metamethod __call: function(self, a: number, b: number): CV
                end
                local seenPayload: {string: any} = nil
                local Comp: CV
                Comp = tecs.ecs.newFFIComponent({
                    name = compName,
                    container = {} as CV,
                    fields = {{"a", "double"}, {"b", "double"}},
                    serialize = function(value: CV): {string: any} return {a = value.a} end,
                    deserialize = function(_world: tecs.World, data: {string: any}): CV
                        seenPayload = data
                        return Comp(data.a as number, 42)
                    end,
                })

                local buffer = require("string.buffer")
                local ffi = require("ffi")
                local buf = buffer.new()
                buf:encode(2) -- version
                buf:encode(2) -- nextEntityId
                buf:encode(1) -- entityCount
                buf:encode(1) -- archetypeCount
                buf:encode(1) -- componentCount
                buf:encode(compName)
                buf:encode("a:double|8") -- SAVED schema (1 field)
                -- Archetype frame
                buf:encode(1) -- columnCount
                buf:encode(1) -- entityCount
                buf:encode(1) -- columnIndex
                buf:encode(0) -- column-major mode
                local idsRaw = ffi.new("double[?]", 1)
                local ids = idsRaw as {number}
                ids[0] = 1
                buf:putcdata(idsRaw, 8)
                -- Column value: the structured payload a custom serialize wrote.
                buf:encode({a = 3.5})
                -- Data section: empty
                buf:encode(nil)

                local world = tecs.ecs.newWorld()
                world:loadSnapshot(buf)

                luassert.is_true(world:isAlive(1))
                luassert.is_not_nil(seenPayload, "the custom deserialize must receive the old payload")
                luassert.equals(3.5, seenPayload.a as number)
                local v = world:get(1, Comp)
                luassert.equals(3.5, v.a)
                luassert.equals(42, v.b, "the deserialize hook owns migration of new fields")
            end
        )

        it(
            "componentTable in saveSnapshotTable lists each component once",
            function()
                -- The pre-pass deduplicates components into Snapshot.componentTable;
                -- per-archetype frames reference entries by 1-based index.
                local world = tecs.ecs.newWorld()
                world:spawn(PositionComp(10, 20), HealthComp(50))
                world:spawn(PositionComp(-1, -2))
                world:commit()

                local snap = saveTableSnapshot(world)
                luassert.is_not_nil(snap.componentTable)
                -- Two unique components used: Position (in both archetypes), Health (in one).
                luassert.equals(2, #snap.componentTable)
                -- Both archetypes reference Position via index 1.
                luassert.is_true(#snap.archetypes >= 2)
                for i = 1, #snap.archetypes do
                    local arch = snap.archetypes[i]
                    luassert.is_not_nil(arch.columnIndices, "ArchetypeEntry has columnIndices")
                    luassert.is_true(#arch.columnIndices >= 1)
                end
            end
        )
    end
)
