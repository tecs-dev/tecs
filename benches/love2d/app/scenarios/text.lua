--- Static text steady state: many text entities whose strings never
--- change. Measures per-frame text sync cost (live-count walks, shader
--- sends, glyph upload gating) when nothing is dirty.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local TEXTS = tonumber(os.getenv("TECS_BENCH_TEXTS")) or 1200
local FONT = "assets/press-start-2p.fnt"
local AREA_W, AREA_H = 2400, 1400

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
        cameraPosition = {AREA_W / 2, AREA_H / 2},
        sizeHints = {textEntities = TEXTS + 64, textGlyphs = TEXTS * 16},
    },
    meta = {texts = TEXTS},
    setup = function(world)
        math.randomseed(42)
        local rand = math.random
        for i = 1, TEXTS do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0, 1),
                gfx.Text(FONT, "entity " .. i, 1.0)
            )
        end
    end,
}
