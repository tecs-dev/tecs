require("busted")

rawset(_G, "love", require("spec.love2d.love2d_mock"))

local luassert <const> = require("luassert")
local image <const> = require("tecs2d.gfx.internal.Image")

describe("tecs2d.gfx Image", function()
    local Image <const> = image.Image

    it("captures texture dimensions and construction options", function()
        local texture = love.graphics.newImage() as love.graphics.Texture
        local value = Image.fromTexture(texture, {
            path = "assets/backdrop.png",
            repeatX = true,
        })

        luassert.is_equal(texture, value.texture)
        luassert.is_equal(256, value.width)
        luassert.is_equal(256, value.height)
        luassert.is_equal("assets/backdrop.png", value.path)
        luassert.is_true(value.repeatX)
        luassert.is_false(value.repeatY)
    end)

    it("defaults to an in-memory non-repeating image", function()
        local texture = love.graphics.newImage() as love.graphics.Texture
        local value = Image(texture)

        luassert.is_equal("", value.path)
        luassert.is_false(value.repeatX)
        luassert.is_false(value.repeatY)
        luassert.is_nil(Image.serialize(value))
    end)

    it("serializes durable construction data", function()
        local texture = love.graphics.newImage() as love.graphics.Texture
        local value = Image(texture, {
            path = "assets/sky.png",
            repeatX = true,
            repeatY = true,
        })

        luassert.same({
            path = "assets/sky.png",
            repeatX = true,
            repeatY = true,
        }, Image.serialize(value))
    end)

    it("reconstructs a durable image from its path", function()
        local value = Image.deserialize(nil, {
            path = "assets/sky.png",
            repeatX = true,
            repeatY = false,
        })

        luassert.is_equal("assets/sky.png", value.path)
        luassert.is_true(value.repeatX)
        luassert.is_false(value.repeatY)
        luassert.is_not_nil(value.texture)
    end)

end)
