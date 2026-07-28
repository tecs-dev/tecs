-- Sprite sheets and the playback that reads them.
--
-- Two properties are worth more than the rest here. Playback advances in the
-- fixed phases, so the same sequence of steps has to produce the same frame
-- however many frames were drawn between them. And a sprite whose frame did
-- not change this step must leave its column clean, because the renderer skips
-- archetypes on exactly that bit.
--
-- Playback resolves on the GPU by default and on the host behind the flag, and
-- the two agree on the frame while differing on what they write to reach it.
-- So a case that asks which frame is showing asks `animation.frameOf`, which
-- answers from wherever the path it is on keeps the answer, and a case about
-- what a path writes names its path with `withPlayback`.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local sheet = require("tecs.gfx.sheet")
local animation = require("tecs.gfx.animation")
local frametable = require("tecs.gfx.frametable")

local Sprite = components.Sprite
local Animation = animation.Animation
local AnimationEvents = animation.AnimationEvents
local Pivot = sheet.Pivot

local STEP = 1 / 60
local EPSILON = 1e-6

local function near(actual, expected, what)
    assert.is_true(
        math.abs(actual - expected) < EPSILON,
        ("%s: expected %.6f, got %.6f"):format(what or "value", expected, actual)
    )
end

-- Sheet names are process wide, so each case takes a fresh one.
local nextName = 0
local function uniqueName(prefix)
    nextName = nextName + 1
    return ("%s%d"):format(prefix, nextName)
end

-- Four 16x16 frames in a 2x2 grid, with "walk" naming the second row.
local function walkSheet()
    return sheet.grid({
        name = uniqueName("walk"),
        imageWidth = 32,
        imageHeight = 32,
        frameWidth = 16,
        frameHeight = 16,
        tags = { walk = { from = 3, to = 4 }, whole = { from = 1, to = 4 } },
    })
end

-- Four frames in a row, which is what the playback cases count through.
local function stripSheet()
    return sheet.grid({
        name = uniqueName("strip"),
        imageWidth = 64,
        imageHeight = 16,
        frameWidth = 16,
        frameHeight = 16,
        tags = { run = { from = 1, to = 4 } },
    })
end

local function animatedWorld()
    local world = tecs.ecs.newWorld()
    world:addPlugin(animation.plugin)
    return world
end

local function drive(world, steps)
    for _ = 1, steps do
        world:update(STEP)
    end
end

-- Runs a body on one playback path and puts the flag back however it ends.
-- Which systems a world gets is decided when the plugin is added, so the flag
-- has to be set before `animatedWorld` and not after it.
local function withPlayback(gpu, body)
    local was = animation.usesGPU()
    animation.useGPU(gpu)
    local ok, err = pcall(body)
    animation.useGPU(was)
    if not ok then
        error(err, 0)
    end
end

describe("the surface a game reaches sheets through", function()
    -- Nothing else in the suite names the surface key, so nothing else would
    -- notice a re-export that named the wrong function or was left off.
    it("answers with the same functions the module holds", function()
        assert.are.equal(sheet.Sheet, tecs.animation.Sheet)
        assert.are.equal(sheet.Pivot, tecs.animation.Pivot)
        assert.are.equal(sheet.DEFAULT_DURATION, tecs.animation.DEFAULT_DURATION)
        assert.are.equal(sheet.grid, tecs.animation.grid)
        assert.are.equal(sheet.rects, tecs.animation.rects)
        assert.are.equal(sheet.build, tecs.animation.build)
        assert.are.equal(sheet.fromAseprite, tecs.animation.fromAseprite)
        assert.are.equal(sheet.replace, tecs.animation.replace)
    end)

    it("renames the three whose subject the move made ambiguous", function()
        -- `byName` on a module called animation reads as an animation lookup
        -- and answers with a sheet, which is why these three carry the word.
        assert.are.equal(sheet.byId, tecs.animation.sheetById)
        assert.are.equal(sheet.byName, tecs.animation.sheetByName)
        assert.are.equal(sheet.revision, tecs.animation.sheetRevision)
        assert.is_nil(rawget(tecs.animation, "byId"))
        assert.is_nil(rawget(tecs.animation, "byName"))
        assert.is_nil(rawget(tecs.animation, "revision"))
    end)

    it("no longer answers to a module of its own", function()
        -- Nil rather than an error, because the surface catches a name it does
        -- not carry where it is written: Teal refuses `tecs.sheet` at compile
        -- time, and a Lua spec is the one caller that gets this far.
        assert.is_nil(tecs.sheet)
    end)
end)

