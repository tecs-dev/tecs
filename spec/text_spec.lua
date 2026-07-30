-- Text, asserted on rendered pixels.
--
-- "It drew something" is not the claim. A glyph is a quad whose UV rect
-- addresses one cell of a font atlas and whose material reads a distance
-- field out of it, and every one of those can be wrong in a way that still
-- puts ink on the screen: the wrong glyph, the right glyph upside down, the
-- right glyph in the wrong place. So these tests render offscreen and look at
-- where the ink actually landed.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local filesystem = require("tecs.platform.filesystem")
local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Renderer = require("tecs.Renderer")
local assets = require("tecs.assets")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local text = require("tecs.gfx.text")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 256

local Transform = tecs.Transform
local Tint = components.Tint

describe("gfx.text", function()
    local window, device, screen, font

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "text", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
        assets.install()
        font = text.defaultFont()
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

    -- A world with a renderer and the text plugin. Ambient is full white so a
    -- glyph's color reaches the screen without a light in the way.
    local function newScene()
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 4096,
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

    -- The atlas decodes on a worker and the first frame a text is laid out is
    -- what queues it, so a font arrives no earlier than the frame after that.
    -- Waiting for the decode in between is what makes this deterministic
    -- rather than a race the test usually wins.
    local function settle(world, renderer)
        frame(world, renderer)
        assets.waitAll()
        frame(world, renderer)
        return frame(world, renderer)
    end

    -- Ink in the rectangle, counted as pixels whose green channel is lit. Text
    -- is drawn green throughout so a lit pixel cannot be the clear color.
    local function ink(pixels, x0, y0, x1, y1)
        local count = 0
        for y = math.floor(y0), math.floor(y1) - 1 do
            for x = math.floor(x0), math.floor(x1) - 1 do
                if screen:getPixel(pixels, x, y).g > 128 then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function spawnText(world, x, y, body, size, align)
        return world:spawn(
            Transform(x, y, 0, 1),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({
                text = body,
                font = font,
                size = size or 48,
                align = align,
            })
        )
    end

    it("loads the bundled font's metrics", function()
        assert.are.equal(64, font.size, "the atlas was generated at 64")
        assert.are.equal(512, font.atlasWidth)
        assert.are.equal(8, font.distanceRange)
        assert.is_not_nil(font.glyphs[string.byte("H")])
        assert.are.equal(0, font.glyphs[string.byte(" ")].width, "a space has an advance and no quad")
    end)

    it("does not register an atlas after its renderer is destroyed", function()
        local world, renderer = newScene()
        local registerImage = renderer.registerImage
        local registrations = 0
        renderer.registerImage = function(self, image)
            registrations = registrations + 1
            return registerImage(self, image)
        end
        spawnText(world, 16, 16, "pending")

        -- Layout starts the decode, but only the asset pump can deliver it.
        world:update(1 / 60)
        assert.is_true(assets.pending() > 0, "the atlas load did not start")
        renderer:destroy()
        assets.waitAll()
        assets.update()

        assert.are.equal(0, registrations, "a retained future reached the destroyed renderer")
        assert.are.equal(0, assets.pending())
    end)

    it("gives every glyph an instance owned by its text", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 16, 16, "Hi there")
        settle(world, renderer)

        -- Eight characters, one of them a space, which has no quad.
        assert.are.equal(7, renderer.count, "one instance per glyph, and a space is not one")

        local item = world:get(entity, text.Text)
        assert.are.equal(7, item._spanCount, "the text owns a span of seven")
        assert.are.equal(1, item._span, "and it is the only text, so the span starts the run")
        for index = 1, item._spanCount do
            local x, y = text.glyphAt(world, entity, index)
            assert.is_not_nil(x, "every glyph of the span was written")
            assert.is_true(x > 16 and y > 16, "a glyph belongs to its text, so it sits at its position")
        end
        renderer:destroy()
    end)

    it("draws a glyph where the layout puts it", function()
        -- One glyph, placed by hand from the metrics, and nothing else on
        -- screen. Its ink must land inside the rect the layout computed and
        -- nowhere outside it.
        local world, renderer = newScene()
        local size = 96
        local x, y = 40, 60
        spawnText(world, x, y, "H", size)
        local pixels = settle(world, renderer)

        local metrics = font.glyphs[string.byte("H")]
        local scale = size / font.size
        local left = x + metrics.xOffset * scale
        local top = y + metrics.yOffset * scale
        local right = left + metrics.width * scale
        local bottom = top + metrics.height * scale

        assert.are.equal(1, renderer.count)
        assert.is_true(ink(pixels, left, top, right, bottom) > 500, "the glyph must fill the rect the metrics describe")
        assert.are.equal(0, ink(pixels, 0, 0, SIZE, top - 2), "and nothing above it")
        assert.are.equal(0, ink(pixels, 0, bottom + 2, SIZE, SIZE), "and nothing below it")
        assert.are.equal(0, ink(pixels, 0, 0, left - 2, SIZE), "and nothing to its left")
        assert.are.equal(0, ink(pixels, right + 2, 0, SIZE, SIZE), "and nothing to its right")
        renderer:destroy()
    end)

    it("draws a glyph the right way up", function()
        -- An L is ink across the bottom of its box and only a stem at the
        -- top, so it tells an upside-down glyph from a correct one. A glyph
        -- reaches the screen through the same UV rect a sprite does, and a
        -- sign wrong anywhere along that path renders a plausible glyph that
        -- happens to be mirrored. spec/orientation_spec.lua is the other half
        -- of that: this pins the atlas rect, that one pins the mapping.
        local world, renderer = newScene()
        local size = 96
        local x, y = 40, 60
        spawnText(world, x, y, "L", size)
        local pixels = settle(world, renderer)

        local metrics = font.glyphs[string.byte("L")]
        local scale = size / font.size
        local left = x + metrics.xOffset * scale
        local top = y + metrics.yOffset * scale
        local right = left + metrics.width * scale
        local bottom = top + metrics.height * scale
        local middle = (left + right) * 0.5
        -- The atlas rect is padded by half the field's range so the outline
        -- has room, so the ink stops that far short of the rect's edges.
        local margin = font.distanceRange * 0.5 * scale

        local foot = ink(pixels, middle, bottom - margin - 10, right - margin, bottom - margin)
        local shoulder = ink(pixels, middle, top, right, top + metrics.height * scale * 0.4)

        assert.is_true(foot > 100, "an L has its foot at the bottom right")
        assert.are.equal(0, shoulder, "and nothing at the top right; a flipped L would have it there")
        renderer:destroy()
    end)

    it("advances a string of glyphs across the line", function()
        -- Three of the same glyph, so anything that differs between them is
        -- position. The font is monospaced, which makes the expected pitch a
        -- single number rather than a sum.
        local world, renderer = newScene()
        local size = 64
        local x, y = 20, 60
        local entity = spawnText(world, x, y, "III", size)
        local pixels = settle(world, renderer)

        assert.are.equal(3, renderer.count)

        local metrics = font.glyphs[string.byte("I")]
        local scale = size / font.size
        local pitch = metrics.xAdvance * scale
        local top = y + metrics.yOffset * scale
        local bottom = top + metrics.height * scale

        for index = 0, 2 do
            local left = x + index * pitch + metrics.xOffset * scale
            local right = left + metrics.width * scale
            assert.is_true(
                ink(pixels, left, top, right, bottom) > 200,
                ("glyph %d belongs one advance along from the last"):format(index)
            )
        end

        -- The gap after the run is empty, which is what pins the advance
        -- rather than merely a wide smear of ink.
        local after = x + 3 * pitch
        assert.are.equal(0, ink(pixels, after + 2, 0, SIZE, SIZE), "nothing is drawn past the last glyph")

        local item = world:get(entity, text.Text)
        assert.is_true(math.abs(item.width - 3 * pitch) < 0.01, "the measured width is three advances")
        renderer:destroy()
    end)

    it("breaks lines on a newline and aligns them", function()
        local world, renderer = newScene()
        local size = 48
        local entity = spawnText(world, 20, 20, "II\nIIII", size, "right")
        settle(world, renderer)

        local item = world:get(entity, text.Text)
        local scale = size / font.size
        local pitch = font.glyphs[string.byte("I")].xAdvance * scale
        assert.is_true(math.abs(item.width - 4 * pitch) < 0.01, "the block is as wide as its widest line")
        assert.is_true(math.abs(item.height - 2 * font.lineHeight * scale) < 0.01, "and two lines tall")

        -- Right alignment moves the short line to the block's right edge, so
        -- its first glyph starts two advances in.
        local firstX, _, firstWidth = text.glyphAt(world, entity, 1)
        assert.is_true(
            math.abs(firstX - (20 + 2 * pitch + firstWidth * 0.5 + font.glyphs[string.byte("I")].xOffset * scale))
                < 0.01,
            "the shorter line is pushed right"
        )
        renderer:destroy()
    end)

    it("changes what is drawn when the string changes", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 30, 60, "I", 96)
        local before = settle(world, renderer)

        local metrics = font.glyphs[string.byte("I")]
        local scale = 96 / font.size
        local top = 60 + metrics.yOffset * scale
        local bottom = top + metrics.height * scale
        -- Where the second glyph of a two-character string would be, and is
        -- not yet.
        local secondLeft = 30 + metrics.xAdvance * scale
        local secondRight = secondLeft + metrics.width * scale
        assert.are.equal(0, ink(before, secondLeft, top, secondRight, bottom), "one glyph is drawn to start with")

        world:getMut(entity, text.Text).text = "II"
        local after = frame(world, renderer)

        assert.are.equal(2, renderer.count)
        assert.is_true(
            ink(after, secondLeft, top, secondRight, bottom) > 200,
            "the second glyph appears where the layout puts it"
        )
        renderer:destroy()
    end)

    it("despawns a text's glyphs with it", function()
        local world, renderer = newScene()
        local entity = spawnText(world, 30, 60, "Hello", 64)
        local pixels = settle(world, renderer)
        assert.are.equal(5, renderer.count)
        assert.is_true(ink(pixels, 0, 0, SIZE, SIZE) > 500)

        local item = world:get(entity, text.Text)
        assert.are.equal(5, item._spanCount)

        world:despawn(entity)
        pixels = frame(world, renderer)

        assert.are.equal(0, renderer.count, "the glyphs went with their text")
        assert.are.equal(0, ink(pixels, 0, 0, SIZE, SIZE))
        assert.are.equal(0, item._spanCount, "and the span went with them")
        renderer:destroy()
    end)

    it("does not lay out a text that did not change", function()
        local world, renderer = newScene()
        spawnText(world, 30, 60, "Static", 48)
        settle(world, renderer)

        local built = text.textLayouts(world)
        assert.is_true(built >= 1, "the text was laid out at least once")

        for _ = 1, 8 do
            frame(world, renderer)
        end
        assert.are.equal(built, text.textLayouts(world), "an unchanged string must not be laid out again")

        -- And the gate opens for a change, so it is a gate and not a
        -- permanent stop.
        local entity = spawnText(world, 30, 140, "Moved", 48)
        frame(world, renderer)
        assert.are.equal(built + 1, text.textLayouts(world))

        world:getMut(entity, text.Text).text = "Moved on"
        frame(world, renderer)
        assert.are.equal(built + 2, text.textLayouts(world))
        renderer:destroy()
    end)

    it("colors glyphs from the text's tint", function()
        local world, renderer = newScene()
        local entity = world:spawn(
            Transform(20, 60, 0, 1),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({ text = "H", font = font, size = 96 })
        )
        local pixels = settle(world, renderer)
        local lit = ink(pixels, 0, 0, SIZE, SIZE)
        assert.is_true(lit > 500, "green to start with")

        local tint = world:getMut(entity, Tint)
        tint.r, tint.g, tint.b = 1.0, 0.0, 0.0
        pixels = frame(world, renderer)

        assert.are.equal(0, ink(pixels, 0, 0, SIZE, SIZE), "nothing green is left")
        local red = 0
        for y = 0, SIZE - 1 do
            for x = 0, SIZE - 1 do
                if screen:getPixel(pixels, x, y).r > 128 then
                    red = red + 1
                end
            end
        end
        assert.is_true(math.abs(red - lit) <= lit * 0.1, "the same glyph, in the tint the text now carries")
        renderer:destroy()
    end)

    it("moves its glyphs when the text moves", function()
        -- A glyph carries an absolute position, so a moved text is a stale
        -- text and the move is applied by laying it out again.
        local world, renderer = newScene()
        local entity = spawnText(world, 20, 40, "H", 96)
        local before = settle(world, renderer)
        assert.is_true(ink(before, 0, 0, SIZE / 2, SIZE) > 500)
        assert.are.equal(0, ink(before, SIZE / 2, 0, SIZE, SIZE))

        local built = text.textLayouts(world)
        local span = world:get(entity, text.Text)._span
        local transform = world:getMut(entity, Transform)
        transform.x = transform.x + SIZE / 2
        local after = frame(world, renderer)

        assert.are.equal(0, ink(after, 0, 0, SIZE / 2, SIZE), "the glyph left the half it started in")
        assert.is_true(ink(after, SIZE / 2, 0, SIZE, SIZE) > 500, "and arrived in the other one")
        assert.are.equal(
            built + 1,
            text.textLayouts(world),
            "a move is a relayout, since the glyphs carry where they are"
        )
        assert.are.equal(
            span,
            world:get(entity, text.Text)._span,
            "and it rewrites the span rather than taking another"
        )
        renderer:destroy()
    end)

    it("follows a parent that moves it", function()
        -- The hierarchy composes the text's own Transform, and its glyphs
        -- carry absolute positions, so the layout has to run against the
        -- composed value in the frame that produced it.
        local world, renderer = newScene()
        local parent = world:spawn(Transform(20, 40, 0, 1))
        world:spawn(
            Transform(0, 0, 0, 1),
            tecs.ecs.RelativeTransform(0, 0, 0, 0, 1, 1),
            tecs.ecs.ChildOf(parent),
            Tint(0.0, 1.0, 0.0, 1.0),
            text.Text.new({ text = "H", font = font, size = 96 })
        )
        local before = settle(world, renderer)
        assert.is_true(ink(before, 0, 0, SIZE / 2, SIZE) > 500, "the glyph is drawn where the parent puts it")
        assert.are.equal(0, ink(before, SIZE / 2, 0, SIZE, SIZE))

        local transform = world:getMut(parent, Transform)
        transform.x = transform.x + SIZE / 2
        local after = frame(world, renderer)

        assert.are.equal(0, ink(after, 0, 0, SIZE / 2, SIZE), "and goes with the parent in the frame the parent moved")
        assert.is_true(ink(after, SIZE / 2, 0, SIZE, SIZE) > 500)
        renderer:destroy()
    end)

    it("lays its glyphs out again after a snapshot round trip", function()
        -- Glyphs are derived from the Text, so a snapshot omits them. Saving
        -- them and re-deriving them on load would draw every string twice.
        local world, renderer = newScene()
        spawnText(world, 30, 60, "Save", 48)
        local before = settle(world, renderer)
        assert.are.equal(4, renderer.count)

        local saved = world:saveSnapshot({}).buffer
        renderer:destroy()

        local restored, second = newScene()
        restored:loadSnapshot(saved)
        local after = settle(restored, second)

        assert.are.equal(4, second.count, "the restored text laid out its own glyphs, and only its own")
        assert.are.equal(
            ink(before, 0, 0, SIZE, SIZE),
            ink(after, 0, 0, SIZE, SIZE),
            "and drew the same string in the same place"
        )
        second:destroy()
    end)

    it("keeps a text's span when its glyph count is unchanged", function()
        -- The whole point of a span: a string swapped for another of the same
        -- length rewrites its own slots and moves nothing else.
        local world, renderer = newScene()
        local first = spawnText(world, 20, 30, "AAAA", 24)
        local second = spawnText(world, 20, 60, "BBBB", 24)
        settle(world, renderer)

        local item = world:get(first, text.Text)
        local other = world:get(second, text.Text)
        assert.are.equal(4, item._spanCount)
        assert.are.equal(8, renderer.count)
        local span, neighbor = item._span, other._span

        world:getMut(first, text.Text).text = "CCCC"
        frame(world, renderer)

        assert.are.equal(span, item._span, "the same span, rewritten")
        assert.are.equal(4, item._spanCount)
        assert.are.equal(neighbor, other._span, "and nothing else moved")
        assert.are.equal(8, renderer.count)
        renderer:destroy()
    end)

    it("frees the difference when a string gets shorter", function()
        local world, renderer = newScene()
        local long = spawnText(world, 20, 30, "AAAAAAAA", 24)
        spawnText(world, 20, 60, "BBBB", 24)
        settle(world, renderer)
        assert.are.equal(12, renderer.count)

        local item = world:get(long, text.Text)
        local span = item._span
        world:getMut(long, text.Text).text = "AAAAA"
        frame(world, renderer)

        assert.are.equal(span, item._span, "the front of the span stays")
        assert.are.equal(5, item._spanCount)
        assert.are.equal(12, renderer.count, "and the run does not shrink, so nothing after it moves")

        -- The three slots it gave up are the three a new text takes.
        local short = spawnText(world, 20, 90, "CCC", 24)
        frame(world, renderer)
        assert.are.equal(
            span + 5,
            world:get(short, text.Text)._span,
            "the freed tail is what the next three-glyph text gets"
        )
        assert.are.equal(12, renderer.count, "so the run is still the same")
        renderer:destroy()
    end)

    it("reuses a despawned text's span for one the same length", function()
        local world, renderer = newScene()
        local first = spawnText(world, 20, 30, "AAA", 24)
        spawnText(world, 20, 60, "BBB", 24)
        settle(world, renderer)
        assert.are.equal(6, renderer.count)

        local span = world:get(first, text.Text)._span
        world:despawn(first)
        frame(world, renderer)
        assert.are.equal(6, renderer.count, "a freed span keeps its place in the run")

        local third = spawnText(world, 20, 90, "CCC", 24)
        frame(world, renderer)
        assert.are.equal(span, world:get(third, text.Text)._span, "and the next text of that length takes it")
        assert.are.equal(6, renderer.count, "so the run never grew for the second three glyphs")
        renderer:destroy()
    end)

    it("gives back the span of a text whose component was removed", function()
        -- Despawning is observed and removing a component is not, so a span
        -- freed by a removal has to be noticed rather than reported. Left
        -- alone it is a leak with no upper bound: the slots never rejoin the
        -- free list and the run's high-water mark never comes back down.
        local world, renderer = newScene()
        spawnText(world, 20, 30, "AAA", 24)
        local second = spawnText(world, 20, 60, "BBB", 24)
        settle(world, renderer)
        assert.are.equal(6, renderer.count)

        world:remove(second, text.Text)
        frame(world, renderer)
        assert.are.equal(3, renderer.count, "the span was at the top of the run, so the mark comes back down")

        -- And one that was not at the top rejoins the free list, so the next
        -- text of that length takes it instead of growing the run.
        local third = spawnText(world, 20, 90, "CCC", 24)
        spawnText(world, 20, 120, "DDD", 24)
        frame(world, renderer)
        assert.are.equal(9, renderer.count)

        local span = world:get(third, text.Text)._span
        world:remove(third, text.Text)
        frame(world, renderer)
        assert.are.equal(9, renderer.count, "a freed span in the middle keeps its place in the run")

        local fifth = spawnText(world, 20, 150, "EEE", 24)
        frame(world, renderer)
        assert.are.equal(
            span,
            world:get(fifth, text.Text)._span,
            "the freed span is what the next three-glyph text gets"
        )
        assert.are.equal(9, renderer.count, "so the run never grew for it")
        renderer:destroy()
    end)

    it("rewrites only the sub-range of the text that changed", function()
        local world, renderer = newScene()
        for index = 1, 4 do
            spawnText(world, 20, 20 + index * 30, "AAAAAAAA", 24)
        end
        local edited = spawnText(world, 20, 170, "BBBBBBBB", 24)
        settle(world, renderer)
        assert.are.equal(40, renderer.count)

        frame(world, renderer)
        assert.are.equal(0, renderer.rewritten, "a still frame rewrites nothing at all")

        world:getMut(edited, text.Text).text = "CCCCCCCC"
        frame(world, renderer)
        assert.are.equal(8, renderer.rewritten, "one string's eight glyphs, not the other thirty-two")
        renderer:destroy()
    end)

    it("gives up its spans when a snapshot replaces the world", function()
        -- A load wipes entities in place, so nothing is despawned and the
        -- spans the wiped texts held have to go with them anyway.
        local world, renderer = newScene()
        spawnText(world, 30, 60, "Before", 48)
        settle(world, renderer)
        assert.are.equal(6, renderer.count)

        local other = tecs.ecs.newWorld()
        spawnText(other, 30, 60, "Hi", 48)
        local saved = other:saveSnapshot({}).buffer

        world:loadSnapshot(saved)
        local pixels = settle(world, renderer)

        assert.are.equal(2, renderer.count, "only the restored text is drawn, and the old glyphs are gone")
        assert.is_true(ink(pixels, 0, 0, SIZE, SIZE) > 100)
        renderer:destroy()
    end)

    -- Re-reading a font's metrics. The atlas is an image and reloads as one,
    -- under the rect it already occupies; the metrics are the half that decides
    -- what a glyph is and where the pen goes next, so they are the half a text
    -- has to be laid out again from.
    --
    -- Two fonts in one world, because the interesting claim is not that a
    -- re-read is picked up. It is that it is picked up by exactly the texts
    -- drawing that font: they share an archetype, the gate that opens is the
    -- archetype's, and what tells the two apart has to be finer than that.
    describe("re-reading a font", function()
        local second, secondPath, dir

        local function write(path, body)
            local file = assert(io.open(path, "wb"))
            file:write(body)
            file:close()
        end

        --- The shipped metrics, with every advance scaled. A second font over
        --- the same atlas, so what differs between the two is the metrics and
        --- nothing about the image behind them.
        local function shipped(factor)
            local cjson = require("cjson")
            local source = filesystem.read(tecs.filesystem.assetPath("fonts/jetbrainsmono-extrabold-msdf.json"))
            local root = cjson.decode(source)
            for _, entry in ipairs(root.chars) do
                entry.xadvance = entry.xadvance * factor
            end
            return cjson.encode(root)
        end

        before_each(function()
            local scratch = os.tmpname()
            os.remove(scratch)
            os.execute("mkdir -p '" .. scratch .. "'")
            dir = scratch .. "/"
            secondPath = dir .. "specsecond.json"
            write(secondPath, shipped(1))
            second = text.loadFont({
                metrics = secondPath,
                atlas = tecs.filesystem.assetPath("fonts/jetbrainsmono-extrabold-msdf.png"),
            })
        end)

        after_each(function()
            os.execute("rm -rf '" .. dir .. "'")
        end)

        it("lays out only the texts that draw the font that was re-read", function()
            local world, renderer = newScene()
            local size = 32
            local kept = spawnText(world, 20, 30, "II", size)
            local reread = world:spawn(
                Transform(20, 90, 0, 1),
                Tint(0.0, 1.0, 0.0, 1.0),
                text.Text.new({ text = "II", font = second, size = size })
            )
            settle(world, renderer)
            assert.are.equal(4, renderer.count)

            local before = text.textLayouts(world)
            local keptSpan = world:get(kept, text.Text)._span
            local keptX, keptY = text.glyphAt(world, kept, 2)

            write(secondPath, shipped(2))
            assert.are.equal(second, text.reloadFont(secondPath), "a re-read keeps the table the Text holds")

            -- The record holding the atlas was given up with the metrics, but
            -- the atlas is still on the renderer under its own name, so it is
            -- picked up again without a decode and the text lays out once. If
            -- the other text had relaid too this would be two.
            frame(world, renderer)
            assets.waitAll()
            frame(world, renderer)

            assert.are.equal(before + 1, text.textLayouts(world), "a text naming another font was laid out again")
            assert.are.equal(keptSpan, world:get(kept, text.Text)._span, "and it kept its span")
            local afterX, afterY = text.glyphAt(world, kept, 2)
            assert.are.equal(keptX, afterX, "and its glyphs are where they were")
            assert.are.equal(keptY, afterY)

            -- And the one that was re-read draws from the metrics that arrived.
            local metrics = font.glyphs[string.byte("I")]
            local scale = size / second.size
            local firstX = text.glyphAt(world, reread, 1)
            local secondX = text.glyphAt(world, reread, 2)
            assert.is_true(
                math.abs((secondX - firstX) - 2 * metrics.xAdvance * scale) < 0.01,
                "the second glyph belongs one doubled advance along from the first"
            )
            assert.are.equal(4, renderer.count, "and the run is the length it was")
            renderer:destroy()
        end)

        it("refuses metrics that name an atlas of another size", function()
            -- A glyph carries UV extents computed against the atlas size, and
            -- every glyph already drawn holds them, so this is refused on the
            -- terms `reload_image` refuses an image whose size moved.
            local world, renderer = newScene()
            world:spawn(
                Transform(20, 30, 0, 1),
                Tint(0.0, 1.0, 0.0, 1.0),
                text.Text.new({ text = "II", font = second, size = 32 })
            )
            settle(world, renderer)

            local cjson = require("cjson")
            local root = cjson.decode(shipped(2))
            root.common.scaleW = root.common.scaleW * 2
            write(secondPath, cjson.encode(root))

            local ok, reason = pcall(text.reloadFont, secondPath)
            assert.is_false(ok)
            assert.is_truthy(tostring(reason):find("1024", 1, true), "unexpected refusal: " .. tostring(reason))
            assert.are.equal(512, second.atlasWidth, "a refusal leaves the font as it was")

            local before = text.textLayouts(world)
            frame(world, renderer)
            assert.are.equal(before, text.textLayouts(world), "a refused re-read must not lay anything out")
            assert.are.equal(2, renderer.count)
            renderer:destroy()
        end)
    end)

    it("refuses an alignment it does not have", function()
        local ok, reason = pcall(function()
            return text.Text.new({ text = "x", font = font, align = "middle" })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("middle", 1, true), "the error should name what was asked for")
    end)
end)
