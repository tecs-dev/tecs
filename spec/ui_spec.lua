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

local function fakeInput()
    local input = {
        mouseX = 0,
        mouseY = 0,
        wheelX = 0,
        wheelY = 0,
        pressed = {},
        released = {},
        keys = {},
        modifiers = {},
    }
    function input:canRead()
        return true
    end
    function input:mousePressed(button)
        return self.pressed[button] == true
    end
    function input:mouseReleased(button)
        return self.released[button] == true
    end
    function input:keyPressed(key)
        return self.keys[key] == true
    end
    function input:modifierDown(name)
        return self.modifiers[name] == true
    end
    function input:clear()
        self.wheelX, self.wheelY = 0, 0
        self.pressed, self.released = {}, {}
        self.keys, self.modifiers = {}, {}
    end
    return input
end

describe("tecs.ui", function()
    it("scrolls descendants without recomputing their Taffy layout", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local viewport =
            world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 2), ui.Scroll(10, 12))
        local child = world:spawn(ui.Style({ width = 20, height = 10 }), RelativeTransform(), ChildOf(viewport))

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

    it("centers a stretched drawing leaf over its Taffy box", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity = world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 1))
        local visual =
            world:spawn(ui.Style({ width = 30, height = 18 }), ui.Paint(true), RelativeTransform(), ChildOf(rootEntity))

        world:update(1 / 60)

        local relative = world:get(visual, RelativeTransform)
        assert.are.equal(15, relative.x)
        assert.are.equal(9, relative.y)
        assert.are.equal(30, relative.scaleX)
        assert.are.equal(18, relative.scaleY)
    end)

    it("intersects nested scroll viewports before assigning a clip", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 100 }), ui.Root("screen", 100, 100, 1), ui.Scroll())
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
        local content = world:spawn(ui.Style({ width = 120, height = 120 }), RelativeTransform(), ChildOf(nested))

        world:update(1 / 60)

        local clip = world:get(content, Clip)
        assert.same({ x = 30, y = 40, width = 70, height = 60 }, renderer.clips[clip.index])

        world:getMut(rootEntity, ui.Scroll).x = 10
        world:update(1 / 60)

        local movedClip = world:get(content, Clip)
        assert.are.equal(clip.index, movedClip.index)
        assert.same({ x = 20, y = 40, width = 80, height = 60 }, renderer.clips[movedClip.index])
    end)

    it("captures clicks, bubbles events, and respects clipping", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 1), ui.Scroll())
        local button = world:spawn(
            ui.Style({ width = 40, height = 24 }),
            ui.Interaction(),
            RelativeTransform(),
            ChildOf(rootEntity)
        )
        world:spawn(
            ui.Style({ width = 20, height = 20, margin = { top = 100 } }),
            ui.Interaction(),
            RelativeTransform(),
            ChildOf(rootEntity)
        )

        local seen = {}
        world:observe(button, ui.Event, function(event)
            seen[#seen + 1] = event.kind .. ":" .. event.currentTarget
        end)
        world:observe(rootEntity, ui.Event, function(event)
            seen[#seen + 1] = event.kind .. ":" .. event.currentTarget
        end)

        world:update(1 / 60)
        input.mouseX, input.mouseY = 10, 10
        input.pressed.left = true
        world:update(1 / 60)

        local state = world:get(button, ui.InteractionState)
        assert.is_true(state.hovered)
        assert.is_true(state.pressed)
        assert.is_true(state.focused)
        assert.same({
            "pointerEnter:" .. button,
            "focus:" .. button,
            "focus:" .. rootEntity,
            "pointerDown:" .. button,
            "pointerDown:" .. rootEntity,
        }, seen)

        input:clear()
        input.mouseX, input.mouseY = 90, 70
        input.released.left = true
        world:update(1 / 60)
        assert.is_false(world:get(button, ui.InteractionState).pressed)
        assert.is_nil(seen[6] and seen[6]:match("^click:"))

        input:clear()
        input.mouseX, input.mouseY = 10, 10
        input.pressed.left = true
        world:update(1 / 60)
        input:clear()
        input.released.left = true
        world:update(1 / 60)
        assert.are.equal("click:" .. button, seen[#seen - 3])
        assert.are.equal("click:" .. rootEntity, seen[#seen - 2])
        assert.are.equal("activate:" .. button, seen[#seen - 1])
        assert.are.equal("activate:" .. rootEntity, seen[#seen])

        input:clear()
        input.mouseX, input.mouseY = 10, 105
        world:update(1 / 60)
        assert.is_false(world:get(button, ui.InteractionState).hovered)
    end)

    it("scrolls the deepest viewport before layout in the same frame", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local viewport = world:spawn(ui.Style({ width = 100, height = 60 }), ui.Root("screen", 100, 60, 1), ui.Scroll())
        local content = world:spawn(ui.Style({ width = 100, height = 180 }), RelativeTransform(), ChildOf(viewport))

        world:update(1 / 60)
        assert.are.equal(180, world:get(viewport, ui.Scroll).contentHeight)

        input.mouseX, input.mouseY = 20, 20
        input.wheelY = -1
        world:update(1 / 60)

        assert.are.equal(40, world:get(viewport, ui.Scroll).y)
        assert.are.equal(-40, world:get(content, RelativeTransform).y)

        input:clear()
        world:observe(viewport, ui.Event, function(event)
            if event.kind == "wheel" then
                event.consumed = true
            end
        end)
        input.wheelY = -1
        world:update(1 / 60)
        assert.are.equal(40, world:get(viewport, ui.Scroll).y)
    end)

    it("navigates visible controls and activates focus from the keyboard", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 40, flexDirection = "row" }), ui.Root("screen", 100, 40, 1))
        local first = world:spawn(
            ui.Style({ width = 40, height = 30 }),
            ui.Interaction(),
            RelativeTransform(),
            ChildOf(rootEntity)
        )
        local second = world:spawn(
            ui.Style({ width = 40, height = 30 }),
            ui.Interaction(),
            RelativeTransform(),
            ChildOf(rootEntity)
        )
        local activated = 0
        world:observe(second, ui.Event, function(event)
            if event.kind == "activate" then
                activated = activated + 1
            end
        end)

        world:update(1 / 60)
        input.keys.tab = true
        world:update(1 / 60)
        assert.is_true(world:get(first, ui.InteractionState).focused)

        input:clear()
        input.keys.tab = true
        world:update(1 / 60)
        assert.is_false(world:get(first, ui.InteractionState).focused)
        assert.is_true(world:get(second, ui.InteractionState).focused)

        input:clear()
        input.keys["return"] = true
        world:update(1 / 60)
        assert.are.equal(1, activated)

        input:clear()
        input.keys.tab = true
        input.modifiers.shift = true
        world:update(1 / 60)
        assert.is_true(world:get(first, ui.InteractionState).focused)
        assert.is_false(world:get(second, ui.InteractionState).focused)
    end)
end)