describe("tecs.gfx.sheet", function()
    describe("a uniform grid", function()
        it("cuts the cells left to right and then top to bottom", function()
            local s = sheet.grid({
                name = uniqueName("grid"),
                imageWidth = 64,
                imageHeight = 32,
                frameWidth = 16,
                frameHeight = 16,
            })

            assert.equal(8, s.count)

            local x, y, w, h = s:rect(1)
            assert.equal(0, x)
            assert.equal(0, y)
            assert.equal(16, w)
            assert.equal(16, h)

            -- Last cell of the first row.
            x, y = s:rect(4)
            assert.equal(48, x)
            assert.equal(0, y)

            -- First cell of the second row, which is where the wrap shows.
            x, y = s:rect(5)
            assert.equal(0, x)
            assert.equal(16, y)

            x, y = s:rect(8)
            assert.equal(48, x)
            assert.equal(16, y)
        end)

        it("insets by the margin and separates by the spacing", function()
            local s = sheet.grid({
                name = uniqueName("padded"),
                imageWidth = 40,
                imageHeight = 40,
                frameWidth = 16,
                frameHeight = 16,
                margin = 2,
                spacing = 4,
            })

            -- Two cells fit across 40 pixels once a 2 pixel border and a 4
            -- pixel gap are taken out: 2 + 16 + 4 + 16 + 2 == 40.
            assert.equal(4, s.count)

            local x, y, w, h = s:rect(1)
            assert.equal(2, x)
            assert.equal(2, y)
            assert.equal(16, w)
            assert.equal(16, h)

            x, y = s:rect(2)
            assert.equal(22, x)
            assert.equal(2, y)

            x, y = s:rect(3)
            assert.equal(2, x)
            assert.equal(22, y)

            x, y = s:rect(4)
            assert.equal(22, x)
            assert.equal(22, y)
        end)

        it("reports a frame's region as its fraction of the image", function()
            local s = sheet.grid({
                name = uniqueName("uv"),
                imageWidth = 40,
                imageHeight = 40,
                frameWidth = 16,
                frameHeight = 16,
                margin = 2,
                spacing = 4,
            })

            local u0, v0, u1, v1 = s:uv(2)
            near(u0, 22 / 40, "u0")
            near(v0, 2 / 40, "v0")
            near(u1, 38 / 40, "u1")
            near(v1, 18 / 40, "v1")
        end)

        it("scales the regions into the layer the image was given", function()
            local s = sheet.grid({
                name = uniqueName("bound"),
                imageWidth = 64,
                imageHeight = 32,
                frameWidth = 16,
                frameHeight = 16,
            })

            -- What Renderer:sprite hands back for a whole image that fills
            -- half its texture-array layer.
            s:bind(Sprite(7, 0, 0, 0.5, 0.25, 3))

            local u0, v0, u1, v1 = s:uv(5)
            near(u0, 0.0, "u0")
            near(v0, 16 / 32 * 0.25, "v0")
            near(u1, 16 / 64 * 0.5, "u1")
            near(v1, 1.0 * 0.25, "v1")

            local frame = s:sprite(5)
            assert.equal(7, frame.image)
            assert.equal(3, frame.slot)
            near(frame.u1, 16 / 64 * 0.5, "sprite u1")
        end)

        it("rejects a grid no cell fits in", function()
            assert.has_error(function()
                sheet.grid({
                    name = uniqueName("tiny"),
                    imageWidth = 8,
                    imageHeight = 8,
                    frameWidth = 16,
                    frameHeight = 16,
                })
            end)
        end)
    end)

    describe("an explicit rect list", function()
        it("addresses the rects in the order they were given", function()
            local s = sheet.rects({
                name = uniqueName("atlas"),
                imageWidth = 128,
                imageHeight = 64,
                frames = {
                    { x = 0, y = 0, w = 32, h = 64 },
                    { x = 32, y = 0, w = 16, h = 16 },
                    { x = 48, y = 8, w = 24, h = 12 },
                },
                tags = { blink = { from = 2, to = 3 } },
            })

            assert.equal(3, s.count)

            local x, y, w, h = s:rect(1)
            assert.equal(0, x)
            assert.equal(0, y)
            assert.equal(32, w)
            assert.equal(64, h)

            x, y, w, h = s:rect(3)
            assert.equal(48, x)
            assert.equal(8, y)
            assert.equal(24, w)
            assert.equal(12, h)

            local u0, v0, u1, v1 = s:uv(3)
            near(u0, 48 / 128, "u0")
            near(v0, 8 / 64, "v0")
            near(u1, 72 / 128, "u1")
            near(v1, 20 / 64, "v1")

            local from, to = s:tag("blink")
            assert.equal(2, from)
            assert.equal(3, to)
        end)

        it("rejects a frame with no size", function()
            assert.has_error(function()
                sheet.rects({
                    name = uniqueName("bad"),
                    imageWidth = 32,
                    imageHeight = 32,
                    frames = { { x = 0, y = 0 } },
                })
            end)
        end)
    end)

    describe("named tags", function()
        it("spans frames inclusively at both ends", function()
            local s = walkSheet()

            assert.is_true(s:hasTag("walk"))
            assert.is_false(s:hasTag("crawl"))

            local from, to = s:tag("walk")
            assert.equal(3, from)
            assert.equal(4, to)

            -- Ids follow the names in sorted order, so "walk" comes after
            -- "whole" and the pair round trips.
            assert.equal("walk", s:tagName(s:tagId("walk")))
            assert.equal("whole", s:tagName(s:tagId("whole")))
            assert.equal(0, s:tagId("crawl"))
            assert.equal("", s:tagName(0))
        end)

        it("rejects a span outside the sheet", function()
            assert.has_error(function()
                sheet.grid({
                    name = uniqueName("overrun"),
                    imageWidth = 32,
                    imageHeight = 16,
                    frameWidth = 16,
                    frameHeight = 16,
                    tags = { walk = { from = 1, to = 9 } },
                })
            end)
        end)

        it("rejects a direction it does not play", function()
            assert.has_error(function()
                sheet.grid({
                    name = uniqueName("sideways"),
                    imageWidth = 32,
                    imageHeight = 16,
                    frameWidth = 16,
                    frameHeight = 16,
                    tags = { walk = { from = 1, to = 2, direction = "up" } },
                })
            end)
        end)
    end)

    -- Timing is per frame, because that is where an artist sets it: a hold
    -- frame is a frame with a long duration and no single rate expresses one.
    describe("frame durations", function()
        it("defaults to what Aseprite writes for an untouched frame", function()
            local s = stripSheet()
            near(s:duration(1), 0.1, "duration")
            near(s:cycle(s:tagId("run")), 0.4, "cycle")
        end)

        it("holds a frame for as long as its own duration", function()
            local s = sheet.rects({
                name = uniqueName("held"),
                imageWidth = 64,
                imageHeight = 16,
                frames = {
                    { x = 0, y = 0, w = 16, h = 16, duration = 50 },
                    { x = 16, y = 0, w = 16, h = 16, duration = 500 },
                    { x = 32, y = 0, w = 16, h = 16, duration = 50 },
                },
            })

            near(s:duration(2), 0.5, "the held frame")
            near(s:cycle(0), 0.6, "the cycle is the sum of the three")

            -- The long frame occupies the middle ten twelfths of the cycle.
            assert.equal(1, s:frameAt(0, 0.0))
            assert.equal(1, s:frameAt(0, 0.049))
            assert.equal(2, s:frameAt(0, 0.06))
            assert.equal(2, s:frameAt(0, 0.54))
            assert.equal(3, s:frameAt(0, 0.56))
        end)

        it("drives playback from the sheet's own timing", function()
            local world = animatedWorld()
            local s = sheet.rects({
                name = uniqueName("heldplay"),
                imageWidth = 64,
                imageHeight = 16,
                frames = {
                    { x = 0, y = 0, w = 16, h = 16, duration = 100 },
                    { x = 16, y = 0, w = 16, h = 16, duration = 500 },
                },
            })
            local entity = world:spawn(s:sprite(1), animation.of(s))

            drive(world, 3)
            assert.equal(1, animation.frameOf(world, entity))

            -- Six steps in is past the first frame's hundred milliseconds and
            -- nowhere near the end of the second's five hundred.
            drive(world, 6)
            assert.equal(2, animation.frameOf(world, entity))
            drive(world, 20)
            assert.equal(2, animation.frameOf(world, entity), "the held frame is still up half a second in")
            drive(world, 8)
            assert.equal(1, animation.frameOf(world, entity), "and the cycle wraps once it is spent")
        end)

        it("scales the whole cycle by an entity's speed", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { speed = 2 }))

            -- Twice as fast is three steps to the frame rather than six.
            drive(world, 2)
            assert.equal(1, animation.frameOf(world, entity))
            drive(world, 2)
            assert.equal(2, animation.frameOf(world, entity))
            drive(world, 3)
            assert.equal(3, animation.frameOf(world, entity))
        end)
    end)

    describe("tag directions", function()
        local function walked(direction, steps)
            local s = sheet.grid({
                name = uniqueName("dir"),
                imageWidth = 48,
                imageHeight = 16,
                frameWidth = 16,
                frameHeight = 16,
                tags = { go = { from = 1, to = 3, direction = direction } },
            })
            local world = animatedWorld()
            local entity = world:spawn(s:sprite(1), animation.of(s, "go"))

            local seen = {}
            for _ = 1, steps do
                world:update(STEP)
                seen[#seen + 1] = animation.frameOf(world, entity)
            end
            return seen, s
        end

        -- Sampled in the middle of each frame rather than at its edges, so a
        -- rounding difference at a boundary cannot decide the answer. A frame
        -- runs for six steps, and the two paths anchor a fresh entity's cycle
        -- one step apart, so a sample within a step of a boundary is one the
        -- suite decides by luck rather than by measurement.
        local function atFrames(seen, ...)
            local out = {}
            for index = 1, select("#", ...) do
                out[index] = seen[select(index, ...)]
            end
            return out
        end

        it("walks forward from the first frame to the last", function()
            local seen = walked("forward", 20)
            assert.are.same({ 1, 2, 3, 1 }, atFrames(seen, 3, 9, 15, 20))
        end)

        it("walks a reverse tag from the last frame to the first", function()
            local seen = walked("reverse", 20)
            assert.are.same({ 3, 2, 1, 3 }, atFrames(seen, 3, 9, 15, 20))
        end)

        it("walks a pingpong tag out and back without repeating an end", function()
            -- Three frames pingpong is 1, 2, 3, 2 and then round: five
            -- steps of a hundred milliseconds is a cycle of four frames,
            -- not six, because neither end plays twice.
            --
            -- The sixth sample is at 33 rather than 30 because 30 steps is 500
            -- milliseconds, which is a hundred into the second cycle and so
            -- exactly on a frame boundary.
            local seen, s = walked("pingpong", 33)
            near(s:cycle(s:tagId("go")), 0.4, "the cycle skips both ends")
            assert.are.same({ 1, 2, 3, 2, 1, 2 }, atFrames(seen, 3, 9, 15, 21, 27, 33))
        end)

        it("defaults to forward", function()
            local s = sheet.grid({
                name = uniqueName("plain"),
                imageWidth = 32,
                imageHeight = 16,
                frameWidth = 16,
                frameHeight = 16,
                tags = { go = { from = 1, to = 2 } },
            })
            local _, _, direction = s:tag("go")
            assert.equal("forward", direction)
        end)
    end)

    -- Slices are Aseprite's, and a pivot is read out of one rather than
    -- invented alongside it. What the engine wants is a fraction of the frame,
    -- so the slice's own origin is added and the frame's size divided out here
    -- and nowhere downstream.
    describe("slices", function()
        local function sliced()
            return sheet
                .build(uniqueName("sliced"), 64, 32)
                :frame(0, 0, 32, 32)
                :frame(32, 0, 32, 32)
                :slice("feet", 8, 24, 16, 8, 8, 8)
                :slice("plain", 4, 4, 8, 8)
                :finish()
        end

        it("addresses a slice by name and by index", function()
            local s = sliced()
            local feet = s:sliceId("feet")
            assert.is_true(feet > 0)
            assert.equal("feet", s:sliceName(feet))
            assert.equal(0, s:sliceId("elbow"))
            assert.equal("feet", s:slice("feet").name)
            assert.is_nil(s:slice("elbow"))
        end)

        it("reads a pivot as a fraction of the frame", function()
            local s = sliced()
            -- The slice sits at 8,24 in a 32x32 frame and its pivot is 8,8
            -- into the slice, so the point is 16,32 of the frame.
            local x, y = s:pivotOf(s:sliceId("feet"), 1)
            near(x, 0.5, "pivot x")
            near(y, 1.0, "pivot y")
        end)

        it("stands the middle of a slice in for a pivot it has none", function()
            local s = sliced()
            -- 4,4 plus half of 8x8 is 8,8 of a 32x32 frame.
            local x, y = s:pivotOf(s:sliceId("plain"), 1)
            near(x, 0.25, "pivot x")
            near(y, 0.25, "pivot y")
        end)

        it("answers the middle of the frame for no slice at all", function()
            local s = sliced()
            local x, y = s:pivotOf(0, 1)
            near(x, 0.5, "pivot x")
            near(y, 0.5, "pivot y")
        end)

        it("holds a key until the next one", function()
            local s = sheet
                .build(uniqueName("moving"), 64, 32)
                :frame(0, 0, 32, 32)
                :frame(32, 0, 32, 32)
                :frame(0, 0, 32, 32)
                :sliceKeys("hand", "grip", {
                    { frame = 1, x = 0, y = 0, w = 8, h = 8, pivotX = 4, pivotY = 4 },
                    { frame = 3, x = 16, y = 16, w = 8, h = 8, pivotX = 4, pivotY = 4 },
                })
                :finish()

            local hand = s:sliceId("hand")
            assert.equal("grip", s:slice("hand").data)
            assert.equal(1, s:sliceKeyAt(hand, 1).frame)
            assert.equal(1, s:sliceKeyAt(hand, 2).frame, "frame two has no key of its own and holds frame one's")
            assert.equal(3, s:sliceKeyAt(hand, 3).frame)

            local x, y = s:pivotOf(hand, 3)
            near(x, 20 / 32, "pivot x on the third frame")
            near(y, 20 / 32, "pivot y on the third frame")
        end)
    end)

    describe("pivots", function()
        -- Two 32x32 frames with a slice that moves between them, which is what
        -- tells a pivot that follows its slice from one that was resolved once
        -- and left there.
        local function pivoted(name)
            return sheet
                .build(name or uniqueName("pivoted"), 64, 32)
                :frame(0, 0, 32, 32)
                :frame(32, 0, 32, 32)
                :sliceKeys("feet", nil, {
                    { frame = 1, x = 8, y = 24, w = 16, h = 8, pivotX = 8, pivotY = 8 },
                    { frame = 2, x = 0, y = 0, w = 16, h = 8, pivotX = 8, pivotY = 0 },
                })
                :finish()
        end

        it("resolves a named slice and stays bound to it", function()
            local s = pivoted()
            local p = s:pivot("feet")

            -- The slice sits at 8,24 in a 32x32 frame and its pivot is 8,8
            -- into the slice, so the point is 16,32 of the frame.
            near(p.x, 0.5, "pivot x")
            near(p.y, 1.0, "pivot y")
            assert.equal(s.id, p.sheet)
            assert.equal(s:sliceId("feet"), p.slice, "bound, so playback can move it")
        end)

        it("resolves at the frame it is asked for", function()
            local s = pivoted()
            local p = s:pivot("feet", 2)
            near(p.x, 0.25, "pivot x")
            near(p.y, 0.0, "pivot y")
        end)

        it("fails on a slice the sheet does not carry", function()
            local s = pivoted()
            assert.has_error(function()
                s:pivot("elbow")
            end)
        end)

        it("sits in the middle of the frame until something says otherwise", function()
            local p = Pivot()
            near(p.x, 0.5, "pivot x")
            near(p.y, 0.5, "pivot y")
            assert.equal(0, p.sheet, "written directly")
            assert.equal(0, p.slice)
        end)

        it("carries the sheet and slice by name through a snapshot", function()
            local world = tecs.ecs.newWorld()
            local name = uniqueName("saved")
            local first = pivoted(name)
            local entity = world:spawn(first:pivot("feet"))

            local saved = world:saveSnapshot({ format = "table" }).snapshot

            -- A second sheet under the same name takes it over, with an extra
            -- slice ahead of the one that matters so both indices move. An
            -- index in a file would land on whatever this run numbered the
            -- same; a name lands on the sheet the run actually has.
            local second = sheet
                .build(name, 64, 32)
                :frame(0, 0, 32, 32)
                :frame(32, 0, 32, 32)
                :slice("head", 8, 0, 16, 8)
                :sliceKeys("feet", nil, {
                    { frame = 1, x = 8, y = 24, w = 16, h = 8, pivotX = 8, pivotY = 8 },
                })
                :finish()
            assert.is_true(second.id ~= first.id, "a rebuild takes a fresh id")
            assert.is_true(second:sliceId("feet") ~= first:sliceId("feet"), "and numbers its slices differently")

            world:loadSnapshot(saved)

            local restored = world:get(entity, Pivot)
            assert.equal(second.id, restored.sheet)
            assert.equal(second:sliceId("feet"), restored.slice)
            near(restored.x, 0.5, "pivot x")
            near(restored.y, 1.0, "pivot y")
        end)

        it("restores a pivot written directly with no sheet to name", function()
            local world = tecs.ecs.newWorld()
            local entity = world:spawn(Pivot(0.25, 0.75))

            local saved = world:saveSnapshot({ format = "table" }).snapshot
            world:loadSnapshot(saved)

            local restored = world:get(entity, Pivot)
            near(restored.x, 0.25, "pivot x")
            near(restored.y, 0.75, "pivot y")
            assert.equal(0, restored.slice, "still bound to nothing")
        end)
    end)

    describe("the builder", function()
        it("writes frames, tags and slices in any order", function()
            local s = sheet
                .build(uniqueName("built"), 64, 16)
                :tag("blink", 2, 3, "pingpong")
                :frame(0, 0, 16, 16, 40)
                :frame(16, 0, 16, 16)
                :frame(32, 0, 16, 16, 250)
                :slice("eye", 2, 2, 4, 4)
                :finish()

            assert.equal(3, s.count)
            near(s:duration(1), 0.04, "an explicit duration")
            near(s:duration(2), 0.1, "and the default for one left out")
            near(s:duration(3), 0.25, "duration three")

            local from, to, direction = s:tag("blink")
            assert.equal(2, from)
            assert.equal(3, to)
            assert.equal("pingpong", direction)
            assert.is_true(s:sliceId("eye") > 0)

            -- A two-frame pingpong has no middle to fold back through, so it
            -- is the two frames and nothing more.
            near(s:cycle(s:tagId("blink")), 0.35, "the blink cycle")
        end)

        it("registers the sheet under its name", function()
            local name = uniqueName("registered")
            local s = sheet.build(name, 16, 16):frame(0, 0, 16, 16):finish()
            assert.equal(s, sheet.byName(name))
            assert.equal(s, sheet.byId(s.id))
        end)

        it("refuses a sheet with no frames", function()
            assert.has_error(function()
                sheet.build(uniqueName("empty"), 16, 16):finish()
            end)
        end)

        it("refuses a frame with no size", function()
            assert.has_error(function()
                sheet.build(uniqueName("flat"), 16, 16):frame(0, 0, 0, 16)
            end)
        end)
    end)

    -- The JSON export is one reader in front of the model, not a second model.
    -- A reader for the binary format populates the same sheet.
    describe("an Aseprite export", function()
        local EXPORT = {
            frames = {
                {
                    filename = "hero 0.aseprite",
                    frame = { x = 0, y = 0, w = 16, h = 24 },
                    duration = 80,
                },
                {
                    filename = "hero 1.aseprite",
                    frame = { x = 16, y = 0, w = 16, h = 24 },
                    duration = 300,
                },
                {
                    filename = "hero 2.aseprite",
                    frame = { x = 32, y = 0, w = 16, h = 24 },
                    duration = 80,
                },
            },
            meta = {
                image = "hero.png",
                size = { w = 48, h = 24 },
                frameTags = {
                    { name = "idle", from = 0, to = 0, direction = "forward" },
                    { name = "walk", from = 1, to = 2, direction = "pingpong" },
                },
                slices = {
                    {
                        name = "feet",
                        data = "anchor",
                        keys = {
                            {
                                frame = 0,
                                bounds = { x = 4, y = 20, w = 8, h = 4 },
                                pivot = { x = 4, y = 4 },
                            },
                        },
                    },
                },
            },
        }

        it("reads frames, their durations, tags and slices", function()
            local s = sheet.fromAseprite({
                name = uniqueName("hero"),
                json = EXPORT,
            })

            assert.equal(3, s.count)
            assert.equal(48, s.imageWidth)
            assert.equal(24, s.imageHeight)

            local x, y, w, h = s:rect(2)
            assert.equal(16, x)
            assert.equal(0, y)
            assert.equal(16, w)
            assert.equal(24, h)
            near(s:duration(2), 0.3, "the held frame")

            -- Aseprite counts frames from zero and the model from one, so the
            -- span moves by one at the boundary and nowhere else.
            local from, to, direction = s:tag("walk")
            assert.equal(2, from)
            assert.equal(3, to)
            assert.equal("pingpong", direction)
            assert.equal(1, select(1, s:tag("idle")))

            local feet = s:sliceId("feet")
            assert.is_true(feet > 0)
            assert.equal("anchor", s:slice("feet").data)
            local px, py = s:pivotOf(feet, 1)
            near(px, 8 / 16, "pivot x")
            near(py, 24 / 24, "pivot y")
        end)

        it("takes its name from the export when none is given", function()
            local s = sheet.fromAseprite({ json = EXPORT })
            assert.equal("hero.png", s.name)
        end)

        it("orders an object of frames by name", function()
            -- The other layout Aseprite writes. The names carry the frame
            -- number, so sorting them is what puts the frames back in order.
            local s = sheet.fromAseprite({
                name = uniqueName("keyed"),
                json = {
                    frames = {
                        ["hero 2.aseprite"] = { frame = { x = 32, y = 0, w = 16, h = 16 } },
                        ["hero 0.aseprite"] = { frame = { x = 0, y = 0, w = 16, h = 16 } },
                        ["hero 1.aseprite"] = { frame = { x = 16, y = 0, w = 16, h = 16 } },
                    },
                    meta = { size = { w = 48, h = 16 } },
                },
            })

            assert.equal(3, s.count)
            assert.equal(0, select(1, s:rect(1)))
            assert.equal(16, select(1, s:rect(2)))
            assert.equal(32, select(1, s:rect(3)))
        end)

        it("reads the export as text as well as as a table", function()
            local json = require("tecs.json")
            local s = sheet.fromAseprite({
                name = uniqueName("text"),
                json = json.encode(EXPORT),
            })
            assert.equal(3, s.count)
            near(s:duration(2), 0.3, "the held frame survived the round trip")
        end)

        it("plays what it read", function()
            local world = animatedWorld()
            local s = sheet.fromAseprite({
                name = uniqueName("played"),
                json = EXPORT,
            })
            local entity = world:spawn(s:sprite(1), animation.of(s, "walk"))

            -- Model frames two and three, three hundred and eighty
            -- milliseconds. A two-frame pingpong has no middle to fold back
            -- through, so the cycle is the two of them: 0.38 seconds.
            near(s:cycle(s:tagId("walk")), 0.38, "the walk cycle")

            drive(world, 3)
            assert.equal(2, animation.frameOf(world, entity))
            drive(world, 14)
            assert.equal(2, animation.frameOf(world, entity), "the three hundred millisecond frame is still up")
            drive(world, 3)
            assert.equal(3, animation.frameOf(world, entity))
            drive(world, 4)
            assert.equal(2, animation.frameOf(world, entity), "and the cycle wrapped once both were spent")
        end)
    end)

    -- Overwriting a sheet in place, which is what a re-exported file wants and
    -- the opposite of what building under a taken name does. Building again is
    -- right for two sheets that happen to share a name and wrong for one file
    -- that was exported twice: an entity already playing keeps the old id and
    -- goes on showing the old frames, which is exactly what a reload must not
    -- do.
    describe("replacing a sheet in place", function()
        --- The same grid at a chosen cell size, so a re-export can change the
        --- frames without changing the tags over them.
        local function grid(name, cell, tags)
            return sheet.grid({
                name = name,
                imageWidth = 32,
                imageHeight = 32,
                frameWidth = cell,
                frameHeight = cell,
                tags = tags or { walk = { from = 1, to = 2 } },
            })
        end

        it("keeps the id and the object, and shows the new frames", function()
            local name = uniqueName("reload")
            local live = grid(name, 16)
            local id = live.id
            near(select(3, live:rect(1)), 16, "the frame width before")

            local built = grid(name, 8)
            local replaced = sheet.replace(built)

            assert.are.equal(live, replaced, "an entity already playing holds this table")
            assert.are.equal(id, live.id, "an Animation carries the id, so it cannot move")
            assert.are.equal(live, sheet.byName(name), "the name answers the live sheet again")
            assert.are.equal(16, live.count, "the re-export cut sixteen frames, not four")
            near(select(3, live:rect(1)), 8, "the frame width after")

            -- The build is spent, so the id it took resolves to the sheet its
            -- frames ended up in. The two share those tables now, and leaving
            -- both reachable would let a bind on one write through the other.
            assert.are.equal(live, sheet.byId(built.id))
            assert.are.equal(live, sheet.byId(id))
        end)

        it("rescales the new frames against the bind the sheet already had", function()
            local name = uniqueName("reload")
            local live = grid(name, 16)
            -- Half a layer, the way a packed image reports itself.
            live:bind(components.Sprite(3, 0.0, 0.0, 0.5, 0.5, 2))
            near(select(3, live:uv(1)), 0.25, "half of half the image")

            sheet.replace(grid(name, 8))

            local _, _, u1 = live:uv(1)
            near(u1, 0.125, "the new frame is a quarter of the image and the image is half the layer")
            assert.are.equal(2, live:sprite(1).slot, "the layer the sheet was bound to")
        end)

        it("refuses a re-export whose tags would renumber", function()
            local name = uniqueName("reload")
            local live = grid(name, 16)
            local before = live:tagId("walk")

            local replaced, reason = sheet.replace(grid(name, 8, {
                walk = { from = 1, to = 2 },
                idle = { from = 3, to = 4 },
            }))

            assert.is_nil(replaced)
            assert.is_truthy(reason:find("idle", 1, true), "the refusal must name what moved: " .. tostring(reason))
            assert.are.equal(before, live:tagId("walk"), "a refusal leaves the live sheet alone")
            assert.are.equal(4, live.count)
            assert.are.equal(live, sheet.byName(name), "and leaves the name answering it")
        end)

        it("refuses a re-export whose slices would renumber", function()
            local name = uniqueName("reload")
            local live = sheet.grid({
                name = name,
                imageWidth = 32,
                imageHeight = 32,
                frameWidth = 16,
                frameHeight = 16,
                slices = { { name = "head", keys = { { frame = 1, x = 0, y = 0, w = 4, h = 4 } } } },
            })
            local before = live:sliceId("head")

            local replaced, reason = sheet.replace(sheet.grid({
                name = name,
                imageWidth = 32,
                imageHeight = 32,
                frameWidth = 16,
                frameHeight = 16,
                slices = {
                    { name = "foot", keys = { { frame = 1, x = 0, y = 0, w = 4, h = 4 } } },
                    { name = "head", keys = { { frame = 1, x = 0, y = 0, w = 4, h = 4 } } },
                },
            }))

            assert.is_nil(replaced)
            assert.is_truthy(reason:find("Pivot", 1, true), "unexpected refusal: " .. tostring(reason))
            assert.are.equal(before, live:sliceId("head"))
        end)

        it("refuses a name nothing is registered under", function()
            local replaced, reason = sheet.replace(grid(uniqueName("fresh"), 16))
            assert.is_nil(replaced)
            assert.is_truthy(reason:find("nothing to replace", 1, true), "unexpected refusal: " .. tostring(reason))
        end)

        it("carries an entity that is already playing onto the new frames", function()
            local name = uniqueName("reload")
            local live = grid(name, 16)
            local world = animatedWorld()
            local entity = world:spawn(live:sprite(1), animation.of(live, "walk"))

            sheet.replace(grid(name, 8))
            drive(world, 12)

            -- The id never moved, so playback resolved through the same sheet
            -- and landed on a frame of the ones it now holds. Eight pixels
            -- across is the re-export's cut and four the one it displaced, so
            -- the frame's own width is what says which sheet answered.
            assert.are.equal(live.id, world:get(entity, Animation).sheet)
            local frame = animation.frameOf(world, entity)
            assert.is_true(frame >= 1 and frame <= live.count, "a frame of the sheet as it reads now")
            near(select(3, live:rect(frame)), 8, "and cut to the re-export's size")
        end)
    end)
end)

