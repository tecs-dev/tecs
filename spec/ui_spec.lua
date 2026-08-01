-- Retained UI layout, scrolling, and renderer clip assignment.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local ui = require("tecs.ui")
local components = require("tecs.components")
local platformEvents = require("tecs.platform.events")

local ChildOf = tecs.ecs.ChildOf
local RelativeTransform2D = tecs.ecs.RelativeTransform2D
local Transform2D = tecs.Transform2D
local Clip = components.Clip

local function fakeRenderer()
    local sprites = {
        clips = {},
        cleared = {},
        camera = {
            x = 0,
            y = 0,
            zoom = 1,
            rotation = 0,
            calls = 0,
        },
    }
    local renderer = { sprites = sprites }
    function sprites.camera:toScreen(x, y)
        self.calls = self.calls + 1
        return x, y
    end
    function sprites.camera:toWorld(x, y, width, height)
        local dx = (x - width * 0.5) / self.zoom
        local dy = (y - height * 0.5) / self.zoom
        local cosine, sine = math.cos(self.rotation), math.sin(self.rotation)
        return self.x + dx * cosine - dy * sine, self.y + dx * sine + dy * cosine
    end
    function sprites:spriteSize()
        return self.spriteWidth or 0, self.spriteHeight or 0
    end
    function sprites:setClipRegion(index, region)
        self.clips[index] = {
            x = region.x,
            y = region.y,
            width = region.width,
            height = region.height,
        }
    end
    function sprites:clearClipRegion(index)
        self.clips[index] = nil
        self.cleared[index] = true
    end
    return renderer
end

local function fakeWindow(width, height, density)
    local window = {
        width = width,
        height = height,
        density = density,
        sizeReads = 0,
        densityReads = 0,
    }
    function window:getSize()
        self.sizeReads = self.sizeReads + 1
        return self.width, self.height
    end
    function window:pixelDensity()
        self.densityReads = self.densityReads + 1
        return self.density
    end
    return window
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
        down = {},
        modifiers = {},
        touchList = {},
        readable = true,
    }
    function input:canRead()
        return self.readable
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
    function input:keyDown(key)
        return self.down[key] == true
    end
    function input:modifierDown(name)
        return self.modifiers[name] == true
    end
    function input:touches()
        return self.touchList
    end
    function input:clear()
        self.wheelX, self.wheelY = 0, 0
        self.wheelPreferredX, self.wheelPreferredY = nil, nil
        self.pressed, self.released = {}, {}
        self.keys, self.modifiers = {}, {}
    end
    return input
end

