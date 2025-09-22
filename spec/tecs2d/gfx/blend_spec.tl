require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local blend <const> = require("tecs2d.gfx.internal.blend")

describe("blend tag components", function()
    local world: tecs.World
    local testId = 0
    local Transform: tecs.Component

    before_each(function()
        testId = testId + 1
        world = tecs.newWorld()

        -- Create a simple transform component for testing
        Transform = tecs.newFFIComponent({
            name = "BlendTestTransform_" .. testId,
            container = {} as tecs.Component,
            fields = {{"x", "float"}, {"y", "float"}},
        })
    end)

    after_each(function()
        if world then
            world:shutdown()
        end
    end)

    describe("mutual exclusivity", function()
        it("removes existing blend component when adding a different one", function()
            local entityId = world:spawn(Transform(0, 0), blend.AdditiveBlend())
            world:update(0)

            -- Verify AdditiveBlend is present (get returns truthy for tag components)
            luassert.is_truthy(world:get(entityId, blend.AdditiveBlend), "Should have AdditiveBlend")
            luassert.is_falsy(world:get(entityId, blend.MultiplyBlend), "Should not have MultiplyBlend")

            -- Switch modes via blend.set (the explicit mutex API; plain
            -- world:set does NOT enforce exclusivity post-hook-removal).
            blend.set(world, entityId, blend.MultiplyBlend as tecs.Component)
            world:update(0)

            -- Verify only MultiplyBlend is present
            luassert.is_falsy(world:get(entityId, blend.AdditiveBlend), "AdditiveBlend should be removed")
            luassert.is_truthy(world:get(entityId, blend.MultiplyBlend), "Should have MultiplyBlend")
        end)

        it("allows entity without any blend component", function()
            local entityId = world:spawn(Transform(0, 0))
            world:update(0)

            for i = 1, #blend.ALL do
                luassert.is_falsy(world:get(entityId, blend.ALL[i]), "Should not have any blend component")
            end
        end)

        it("replaces blend component through multiple changes", function()
            local entityId = world:spawn(Transform(0, 0), blend.ScreenBlend())
            world:update(0)

            -- Chain through several blend modes via blend.set (mutex).
            blend.set(world, entityId, blend.DarkenBlend as tecs.Component)
            world:update(0)
            blend.set(world, entityId, blend.LightenBlend as tecs.Component)
            world:update(0)
            blend.set(world, entityId, blend.SubtractBlend as tecs.Component)
            world:update(0)

            -- Verify only final blend mode is present
            luassert.is_truthy(world:get(entityId, blend.SubtractBlend), "Should have SubtractBlend")

            -- Verify all others are gone
            local otherBlends = {
                blend.ScreenBlend, blend.DarkenBlend, blend.LightenBlend,
                blend.AdditiveBlend, blend.MultiplyBlend, blend.ReplaceBlend
            }
            for i = 1, #otherBlends do
                luassert.is_falsy(world:get(entityId, otherBlends[i]), "Should not have other blend")
            end
        end)
    end)

    describe("blend.ALL array", function()
        it("contains exactly 14 components", function()
            luassert.equals(14, #blend.ALL)
        end)

        it("contains all defined blend components", function()
            local expected = {
                blend.AdditiveBlend, blend.AdditiveBlendPremul,
                blend.MultiplyBlend, blend.MultiplyBlendPremul,
                blend.ScreenBlend, blend.ScreenBlendPremul,
                blend.SubtractBlend, blend.SubtractBlendPremul,
                blend.LightenBlend, blend.LightenBlendPremul,
                blend.DarkenBlend, blend.DarkenBlendPremul,
                blend.ReplaceBlend, blend.ReplaceBlendPremul,
            }

            for i = 1, #expected do
                local found = false
                for j = 1, #blend.ALL do
                    if blend.ALL[j] == expected[i] then
                        found = true
                        break
                    end
                end
                luassert.is_truthy(found, "blend.ALL should contain " .. tostring(expected[i]))
            end
        end)
    end)

    describe("blend.INFO map", function()
        it("maps each component to correct blend mode info", function()
            local info = blend.INFO[blend.AdditiveBlend]
            luassert.equals("add", info.mode)
            luassert.equals("alphamultiply", info.alphaMode)

            info = blend.INFO[blend.MultiplyBlendPremul]
            luassert.equals("multiply", info.mode)
            luassert.equals("premultiplied", info.alphaMode)

            info = blend.INFO[blend.ScreenBlend]
            luassert.equals("screen", info.mode)
            luassert.equals("alphamultiply", info.alphaMode)

            info = blend.INFO[blend.ReplaceBlendPremul]
            luassert.equals("replace", info.mode)
            luassert.equals("premultiplied", info.alphaMode)
        end)
    end)

    describe("blend.ID constants", function()
        it("has unique integer IDs for each blend mode", function()
            local seen: {integer: boolean} = {}
            for name, id in pairs(blend.ID) do
                luassert.is_falsy(seen[id], "Duplicate ID for " .. name)
                seen[id] = true
            end
        end)

        it("IDs are in range 1-14", function()
            for _, id in pairs(blend.ID) do
                luassert.is_truthy(id >= 1 and id <= 14, "ID out of range: " .. id)
            end
        end)
    end)
end)