describe("tecs.gfx.animation", function()
    -- A frame's default hundred milliseconds against a sixtieth of a second
    -- step is six steps to the frame, so every assertion below lands in the
    -- middle of one rather than on a boundary where a rounding difference
    -- would decide it.
    local STEPS_PER_FRAME = 6

    describe("playing a named tag", function()
        it("walks the tag in order", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

            local expected = { 1, 2, 3, 4 }
            for index = 1, #expected do
                drive(world, index == 1 and 3 or STEPS_PER_FRAME)
                assert.equal(expected[index], animation.frameOf(world, entity))
            end
        end)

        -- Which frame is showing is one answer and what the entity carries to
        -- reach it is the other, and the two paths differ only in the second.
        it("writes the frame's region into the Sprite on the host", function()
            withPlayback(false, function()
                local world = animatedWorld()
                local s = stripSheet()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

                drive(world, 3 + STEPS_PER_FRAME)
                local frame = animation.frameOf(world, entity)
                assert.equal(2, frame)

                local u0, v0, u1, v1 = s:uv(frame)
                local sprite = world:get(entity, Sprite)
                near(sprite.u0, u0, "u0 of frame " .. frame)
                near(sprite.v0, v0, "v0 of frame " .. frame)
                near(sprite.u1, u1, "u1 of frame " .. frame)
                near(sprite.v1, v1, "v1 of frame " .. frame)
            end)
        end)

        it("carries a playback rather than a region on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = stripSheet()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

                drive(world, 3 + STEPS_PER_FRAME)
                assert.equal(2, animation.frameOf(world, entity))

                -- The region the frame resolves to lives in the table the
                -- shader reads, and what the entity carries is which playback
                -- it is on. The frame moving is then not a write at all.
                local sprite = world:get(entity, Sprite)
                assert.is_true(frametable.isPlayback(sprite), "the Sprite names a playback")
                assert.equal(frametable.register(s, s:tagId("run")), frametable.playbackOf(sprite))
            end)
        end)

        it("plays only the frames the tag names", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "walk"))

            drive(world, 3)
            assert.equal(3, animation.frameOf(world, entity))

            drive(world, STEPS_PER_FRAME)
            assert.equal(4, animation.frameOf(world, entity))

            -- Two frames at ten a second is a fifth of a second, so the next
            -- step past it is back at the tag's first frame and not the
            -- sheet's.
            drive(world, STEPS_PER_FRAME)
            assert.equal(3, animation.frameOf(world, entity))
        end)

        it("plays the whole sheet when no tag is named", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, nil))

            drive(world, 3 + STEPS_PER_FRAME * 2)
            assert.equal(3, animation.frameOf(world, entity))
        end)

        it("refuses a tag the sheet does not carry", function()
            local s = stripSheet()
            assert.has_error(function()
                animation.of(s, "crawl")
            end)
        end)
    end)

    describe("ending", function()
        it("wraps a looping tag back to its first frame", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = true }))

            -- Four frames at ten a second is 24 steps to the cycle. Three past
            -- the wrap is the first frame again, not the last.
            drive(world, 27)
            assert.equal(1, animation.frameOf(world, entity))
            assert.is_true(world:get(entity, Animation).playing)
        end)

        it("parks a one-shot on its last frame and stops", function()
            local world = animatedWorld()
            local s = stripSheet()
            -- The flag a one-shot parks behind is what `Completed` sets, and
            -- the event reaches the entities that asked for it, so this asks.
            -- The frame parks either way: playback that runs off the end of a
            -- tag that does not loop holds the last tick whether or not
            -- anything is listening.
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

            drive(world, 27)
            assert.equal(4, animation.frameOf(world, entity))
            assert.is_false(world:get(entity, Animation).playing)

            -- And stays there however long the world keeps running.
            drive(world, 120)
            assert.equal(4, animation.frameOf(world, entity))
            assert.is_false(world:get(entity, Animation).playing)
        end)

        it("parks the frame of a one-shot nothing is listening to", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

            drive(world, 27)
            assert.equal(4, animation.frameOf(world, entity))
            drive(world, 120)
            assert.equal(4, animation.frameOf(world, entity), "and holds it")
        end)

        it("holds the first frame when the rate is zero", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { speed = 0 }))

            drive(world, 60)
            assert.equal(1, animation.frameOf(world, entity))
        end)
    end)

    -- Both events are derived rather than observed on the GPU path: what says
    -- an entity crossed its cycle is its start and its rate against the step
    -- count, so nothing is written to report one. The cost of that is the
    -- opt-in, which puts the entities a game listens to in an archetype of
    -- their own and leaves a crowd of animations visited by no query at all.
    describe("events", function()
        it("reports a one-shot completing once", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

            local seen = {}
            world:observe(0, animation.Completed, function(event)
                seen[#seen + 1] = {
                    entity = event.entity,
                    tag = event.tag,
                    sheet = event.sheet,
                }
            end)

            drive(world, 120)

            assert.equal(1, #seen)
            assert.equal(entity, seen[1].entity)
            assert.equal("run", seen[1].tag)
            assert.equal(s, seen[1].sheet)
        end)

        it("reports a looping tag wrapping once per cycle", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = true }), AnimationEvents())

            local seen = {}
            world:observe(0, animation.Looped, function(event)
                seen[#seen + 1] = { entity = event.entity, tag = event.tag }
            end)

            -- One cycle is 24 steps, so 27 has passed the first wrap and is
            -- nowhere near the second.
            drive(world, 27)
            assert.equal(1, #seen)
            assert.equal(entity, seen[1].entity)
            assert.equal("run", seen[1].tag)

            drive(world, 24)
            assert.equal(2, #seen)
        end)

        it("does not report a loop for a one-shot, or the reverse", function()
            local world = animatedWorld()
            local s = stripSheet()
            world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

            local loops, completions = 0, 0
            world:observe(0, animation.Looped, function()
                loops = loops + 1
            end)
            world:observe(0, animation.Completed, function()
                completions = completions + 1
            end)

            drive(world, 120)

            assert.equal(0, loops)
            assert.equal(1, completions)
        end)

        it("reaches only the entities that asked, once playback is on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))
                world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

                local completions = 0
                world:observe(0, animation.Completed, function()
                    completions = completions + 1
                end)

                drive(world, 120)

                assert.equal(1, completions, "one of the two subscribed")
            end)
        end)

        it("writes nothing to report a cycle wrapping on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run", { loop = true }), AnimationEvents())

                local wraps = 0
                world:observe(0, animation.Looped, function()
                    wraps = wraps + 1
                end)

                local dirtied = false
                local query = world:query({
                    name = "spec.SubscriberProbe",
                    include = { Animation, Sprite, AnimationEvents },
                })
                world:addSystem({
                    name = "spec.ReadSubscriberDirty",
                    phase = tecs.ecs.phases.Last,
                    run = function()
                        for archetype in query:iter() do
                            if archetype:isComponentDirty(Sprite) or archetype:isComponentDirty(Animation) then
                                dirtied = true
                            end
                        end
                    end,
                })

                -- Past the first encode, which is a write and the only one.
                drive(world, 2)
                dirtied = false
                drive(world, 60)

                assert.is_true(wraps >= 2, "two cycles went by")
                assert.is_false(dirtied, "and neither column was touched to say so")
            end)
        end)
    end)

    -- What an entity is playing has to survive things that are not about
    -- playback. Moving archetype marks every component on the destination
    -- dirty, which is how a spawn and a snapshot load reach playback without
    -- knowing it exists; the cost of that is that adding an unrelated component
    -- asks playback to write the row again, and what it writes has to be where
    -- the cycle actually got to rather than where it was last started from.
    describe("carrying on through a change", function()
        it("keeps its place when the entity changes archetype", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

            -- Two frames in, so starting over and carrying on are different
            -- answers rather than the same one.
            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, animation.frameOf(world, entity))

            -- Nothing to do with playback, and it moves the row.
            world:set(entity, components.Tint(1, 1, 1, 1))
            world:update(STEP)
            assert.equal(2, animation.frameOf(world, entity), "the move is not a rewind")

            drive(world, STEPS_PER_FRAME)
            assert.equal(3, animation.frameOf(world, entity), "and the cycle runs on from there")
        end)

        it("holds a paused entity where it was and resumes there", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, animation.frameOf(world, entity))

            -- Pausing is an archetype move as well, and the world's clock does
            -- not stop for one entity, so where it holds has to be said rather
            -- than assumed.
            world:set(entity, tecs.ecs.builtins.Paused)
            drive(world, 60)
            assert.equal(2, animation.frameOf(world, entity), "held on the frame it was on")

            world:remove(entity, tecs.ecs.builtins.Paused)
            drive(world, STEPS_PER_FRAME)
            assert.equal(3, animation.frameOf(world, entity), "and carries on from it")
        end)

        it("keeps its place when only the speed changes", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, animation.frameOf(world, entity))

            -- Twice as fast from here, which is a rewrite of the row and must
            -- not be a jump: the frame it is on is the frame it stays on.
            world:getMut(entity, Animation).speed = 2.0
            world:update(STEP)
            assert.equal(2, animation.frameOf(world, entity), "the rate changed, not the position")

            -- Three steps to the frame now rather than six.
            drive(world, 3)
            assert.equal(3, animation.frameOf(world, entity))
        end)
    end)

    describe("the dirty gate", function()
        -- Dirty bits clear at the end of world:update, so the answer has to be
        -- read inside the frame that produced it.
        local function probe(world)
            local seen = { sprite = false, animation = false }
            local query = world:query({
                name = "spec.AnimatedProbe",
                include = { Animation, Sprite },
            })
            world:addSystem({
                name = "spec.ReadDirty",
                phase = tecs.ecs.phases.Last,
                run = function()
                    seen.sprite, seen.animation = false, false
                    for archetype in query:iter() do
                        if archetype:isComponentDirty(Sprite) then
                            seen.sprite = true
                        end
                        if archetype:isComponentDirty(Animation) then
                            seen.animation = true
                        end
                    end
                end,
            })
            return seen
        end

        it("leaves the Sprite column clean on a step that changed no frame", function()
            withPlayback(false, function()
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run"))
                local seen = probe(world)

                -- The first step resolves the frame, which is a write.
                world:update(STEP)
                assert.is_true(seen.sprite)
                assert.is_true(seen.animation)

                -- The next five stay on it. Time still moves, so the two
                -- columns have to disagree or the gate is not per component.
                for _ = 1, 4 do
                    world:update(STEP)
                    assert.is_false(seen.sprite)
                    assert.is_true(seen.animation)
                end

                -- Sixth step crosses into the next frame.
                world:update(STEP)
                assert.is_true(seen.sprite)
            end)
        end)

        -- The same property one step further, which is the whole reason the
        -- GPU path exists: a frame changing is not a write at all, so a step
        -- that crosses a frame boundary leaves both columns exactly as clean as
        -- one that stayed put.
        it("writes the Sprite column once and never again on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run"))
                local seen = probe(world)

                -- The first step encodes what is playing, which is a write.
                world:update(STEP)
                assert.is_true(seen.sprite)

                -- Two whole cycles, crossing eight frame boundaries.
                for step = 1, 48 do
                    world:update(STEP)
                    assert.is_false(seen.sprite, "step " .. step)
                    assert.is_false(seen.animation, "step " .. step)
                end
            end)
        end)

        -- Counts what a step asks the sheet for. Shadowing the method on the
        -- instance is what makes the cost observable: the sheet is a table
        -- behind a metatable, so a field written on it wins over the one the
        -- metatable would find.
        local function countLookups(source)
            local counted = { frames = 0 }
            local frameAt = source.frameAt
            source.frameAt = function(self, id, time)
                counted.frames = counted.frames + 1
                return frameAt(self, id, time)
            end
            return counted
        end

        it("looks up no frame for a row whose time stood still", function()
            withPlayback(false, function()
                -- A world of sprites is mostly sprites standing still at any
                -- moment, and a walk over all of them that looks each one up
                -- again makes a scene where a hundredth of them animate cost
                -- what one where all of them do costs.
                local world = animatedWorld()
                local s = stripSheet()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

                -- One step to settle it on a frame, then stop its clock.
                world:update(STEP)
                world:getMut(entity, Animation).playing = false

                local counted = countLookups(s)
                drive(world, 10)

                assert.equal(0, counted.frames, "a paused sprite shows the frame it already has")
            end)
        end)

        it("looks a paused row up until it has a frame at all", function()
            withPlayback(false, function()
                -- Zero is no frame written yet, so a sprite that has never been
                -- resolved has to be, playing or not, or it draws whatever its
                -- Sprite happened to carry.
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(Sprite(3, 0, 0, 1, 1, 6), animation.of(s, "run", { playing = false }))

                local counted = countLookups(s)
                drive(world, 4)

                assert.equal(1, counted.frames, "once to settle it, and never again")
            end)
        end)

        it("looks up no frame for a row held by its speed", function()
            withPlayback(false, function()
                -- A speed of zero holds the frame and leaves `playing` alone,
                -- which is the second way a row stands still. It has to cost
                -- what the first one costs or half a parked crowd is charged
                -- for a scan of the cycle it is not moving through.
                local world = animatedWorld()
                local s = stripSheet()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"))

                world:update(STEP)
                world:getMut(entity, Animation).speed = 0.0

                local counted = countLookups(s)
                drive(world, 10)

                assert.equal(0, counted.frames, "a held sprite shows the frame it already has")
            end)
        end)

        it("looks no frame up at all once playback is on the GPU", function()
            withPlayback(true, function()
                -- The whole cost this removes: a scene of animations asks the
                -- sheet nothing, however many of them are running, because the
                -- frame is worked out where it is drawn.
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run"))

                world:update(STEP)
                local counted = countLookups(s)
                drive(world, 30)

                assert.equal(0, counted.frames, "five frame boundaries and no lookup")
            end)
        end)

        it("leaves both columns clean when nothing is playing", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))
            local seen = probe(world)

            -- One step to resolve the frame, then stop.
            world:update(STEP)
            world:getMut(entity, Animation).playing = false

            world:update(STEP)
            world:update(STEP)
            assert.is_false(seen.sprite)
            assert.is_false(seen.animation)
        end)
    end)

    describe("determinism", function()
        -- Eight frames held for half a step each, so a frame boundary falls in
        -- the middle of a step. That is what makes the leftover of a long
        -- frame visible: at a rate no faster than the step, the leftover is
        -- always less than one frame and the difference hides.
        local function eightFrames()
            return sheet.grid({
                name = uniqueName("eight"),
                imageWidth = 128,
                imageHeight = 16,
                frameWidth = 16,
                frameHeight = 16,
                duration = 1000 / 120,
                tags = { run = { from = 1, to = 8 } },
            })
        end

        -- Asked rather than read out of a column: the two paths keep the answer
        -- in different places and `frameOf` is what both of them answer from.
        -- The region is the frame's, so holding the frame holds the picture.
        local function played(steps, frameLength)
            local world = animatedWorld()
            local s = eightFrames()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))
            for _ = 1, steps do
                world:update(frameLength)
            end
            return {
                frame = animation.frameOf(world, entity),
                time = animation.timeOf(world, entity),
            }
        end

        it("shows the same frame for the same steps however few frames ran", function()
            -- Two steps either way. The long frame carries nine tenths of
            -- a third step that has not run and must not be counted.
            local a = played(2, STEP)
            local b = played(1, STEP * 2.9)

            assert.equal(a.frame, b.frame)
            assert.equal(a.time, b.time)
        end)

        it("ignores the leftover of frames that did not fill a step", function()
            -- Three steps either way, the second world drawing more than
            -- three frames per step and finishing a third of one short.
            local a = played(3, STEP)
            local b = played(10, STEP / 3)

            assert.equal(a.frame, b.frame)
            assert.equal(a.time, b.time)
        end)
    end)

    describe("pivots", function()
        -- Two 16x16 frames whose "feet" slice moves from the bottom middle of
        -- the first to the top quarter of the second, so following the slice
        -- and standing still are two different answers.
        local function walker()
            return sheet
                .build(uniqueName("walker"), 32, 16)
                :frame(0, 0, 16, 16)
                :frame(16, 0, 16, 16)
                :tag("run", 1, 2)
                :sliceKeys("feet", nil, {
                    { frame = 1, x = 4, y = 12, w = 8, h = 4, pivotX = 4, pivotY = 4 },
                    { frame = 2, x = 8, y = 0, w = 8, h = 4, pivotX = 4, pivotY = 0 },
                })
                :finish()
        end

        it("moves a bound pivot with the slice as the frame changes", function()
            withPlayback(false, function()
                local world = animatedWorld()
                local s = walker()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))

                world:update(STEP)
                local p = world:get(entity, Pivot)
                near(p.x, 0.5, "pivot x on frame one")
                near(p.y, 1.0, "pivot y on frame one")

                drive(world, STEPS_PER_FRAME)
                p = world:get(entity, Pivot)
                near(p.x, 0.75, "pivot x on frame two")
                near(p.y, 0.0, "pivot y on frame two")
            end)
        end)

        -- With the frame resolved in the shader the host cannot write the
        -- frame's pivot, because it does not know the frame. What it writes
        -- instead is the middle of where the slice goes and how far either side
        -- of it the slice reaches: the middle is folded into the quad's origin
        -- exactly as a resolved pivot was, the frame table carries each step's
        -- offset from it, and the travel is what the cull bound grows by.
        it("writes the middle of a moving slice and how far it travels", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = walker()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))

                -- The slice sits at 0.5, 1.0 on the first frame and 0.75, 0.0
                -- on the second, so the middle is 0.625, 0.5 and the travel a
                -- half range of 0.125 and 0.5.
                world:update(STEP)
                local p = world:get(entity, Pivot)
                near(p.x, 0.625, "pivot x")
                near(p.y, 0.5, "pivot y")
                near(p.halfX, 0.125, "half the travel across")
                near(p.halfY, 0.5, "half the travel down")

                -- And stays there, because it is the playback's answer rather
                -- than the frame's.
                drive(world, STEPS_PER_FRAME)
                p = world:get(entity, Pivot)
                near(p.x, 0.625, "pivot x a frame later")
                near(p.y, 0.5, "pivot y a frame later")
            end)
        end)

        it("leaves a slice that never moves exactly where it was", function()
            withPlayback(true, function()
                -- One key, which is what `Builder:slice` writes and what an
                -- Aseprite slice that does not move exports. The middle is then
                -- the pivot itself, the travel is nothing, and both the fold
                -- and the cull bound are what they always were.
                local world = animatedWorld()
                local s = sheet
                    .build(uniqueName("still"), 32, 16)
                    :frame(0, 0, 16, 16)
                    :frame(16, 0, 16, 16)
                    :tag("run", 1, 2)
                    :slice("feet", 4, 12, 8, 4, 4, 4)
                    :finish()
                local entity = world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))

                drive(world, 2 * STEPS_PER_FRAME + 1)

                local p = world:get(entity, Pivot)
                near(p.x, 0.5, "pivot x")
                near(p.y, 1.0, "pivot y")
                near(p.halfX, 0.0, "and no travel to cover")
                near(p.halfY, 0.0)
            end)
        end)

        it("leaves a pivot bound to nothing where it was written", function()
            local world = animatedWorld()
            local s = walker()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"), Pivot(0.25, 0.75))

            drive(world, 2 * STEPS_PER_FRAME + 1)

            local p = world:get(entity, Pivot)
            near(p.x, 0.25, "pivot x")
            near(p.y, 0.75, "pivot y")
        end)

        it("leaves a pivot bound to another sheet's slice alone", function()
            local world = animatedWorld()
            local s = walker()
            -- A slice of the same name at a different place, so resolving it
            -- against the sheet being played answers something else and the
            -- two cases are told apart.
            local other = sheet
                .build(uniqueName("other"), 32, 16)
                :frame(0, 0, 16, 16)
                :frame(16, 0, 16, 16)
                :slice("feet", 0, 0, 4, 4, 2, 2)
                :finish()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"), other:pivot("feet"))

            drive(world, STEPS_PER_FRAME + 1)

            local p = world:get(entity, Pivot)
            near(p.x, 0.125, "pivot x")
            near(p.y, 0.125, "pivot y")
        end)

        -- Watches the Pivot column's dirty bit through a world's updates.
        -- Dirty bits clear at the end of world:update, so the answer has to be
        -- read inside the frame that produced it.
        local function pivotProbe(world)
            local seen = { dirty = false }
            local query = world:query({
                name = "spec.PivotProbe",
                include = { Animation, Pivot },
            })
            world:addSystem({
                name = "spec.ReadPivotDirty",
                phase = tecs.ecs.phases.Last,
                run = function()
                    seen.dirty = false
                    for archetype in query:iter() do
                        if archetype:isComponentDirty(Pivot) then
                            seen.dirty = true
                        end
                    end
                end,
            })
            return seen
        end

        it("leaves the Pivot column clean on a step that changed no frame", function()
            withPlayback(false, function()
                local world = animatedWorld()
                local s = walker()
                world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))
                local seen = pivotProbe(world)

                -- The first step resolves the frame, which moves the pivot.
                world:update(STEP)
                assert.is_true(seen.dirty)

                -- Four more stay on it. A frame's hundred milliseconds is six
                -- steps and the sixth lands a hair past the end of it, so that
                -- is the one that crosses.
                for _ = 1, STEPS_PER_FRAME - 2 do
                    world:update(STEP)
                    assert.is_false(seen.dirty, "the frame stood still, so the pivot did")
                end

                world:update(STEP)
                assert.is_true(seen.dirty, "crossing into the next frame moves it again")
            end)
        end)

        it("writes the Pivot column once and never again on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local s = walker()
                world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))
                local seen = pivotProbe(world)

                -- The middle and the travel are the playback's answer, so they
                -- are written when what is playing changes and never when a
                -- frame does.
                world:update(STEP)
                assert.is_true(seen.dirty)

                for step = 1, 4 * STEPS_PER_FRAME do
                    world:update(STEP)
                    assert.is_false(seen.dirty, "step " .. step)
                end
            end)
        end)
    end)

    describe("play", function()
        it("restarts an entity on the tag it is pointed at", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "whole"))

            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, animation.frameOf(world, entity))

            animation.play(world, entity, s, "walk")
            local instance = world:get(entity, Animation)
            assert.equal(0, instance.frame)
            assert.equal(0, instance.time)

            drive(world, 3)
            assert.equal(3, animation.frameOf(world, entity))
        end)

        it("adds an Animation to an entity carrying none", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1))

            animation.play(world, entity, s, "run")
            drive(world, 3)

            assert.equal(1, animation.frameOf(world, entity))
        end)

        -- A frame is a region of an image. Playback that wrote only the region
        -- would leave an entity pointed at a sheet on another image sampling
        -- the old layer with the new rect, which draws part of the wrong
        -- picture rather than nothing at all.
        it("moves the Sprite's image when the sheet does", function()
            withPlayback(false, function()
                local world = animatedWorld()
                local first = stripSheet()
                local second = stripSheet()
                -- What Renderer:sprite hands back for two images that landed on
                -- different layers of the array.
                first:bind(Sprite(4, 0, 0, 1.0, 1.0, 2))
                second:bind(Sprite(9, 0, 0, 1.0, 1.0, 5))

                local entity = world:spawn(first:sprite(1), animation.of(first, "run"))
                drive(world, 3)
                assert.equal(2, world:get(entity, Sprite).slot)

                animation.play(world, entity, second, "run")
                drive(world, 3)

                local sprite = world:get(entity, Sprite)
                assert.equal(5, sprite.slot, "the layer follows the sheet")
                assert.equal(9, sprite.image, "and so does the image it names")
            end)
        end)

        -- The layer is a property of the frame rather than of the entity once
        -- the shader resolves the frame, so it lives in the table beside the
        -- region and the Sprite is left alone. That is what makes rebinding a
        -- sheet to another image cost one table and no instances at all.
        it("moves the layer in the table rather than in the Sprite on the GPU", function()
            withPlayback(true, function()
                local world = animatedWorld()
                local first = stripSheet()
                local second = stripSheet()
                first:bind(Sprite(4, 0, 0, 1.0, 1.0, 2))
                second:bind(Sprite(9, 0, 0, 1.0, 1.0, 5))

                local entity = world:spawn(first:sprite(1), animation.of(first, "run"))
                drive(world, 3)
                assert.equal(
                    frametable.register(first, first:tagId("run")),
                    frametable.playbackOf(world:get(entity, Sprite))
                )

                animation.play(world, entity, second, "run")
                drive(world, 3)

                assert.equal(
                    frametable.register(second, second:tagId("run")),
                    frametable.playbackOf(world:get(entity, Sprite)),
                    "the entity is on the second sheet's playback"
                )
                assert.equal(2, world:get(entity, Sprite).slot, "and its own layer was never touched")
            end)
        end)

        it("moves the image even when the frame index does not change", function()
            withPlayback(false, function()
                -- Both sheets are playing their first frame, so the index the
                -- second one lands on is the one the first one left behind.
                -- Gating the write on the frame alone misses this entirely.
                local world = animatedWorld()
                local first = stripSheet()
                local second = stripSheet()
                first:bind(Sprite(4, 0, 0, 1.0, 1.0, 2))
                second:bind(Sprite(9, 0, 0, 1.0, 1.0, 5))

                local entity = world:spawn(first:sprite(1), animation.of(first, "run", { speed = 0 }))
                drive(world, 3)
                assert.equal(1, world:get(entity, Animation).frame)

                -- Written straight into the component, which is the case
                -- `play` would have papered over by resetting the frame.
                world:getMut(entity, Animation).sheet = second.id
                drive(world, 1)

                local sprite = world:get(entity, Sprite)
                assert.equal(1, world:get(entity, Animation).frame, "the frame index is the one it already had")
                assert.equal(5, sprite.slot, "and the layer moved anyway")
                assert.equal(9, sprite.image)
            end)
        end)

        it("follows a sheet rebound under a sprite that is not playing", function()
            withPlayback(false, function()
                -- The case a walk that skipped every parked row would swallow.
                -- Rebinding is what a reloaded image does, and an entity
                -- standing still through it has to end up pointed at the layer
                -- the image landed on rather than at the one it left.
                local world = animatedWorld()
                local s = stripSheet()
                s:bind(Sprite(4, 0, 0, 1.0, 1.0, 2))

                world:spawn(s:sprite(1), animation.of(s, "run", { playing = false }))
                local entity = world:spawn(s:sprite(1), animation.of(s, "run", { playing = false }))
                drive(world, 3)
                assert.equal(2, world:get(entity, Sprite).slot)

                s:bind(Sprite(9, 0, 0, 1.0, 1.0, 5))
                drive(world, 1)

                local sprite = world:get(entity, Sprite)
                assert.equal(5, sprite.slot, "the layer moved without the clock moving")
                assert.equal(9, sprite.image)
            end)
        end)

        it("re-encodes a sheet written straight into the component on the GPU", function()
            withPlayback(true, function()
                -- The same case from the other side: the sheet moved and the
                -- frame index did not, and what has to follow is which playback
                -- the entity is on rather than a region it carries.
                local world = animatedWorld()
                local first = stripSheet()
                local second = stripSheet()
                first:bind(Sprite(4, 0, 0, 1.0, 1.0, 2))
                second:bind(Sprite(9, 0, 0, 1.0, 1.0, 5))

                local entity = world:spawn(first:sprite(1), animation.of(first, "run", { speed = 0 }))
                drive(world, 3)

                world:getMut(entity, Animation).sheet = second.id
                drive(world, 1)

                assert.equal(1, animation.frameOf(world, entity), "the frame index is the one it already had")
                assert.equal(
                    frametable.register(second, second:tagId("run")),
                    frametable.playbackOf(world:get(entity, Sprite)),
                    "and the playback moved anyway"
                )
            end)
        end)

        it("leaves the Sprite's image alone for an unbound sheet", function()
            -- A sheet that names no image has no layer to write, so playback
            -- writes the region and leaves whatever the Sprite carried.
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(Sprite(3, 0, 0, 1, 1, 6), animation.of(s, "run"))

            drive(world, 3)
            local sprite = world:get(entity, Sprite)
            assert.equal(6, sprite.slot)
            assert.equal(3, sprite.image)
        end)
    end)

    describe("restart", function()
        -- A one-shot parks at the end of its cycle and stops. Setting it
        -- playing again from there used to leave the time at the end, so it
        -- parked and completed again on that step, and on every step after it.
        it("plays a finished one-shot again instead of completing forever", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

            local completions = 0
            world:observe(0, animation.Completed, function()
                completions = completions + 1
            end)

            drive(world, 27)
            assert.equal(1, completions)
            assert.is_false(world:get(entity, Animation).playing)

            world:getMut(entity, Animation).playing = true
            drive(world, 3)
            assert.equal(1, animation.frameOf(world, entity), "asking for it again starts it again")
            assert.equal(1, completions, "and does not complete on the way")

            -- Through the whole cycle once more: one more completion, not
            -- one per step.
            drive(world, 24)
            assert.equal(2, completions)
            drive(world, 60)
            assert.equal(2, completions)
        end)

        it("rewinds an entity without changing what it plays", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

            drive(world, 3 + STEPS_PER_FRAME * 2)
            assert.equal(3, animation.frameOf(world, entity))

            assert.is_true(animation.restart(world, entity))
            local instance = world:get(entity, Animation)
            assert.equal(0, instance.frame)
            assert.equal(0, instance.time)
            assert.is_true(instance.playing)
            assert.equal(s.id, instance.sheet, "the sheet is left alone")
            assert.equal(s:tagId("run"), instance.tag)
            assert.is_false(instance.loop)

            drive(world, 3)
            assert.equal(1, animation.frameOf(world, entity))
        end)

        it("restarts a one-shot that has already finished", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }), AnimationEvents())

            drive(world, 27)
            assert.is_false(world:get(entity, Animation).playing)

            animation.restart(world, entity)
            drive(world, 3)
            assert.equal(1, animation.frameOf(world, entity))
            assert.is_true(world:get(entity, Animation).playing)
        end)

        it("answers false for an entity carrying no Animation", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1))
            assert.is_false(animation.restart(world, entity))
        end)
    end)

    describe("a saved animated sprite", function()
        it("carries the whole image rather than this run's playback", function()
            -- The four UV lanes hold a playback while an animation resolves on
            -- the GPU: an index into this run's frame table and a count of
            -- this world's fixed steps. A file holding those would land on
            -- whatever the next run numbered the same.
            local world = animatedWorld()
            local live = sheet
                .build(uniqueName("savedplayback"), 64, 32)
                :frame(0, 0, 32, 32)
                :frame(32, 0, 32, 32)
                :tag("all", 1, 2)
                :finish()
            local entity = world:spawn(live:sprite(1), animation.of(live, "all"))
            drive(world, 3)

            local sprite = world:get(entity, Sprite)
            assert.is_true(sprite.u0 < 0.0, "the lanes really do hold a playback")

            local saved = world:saveSnapshot({ format = "table" }).snapshot

            -- Restored and read before a step re-encodes it, which is the only
            -- moment the file's own value is what the component holds.
            local fresh = animatedWorld()
            fresh:loadSnapshot(saved)
            local restored = nil
            local query = fresh:query({ include = { Sprite } })
            for archetype, length in query:iter() do
                local column = archetype:get(Sprite)
                for row = 1, length do
                    restored = column[row]
                end
            end

            assert.is_not_nil(restored, "the sprite came back")
            assert.is_true(restored.u0 >= 0.0, "and not carrying a playback this run never handed out")
            assert.are.equal(1.0, restored.u1)
        end)
    end)
end)
