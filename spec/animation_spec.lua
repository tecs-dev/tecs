-- Sprite sheets and the playback that reads them.
--
-- Two properties are worth more than the rest here. Playback advances in the
-- fixed phases, so the same sequence of steps has to produce the same frame
-- however many frames were drawn between them. And a sprite whose frame did
-- not change this step must leave its column clean, because the renderer skips
-- archetypes on exactly that bit.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local sheet = require("tecs.gfx.sheet")
local animation = require("tecs.gfx.animation")

local Sprite = components.Sprite
local Animation = animation.Animation
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
    local world = tecs.newWorld()
    world:addPlugin(animation.plugin)
    return world
end

local function drive(world, steps)
    for _ = 1, steps do
        world:update(STEP)
    end
end

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
            assert.equal(1, world:get(entity, Animation).frame)

            -- Six steps in is past the first frame's hundred milliseconds and
            -- nowhere near the end of the second's five hundred.
            drive(world, 6)
            assert.equal(2, world:get(entity, Animation).frame)
            drive(world, 20)
            assert.equal(2, world:get(entity, Animation).frame, "the held frame is still up half a second in")
            drive(world, 8)
            assert.equal(1, world:get(entity, Animation).frame, "and the cycle wraps once it is spent")
        end)

        it("scales the whole cycle by an entity's speed", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { speed = 2 }))

            -- Twice as fast is three steps to the frame rather than six.
            drive(world, 2)
            assert.equal(1, world:get(entity, Animation).frame)
            drive(world, 2)
            assert.equal(2, world:get(entity, Animation).frame)
            drive(world, 3)
            assert.equal(3, world:get(entity, Animation).frame)
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
                seen[#seen + 1] = world:get(entity, Animation).frame
            end
            return seen, s
        end

        -- Sampled in the middle of each frame rather than at its edges, so a
        -- rounding difference at a boundary cannot decide the answer.
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
            local seen, s = walked("pingpong", 30)
            near(s:cycle(s:tagId("go")), 0.4, "the cycle skips both ends")
            assert.are.same({ 1, 2, 3, 2, 1, 2 }, atFrames(seen, 3, 9, 15, 21, 27, 30))
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
            local world = tecs.newWorld()
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
            local world = tecs.newWorld()
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
            assert.equal(2, world:get(entity, Animation).frame)
            drive(world, 14)
            assert.equal(2, world:get(entity, Animation).frame, "the three hundred millisecond frame is still up")
            drive(world, 3)
            assert.equal(3, world:get(entity, Animation).frame)
            drive(world, 4)
            assert.equal(2, world:get(entity, Animation).frame, "and the cycle wrapped once both were spent")
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
                local frame = expected[index]
                assert.equal(frame, world:get(entity, Animation).frame)

                local u0, v0, u1, v1 = s:uv(frame)
                local sprite = world:get(entity, Sprite)
                near(sprite.u0, u0, "u0 of frame " .. frame)
                near(sprite.v0, v0, "v0 of frame " .. frame)
                near(sprite.u1, u1, "u1 of frame " .. frame)
                near(sprite.v1, v1, "v1 of frame " .. frame)
            end
        end)

        it("plays only the frames the tag names", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "walk"))

            drive(world, 3)
            assert.equal(3, world:get(entity, Animation).frame)

            drive(world, STEPS_PER_FRAME)
            assert.equal(4, world:get(entity, Animation).frame)

            -- Two frames at ten a second is a fifth of a second, so the next
            -- step past it is back at the tag's first frame and not the
            -- sheet's.
            drive(world, STEPS_PER_FRAME)
            assert.equal(3, world:get(entity, Animation).frame)
        end)

        it("plays the whole sheet when no tag is named", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, nil))

            drive(world, 3 + STEPS_PER_FRAME * 2)
            assert.equal(3, world:get(entity, Animation).frame)
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
            local instance = world:get(entity, Animation)
            assert.equal(1, instance.frame)
            assert.is_true(instance.playing)
        end)

        it("parks a one-shot on its last frame and stops", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

            drive(world, 27)
            local instance = world:get(entity, Animation)
            assert.equal(4, instance.frame)
            assert.is_false(instance.playing)

            -- And stays there however long the world keeps running.
            drive(world, 120)
            instance = world:get(entity, Animation)
            assert.equal(4, instance.frame)
            assert.is_false(instance.playing)
        end)

        it("holds the first frame when the rate is zero", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { speed = 0 }))

            drive(world, 60)
            assert.equal(1, world:get(entity, Animation).frame)
        end)
    end)

    describe("events", function()
        it("reports a one-shot completing once", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

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
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = true }))

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
            world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

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
                phase = tecs.phases.Last,
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

        -- Copied out rather than handed back: what `get` returns for an FFI
        -- component points into the archetype's column, and the world holding
        -- it goes out of scope when this returns.
        local function played(steps, frameLength)
            local world = animatedWorld()
            local s = eightFrames()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run"))
            for _ = 1, steps do
                world:update(frameLength)
            end
            local instance = world:get(entity, Animation)
            local sprite = world:get(entity, Sprite)
            return {
                frame = instance.frame,
                time = instance.time,
                u0 = sprite.u0,
                u1 = sprite.u1,
            }
        end

        it("shows the same frame for the same steps however few frames ran", function()
            -- Two steps either way. The long frame carries nine tenths of
            -- a third step that has not run and must not be counted.
            local a = played(2, STEP)
            local b = played(1, STEP * 2.9)

            assert.equal(a.frame, b.frame)
            assert.equal(a.time, b.time)
            assert.equal(a.u0, b.u0)
            assert.equal(a.u1, b.u1)
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

        it("leaves the Pivot column clean on a step that changed no frame", function()
            local world = animatedWorld()
            local s = walker()
            world:spawn(s:sprite(1), animation.of(s, "run"), s:pivot("feet"))

            local seen = false
            local query = world:query({
                name = "spec.PivotProbe",
                include = { Animation, Pivot },
            })
            world:addSystem({
                name = "spec.ReadPivotDirty",
                phase = tecs.phases.Last,
                run = function()
                    seen = false
                    for archetype in query:iter() do
                        if archetype:isComponentDirty(Pivot) then
                            seen = true
                        end
                    end
                end,
            })

            -- The first step resolves the frame, which moves the pivot.
            world:update(STEP)
            assert.is_true(seen)

            -- Four more stay on it. A frame's hundred milliseconds is six
            -- steps and the sixth lands a hair past the end of it, so that is
            -- the one that crosses.
            for _ = 1, STEPS_PER_FRAME - 2 do
                world:update(STEP)
                assert.is_false(seen, "the frame stood still, so the pivot did")
            end

            world:update(STEP)
            assert.is_true(seen, "crossing into the next frame moves it again")
        end)
    end)

    describe("play", function()
        it("restarts an entity on the tag it is pointed at", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "whole"))

            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, world:get(entity, Animation).frame)

            animation.play(world, entity, s, "walk")
            local instance = world:get(entity, Animation)
            assert.equal(0, instance.frame)
            assert.equal(0, instance.time)

            drive(world, 3)
            assert.equal(3, world:get(entity, Animation).frame)
        end)

        it("adds an Animation to an entity carrying none", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1))

            animation.play(world, entity, s, "run")
            drive(world, 3)

            assert.equal(1, world:get(entity, Animation).frame)
        end)

        -- A frame is a region of an image. Playback that wrote only the region
        -- would leave an entity pointed at a sheet on another image sampling
        -- the old layer with the new rect, which draws part of the wrong
        -- picture rather than nothing at all.
        it("moves the Sprite's image when the sheet does", function()
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

        it("moves the image even when the frame index does not change", function()
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
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

            local completions = 0
            world:observe(0, animation.Completed, function()
                completions = completions + 1
            end)

            drive(world, 27)
            assert.equal(1, completions)
            assert.is_false(world:get(entity, Animation).playing)

            world:getMut(entity, Animation).playing = true
            drive(world, 3)
            assert.equal(1, world:get(entity, Animation).frame, "asking for it again starts it again")
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
            assert.equal(3, world:get(entity, Animation).frame)

            assert.is_true(animation.restart(world, entity))
            local instance = world:get(entity, Animation)
            assert.equal(0, instance.frame)
            assert.equal(0, instance.time)
            assert.is_true(instance.playing)
            assert.equal(s.id, instance.sheet, "the sheet is left alone")
            assert.equal(s:tagId("run"), instance.tag)
            assert.is_false(instance.loop)

            drive(world, 3)
            assert.equal(1, world:get(entity, Animation).frame)
        end)

        it("restarts a one-shot that has already finished", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1), animation.of(s, "run", { loop = false }))

            drive(world, 27)
            assert.is_false(world:get(entity, Animation).playing)

            animation.restart(world, entity)
            drive(world, 3)
            local instance = world:get(entity, Animation)
            assert.equal(1, instance.frame)
            assert.is_true(instance.playing)
        end)

        it("answers false for an entity carrying no Animation", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1))
            assert.is_false(animation.restart(world, entity))
        end)
    end)
end)
