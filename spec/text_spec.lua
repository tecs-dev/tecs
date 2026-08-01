-- SDL_ttf shaping feeding Tecs' instanced glyph renderer.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Renderer = require("tecs.Renderer")
local assets = require("tecs.assets")
local components = require("tecs.components")
local text = require("tecs.gfx.text")
local ui = require("tecs.ui")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 256

local Transform2D = tecs.Transform2D
local Tint = components.Tint
local ChildOf = tecs.ecs.ChildOf
local RelativeTransform2D = tecs.ecs.RelativeTransform2D

describe("gfx.text", function()
    local window, device, screen, font, alphaFont

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "text", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
        assets.install()
        font = text.newTTF({
            source = "fonts/JetBrainsMono-ExtraBold.ttf",
            name = "text-sdf-64",
            size = 64,
        })
            :wait().value
        alphaFont = text.newTTF({
            source = "fonts/JetBrainsMono-ExtraBold.ttf",
            name = "text-alpha-16",
            size = 16,
            raster = "alpha",
        })
            :wait().value
    end)

    teardown(function()
        assets.shutdown()
        if screen then
            screen:destroy()
        end
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    local function newScene()
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            sprites = { capacity = 4096 },
        })
        renderer:install(world)
        world:addPlugin(text.textPlugin({ renderer = renderer }))
        return world, renderer
    end

    local function frame(world, renderer)
        world:update(1 / 60)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        renderer:render({
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return screen:readback()
    end

    local function ink(pixels)
        local count = 0
        for y = 0, SIZE - 1 do
            for x = 0, SIZE - 1 do
                if screen:getPixel(pixels, x, y).g > 128 then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function spawnText(world, x, y, body, size, align)
        return world:spawn(
            Transform2D(x, y, 0, 1),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({
                text = body,
                font = font,
                size = size or 48,
                align = align,
            })
        )
    end

    it("opens source fonts with scalable or direct-alpha glyphs", function()
        assert.are.equal("text-sdf-64", font.name)
        assert.are.equal("fonts/JetBrainsMono-ExtraBold.ttf", font.source)
        assert.are.equal(64, font.size)
        assert.are.equal("sdf", font.raster)
        assert.is_not_nil(font._font)
        assert.are.equal("alpha", alphaFont.raster)
        assert.are.equal(16, alphaFont.size)

        local failed = text.newTTF({ source = "fonts/missing.ttf" }):wait(1000)
        assert.are.equal("failed", failed.status)
        assert.has_error(function()
            text.newTTF({ source = "fonts/JetBrainsMono-ExtraBold.ttf", raster = "lcd" })
        end, "tecs: a TTF font `raster` must be 'sdf' or 'alpha'")
    end)

    it("draws alpha glyphs and snaps their screen-space origin", function()
        local world, renderer = newScene()
        tecs.gfx.layers.configure(16, { sort = "z", screenSpace = true, unlit = true })
        local entity = world:spawn(
            Transform2D(32.2, 32.2, 0, 16),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({ text = "Aligned", font = alphaFont, size = 16 })
        )
        local pixels = frame(world, renderer)
        local firstX, firstY = text.glyphAt(world, entity, 1)
        assert.is_true(ink(pixels) > 10)

        local transform = world:getMut(entity, Transform2D)
        transform.x, transform.y = 32.4, 32.4
        frame(world, renderer)
        local secondX, secondY = text.glyphAt(world, entity, 1)
        assert.are.equal(firstX, secondX)
        assert.are.equal(firstY, secondY)
        renderer:destroy()
    end)

    it("draws one renderer instance per shaped copy operation", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 24, 48, "Hello", 64)
        local pixels = frame(world, renderer)

        local item = world:get(entity, text.Text)
        assert.is_true(item._spanCount > 0)
        assert.are.equal(item._spanCount, renderer.sprites.count)
        assert.is_true(ink(pixels) > 100)
        renderer:destroy()
    end)

    it("preserves narrow lowercase strokes at UI sizes", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 32, 32, "i", 13)
        local pixels = frame(world, renderer)
        local x, y, width, height = text.glyphAt(world, entity, 1)
        local stem = 0
        for py = math.floor(y), math.floor(y + height * 0.2) do
            for px = math.floor(x - width * 0.6), math.ceil(x + width * 0.6) do
                local green = screen:getPixel(pixels, px, py).g
                if green > 0 then
                    stem = stem + 1
                end
            end
        end
        assert.is_true(stem > 0, "the i stem should survive the UI-size downsample")
        renderer:destroy()
    end)

    it("advances whitespace without emitting a glyph instance", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 24, 48, "A A", 64)
        frame(world, renderer)

        local item = world:get(entity, text.Text)
        assert.are.equal(2, item._spanCount)
        assert.are.equal(2, renderer.sprites.count)
        assert.is_not_nil(text.glyphAt(world, entity, 2))
        assert.is_nil(text.glyphAt(world, entity, 3))
        renderer:destroy()
    end)

    it("keeps glyphs after multiline copy offsets reset", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 24, 24, "tecs 0.1.0\n4000 entities", 32)
        frame(world, renderer)

        local item = world:get(entity, text.Text)
        assert.are.equal(21, item._spanCount)
        assert.is_not_nil(text.glyphAt(world, entity, 19))
        assert.is_not_nil(text.glyphAt(world, entity, 21))
        renderer:destroy()
    end)

    it("reuses rasterized glyph residency across texts and display sizes", function()
        local world, renderer = newScene()
        local first = spawnText(world, 16, 32, "Cache", 32)
        frame(world, renderer)
        local occupied = renderer.sprites.images:usage()

        spawnText(world, 16, 96, "Cache", 80)
        frame(world, renderer)
        local afterSecond = renderer.sprites.images:usage()
        assert.are.equal(occupied, afterSecond, "a second size reuses the same SDF glyphs")

        world:getMut(first, text.Text).size = 52
        frame(world, renderer)
        local afterResize = renderer.sprites.images:usage()
        assert.are.equal(occupied, afterResize, "resizing changes instances, not native glyph generation")
        renderer:destroy()
    end)

    it("uses SDL_ttf line layout and aligns within the widest line", function()
        local world, renderer = newScene()
        local left = spawnText(world, 20, 20, "II\nIIII", 48, "left")
        local right = spawnText(world, 20, 120, "II\nIIII", 48, "right")
        frame(world, renderer)

        local leftX = text.glyphAt(world, left, 1)
        local rightX = text.glyphAt(world, right, 1)
        assert.is_true(rightX > leftX, "right alignment shifts the shorter first line")

        local item = world:get(left, text.Text)
        local measuredWidth, measuredHeight = text.measureText(item)
        assert.is_true(measuredWidth > 0)
        assert.is_true(measuredHeight > 48)
        assert.is_true(math.abs(item.width - measuredWidth) < 0.01)
        assert.is_true(math.abs(item.height - measuredHeight) < 0.01)
        renderer:destroy()
    end)

    it("measures intrinsic runs and wraps retained text at an authored width", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 20, 20, "alpha beta gamma", 32, "left")
        frame(world, renderer)

        local item = world:get(entity, text.Text)
        local preferredWidth, preferredHeight, minWidth = text.measureIntrinsic(item)
        assert.is_true(preferredWidth > minWidth)
        assert.is_true(minWidth > 0)
        local wrappedWidth, wrappedHeight = text.measureText(item, preferredWidth * 0.55)
        assert.is_true(wrappedWidth < preferredWidth)
        assert.is_true(wrappedHeight > preferredHeight)
        assert.are.equal(0, item.wrapWidth)

        world:getMut(entity, text.Text).wrapWidth = preferredWidth * 0.55
        frame(world, renderer)
        item = world:get(entity, text.Text)
        assert.is_true(math.abs(item.width - wrappedWidth) < 0.01)
        assert.is_true(math.abs(item.height - wrappedHeight) < 0.01)
        renderer:destroy()
    end)

    it("converges intrinsic UI text to Taffy's chosen wrapping width", function()
        local world, renderer = newScene()
        world:addPlugin(ui.plugin({ renderer = renderer }))
        local rootEntity = world:spawn(
            ui.Style({ width = 120, height = 120, flexDirection = "column" }),
            ui.Root("screen", 120, 120, 1)
        )
        local entity = world:spawn(
            ui.Style({ maxWidth = "100%" }),
            ui.Intrinsic("text", { wrap = true }),
            RelativeTransform2D(),
            ChildOf(rootEntity),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({ text = "alpha beta gamma", font = font, size = 32 })
        )
        frame(world, renderer)

        local layout = world:get(entity, ui.Layout)
        local item = world:get(entity, text.Text)
        assert.is_true(layout.width <= 120)
        assert.is_true(layout.height > 32)
        assert.is_true(math.abs(item.wrapWidth - layout.width) < 0.01)
        assert.is_true(
            math.abs(item.height - layout.height) <= 1,
            ("rendered height %.3f should match UI height %.3f"):format(item.height, layout.height)
        )
        renderer:destroy()
    end)

    it("rewrites only the dirty text's instance span", function()
        local world, renderer = newScene()
        for index = 1, 4 do
            spawnText(world, 10, index * 30, "AAAAAAAA", 24)
        end
        local edited = spawnText(world, 10, 160, "BBBBBBBB", 24)
        frame(world, renderer)
        frame(world, renderer)
        assert.are.equal(0, renderer.sprites.rewritten)

        world:getMut(edited, text.Text).text = "CCCCCCCC"
        frame(world, renderer)
        assert.are.equal(8, renderer.sprites.rewritten)
        renderer:destroy()
    end)

    it("releases a text's instance span when it despawns", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 24, 48, "Gone", 48)
        frame(world, renderer)
        assert.is_true(renderer.sprites.count > 0)

        world:despawn(entity)
        local pixels = frame(world, renderer)
        assert.are.equal(0, renderer.sprites.count)
        assert.are.equal(0, ink(pixels))
        renderer:destroy()
    end)
end)
