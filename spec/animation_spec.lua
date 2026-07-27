-- Sprite sheets and the playback that reads them.
--
-- Two properties are worth more than the rest here. Playback advances in the
-- fixed phases, so the same sequence of steps has to produce the same frame
-- however many frames were drawn between them. And a sprite whose frame did
-- not change this step must leave its column clean, because the renderer skips
-- archetypes on exactly that bit.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local sheet = require("tecs.gfx.sheet")
local animation = require("tecs.gfx.animation")

local Sprite = components.Sprite
local Animation = animation.Animation

local STEP = 1 / 60
local EPSILON = 1e-6

local function near(actual, expected, what)
    assert.is_true(math.abs(actual - expected) < EPSILON,
        ("%s: expected %.6f, got %.6f")
            :format(what or "value", expected, actual))
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
        ranges = { walk = { from = 3, to = 4 }, whole = { from = 1, to = 4 } },
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
        ranges = { run = { from = 1, to = 4 } },
    })
end

local function animatedWorld()
    local world = tecs.newWorld()
    world:addPlugin(animation.plugin)
    return world
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
                ranges = { blink = { from = 2, to = 3 } },
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

            local from, to = s:range("blink")
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

    describe("named ranges", function()
        it("spans frames inclusively at both ends", function()
            local s = walkSheet()

            assert.is_true(s:hasRange("walk"))
            assert.is_false(s:hasRange("crawl"))

            local from, to = s:range("walk")
            assert.equal(3, from)
            assert.equal(4, to)

            -- Ids follow the names in sorted order, so "walk" comes after
            -- "whole" and the pair round trips.
            assert.equal("walk", s:rangeName(s:rangeId("walk")))
            assert.equal("whole", s:rangeName(s:rangeId("whole")))
            assert.equal(0, s:rangeId("crawl"))
            assert.equal("", s:rangeName(0))
        end)

        it("rejects a span outside the sheet", function()
            assert.has_error(function()
                sheet.grid({
                    name = uniqueName("overrun"),
                    imageWidth = 32,
                    imageHeight = 16,
                    frameWidth = 16,
                    frameHeight = 16,
                    ranges = { walk = { from = 1, to = 9 } },
                })
            end)
        end)
    end)
end)

