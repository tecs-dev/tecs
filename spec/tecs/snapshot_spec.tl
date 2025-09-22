require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local StringBuffer <const> = require("string.buffer")

local function saveTableSnapshot(world: tecs.World, opts?: tecs.SnapshotOptions): tecs.Snapshot
    local actualOpts: tecs.SnapshotOptions
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

local function saveBinarySnapshot(world: tecs.World, opts?: tecs.SnapshotOptions): StringBuffer
    local out = world:saveSnapshot(opts)
    if out.buffer == nil then
        error("saveSnapshot(binary) returned no buffer")
    end
    return out.buffer
end

describe("snapshot save/load", function()
    local record Position is tecs.Component
        x: number
        y: number
        metamethod __call: function(self, x: number, y: number): Position
    end

    local record Health is tecs.Component
        hp: integer
        metamethod __call: function(self, hp: integer): Health
    end

    local PositionComp: Position
    local HealthComp: Health

    before_each(function()
        local testId = math.random(1, 1000000)
        local posContainer: Position = {}
        PositionComp = tecs.newComponent({
            name = "SnapPosition" .. testId,
            container = posContainer,
            fields = {"x", "y"},
        })
        local hpContainer: Health = {}
        HealthComp = tecs.newComponent({
            name = "SnapHealth" .. testId,
            container = hpContainer,
            fields = {"hp"},
        })
    end)

    it("round-trips components with preserved entity IDs", function()
        local world = tecs.newWorld()
        local a = world:spawn(PositionComp(10, 20), HealthComp(100))
        local b = world:spawn(PositionComp(30, 40))
        world:commit()

        local snap = saveTableSnapshot(world)
        luassert.equals(1, snap.version)
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
    end)

    it("can be called a second time to restore the same snapshot", function()
        local world = tecs.newWorld()
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
    end)

    it("round-trips FFI + table components through JSON", function()
        -- Mirrors the save-game paint demo: one FFI component (Transform-ish)
        -- plus one table component (Cell-ish) on the same entity, through the
        -- full save -> serialize -> parse -> load pipeline.
        local json <const> = require("tecs.utils.json")
        local testId = math.random(1, 1000000)

        local record FFIStruct is tecs.Component
            x: number
            y: number
            layer: integer
            gpuSlot: integer
            metamethod __call: function(self, x: number, y: number, layer: integer): FFIStruct
        end
        local ffiContainer: FFIStruct = {}
        local FFIComp: FFIStruct = tecs.newFFIComponent({
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

        local record Cell is tecs.Component
            col: integer
            row: integer
            colorIdx: integer
            metamethod __call: function(self, c: integer, r: integer, k: integer): Cell
        end
        local cellContainer: Cell = {}
        local CellComp: Cell = tecs.newComponent({
            name = "SnapCell" .. testId,
            container = cellContainer,
            fields = {"col", "row", "colorIdx"},
        })

        local world = tecs.newWorld()
        local a = world:spawn(FFIComp(100, 200, 3), CellComp(4, 5, 7))
        local b = world:spawn(FFIComp(-10, -20, 1), CellComp(0, 0, 1))
        world:commit()

        local snap = saveTableSnapshot(world)
        local jsonStr = json.serialize(snap as {string: any})
        local parsed = json.parse(jsonStr) as tecs.Snapshot

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
    end)

    it("preserves FFI component metatable methods across save/load", function()
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

        local record Vec3 is tecs.Component
            x: number
            y: number
            z: number
            length: function(self): number
            metamethod __call: function(self, x: number, y: number, z: number): Vec3
        end
        local vec3Container: Vec3 = {}
        local Vec3Comp: Vec3 = tecs.newFFIComponent({
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

        local world = tecs.newWorld()
        local id = world:spawn(Vec3Comp(3, 4, 12))
        world:commit()

        -- Method works before save (sanity check the metatable wiring itself).
        luassert.equals(13, world:get(id, Vec3Comp):length())

        local buf = saveBinarySnapshot(world)

        -- Load into a brand-new world so we exercise the cold path: fresh
        -- archetype creation, fresh column allocation, fresh cdata slots.
        local fresh = tecs.newWorld()
        fresh:loadSnapshot(buf)

        luassert.is_true(fresh:isAlive(id), "entity should restore at original id")
        local restored = fresh:get(id, Vec3Comp)
        luassert.equals(3, restored.x)
        luassert.equals(4, restored.y)
        luassert.equals(12, restored.z)
        -- The actual assertion: metatable method still resolves.
        luassert.equals(13, restored:length(),
            "metatable :length() should work on cdata loaded into a fresh archetype column")
    end)

    it("round-trips through JSON serialization", function()
        local json <const> = require("tecs.utils.json")
        local world = tecs.newWorld()
        local a = world:spawn(PositionComp(10, 20), HealthComp(100))
        local b = world:spawn(PositionComp(30, 40))
        world:commit()

        local snap = saveTableSnapshot(world)
        local jsonStr = json.serialize(snap as {string: any})
        local parsed = json.parse(jsonStr) as tecs.Snapshot

        world:loadSnapshot(parsed)

        luassert.is_true(world:isAlive(a))
        luassert.is_true(world:isAlive(b))
        luassert.equals(10, world:get(a, PositionComp).x)
        luassert.equals(100, world:get(a, HealthComp).hp)
    end)

    it("survives repeated load-then-mutate cycles without orphans", function()
        local world = tecs.newWorld()
        local a = world:spawn(PositionComp(1, 1), HealthComp(10))
        world:spawn(PositionComp(2, 2), HealthComp(20))
        world:spawn(PositionComp(3, 3), HealthComp(30))
        world:commit()

        local snap = saveTableSnapshot(world)
        -- All 3 entities share the same archetype, so one group of 3 entities.
        luassert.equals(1, #snap.archetypes)
        luassert.equals(3, #(snap.archetypes[1].entities))

        local posQuery = world:query({ name = "Pos", include = {PositionComp} })
        local function count(): integer
            local n = 0
            for _, len in posQuery:iter() do n = n + len end
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
            for i = 1, #ids do world:despawn(ids[i]) end
            world:commit()
            luassert.equals(0, count(), "iter " .. iter .. ": cell count after clear")
        end
    end)

    it("opts.layers filters Transform-bearing entities; non-Transform entities pass through", function()
        -- Lenient semantics: `layers` only filters entities that carry a
        -- Transform. Entities without a Transform (singletons, config)
        -- are never touched by the layer allow-list.
        local world = tecs.newWorld()
        local onLayer2 = world:spawn(tecs.builtins.Transform(0, 0, 0, 2))
        local onLayer5 = world:spawn(tecs.builtins.Transform(0, 0, 0, 5))
        local noTransform = world:spawn(PositionComp(1, 1))
        world:commit()

        local snap = saveTableSnapshot(world, {layers = {2}})
        world:loadSnapshot(snap)

        luassert.is_true(world:isAlive(onLayer2),    "layer-2 entity kept")
        luassert.is_false(world:isAlive(onLayer5),   "layer-5 entity filtered out")
        luassert.is_true(world:isAlive(noTransform), "non-Transform entity passes through")
    end)

    it("filters entities via opts.filterQuery", function()
        -- The previous "decorate writer to filter" pattern doesn't fit the
        -- column-major data layout cleanly (writeEntity isn't called for
        -- dense archetypes). Use opts.filterQuery instead — it builds
        -- a temp query that limits which archetypes get walked at all.
        local world = tecs.newWorld()
        local keeper = world:spawn(PositionComp(1, 1), HealthComp(10))
        local skipper = world:spawn(PositionComp(2, 2))
        world:commit()

        local snap = saveTableSnapshot(world, {
            filterQuery = {include = {PositionComp, HealthComp}},
        })

        world:loadSnapshot(snap)
        luassert.is_true(world:isAlive(keeper))
        luassert.is_false(world:isAlive(skipper))
    end)

    it("round-trips through a LuaJIT string.buffer", function()
        local buffer = require("string.buffer")
        local world = tecs.newWorld()
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
    end)

    it("loadSnapshot accepts a Lua string source", function()
        local world = tecs.newWorld()
        local a = world:spawn(PositionComp(7, 8))
        world:commit()

        local buf = saveBinarySnapshot(world)
        local bytes = tostring(buf)  -- mimic love.filesystem.read return shape

        world:loadSnapshot(bytes)
        luassert.is_true(world:isAlive(a))
        luassert.equals(7, world:get(a, PositionComp).x)
    end)

    it("binary sparse loads pass world into deserialize", function()
        local testId = math.random(1, 1000000)

        local record NeedsWorld is tecs.Component
            value: integer
            metamethod __call: function(self, value: integer): NeedsWorld
        end
        local NeedsWorldComp: NeedsWorld

        local needsWorldContainer: NeedsWorld = {}
        NeedsWorldComp = tecs.newComponent({
            name = "SparseSnapNeedsWorld" .. testId,
            container = needsWorldContainer,
            fields = {"value"},
            deserialize = function(worldArg: tecs.World, data: {string: any}): NeedsWorld
                luassert.is_not_nil(worldArg, "binary sparse deserialize should receive world")
                return NeedsWorldComp(data.value as integer)
            end,
        })

        local SparseTagRel = tecs.newTagRelationship({
            name = "SparseSnapDeserialize" .. testId,
            sparse = true,
            exclusive = true,
        })

        local world = tecs.newWorld()
        local target = world:spawn()
        local owner = world:spawn(
            NeedsWorldComp(7),
            SparseTagRel(target) as tecs.Component
        )
        world:commit()

        local buf = saveBinarySnapshot(world)
        local fresh = tecs.newWorld()

        fresh:loadSnapshot(buf)
        luassert.is_true(fresh:isAlive(owner))
        local restoredComp = fresh:get(owner, NeedsWorldComp) as NeedsWorld
        luassert.equals(7, restoredComp.value)
        luassert.is_not_nil(fresh:get(owner, SparseTagRel as tecs.Component))
    end)

    it("binary sparse row-major snapshots handle missing sparse values per entity", function()
        local testId = math.random(1, 1000000)

        local SparseMaybeRel = tecs.newTagRelationship({
            name = "SparseSnapMissingValue" .. testId,
            sparse = true,
            exclusive = true,
        })

        local world = tecs.newWorld()
        local target = world:spawn()
        local wildcardOnly = world:spawn(PositionComp(1, 2), SparseMaybeRel as tecs.Component)
        local withValue = world:spawn(
            PositionComp(3, 4),
            SparseMaybeRel(target) as tecs.Component
        )
        world:commit()

        local buf = saveBinarySnapshot(world)
        local fresh = tecs.newWorld()

        fresh:loadSnapshot(buf)
        luassert.is_true(fresh:isAlive(wildcardOnly))
        luassert.is_true(fresh:isAlive(withValue))
        luassert.equals(1, fresh:get(wildcardOnly, PositionComp).x)
        luassert.equals(3, fresh:get(withValue, PositionComp).x)
        luassert.is_nil(fresh:get(wildcardOnly, SparseMaybeRel as tecs.Component))
        luassert.is_not_nil(fresh:get(withValue, SparseMaybeRel as tecs.Component))
    end)

    it("delivers opts.customData entries via StartSnapshotLoad:onData", function()
        local world = tecs.newWorld()
        world:spawn(PositionComp(1, 1))
        world:commit()

        local buf = saveBinarySnapshot(world, {
            customData = {
                build = "v0.1.2-alpha",
                score = 42,
                checkpoint = {level = "intro"},
            },
        })

        local seen: {string: any} = {}
        world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev: tecs.builtins.StartSnapshotLoad)
            ev:onData("build",      function(v: any) seen.build = v end)
            ev:onData("score",      function(v: any) seen.score = v end)
            ev:onData("checkpoint", function(v: any) seen.checkpoint = v end)
        end)

        world:loadSnapshot(buf)
        luassert.equals("v0.1.2-alpha", seen.build)
        luassert.equals(42, seen.score)
        luassert.equals("intro", (seen.checkpoint as {string: string}).level)
    end)

    it("OnSnapshotSave listeners can attach data via addData", function()
        local world = tecs.newWorld()
        world:spawn(PositionComp(1, 1))
        world:commit()

        world:observe(0, tecs.builtins.OnSnapshotSave, function(ev: tecs.builtins.OnSnapshotSave)
            ev:addData("plugin.physics", "snapshot-bytes")
            ev:addData("plugin.extra", {a = 1, b = 2})
        end)

        local buf = saveBinarySnapshot(world)

        local seen: {string: any} = {}
        world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev: tecs.builtins.StartSnapshotLoad)
            ev:onData("plugin.physics", function(v: any) seen["plugin.physics"] = v end)
            ev:onData("plugin.extra",   function(v: any) seen["plugin.extra"]   = v end)
        end)

        world:loadSnapshot(buf)
        luassert.equals("snapshot-bytes", seen["plugin.physics"])
        luassert.equals(1, (seen["plugin.extra"] as {string: integer}).a)
        luassert.equals(2, (seen["plugin.extra"] as {string: integer}).b)
    end)

    it("FinishSnapshotLoad fires once after the load completes", function()
        local world = tecs.newWorld()
        world:spawn(PositionComp(1, 1))
        world:commit()

        local buf = saveBinarySnapshot(world)

        local fired = 0
        local seenPrelude: any
        world:observe(0, tecs.builtins.FinishSnapshotLoad, function(ev: tecs.builtins.FinishSnapshotLoad)
            fired = fired + 1
            seenPrelude = ev.prelude
        end)

        world:loadSnapshot(buf)
        luassert.equals(1, fired)
        luassert.is_not_nil(seenPrelude)
        luassert.equals(1, (seenPrelude as {string: integer}).version)
    end)

    it("handles nil customData (no user metadata)", function()
        local world = tecs.newWorld()
        world:spawn(PositionComp(1, 1))
        world:commit()

        local buf = saveBinarySnapshot(world)

        local fired = 0
        world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev: tecs.builtins.StartSnapshotLoad)
            ev:onData("anything", function(_v: any) fired = fired + 1 end)
        end)

        local prelude = world:loadSnapshot(buf)
        luassert.equals(0, fired, "no data entries should fire any onData callback")
        luassert.equals(1, prelude.version)
    end)

    it("reuses an existing buffer when opts.buffer is provided", function()
        local buffer = require("string.buffer")
        local world = tecs.newWorld()
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
    end)

    it("FFI schema drift: saved has fewer fields than current (new fields zero-default)", function()
        -- Simulates loading an old save into new code that added a field.
        -- FFI struct names are global, so we register the current schema
        -- once, then hand-craft a buffer whose prelude claims an older
        -- fingerprint. The migrator reads the old-size bytes and projects
        -- same-named fields into the current struct.
        local testId = math.random(1, 1000000)
        local compName = "SchemaDriftAdd" .. testId

        local record V3 is tecs.Component
            x: number
            y: number
            z: number
            metamethod __call: function(self, x: number, y: number, z: number): V3
        end
        local v3Container: V3 = {}
        local Comp: V3 = tecs.newFFIComponent({
            name = compName,
            container = v3Container,
            fields = {{"x", "double"}, {"y", "double"}, {"z", "double"}},
        })

        -- Craft a synthetic buffer that claims fingerprint "x:double,y:double|16"
        -- (no z), with one entity carrying x=3.14 y=2.71.
        local buffer = require("string.buffer")
        local ffi = require("ffi")
        local buf = buffer.new()
        buf:encode(1)                            -- version
        buf:encode(2)                            -- nextEntityId
        buf:encode(1)                            -- entityCount
        buf:encode(1)                            -- archetypeCount
        buf:encode(1)                            -- componentCount
        buf:encode(compName)
        buf:encode("x:double,y:double|16")       -- SAVED schema (2 fields)
        -- Archetype frame
        buf:encode(1)                            -- columnCount
        buf:encode(1)                            -- entityCount
        buf:encode(1)                            -- columnIndex
        buf:encode(0)                            -- column-major mode
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

        local world = tecs.newWorld()
        world:loadSnapshot(buf)

        luassert.is_true(world:isAlive(1))
        local v = world:get(1, Comp)
        luassert.is_true(math.abs(v.x - 3.14) < 1e-9)
        luassert.is_true(math.abs(v.y - 2.71) < 1e-9)
        luassert.equals(0, v.z, "new field z defaults to zero on migrated load")
    end)

    it("FFI schema drift: saved has extra fields than current (extras discarded)", function()
        local testId = math.random(1, 1000000)
        local compName = "SchemaDriftRemove" .. testId

        -- Current schema: one field x.
        local record V1 is tecs.Component
            x: number
            metamethod __call: function(self, x: number): V1
        end
        local v1Container: V1 = {}
        local Comp: V1 = tecs.newFFIComponent({
            name = compName,
            container = v1Container,
            fields = {{"x", "double"}},
        })

        -- Synthetic buffer claiming saved schema "x:double,y:double|16".
        local buffer = require("string.buffer")
        local ffi = require("ffi")
        local buf = buffer.new()
        buf:encode(1)
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

        local world = tecs.newWorld()
        world:loadSnapshot(buf)

        luassert.is_true(world:isAlive(1))
        local v = world:get(1, Comp)
        luassert.equals(100, v.x)
        -- y was saved but has no corresponding field on the current
        -- component; migrator silently drops it.
    end)

    it("componentTable in saveSnapshotTable lists each component once", function()
        -- The pre-pass deduplicates components into Snapshot.componentTable;
        -- per-archetype frames reference entries by 1-based index.
        local world = tecs.newWorld()
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
    end)
end)
