require("busted")

-- Set up Love2D mock before requiring anything else
local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local luassert <const> = require("luassert")

describe("tecs2d.render.sprite.sheet", function()
    describe("fromImage with Aseprite JSON array format", function()
        it("should parse basic frames from JSON", function()
            local jsonData = [[{
                "frames": [
                    {
                        "filename": "sprite 0.ase",
                        "frame": { "x": 0, "y": 0, "w": 32, "h": 32 },
                        "rotated": false,
                        "trimmed": false,
                        "spriteSourceSize": { "x": 0, "y": 0, "w": 32, "h": 32 },
                        "sourceSize": { "w": 32, "h": 32 },
                        "duration": 100
                    },
                    {
                        "filename": "sprite 1.ase",
                        "frame": { "x": 32, "y": 0, "w": 32, "h": 32 },
                        "rotated": false,
                        "trimmed": false,
                        "spriteSourceSize": { "x": 0, "y": 0, "w": 32, "h": 32 },
                        "sourceSize": { "w": 32, "h": 32 },
                        "duration": 150
                    }
                ],
                "meta": {
                    "app": "http://www.aseprite.org/",
                    "version": "1.3.2",
                    "image": "sprite.png",
                    "format": "RGBA8888",
                    "size": { "w": 32, "h": 32 },
                    "scale": "1"
                }
            }]]

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            local result = sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")

            local w, h = result:getSpriteSize()
            luassert.equals(32, w)
            luassert.equals(32, h)
            local frame2 = result:getFrame(2)
            luassert.is_not_nil(frame2)  -- Verify we have 2 frames

            local frame1 = result:getFrame(1)
            luassert.equals(0, frame1.x)
            luassert.equals(0, frame1.y)
            luassert.equals(32, frame1.w)
            luassert.equals(32, frame1.h)
            luassert.equals(0.1, frame1.duration)  -- 100ms -> 0.1s

            local frame2 = result:getFrame(2)
            luassert.equals(32, frame2.x)
            luassert.equals(0.15, frame2.duration)  -- 150ms -> 0.15s
        end)

        it("should parse frameTags with direction conversion", function()
            local jsonData = [[{
                "frames": [
                    { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 }, "duration": 100 },
                    { "frame": { "x": 16, "y": 0, "w": 16, "h": 16 }, "duration": 100 },
                    { "frame": { "x": 32, "y": 0, "w": 16, "h": 16 }, "duration": 100 }
                ],
                "meta": {
                    "size": { "w": 16, "h": 16 },
                    "frameTags": [
                        { "name": "idle", "from": 0, "to": 1, "direction": "forward" },
                        { "name": "walk", "from": 1, "to": 2, "direction": "reverse" }
                    ]
                }
            }]]

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            local result = sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")

            luassert.is_true(result:hasFrameTag("idle"))
            luassert.is_true(result:hasFrameTag("walk"))

            local idleTag = result:getFrameTag("idle")
            luassert.equals(1, idleTag.from)  -- 0-based -> 1-based
            luassert.equals(2, idleTag.to)
            luassert.equals(sheet.Direction.FORWARD, idleTag.direction)

            local walkTag = result:getFrameTag("walk")
            luassert.equals(2, walkTag.from)
            luassert.equals(3, walkTag.to)
            luassert.equals(sheet.Direction.REVERSE, walkTag.direction)
        end)

        it("should parse slices with pivot and center", function()
            local jsonData = [[{
                "frames": [
                    { "frame": { "x": 0, "y": 0, "w": 32, "h": 32 }, "duration": 100 }
                ],
                "meta": {
                    "size": { "w": 32, "h": 32 },
                    "slices": [
                        {
                            "name": "hitbox",
                            "color": "#0000ffff",
                            "keys": [
                                {
                                    "frame": 0,
                                    "bounds": { "x": 8, "y": 8, "w": 16, "h": 16 },
                                    "center": { "x": 4, "y": 4, "w": 8, "h": 8 },
                                    "pivot": { "x": 16, "y": 16 }
                                }
                            ]
                        }
                    ]
                }
            }]]

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            local result = sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")

            local slice = result:getSlice("hitbox")
            luassert.is_not_nil(slice)
            luassert.equals(1, #slice.keys)

            local key = slice.keys[1]
            luassert.equals(1, key.frame)  -- 0-based -> 1-based
            luassert.equals(8, key.x)
            luassert.equals(8, key.y)
            luassert.equals(16, key.w)
            luassert.equals(16, key.h)
            luassert.is_true(key.hasCenter)
            luassert.equals(4, key.centerX)
            luassert.equals(4, key.centerY)
            luassert.is_true(key.hasPivot)
            luassert.equals(16, key.pivotX)
            luassert.equals(16, key.pivotY)
        end)

        it("should handle empty frameTags and slices", function()
            local jsonData = [[{
                "frames": [
                    { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 }, "duration": 100 }
                ],
                "meta": {
                    "size": { "w": 16, "h": 16 }
                }
            }]]

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            local result = sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")

            local frame1 = result:getFrame(1)
            luassert.is_not_nil(frame1)  -- Verify we have 1 frame
        end)
    end)

    describe("fromImage with Aseprite JSON hash format", function()
        it("should parse hash format frames sorted alphabetically", function()
            local jsonData = [[{
                "frames": {
                    "sprite 1.ase": {
                        "frame": { "x": 32, "y": 0, "w": 32, "h": 32 },
                        "duration": 150
                    },
                    "sprite 0.ase": {
                        "frame": { "x": 0, "y": 0, "w": 32, "h": 32 },
                        "duration": 100
                    }
                },
                "meta": {
                    "size": { "w": 32, "h": 32 }
                }
            }]]

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            local result = sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")

            -- Frames should be sorted: "sprite 0.ase" comes before "sprite 1.ase"
            local frame1 = result:getFrame(1)
            luassert.equals(0, frame1.x)  -- sprite 0 at x=0
            luassert.equals(0.1, frame1.duration)  -- 100ms

            local frame2 = result:getFrame(2)
            luassert.equals(32, frame2.x)  -- sprite 1 at x=32
            luassert.equals(0.15, frame2.duration)  -- 150ms
        end)
    end)

    describe("getAnimationFrame", function()
        local function createSheet(direction: string): sheet.SpriteSheet
            local jsonData = string.format([[{
                "frames": [
                    { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 }, "duration": 100 },
                    { "frame": { "x": 16, "y": 0, "w": 16, "h": 16 }, "duration": 100 },
                    { "frame": { "x": 32, "y": 0, "w": 16, "h": 16 }, "duration": 100 }
                ],
                "meta": {
                    "size": { "w": 16, "h": 16 },
                    "frameTags": [
                        { "name": "anim", "from": 0, "to": 2, "direction": "%s" }
                    ]
                }
            }]], direction)

            local mockImage = {
                getDimensions = function(): number, number return 256, 256 end
            } as love.graphics.Image
            local mockData = {
                getString = function(): string
                    return jsonData
                end
            } as love.filesystem.FileData

            return sheet.SpriteSheet.fromImage(mockImage, mockData, "test.json")
        end

        it("should play forward direction correctly", function()
            local s = createSheet("forward")

            local frame: integer = s:getAnimationFrame("anim", 0.0)
            luassert.equals(1, frame)  -- First frame at t=0

            frame = s:getAnimationFrame("anim", 0.05)
            luassert.equals(1, frame)  -- Still first frame

            frame = s:getAnimationFrame("anim", 0.11)
            luassert.equals(2, frame)  -- Second frame after 0.1s

            frame = s:getAnimationFrame("anim", 0.21)
            luassert.equals(3, frame)  -- Third frame after 0.2s
        end)

        it("should play reverse direction correctly", function()
            local s = createSheet("reverse")

            local frame: integer = s:getAnimationFrame("anim", 0.0)
            luassert.equals(3, frame)  -- Last frame first in reverse

            frame = s:getAnimationFrame("anim", 0.11)
            luassert.equals(2, frame)  -- Second to last

            frame = s:getAnimationFrame("anim", 0.21)
            luassert.equals(1, frame)  -- First frame last
        end)

        it("should play pingpong direction correctly", function()
            local s = createSheet("pingpong")

            -- Forward phase: 1, 2, 3
            local frame: integer = s:getAnimationFrame("anim", 0.0)
            luassert.equals(1, frame)

            frame = s:getAnimationFrame("anim", 0.11)
            luassert.equals(2, frame)

            frame = s:getAnimationFrame("anim", 0.21)
            luassert.equals(3, frame)

            -- Reverse phase: 2 (skips 3 and 1 to avoid doubling)
            frame = s:getAnimationFrame("anim", 0.31)
            luassert.equals(2, frame)

            -- Total duration should be 4 frames * 100ms = 0.4s, then loops
            local tag = s:getFrameTag("anim")
            luassert.equals(0.4, tag.duration)
        end)

        it("should loop correctly", function()
            local s = createSheet("forward")

            -- Total duration is 0.3s (3 frames * 100ms)
            local frame: integer = s:getAnimationFrame("anim", 0.35)
            -- Should loop: 0.35 % 0.3 = 0.05, which is still frame 1
            luassert.equals(1, frame)
        end)
    end)
end)
