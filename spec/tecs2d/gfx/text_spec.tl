require("busted")

-- Set up love mock before requiring tecs2d.gfx modules
rawset(_G, "love", require("spec.love2d.love2d_mock"))

-- Skip if Love2D 12 GPU features aren't available (mock doesn't support full GPU)
if not love.graphics.newComputeShader then
    pending("Text tests require Love2D 12 GPU features")
    return
end

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")

local Text <const> = gfx.Text

-- BMFont tests require actual font files which aren't available in unit tests.
-- These tests are pending until we have a test font available.
describe("tecs2d.gfx Text", function()
    pending("Text tests require BMFont files")
end)