describe("tecs.ui", function()
    it("parses CSS-like dimensions and follows an application window", function()
        local renderer = fakeRenderer()
        local window = fakeWindow(200, 120, 2)
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, window = window }))

        local rootEntity =
            world:spawn(ui.Style({ width = "100%", height = "100%", padding = "10px" }), ui.Root("screen"))
        local child =
            world:spawn(ui.Style({ width = "50%", height = "20px" }), RelativeTransform2D(), ChildOf(rootEntity))

        world:update(1 / 60)

        local root = world:get(rootEntity, ui.Root)
        assert.are.equal(200, root.width)
        assert.are.equal(120, root.height)
        assert.are.equal(2, root.pixelDensity)
        assert.are.equal(90, world:get(child, ui.Layout).width)
        assert.are.equal(20, world:get(child, ui.Layout).height)
        assert.are.equal(1, window.sizeReads)
        assert.are.equal(1, window.densityReads)

        world:update(1 / 60)
        assert.are.equal(1, window.sizeReads)
        assert.are.equal(1, window.densityReads)

        window.width, window.height, window.density = 300, 180, 1.5
        world:update(1 / 60)

        root = world:get(rootEntity, ui.Root)
        assert.are.equal(200, root.width)
        assert.are.equal(120, root.height)
        assert.are.equal(2, root.pixelDensity)
        assert.are.equal(1, window.sizeReads)
        assert.are.equal(1, window.densityReads)

        world:emit(0, platformEvents.on.windowResized)
        world:emit(0, platformEvents.on.windowPixelSizeChanged)
        world:emit(0, platformEvents.on.windowDisplayChanged)
        world:emit(0, platformEvents.on.windowDisplayScaleChanged)
        world:update(1 / 60)

        root = world:get(rootEntity, ui.Root)
        assert.are.equal(300, root.width)
        assert.are.equal(180, root.height)
        assert.are.equal(1.5, root.pixelDensity)
        assert.are.equal(140, world:get(child, ui.Layout).width)
        assert.are.equal(2, window.sizeReads)
        assert.are.equal(2, window.densityReads)
    end)

    it("measures custom and image leaves without authored dimensions", function()
        local renderer = fakeRenderer()
        renderer.sprites.spriteWidth, renderer.sprites.spriteHeight = 80, 40
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity = world:spawn(
            ui.Style({ width = 200, height = 100, flexDirection = "row", alignItems = "center" }),
            ui.Root("screen", 200, 100, 1)
        )
        local custom = world:spawn(
            ui.Style(),
            ui.Intrinsic("custom", { width = 42, height = 17 }),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local image = world:spawn(
            ui.Style({ width = 30 }),
            ui.Intrinsic("image"),
            components.Sprite(1),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )

        world:update(1 / 60)

        assert.are.equal(42, world:get(custom, ui.Layout).width)
        assert.are.equal(17, world:get(custom, ui.Layout).height)
        assert.are.equal(30, world:get(image, ui.Layout).width)
        assert.are.equal(15, world:get(image, ui.Layout).height)
    end)

    it("derives camera-sized world roots and preserves manual roots", function()
        local renderer = fakeRenderer()
        renderer.sprites.camera.x, renderer.sprites.camera.y, renderer.sprites.camera.zoom = 10, 20, 2
        local window = fakeWindow(200, 100, 2)
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, window = window }))

        local cameraRoot = world:spawn(ui.Style(), ui.Root("world", 0, 0, 1, "camera"))
        local manualRoot = world:spawn(ui.Style(), ui.Root("world", 70, 40, 3, "manual"))
        world:update(1 / 60)

        local root = world:get(cameraRoot, ui.Root)
        local transform = world:get(cameraRoot, Transform2D)
        assert.are.equal(200, root.width)
        assert.are.equal(100, root.height)
        assert.are.equal(2, root.pixelDensity)
        assert.are.equal(-90, transform.x)
        assert.are.equal(-30, transform.y)
        assert.are.equal(70, world:get(manualRoot, ui.Root).width)

        window.width = 300
        renderer.sprites.camera.x = 30
        world:emit(0, platformEvents.on.windowResized)
        world:update(1 / 60)
        assert.are.equal(300, world:get(cameraRoot, ui.Root).width)
        assert.are.equal(70, world:get(manualRoot, ui.Root).width)
    end)

    it("rejects malformed dimension strings when a style is synchronized", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))
        world:spawn(ui.Style({ width = "wide", height = 20 }), ui.Root("screen", 100, 100, 1))

        local ok, message = pcall(function()
            world:update(1 / 60)
        end)
        assert.is_false(ok)
        assert.matches("invalid UI dimension", message)
    end)

    it("skips clip and hit geometry until retained state changes", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("world", 100, 80, 1), ui.Scroll())
        world:spawn(ui.Style({ width = 40, height = 20 }), ui.Interaction(), RelativeTransform2D(), ChildOf(rootEntity))

        world:update(1 / 60)
        local calls = renderer.sprites.camera.calls
        assert.is_true(calls > 0)

        world:update(1 / 60)
        assert.are.equal(calls, renderer.sprites.camera.calls)

        local unrelated = world:spawn(Transform2D())
        world:getMut(unrelated, Transform2D).x = 20
        world:update(1 / 60)
        assert.are.equal(calls, renderer.sprites.camera.calls)

        renderer.sprites.camera.x = 10
        world:update(1 / 60)
        assert.is_true(renderer.sprites.camera.calls > calls)
    end)

    it("updates changed boxes across independent retained roots", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local firstRoot = world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 1))
        local secondRoot = world:spawn(ui.Style({ width = 120, height = 90 }), ui.Root("screen", 120, 90, 1))
        local first = world:spawn(ui.Style({ width = 20, height = 10 }), RelativeTransform2D(), ChildOf(firstRoot))
        local second = world:spawn(ui.Style({ width = 40, height = 15 }), RelativeTransform2D(), ChildOf(secondRoot))

        world:update(1 / 60)
        assert.are.equal(20, world:get(first, ui.Layout).width)
        assert.are.equal(40, world:get(second, ui.Layout).width)

        world:getMut(first, ui.Style).style.width = 35
        world:update(1 / 60)
        assert.are.equal(35, world:get(first, ui.Layout).width)
        assert.are.equal(40, world:get(second, ui.Layout).width)

        world:despawn(first)
        world:update(1 / 60)
        local replacement =
            world:spawn(ui.Style({ width = 25, height = 12 }), RelativeTransform2D(), ChildOf(firstRoot))
        world:update(1 / 60)
        assert.are.equal(25, world:get(replacement, ui.Layout).width)
        assert.are.equal(40, world:get(second, ui.Layout).width)
    end)

    it("scrolls descendants without recomputing their Taffy layout", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local viewport =
            world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 2), ui.Scroll(10, 12))
        local child = world:spawn(
            ui.Style({ width = 200, height = 100, flexShrink = 0 }),
            RelativeTransform2D(),
            ChildOf(viewport)
        )

        world:update(1 / 60)

        local relative = world:get(child, RelativeTransform2D)
        assert.are.equal(-10, relative.x)
        assert.are.equal(-12, relative.y)
        local clip = world:get(child, Clip)
        local region = renderer.sprites.clips[clip.index]
        assert.same({ x = 0, y = 0, width = 200, height = 160 }, region)

        world:getMut(viewport, ui.Scroll).x = 25
        world:update(1 / 60)

        relative = world:get(child, RelativeTransform2D)
        assert.are.equal(-25, relative.x)
        assert.are.equal(-12, relative.y)
        assert.same({ x = 0, y = 0, width = 200, height = 160 }, renderer.sprites.clips[clip.index])

        world:despawn(viewport)
        world:update(1 / 60)

        assert.is_nil(renderer.sprites.clips[clip.index])
        assert.is_true(renderer.sprites.cleared[clip.index])
    end)

    it("centers a stretched drawing leaf over its Taffy box", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local rootEntity = world:spawn(ui.Style({ width = 100, height = 80 }), ui.Root("screen", 100, 80, 1))
        local visual = world:spawn(
            ui.Style({ width = 30, height = 18 }),
            ui.Paint(true),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )

        world:update(1 / 60)

        local relative = world:get(visual, RelativeTransform2D)
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
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local content = world:spawn(ui.Style({ width = 120, height = 120 }), RelativeTransform2D(), ChildOf(nested))

        world:update(1 / 60)

        local clip = world:get(content, Clip)
        assert.same({ x = 30, y = 40, width = 70, height = 60 }, renderer.sprites.clips[clip.index])

        world:getMut(rootEntity, ui.Scroll).x = 10
        world:update(1 / 60)

        local movedClip = world:get(content, Clip)
        assert.are.equal(clip.index, movedClip.index)
        assert.same({ x = 20, y = 40, width = 80, height = 60 }, renderer.sprites.clips[movedClip.index])
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
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        world:spawn(
            ui.Style({ width = 20, height = 20, margin = { top = 100 } }),
            ui.Interaction(),
            RelativeTransform2D(),
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
            "pointerMove:" .. button,
            "pointerMove:" .. rootEntity,
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
        local app = {
            world = world,
            window = {},
            renderer = renderer,
            input = input,
        }
        world:addPlugin(ui.plugin(app, { wheelStep = 12 }))

        local viewport = world:spawn(ui.Style({ width = 100, height = 60 }), ui.Root("screen", 100, 60, 1), ui.Scroll())
        local content = world:spawn(ui.Style({ width = 100, height = 180 }), RelativeTransform2D(), ChildOf(viewport))

        world:update(1 / 60)
        assert.are.equal(180, world:get(viewport, ui.Scroll).contentHeight)

        input.mouseX, input.mouseY = 20, 20
        input.wheelY = -1
        world:update(1 / 60)

        assert.are.equal(12, world:get(viewport, ui.Scroll).y)
        assert.are.equal(-12, world:get(content, RelativeTransform2D).y)

        input:clear()
        world:observe(viewport, ui.Event, function(event)
            if event.kind == "wheel" then
                event.consumed = true
            end
        end)
        input.wheelY = -1
        world:update(1 / 60)
        assert.are.equal(12, world:get(viewport, ui.Scroll).y)
    end)

    it("hands unused wheel distance to ancestor viewports", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input, wheelStep = 10 }))

        local outer = world:spawn(ui.Style({ width = 100, height = 100 }), ui.Root("screen", 100, 100, 1), ui.Scroll())
        local inner =
            world:spawn(ui.Style({ width = 100, height = 60 }), ui.Scroll(), RelativeTransform2D(), ChildOf(outer))
        world:spawn(ui.Style({ width = 100, height = 120 }), RelativeTransform2D(), ChildOf(inner))
        world:spawn(ui.Style({ width = 100, height = 180 }), RelativeTransform2D(), ChildOf(outer))
        world:update(1 / 60)

        world:getMut(inner, ui.Scroll).y = 60
        world:update(1 / 60)
        input.mouseX, input.mouseY = 20, 20
        input.wheelY = -1
        world:update(1 / 60)

        assert.are.equal(60, world:get(inner, ui.Scroll).y)
        assert.are.equal(10, world:get(outer, ui.Scroll).y)
    end)

    it("uses the platform-preferred wheel direction for scrolling", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input, wheelStep = 10 }))

        local viewport = world:spawn(ui.Style({ width = 100, height = 60 }), ui.Root("screen", 100, 60, 1), ui.Scroll())
        world:spawn(ui.Style({ width = 100, height = 180 }), RelativeTransform2D(), ChildOf(viewport))
        world:update(1 / 60)

        input.mouseX, input.mouseY = 20, 20
        input.wheelY = 1
        input.wheelPreferredY = -1
        input.wheelPreferredX = 0
        world:update(1 / 60)

        assert.are.equal(10, world:get(viewport, ui.Scroll).y)
    end)

    it("tracks negative content, clamps offsets, and persists only offsets", function()
        local renderer = fakeRenderer()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer }))

        local viewport = world:spawn(ui.Style({ width = 100, height = 60 }), ui.Root("screen", 100, 60, 1), ui.Scroll())
        world:spawn(
            ui.Style({ position = "absolute", width = 40, height = 30, inset = { left = -25, top = -15 } }),
            RelativeTransform2D(),
            ChildOf(viewport)
        )
        world:update(1 / 60)

        local scroll = world:get(viewport, ui.Scroll)
        assert.are.equal(-25, scroll.contentX)
        assert.are.equal(-15, scroll.contentY)
        world:getMut(viewport, ui.Scroll).x = -100
        world:getMut(viewport, ui.Scroll).y = 100
        world:update(1 / 60)
        scroll = world:get(viewport, ui.Scroll)
        assert.are.equal(scroll.contentX, scroll.x)
        assert.are.equal(0, scroll.y)
        assert.same({ x = scroll.x, y = scroll.y }, ui.Scroll.serialize(scroll))
    end)

    it("derives and drags a composed scrollbar thumb", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input, dragThreshold = 1 }))

        local viewport =
            world:spawn(ui.Style({ width = 100, height = 100 }), ui.Root("screen", 100, 100, 1), ui.Scroll())
        world:spawn(ui.Style({ width = 100, height = 200 }), RelativeTransform2D(), ChildOf(viewport))
        local thumb = world:spawn(
            ui.Scrollbar("vertical", 6, 2, 18),
            ui.Interaction({ draggable = true, focusable = false, order = 10 }),
            ChildOf(viewport)
        )
        world:update(1 / 60)

        local relative = world:get(thumb, RelativeTransform2D)
        assert.are.equal(95, relative.x)
        assert.are.equal(26, relative.y)
        assert.are.equal(6, relative.scaleX)
        assert.are.equal(48, relative.scaleY)

        input.mouseX, input.mouseY = 95, 26
        input.pressed.left = true
        world:update(1 / 60)
        input:clear()
        input.mouseY = 50
        world:update(1 / 60)
        assert.are.equal(50, world:get(viewport, ui.Scroll).y)
        assert.is_true(world:get(thumb, ui.InteractionState).dragging)
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
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local second = world:spawn(
            ui.Style({ width = 40, height = 30 }),
            ui.Interaction(),
            RelativeTransform2D(),
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

    it("repeats focus traversal while Tab remains held", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local rootEntity =
            world:spawn(ui.Style({ width = 120, height = 40, flexDirection = "row" }), ui.Root("screen", 120, 40, 1))
        local controls = {}
        for index = 1, 3 do
            controls[index] = world:spawn(
                ui.Style({ width = 40, height = 30 }),
                ui.Interaction(),
                RelativeTransform2D(),
                ChildOf(rootEntity)
            )
        end

        world:update(1 / 60)
        input.keys.tab = true
        input.down.tab = true
        world:update(1 / 60)
        assert.are.equal(controls[1], ui.focused(world))

        input:clear()
        world:update(0.39)
        assert.are.equal(controls[1], ui.focused(world))
        world:update(0.02)
        assert.are.equal(controls[2], ui.focused(world))
        world:update(0.08)
        assert.are.equal(controls[3], ui.focused(world))

        input.down.tab = false
        world:update(1 / 60)
        world:update(1)
        assert.are.equal(controls[3], ui.focused(world))
    end)

    it("supports programmatic focus, reveal, and nested focus scopes", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 50 }), ui.Root("screen", 100, 50, 1), ui.Scroll())
        local outside = world:spawn(
            ui.Style({ width = 80, height = 30 }),
            ui.Interaction({ order = 1 }),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local scope = world:spawn(
            ui.Style({ width = 80, height = 80 }),
            ui.FocusScope(),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local inside = world:spawn(
            ui.Style({ width = 70, height = 30, margin = { top = 40 } }),
            ui.Interaction({ order = 2 }),
            RelativeTransform2D(),
            ChildOf(scope)
        )
        world:update(1 / 60)

        assert.is_true(ui.focus(world, outside))
        assert.are.equal(outside, ui.focused(world))
        assert.is_true(ui.pushFocusScope(world, scope))
        assert.are.equal(inside, ui.focused(world))
        assert.is_false(ui.focus(world, outside))
        assert.are.equal(inside, ui.focused(world))
        assert.is_true(world:get(rootEntity, ui.Scroll).y > 0)
        assert.is_true(ui.popFocusScope(world, scope))
        assert.are.equal(outside, ui.focused(world))
        assert.is_true(ui.blur(world))
        assert.is_nil(ui.focused(world))
    end)

    it("uses explicit interaction order and a stable retained fallback", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input }))

        local rootEntity = world:spawn(ui.Style({ width = 80, height = 40 }), ui.Root("screen", 80, 40, 1))
        local first = world:spawn(
            ui.Style({ position = "absolute", width = 40, height = 30 }),
            ui.Interaction(),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local second = world:spawn(
            ui.Style({ position = "absolute", width = 40, height = 30 }),
            ui.Interaction(),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local clicked
        world:observe(first, ui.Event, function(event)
            if event.kind == "click" then
                clicked = first
            end
        end)
        world:observe(second, ui.Event, function(event)
            if event.kind == "click" then
                clicked = second
            end
        end)
        world:update(1 / 60)

        input.mouseX, input.mouseY = 10, 10
        input.pressed.left = true
        world:update(1 / 60)
        input:clear()
        input.released.left = true
        world:update(1 / 60)
        assert.are.equal(second, clicked)

        world:getMut(first, ui.Interaction).order = 5
        world:update(1 / 60)
        clicked = nil
        input:clear()
        input.pressed.left = true
        world:update(1 / 60)
        input:clear()
        input.released.left = true
        world:update(1 / 60)
        assert.are.equal(first, clicked)
    end)

    it("tracks simultaneous touches and emits pointer-specific drag events", function()
        local renderer = fakeRenderer()
        local input = fakeInput()
        local world = tecs.ecs.newWorld()
        world:addPlugin(ui.plugin({ renderer = renderer, input = input, dragThreshold = 2 }))

        local rootEntity =
            world:spawn(ui.Style({ width = 100, height = 40, flexDirection = "row" }), ui.Root("screen", 100, 40, 1))
        local first = world:spawn(
            ui.Style({ width = 50, height = 40 }),
            ui.Interaction({ draggable = true }),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local second = world:spawn(
            ui.Style({ width = 50, height = 40 }),
            ui.Interaction(),
            RelativeTransform2D(),
            ChildOf(rootEntity)
        )
        local events = {}
        world:observe(first, ui.Event, function(event)
            if event.kind:match("^drag") then
                events[#events + 1] = event.kind .. ":" .. event.pointerId .. ":" .. event.pointerType
            end
        end)
        world:update(1 / 60)

        input.touchList = {
            { device = "touch", finger = "one", x = 10, y = 10, pressure = 1 },
            { device = "touch", finger = "two", x = 70, y = 10, pressure = 1 },
        }
        world:update(1 / 60)
        assert.is_true(world:get(first, ui.InteractionState).pressed)
        assert.is_true(world:get(second, ui.InteractionState).pressed)

        input.touchList[1].x = 20
        world:update(1 / 60)
        assert.same({ "dragStart:touch:one:touch", "dragMove:touch:one:touch" }, events)
        assert.is_true(world:get(first, ui.InteractionState).dragging)

        table.remove(input.touchList, 1)
        world:update(1 / 60)
        assert.are.equal("dragEnd:touch:one:touch", events[#events])
        assert.is_false(world:get(first, ui.InteractionState).pressed)
        assert.is_true(world:get(second, ui.InteractionState).pressed)
    end)
end)
