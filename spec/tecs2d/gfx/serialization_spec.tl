require("busted")

-- Set up love mock before requiring tecs2d.gfx modules
rawset(_G, "love", require("spec.love2d.love2d_mock"))

-- Skip if Love2D 12 GPU features aren't available (mock doesn't support full GPU)
if not love.graphics.newComputeShader then
    pending("Serialization tests require Love2D 12 GPU features")
    return
end

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")

local Sprite <const> = gfx.Sprite
local Text <const> = gfx.Text

-- Create a mock world for deserialize tests
local function createMockWorld(): tecs.World
    return tecs.newWorld()
end

describe("tecs2d.gfx serialization", function()
    describe("Sprite", function()
        describe("serialize", function()
            it("returns nil when texturePath is not set", function()
                local texture = love.graphics.newImage() as love.graphics.Texture
                local sprite = Sprite(texture)

                local serialized = Sprite.serialize(sprite)

                luassert.is_nil(serialized, "serialize should return nil without texturePath")
            end)

            it("serializes sprite with texturePath", function()
                local texture = love.graphics.newImage() as love.graphics.Texture
                local quad = love.graphics.newQuad(10, 20, 32, 64, 256, 256)
                local sprite = Sprite(texture, quad, 16, 32, "assets/player.png")

                local serialized = Sprite.serialize(sprite)

                luassert.is_not_nil(serialized, "serialize should return data")
                luassert.is_equal("assets/player.png", serialized.texturePath)
                luassert.is_equal(10, serialized.quadX)
                luassert.is_equal(20, serialized.quadY)
                luassert.is_equal(32, serialized.quadW)
                luassert.is_equal(64, serialized.quadH)
                luassert.is_equal(16, serialized.originX)
                luassert.is_equal(32, serialized.originY)
            end)

            it("gets quad viewport from quad object", function()
                local texture = love.graphics.newImage() as love.graphics.Texture
                -- Mock quad returns stored values via getViewport
                local quad = love.graphics.newQuad(5, 10, 48, 96, 256, 256)
                local sprite = Sprite(texture, quad, 24, 48, "spritesheet.png")

                local serialized = Sprite.serialize(sprite)

                -- Should get viewport from quad, not store duplicates
                luassert.is_equal(5, serialized.quadX)
                luassert.is_equal(10, serialized.quadY)
                luassert.is_equal(48, serialized.quadW)
                luassert.is_equal(96, serialized.quadH)
            end)
        end)

        describe("deserialize", function()
            it("deserializes sprite from data", function()
                local world = createMockWorld()
                local data = {
                    texturePath = "assets/enemy.png",
                    quadX = 0,
                    quadY = 0,
                    quadW = 32,
                    quadH = 32,
                    originX = 16,
                    originY = 16
                }

                local sprite = Sprite.deserialize(world, data)

                luassert.is_not_nil(sprite, "deserialize should return sprite")
                luassert.is_not_nil(sprite.texture, "sprite should have texture")
                luassert.is_not_nil(sprite.quad, "sprite should have quad")
                luassert.is_equal(16, sprite.originX)
                luassert.is_equal(16, sprite.originY)
                luassert.is_equal("assets/enemy.png", sprite.texturePath)
            end)

            it("uses full texture dimensions when quad size not provided", function()
                local world = createMockWorld()
                local data = {
                    texturePath = "assets/full.png"
                    -- No quad dimensions
                }

                local sprite = Sprite.deserialize(world, data)

                luassert.is_not_nil(sprite, "deserialize should return sprite")
                -- Mock image returns 256x256, so quad should be full texture
                local qx, qy, qw, qh = sprite.quad:getViewport()
                luassert.is_equal(0, qx)
                luassert.is_equal(0, qy)
                -- Mock returns 256x256 for texture dimensions
                luassert.is_equal(256, qw)
                luassert.is_equal(256, qh)
            end)

            it("defaults quad position to 0,0", function()
                local world = createMockWorld()
                local data = {
                    texturePath = "assets/tile.png",
                    quadW = 16,
                    quadH = 16
                    -- No quadX, quadY
                }

                local sprite = Sprite.deserialize(world, data)

                local qx, qy, _, _ = sprite.quad:getViewport()
                luassert.is_equal(0, qx)
                luassert.is_equal(0, qy)
            end)
        end)

        describe("fromPath", function()
            it("creates sprite from path with default quad", function()
                local world = createMockWorld()
                local sprite = Sprite.fromPath(world, "assets/icon.png")

                luassert.is_not_nil(sprite, "fromPath should return sprite")
                luassert.is_not_nil(sprite.texture, "sprite should have texture")
                luassert.is_not_nil(sprite.quad, "sprite should have quad")
                luassert.is_equal("assets/icon.png", sprite.texturePath)

                -- Default quad should be full texture (256x256 from mock)
                local qx, qy, qw, qh = sprite.quad:getViewport()
                luassert.is_equal(0, qx)
                luassert.is_equal(0, qy)
                luassert.is_equal(256, qw)
                luassert.is_equal(256, qh)
            end)

            it("creates sprite from path with custom quad", function()
                local world = createMockWorld()
                local sprite = Sprite.fromPath(world, "assets/sheet.png", 32, 64, 16, 16)

                local qx, qy, qw, qh = sprite.quad:getViewport()
                luassert.is_equal(32, qx)
                luassert.is_equal(64, qy)
                luassert.is_equal(16, qw)
                luassert.is_equal(16, qh)
            end)

            it("creates sprite from path with custom origin", function()
                local world = createMockWorld()
                local sprite = Sprite.fromPath(world, "assets/centered.png", 0, 0, 32, 32, 16, 16)

                luassert.is_equal(16, sprite.originX)
                luassert.is_equal(16, sprite.originY)
            end)

            it("stores texturePath for serialization", function()
                local world = createMockWorld()
                local sprite = Sprite.fromPath(world, "assets/serializable.png")

                luassert.is_equal("assets/serializable.png", sprite.texturePath)

                -- Should be serializable
                local serialized = Sprite.serialize(sprite)
                luassert.is_not_nil(serialized)
                luassert.is_equal("assets/serializable.png", serialized.texturePath)
            end)
        end)

        describe("roundtrip", function()
            it("serialize then deserialize preserves data", function()
                local world = createMockWorld()
                local original = Sprite.fromPath(world, "assets/roundtrip.png", 10, 20, 30, 40, 15, 20)

                local serialized = Sprite.serialize(original)
                local restored = Sprite.deserialize(world, serialized)

                luassert.is_equal(original.texturePath, restored.texturePath)
                luassert.is_equal(original.originX, restored.originX)
                luassert.is_equal(original.originY, restored.originY)

                local oqx, oqy, oqw, oqh = original.quad:getViewport()
                local rqx, rqy, rqw, rqh = restored.quad:getViewport()
                luassert.is_equal(oqx, rqx)
                luassert.is_equal(oqy, rqy)
                luassert.is_equal(oqw, rqw)
                luassert.is_equal(oqh, rqh)
            end)
        end)
    end)

    describe("Text", function()
        describe("serialize", function()
            it("serializes text with all properties", function()
                local font = love.graphics.newFont(16)
                local txt = Text(font, "Hello World", 2, 2, 10, 5, 0.1, 0.2)
                txt.fontPath = "assets/font.ttf"
                txt.fontSize = 16

                local serialized = Text.serialize(txt)

                luassert.is_not_nil(serialized)
                luassert.is_equal("Hello World", serialized.text)
                luassert.is_equal("assets/font.ttf", serialized.fontPath)
                luassert.is_equal(16, serialized.fontSize)
                luassert.is_equal(2, serialized.sx)
                luassert.is_equal(2, serialized.sy)
                luassert.is_equal(10, serialized.ox)
                luassert.is_equal(5, serialized.oy)
                luassert.is_equal(0.1, serialized.kx)
                luassert.is_equal(0.2, serialized.ky)
            end)

            it("serializes text without fontPath (warns but continues)", function()
                local font = love.graphics.newFont(12)
                local txt = Text(font, "No path")

                local serialized = Text.serialize(txt)

                -- Should still serialize, just with nil fontPath
                luassert.is_not_nil(serialized)
                luassert.is_equal("No path", serialized.text)
                luassert.is_nil(serialized.fontPath)
            end)
        end)

        describe("deserialize", function()
            it("deserializes text with font path", function()
                local world = createMockWorld()
                local data = {
                    text = "Restored text",
                    fontPath = "assets/custom.ttf",
                    fontSize = 24,
                    sx = 1.5,
                    sy = 1.5,
                    ox = 5,
                    oy = 3
                }

                local txt = Text.deserialize(world, data)

                luassert.is_not_nil(txt)
                luassert.is_equal("Restored text", txt.text)
                luassert.is_equal("assets/custom.ttf", txt.fontPath)
                luassert.is_equal(24, txt.fontSize)
                luassert.is_equal(1.5, txt.sx)
                luassert.is_equal(1.5, txt.sy)
                luassert.is_equal(5, txt.ox)
                luassert.is_equal(3, txt.oy)
            end)

            it("uses default font when fontPath is missing", function()
                local world = createMockWorld()
                local data = {
                    text = "Default font"
                }

                local txt = Text.deserialize(world, data)

                luassert.is_not_nil(txt)
                luassert.is_equal("Default font", txt.text)
                luassert.is_equal("default", txt.fontPath)
                luassert.is_equal(12, txt.fontSize) -- Default size
            end)

            it("uses default font size of 12", function()
                local world = createMockWorld()
                local data = {
                    text = "Size test",
                    fontPath = "default"
                    -- No fontSize
                }

                local txt = Text.deserialize(world, data)

                luassert.is_equal(12, txt.fontSize)
            end)

            it("defaults scale to 1", function()
                local world = createMockWorld()
                local data = {
                    text = "Scale test"
                }

                local txt = Text.deserialize(world, data)

                luassert.is_equal(1, txt.sx)
                luassert.is_equal(1, txt.sy)
            end)
        end)

        describe("roundtrip", function()
            it("serialize then deserialize preserves data", function()
                local world = createMockWorld()
                local font = love.graphics.newFont(18)
                local original = Text(font, "Roundtrip test", 1.5, 2.0, 8, 4, 0.05, 0.1)
                original.fontPath = "assets/roundtrip.ttf"
                original.fontSize = 18

                local serialized = Text.serialize(original)
                local restored = Text.deserialize(world, serialized)

                luassert.is_equal(original.text, restored.text)
                luassert.is_equal(original.fontPath, restored.fontPath)
                luassert.is_equal(original.fontSize, restored.fontSize)
                luassert.is_equal(original.sx, restored.sx)
                luassert.is_equal(original.sy, restored.sy)
                luassert.is_equal(original.ox, restored.ox)
                luassert.is_equal(original.oy, restored.oy)
                luassert.is_equal(original.kx, restored.kx)
                luassert.is_equal(original.ky, restored.ky)
            end)
        end)
    end)

    describe("ParticleEmitter", function()
        local ParticleEmitter <const> = gfx.ParticleEmitter

        describe("serialize", function()
            it("returns nil when config is not set", function()
                local system = love.graphics.newParticleSystem(love.graphics.newImage(), 100)
                local emitter = ParticleEmitter(system as love.graphics.ParticleSystem)

                local serialized = ParticleEmitter.serialize(emitter)

                luassert.is_nil(serialized, "serialize should return nil without config")
            end)

            it("serializes emitter with config", function()
                local world = createMockWorld()
                local config: tecs2d.gfx.ParticleEmitterConfig = {
                    texturePath = "particles/spark.png",
                    emissionRate = 100,
                    particleLifetime = {0.5, 1.5},
                    speed = {50, 100},
                    spread = 3.14,
                    sizes = {0.5, 1.0, 0.2},
                    colors = {{1, 1, 1, 1}, {1, 0, 0, 0}}
                }
                local emitter = ParticleEmitter.fromConfig(world, config)

                local serialized = ParticleEmitter.serialize(emitter) as tecs2d.gfx.ParticleEmitterConfig

                luassert.is_not_nil(serialized, "serialize should return data")
                luassert.is_equal("particles/spark.png", serialized.texturePath)
                luassert.is_equal(100, serialized.emissionRate)
                luassert.is_equal(0.5, serialized.particleLifetime[1])
                luassert.is_equal(1.5, serialized.particleLifetime[2])
                luassert.is_equal(50, serialized.speed[1])
                luassert.is_equal(100, serialized.speed[2])
                luassert.is_equal(3.14, serialized.spread)
            end)
        end)

        describe("deserialize", function()
            it("deserializes emitter from config data", function()
                local world = createMockWorld()
                local data = {
                    texturePath = "particles/fire.png",
                    emissionRate = 50,
                    particleLifetime = {1.0, 2.0},
                    speed = {20, 40}
                }

                local emitter = ParticleEmitter.deserialize(world, data)

                luassert.is_not_nil(emitter, "deserialize should return emitter")
                luassert.is_not_nil(emitter.system, "emitter should have system")
                luassert.is_not_nil(emitter.config, "emitter should have config")
                luassert.is_equal("particles/fire.png", emitter.config.texturePath)
                luassert.is_equal(50, emitter.config.emissionRate)
            end)
        end)

        describe("fromConfig", function()
            it("creates emitter with basic config", function()
                local world = createMockWorld()
                local config = {
                    texturePath = "particles/basic.png",
                    emissionRate = 75,
                    particleLifetime = {0.3, 0.8}
                }

                local emitter = ParticleEmitter.fromConfig(world, config)

                luassert.is_not_nil(emitter, "fromConfig should return emitter")
                luassert.is_not_nil(emitter.system, "emitter should have system")
                luassert.is_not_nil(emitter.config, "emitter should have config")
                luassert.is_equal("particles/basic.png", emitter.config.texturePath)
            end)

            it("creates emitter with full config", function()
                local world = createMockWorld()
                local config: tecs2d.gfx.ParticleEmitterConfig = {
                    texturePath = "particles/full.png",
                    bufferSize = 500,
                    emissionRate = 100,
                    emissionArea = {"uniform", 10, 20, 0.5, true},
                    particleLifetime = {0.5, 1.5},
                    direction = 1.57,
                    spread = 0.78,
                    speed = {50, 100},
                    linearAcceleration = {-10, -10, 10, 10},
                    radialAcceleration = {-5, 5},
                    tangentialAcceleration = {-2, 2},
                    linearDamping = {0.1, 0.2},
                    sizes = {0.5, 1.0, 0.2},
                    sizeVariation = 0.3,
                    colors = {{1, 1, 1, 1}, {1, 0.5, 0, 0.5}, {1, 0, 0, 0}},
                    rotation = {0, 6.28},
                    spin = {-1, 1},
                    spinVariation = 0.5,
                    relativeRotation = true,
                    offset = {16, 16},
                    insertMode = "random"
                }

                local emitter = ParticleEmitter.fromConfig(world, config)

                luassert.is_not_nil(emitter, "fromConfig should return emitter")
                luassert.is_equal(500, emitter.config.bufferSize)
                luassert.is_equal(0.3, emitter.config.sizeVariation)
                luassert.is_equal(true, emitter.config.relativeRotation)
                luassert.is_equal("random", emitter.config.insertMode)
            end)

            it("stores config for serialization", function()
                local world = createMockWorld()
                local config = {
                    texturePath = "particles/serializable.png",
                    emissionRate = 25
                }

                local emitter = ParticleEmitter.fromConfig(world, config)

                -- Should be serializable
                local serialized = ParticleEmitter.serialize(emitter)
                luassert.is_not_nil(serialized)
                luassert.is_equal("particles/serializable.png", serialized.texturePath)
            end)

            it("requires texturePath", function()
                local world = createMockWorld()
                local config = {
                    emissionRate = 100
                    -- Missing texturePath
                } as tecs2d.gfx.ParticleEmitterConfig

                luassert.has_error(function()
                    ParticleEmitter.fromConfig(world, config)
                end, "ParticleEmitterConfig.texturePath is required")
            end)
        end)

        describe("roundtrip", function()
            it("serialize then deserialize preserves config", function()
                local world = createMockWorld()
                local originalConfig = {
                    texturePath = "particles/roundtrip.png",
                    emissionRate = 150,
                    particleLifetime = {0.2, 0.6},
                    speed = {80, 120},
                    spread = 1.57,
                    sizes = {0.3, 0.8, 0.1},
                    sizeVariation = 0.2,
                    direction = 0.78
                }

                local original = ParticleEmitter.fromConfig(world, originalConfig)
                local serialized = ParticleEmitter.serialize(original)
                local restored = ParticleEmitter.deserialize(world, serialized)

                luassert.is_equal(original.config.texturePath, restored.config.texturePath)
                luassert.is_equal(original.config.emissionRate, restored.config.emissionRate)
                luassert.is_equal(original.config.particleLifetime[1], restored.config.particleLifetime[1])
                luassert.is_equal(original.config.particleLifetime[2], restored.config.particleLifetime[2])
                luassert.is_equal(original.config.speed[1], restored.config.speed[1])
                luassert.is_equal(original.config.speed[2], restored.config.speed[2])
                luassert.is_equal(original.config.spread, restored.config.spread)
                luassert.is_equal(original.config.sizeVariation, restored.config.sizeVariation)
                luassert.is_equal(original.config.direction, restored.config.direction)
            end)
        end)
    end)
end)
