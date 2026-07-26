--- Love2D integration suite: sprite animation direction and tag UV layout.
--- Sheets are built at runtime with one solid color per frame, so pixel
--- probes identify the exact frame showing:
---   - reverse tags must play last-to-first
---   - pingpong tags must bounce (never wrap last-to-first directly)
---   - tags starting mid-row that wrap to the next row must sample the
---     right frames (not walk off the sheet edge)
---
--- Run via `make test-love FILE_MATCH='sprite_direction'`.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/sprites"

local sleep <const> = socket.sleep as function(number)

--- Classify a probe as a frame color.
local function classify(p: {number}): string
    local r, g, b = p[1], p[2], p[3]
    if r > 0.7 and g > 0.7 and b < 0.3 then return "Y" end
    if r > 0.7 and g < 0.3 and b < 0.3 then return "R" end
    if g > 0.7 and r < 0.3 and b < 0.3 then return "G" end
    if b > 0.7 and r < 0.3 and g < 0.3 then return "B" end
    return "none"
end

--- Sample the probe point for `seconds`, returning deduped consecutive
--- frame colors (ignoring "none" and unchanged samples).
local function observeSequence(app: fixture.App, fx: number, fy: number, seconds: number): {string}
    local sequence: {string} = {}
    local deadline = socket.gettime() + seconds
    while socket.gettime() < deadline do
        local frame = classify(fixture.probePixels(app, {{fx, fy}})[1])
        if frame ~= "none" and frame ~= sequence[#sequence] then
            sequence[#sequence + 1] = frame
        end
        sleep(0.04)
    end
    return sequence
end

local function transitions(sequence: {string}): {string: boolean}
    local seen: {string: boolean} = {}
    for i = 2, #sequence do
        seen[sequence[i - 1] .. ">" .. sequence[i]] = true
    end
    return seen
end

describe("sprite animation: direction and tag layout", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- Three test sprites, each on its own probe point:
        --   (80, 120):  3-frame R,G,B strip, tag direction "reverse"
        --   (240, 120): 3-frame R,G,B strip, tag direction "pingpong"
        --   (240, 180): 2x2 grid R,G,B,Y; tag = frames 1..3 (G,B,Y),
        --               starting mid-row and wrapping to the second row
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform

            local function solid(imageData, x0, y0, r, g, b)
                for y = y0, y0 + 15 do
                    for x = x0, x0 + 15 do
                        imageData:setPixel(x, y, r, g, b, 1)
                    end
                end
            end

            -- 3-frame horizontal strip: R, G, B
            local strip = love.image.newImageData(48, 16)
            solid(strip, 0, 0, 1, 0, 0)
            solid(strip, 16, 0, 0, 1, 0)
            solid(strip, 32, 0, 0, 0, 1)
            local stripImage = love.graphics.newImage(strip)

            local revSheet = gfx.SpriteSheet.builder(stripImage, "dir-reverse")
                :frame(0, 0, 16, 16, 300)
                :frame(16, 0, 16, 16, 300)
                :frame(32, 0, 16, 16, 300)
                :tag("play", 0, 2, "reverse")
                :build()
            world:spawn(Transform(80, 120, 0, 1),
                gfx.Sprite.fromSheet(revSheet, "play"))

            local pingSheet = gfx.SpriteSheet.builder(stripImage, "dir-pingpong")
                :frame(0, 0, 16, 16, 300)
                :frame(16, 0, 16, 16, 300)
                :frame(32, 0, 16, 16, 300)
                :tag("play", 0, 2, "pingpong")
                :build()
            world:spawn(Transform(240, 120, 0, 1),
                gfx.Sprite.fromSheet(pingSheet, "play"))

            -- 2x2 grid: R G / B Y
            local grid = love.image.newImageData(32, 32)
            solid(grid, 0, 0, 1, 0, 0)
            solid(grid, 16, 0, 0, 1, 0)
            solid(grid, 0, 16, 0, 0, 1)
            solid(grid, 16, 16, 1, 1, 0)
            local gridImage = love.graphics.newImage(grid)

            local wrapSheet = gfx.SpriteSheet.builder(gridImage, "dir-wrap")
                :frame(0, 0, 16, 16, 300)
                :frame(16, 0, 16, 16, 300)
                :frame(0, 16, 16, 16, 300)
                :frame(16, 16, 16, 16, 300)
                :tag("wrap", 1, 3)
                :build()
            world:spawn(Transform(240, 180, 0, 1),
                gfx.Sprite.fromSheet(wrapSheet, "wrap"))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("plays reverse tags last-to-first", function()
        local sequence = observeSequence(app, 80 / 320, 120 / 240, 2.5)
        luassert.is_true(#sequence >= 4, "too few samples: " .. table.concat(sequence, ","))
        local seen = transitions(sequence)
        local reverseOnly = {["B>G"] = true, ["G>R"] = true, ["R>B"] = true}
        for pair in pairs(seen) do
            luassert.is_true(reverseOnly[pair] == true,
                "forward-order transition " .. pair .. " in a reverse tag (sequence: "
                .. table.concat(sequence, ",") .. ")")
        end
    end)

    it("bounces pingpong tags instead of wrapping", function()
        local sequence = observeSequence(app, 240 / 320, 120 / 240, 3.0)
        luassert.is_true(#sequence >= 4, "too few samples: " .. table.concat(sequence, ","))
        local seen = transitions(sequence)
        luassert.is_nil(seen["B>R"],
            "pingpong wrapped last-to-first (sequence: " .. table.concat(sequence, ",") .. ")")
        luassert.is_true(seen["B>G"] == true or seen["G>R"] == true,
            "no bounce transitions observed (sequence: " .. table.concat(sequence, ",") .. ")")
    end)

    it("samples the right frames for a mid-row wrapping tag", function()
        local sequence = observeSequence(app, 240 / 320, 180 / 240, 2.5)
        local seen: {string: boolean} = {}
        for _, frame in ipairs(sequence) do
            seen[frame] = true
        end
        luassert.is_true(seen["G"] == true, "green frame missing (sequence: " .. table.concat(sequence, ",") .. ")")
        luassert.is_true(seen["B"] == true,
            "blue frame missing: mid-row wrap sampled off the sheet edge (sequence: "
            .. table.concat(sequence, ",") .. ")")
        luassert.is_true(seen["Y"] == true, "yellow frame missing (sequence: " .. table.concat(sequence, ",") .. ")")
        luassert.is_true(seen["R"] ~= true,
            "red frame appeared but is outside the tag (sequence: " .. table.concat(sequence, ",") .. ")")
    end)
end)
