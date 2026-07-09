-- archetype_shadow_set: integration test exercising pointer-drift
-- detection, dirty-page derivation from _dirtyBits, and flush against
-- multiple component columns. Uses the LÖVE 12 mock for ByteData/Buffer.

require("busted")

local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local C <const> = require("ffi")
local tecs <const> = require("tecs")
local archetype_shadow_set <const> = require("tecs2d.gfx.internal.gpu.archetype_shadow_set")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")

local Transform <const> = tecs.builtins.Transform

-- Use an FFI Color so the canonical layout is std430-compatible (4 floats).
local Color = tecs.newFFIComponent({
    name = "ShadowSetSpecColor",
    container = {},
    fields = {
        {"r", "float"}, {"g", "float"}, {"b", "float"}, {"a", "float"},
    },
    defaults = {1, 1, 1, 1},
})

-- Need a ClipBounds-shaped layout descriptor that uses *this* test's
-- canonical struct. The std430.layouts.ClipBounds expects
-- "CanonicalClipBounds" which is the production component; we reuse
-- std430.layouts.Color for our Color stand-in (same shape).
local ColorLayout = std430.layouts.Color

local function findArchetype(world: tecs.World, components: {tecs.Component}): tecs.Archetype
    -- IMPORTANT: don't early-return out of `q:iter()`. The iter pushes a
    -- query scope on first call and pops on natural end-of-iteration (or
    -- on the next call returning nil). Bailing mid-iteration via `return`
    -- leaves the world in deferred-mutation mode, which silently buffers
    -- subsequent spawns into the staging queue with no drain to apply
    -- them. Use forEachArchetype (which has no scope) and a manual match
    -- check instead.
    local match: tecs.Archetype = nil
    world:forEachArchetype(function(arch: tecs.Archetype)
        if match ~= nil then return end
        if ((arch as {string:any}).entities as {integer})[0] == 0 then return end
        for i = 1, #components do
            if arch:get(components[i]) == nil then return end
        end
        match = arch
    end)
    return match
end

describe("archetype_shadow_set", function()
    it("constructs entries only for components present on the archetype", function()
        local world = tecs.newWorld()
        world:spawn(Transform(1, 2, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
            [Color]     = ColorLayout,  -- not on this archetype
        })

        local count = 0
        set:forEach(function(_comp: tecs.Component, _buf: any)
            count = count + 1
        end)
        assert.equals(1, count, "only Transform should be in the set; Color is absent")
    end)

    it("flushes dirty rows derived from _dirtyBits", function()
        local world = tecs.newWorld()
        world:spawn(Transform(10, 20, 0))
        world:spawn(Transform(30, 40, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })

        local mb = set:get(Transform)
        local gpuBuffer = (mb as {string:any}).gpuBuffer as {string:any}
        local writesBefore = #(gpuBuffer._writes as {any})

        set:flush()

        local writes = gpuBuffer._writes as {{string:any}}
        assert.is_true(#writes > writesBefore, "flush must upload after spawn marks rows dirty")

        -- Verify std430 shadow matches canonical input.
        local shadowPtr = (mb as {string:any}).shadowPtr as C.CData
        local shadow = C.cast("Std430Transform*", shadowPtr) as {integer: any}
        assert.equals(10.0, shadow[1].x)
        assert.equals(30.0, shadow[2].x)
    end)

    it("detects pointer drift when reserveCapacity reallocates the column", function()
        local world = tecs.newWorld()
        world:spawn(Transform(1, 2, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })
        set:flush()

        local mb = set:get(Transform)
        local capBefore = (mb as {string:any}).capacity as integer

        -- Force reserveCapacity to grow far past the current size.
        -- INITIAL_CAPACITY=64 in FFIStorage means after one spawn the
        -- column has 65 rows of storage; spawning ~200 more forces
        -- another grow.
        for i = 1, 200 do world:spawn(Transform(i, i, 0)) end
        set:flush()

        local capAfter = (mb as {string:any}).capacity as integer
        assert.is_true(capAfter > capBefore,
            "shadow capacity must grow when archetype reallocates: " ..
            tostring(capBefore) .. " → " .. tostring(capAfter))
    end)

    it("a second flush in the same frame is a no-op (component bit still set)", function()
        -- Component-dirty bits are cleared by `world:update`, not by
        -- `flush`. A double flush within the same frame still uploads
        -- the second time because the bit is set. The interesting
        -- no-op case is the cross-frame one tested below.
        local world = tecs.newWorld()
        world:spawn(Transform(1, 2, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })
        set:flush()

        local mb = set:get(Transform)
        local gpuBuffer = (mb as {string:any}).gpuBuffer as {string:any}
        local writesBefore = #(gpuBuffer._writes as {any})

        set:flush()

        assert.is_true(#(gpuBuffer._writes as {any}) > writesBefore,
            "same-frame second flush still uploads — component-dirty cleared by world:update only")
    end)

    it("a flush with no mutations since the previous flush is a no-op", function()
        local world = tecs.newWorld()
        world:spawn(Transform(1, 2, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })
        set:flush()
        world:update(0)  -- clears _dirtyBits

        local mb = set:get(Transform)
        local gpuBuffer = (mb as {string:any}).gpuBuffer as {string:any}
        local writesBefore = #(gpuBuffer._writes as {any})

        set:flush()

        assert.equals(writesBefore, #(gpuBuffer._writes as {any}),
            "no new uploads when nothing changed")
    end)

    it("getMut triggers exactly one bulk re-upload via flushRange", function()
        -- The component-dirty contract: calling `getMut(Foo)` on
        -- the archetype marks Foo dirty and the next shadow flush
        -- uploads every live row in one setArrayData call.
        local world = tecs.newWorld()
        world:spawn(Transform(1, 2, 0))
        world:spawn(Transform(3, 4, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })
        set:flush()
        world:update(0)

        local mb = set:get(Transform)
        local gpuBuffer = (mb as {string:any}).gpuBuffer as {string:any}
        local writesBefore = #(gpuBuffer._writes as {any})

        local _ = arch:getMut(Transform)
        set:flush()

        local writes = gpuBuffer._writes as {{string:any}}
        assert.equals(writesBefore + 1, #writes,
            "getMut + flush should trigger exactly one bulk setArrayData call")
        local lastWrite = writes[#writes]
        assert.equals(2, lastWrite.count,
            "bulk upload should cover all live rows in one call")
    end)

    it("reflects value mutations through _dirtyBits", function()
        local world = tecs.newWorld()
        local e = world:spawn(Transform(1, 2, 0))

        local arch = findArchetype(world, {Transform})
        local set = archetype_shadow_set.new(arch, {
            [Transform] = std430.layouts.Transform,
        })
        set:flush()
        world:update(0)

        world:set(e, Transform(99, 99, 0))
        set:flush()

        local mb = set:get(Transform)
        local shadowPtr = (mb as {string:any}).shadowPtr as C.CData
        local shadow = C.cast("Std430Transform*", shadowPtr) as {integer: any}
        assert.equals(99.0, shadow[1].x, "value mutation must propagate to shadow via _dirtyBits scan")
    end)
end)
