-- Retained UI layout, scrolling, and renderer clip assignment.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local ui = require("tecs.ui")
local components = require("tecs.components")

local ChildOf = tecs.ecs.ChildOf
local RelativeTransform = tecs.ecs.RelativeTransform
local Clip = components.Clip

local function fakeRenderer()
    local renderer = {
        clips = {},
        cleared = {},
        camera = {},
    }
    function renderer.camera:toScreen(x, y)
        return x, y
    end
    function renderer:setClipRegion(index, region)
        self.clips[index] = {
            x = region.x,
            y = region.y,
            width = region.width,
            height = region.height,
        }
    end
    function renderer:clearClipRegion(index)
        self.clips[index] = nil
        self.cleared[index] = true
    end
    return renderer
end

describe("tecs.ui", function()
    it("scrolls descendants without recomputing their Taffy layout", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local viewport = world:spawn(
            ui.Style({ width = 100, height = 80 }),
            ui.Root("screen", 100, 80, 2),
            ui.Scroll(10, 12)
        )
        local child = world:spawn(
            ui.Style({ width = 20, height = 10 }),
            RelativeTransform(),
            ChildOf(viewport)
        )

        world:update(1 / 60)

        local relative = world:get(child, RelativeTransform)
        assert.are.equal(-10, relative.x)
        assert.are.equal(-12, relative.y)
        local clip = world:get(child, Clip)
        local region = renderer.clips[clip.index]
        assert.same({ x = 0, y = 0, width = 200, height = 160 }, region)

        world:getMut(viewport, ui.Scroll).x = 25
        world:update(1 / 60)

        relative = world:get(child, RelativeTransform)
        assert.are.equal(-25, relative.x)
        assert.are.equal(-12, relative.y)
        assert.same({ x = 0, y = 0, width = 200, height = 160 }, renderer.clips[clip.index])

        world:despawn(viewport)
        world:update(1 / 60)

        assert.is_nil(renderer.clips[clip.index])
        assert.is_true(renderer.cleared[clip.index])
    end)

    it("intersects nested scroll viewports before assigning a clip", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity = world:spawn(
            ui.Style({ width = 100, height = 100 }),
            ui.Root("screen", 100, 100, 1),
            ui.Scroll()
        )
        local nested = world:spawn(
            ui.Style({
                width = 80,
                height = 80,
                margin = { left = 30, top = 40 },
            }),
            ui.Scroll(),
            RelativeTransform(),
            ChildOf(rootEntity)
        )
        local content = world:spawn(
            ui.Style({ width = 120, height = 120 }),
            RelativeTransform(),
            ChildOf(nested)
        )

        world:update(1 / 60)

        local clip = world:get(content, Clip)
        assert.same(
            { x = 30, y = 40, width = 70, height = 60 },
            renderer.clips[clip.index]
        )

        world:getMut(rootEntity, ui.Scroll).x = 10
        world:update(1 / 60)

        local movedClip = world:get(content, Clip)
        assert.are.equal(clip.index, movedClip.index)
        assert.same(
            { x = 20, y = 40, width = 80, height = 60 },
            renderer.clips[movedClip.index]
        )
    end)
end)