describe("tecs.gfx.animation", function()
    -- Ten frames a second against a sixtieth of a second step is six steps to
    -- the frame, so every assertion below lands in the middle of one rather
    -- than on a boundary where a rounding difference would decide it.
    local FPS = 10
    local STEPS_PER_FRAME = 6

    local function drive(world, steps)
        for _ = 1, steps do world:update(STEP) end
    end

    describe("playing a named range", function()
        it("walks the range in order", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS }))

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

        it("plays only the frames the range names", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "walk", { fps = FPS }))

            drive(world, 3)
            assert.equal(3, world:get(entity, Animation).frame)

            drive(world, STEPS_PER_FRAME)
            assert.equal(4, world:get(entity, Animation).frame)

            -- Two frames at ten a second is a fifth of a second, so the next
            -- step past it is back at the range's first frame and not the
            -- sheet's.
            drive(world, STEPS_PER_FRAME)
            assert.equal(3, world:get(entity, Animation).frame)
        end)

        it("plays the whole sheet when no range is named", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, nil, { fps = FPS }))

            drive(world, 3 + STEPS_PER_FRAME * 2)
            assert.equal(3, world:get(entity, Animation).frame)
        end)

        it("refuses a range the sheet does not carry", function()
            local s = stripSheet()
            assert.has_error(function() animation.of(s, "crawl") end)
        end)
    end)

    describe("ending", function()
        it("wraps a looping range back to its first frame", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS, loop = true }))

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
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS, loop = false }))

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
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = 0 }))

            drive(world, 60)
            assert.equal(1, world:get(entity, Animation).frame)
        end)
    end)

    describe("events", function()
        it("reports a one-shot completing once", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS, loop = false }))

            local seen = {}
            world:observe(0, animation.Completed, function(event)
                seen[#seen + 1] = {
                    entity = event.entity,
                    range = event.range,
                    sheet = event.sheet,
                }
            end)

            drive(world, 120)

            assert.equal(1, #seen)
            assert.equal(entity, seen[1].entity)
            assert.equal("run", seen[1].range)
            assert.equal(s, seen[1].sheet)
        end)

        it("reports a looping range wrapping once per cycle", function()
            local world = animatedWorld()
            local s = stripSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS, loop = true }))

            local seen = {}
            world:observe(0, animation.Looped, function(event)
                seen[#seen + 1] = { entity = event.entity, range = event.range }
            end)

            -- One cycle is 24 steps, so 27 has passed the first wrap and is
            -- nowhere near the second.
            drive(world, 27)
            assert.equal(1, #seen)
            assert.equal(entity, seen[1].entity)
            assert.equal("run", seen[1].range)

            drive(world, 24)
            assert.equal(2, #seen)
        end)

        it("does not report a loop for a one-shot, or the reverse", function()
            local world = animatedWorld()
            local s = stripSheet()
            world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS, loop = false }))

            local loops, completions = 0, 0
            world:observe(0, animation.Looped, function() loops = loops + 1 end)
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

        it("leaves the Sprite column clean on a step that changed no frame",
            function()
                local world = animatedWorld()
                local s = stripSheet()
                world:spawn(s:sprite(1), animation.of(s, "run", { fps = FPS }))
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
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FPS }))
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
        -- Eight frames at twice the step rate, so a frame boundary falls in
        -- the middle of a step. That is what makes the leftover of a long
        -- frame visible: at a rate no faster than the step, the leftover is
        -- always less than one frame and the difference hides.
        local FAST = 120

        local function eightFrames()
            return sheet.grid({
                name = uniqueName("eight"),
                imageWidth = 128,
                imageHeight = 16,
                frameWidth = 16,
                frameHeight = 16,
                ranges = { run = { from = 1, to = 8 } },
            })
        end

        -- Copied out rather than handed back: what `get` returns for an FFI
        -- component points into the archetype's column, and the world holding
        -- it goes out of scope when this returns.
        local function played(steps, frameLength)
            local world = animatedWorld()
            local s = eightFrames()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "run", { fps = FAST }))
            for _ = 1, steps do world:update(frameLength) end
            local instance = world:get(entity, Animation)
            local sprite = world:get(entity, Sprite)
            return {
                frame = instance.frame,
                time = instance.time,
                u0 = sprite.u0,
                u1 = sprite.u1,
            }
        end

        it("shows the same frame for the same steps however few frames ran",
            function()
                -- Two steps either way. The long frame carries nine tenths of
                -- a third step that has not run and must not be counted.
                local a = played(2, STEP)
                local b = played(1, STEP * 2.9)

                assert.equal(a.frame, b.frame)
                assert.equal(a.time, b.time)
                assert.equal(a.u0, b.u0)
                assert.equal(a.u1, b.u1)
            end)

        it("ignores the leftover of frames that did not fill a step",
            function()
                -- Three steps either way, the second world drawing more than
                -- three frames per step and finishing a third of one short.
                local a = played(3, STEP)
                local b = played(10, STEP / 3)

                assert.equal(a.frame, b.frame)
                assert.equal(a.time, b.time)
            end)
    end)

    describe("play", function()
        it("restarts an entity on the range it is pointed at", function()
            local world = animatedWorld()
            local s = walkSheet()
            local entity = world:spawn(s:sprite(1),
                animation.of(s, "whole", { fps = FPS }))

            drive(world, 3 + STEPS_PER_FRAME)
            assert.equal(2, world:get(entity, Animation).frame)

            animation.play(world, entity, s, "walk", { fps = FPS })
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

            animation.play(world, entity, s, "run", { fps = FPS })
            drive(world, 3)

            assert.equal(1, world:get(entity, Animation).frame)
        end)
    end)
end)
