--- Text, which is entities.
---
--- Every glyph is an entity carrying the components that draw, so a screen of
--- text is a screen of instances and text costs what its glyph count costs.
--- That is the design's bet, and this is what settles it.
---
--- Three regimes, because they stress different things:
---
---   static   nothing changes, so layout runs once and the dirty gate should
---            skip every text every frame. The floor.
---   churn    a fraction of the texts change their string each frame, which is
---            what a score, a timer or a debug overlay does.
---   resize   the changed strings change *length*, so glyph entities are
---            spawned or despawned rather than rewritten in place.
---
--- The last one is the cliff worth watching. `syncInstances` sets `relayout`
--- when any archetype's length moves, and a relayout rewrites every instance in
--- the scene rather than the ones that changed. So a single score counter
--- gaining a digit can cost the whole frame's extraction, and the report prints
--- `rewritten` beside the stage table for exactly that reason: if it tracks the
--- instance count rather than the glyph count, the cliff is real.

local root = os.getenv("TECS_LUA")
    or (_G as {string: any})["__tecsContent"] as string
    or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then root = root:sub(1, -2) end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local tecs <const> = require("tecs")
local timing <const> = require("tecs.timing")
local clock <const> = require("tecs.platform.clock")
local text <const> = require("tecs.gfx.text")
local Transform <const> = tecs.components.Transform
local Tint <const> = tecs.components.Tint

--- Text entities on screen.
local TEXTS <const> = math.floor(tonumber(os.getenv("BENCH_TEXTS")) or 400)

--- Characters in each. Glyph count, and so instance count, is this times the
--- number of texts.
local LENGTH <const> = math.floor(tonumber(os.getenv("BENCH_LENGTH")) or 16)

--- Fraction of texts whose string is rewritten each frame, 0 to 1.
local CHURN <const> = tonumber(os.getenv("BENCH_CHURN")) or 0.0

--- Texts spawned per frame, each despawned after `BENCH_LIFETIME` frames. This
--- is the damage-number shape: many short strings appearing and disappearing
--- constantly, rather than a fixed set being edited.
local SPAWN_RATE <const> = math.floor(tonumber(os.getenv("BENCH_SPAWN")) or 0)
local LIFETIME <const> = math.floor(tonumber(os.getenv("BENCH_LIFETIME")) or 60)

--- Whether a changed string also changes length. Same-length changes rewrite
--- glyphs in place; changing length spawns or despawns them, which is what
--- moves the archetype and forces the relayout.
local RESIZE <const> = os.getenv("BENCH_RESIZE") == "1"

local WIDTH <const> = 1280
local HEIGHT <const> = 720
local SIZE <const> = 14.0

local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 900)

timing.enable()

--- Real wall time between iterations, from the clock provider, since the dt the
--- world receives is the one the loop measured.
local DELTA <const> = timing.stage("delta")

local entities: {integer} = {}
local transient: {integer} = {}
local transientFont: text.Font = nil
local rewritten = 0
local glyphs = 0

--- A string of `length` characters that differs from the last one, so a change
--- is a real change rather than an assignment of the same value.
local function phrase(seed: integer, length: integer): string
    local out: {string} = {}
    for index = 1, length do
        out[index] = string.char(33 + (seed + index * 7) % 90)
    end
    return table.concat(out)
end

return tecs.application({
    window = { title = "text", width = WIDTH, height = HEIGHT },
    presentMode = "immediate",
    ambient = { 1.0, 1.0, 1.0 },
    capacity = TEXTS * (LENGTH + 4) + 256,
    maxEntities = TEXTS * (LENGTH + 4) + 4096,
    maxFrames = WARMUP + FRAMES,
    logFile = "",

    load = function(app: tecs.Application)
        -- Real time, recorded where both values are visible. The world's dt is
        -- whatever the loop measured, and this is that same measurement kept
        -- for the report.
        clock.provider = function(realDt: number): number
            timing.mark(DELTA, realDt)
            return realDt
        end

        app.world:addPlugin(text.plugin({ renderer = app.renderer }))
        local font = text.defaultFont()
        transientFont = font

        math.randomseed(42)
        local spawnStart <const> = clock.now()
        local columns <const> = math.max(1, math.floor(WIDTH / (LENGTH * SIZE * 0.62)))
        for index = 1, TEXTS do
            local column = (index - 1) % columns
            local row = math.floor((index - 1) / columns)
            entities[index] = app.world:spawn(
                Transform(column * (WIDTH / columns), 8.0 + row * SIZE * 1.4,
                    0.0, 1, 0.0, 1.0, 1.0),
                Tint(0.9, 0.95, 1.0, 1.0),
                text.Text.new({
                    text = phrase(index, LENGTH),
                    font = font,
                    size = SIZE,
                })
            )
        end

        local spawnMs <const> = (clock.now() - spawnStart) * 1000.0
        print(("text: spawned %d texts (%d glyphs) in %.1f ms, %.3f ms each")
            :format(TEXTS, TEXTS * LENGTH, spawnMs, spawnMs / TEXTS))
        print(("text: %d texts of %d characters, churn %.0f%%%s, "
            .. "measuring %d frames after %d warmup")
            :format(TEXTS, LENGTH, CHURN * 100.0,
                RESIZE and " with length changes" or "", FRAMES, WARMUP))
    end,

    update = function(app: tecs.Application, _: number)
        if app.frame == WARMUP then timing.reset() end

        -- Damage numbers: a burst appears every frame and each is gone a
        -- moment later, so the population is steady while the identities turn
        -- over completely.
        for index = 1, SPAWN_RATE do
            local at = (app.frame * SPAWN_RATE + index) % 997
            transient[#transient + 1] = app.world:spawn(
                Transform(8.0 + (at % 60) * 20.0,
                    8.0 + math.floor(at / 60) * 18.0, 0.0, 1, 0.0, 1.0, 1.0),
                Tint(1.0, 0.8, 0.2, 1.0),
                text.Text.new({
                    text = tostring(100 + at),
                    font = transientFont,
                    size = SIZE,
                })
            )
        end
        if SPAWN_RATE > 0 then
            local expire <const> = #transient - SPAWN_RATE * LIFETIME
            for index = 1, expire do
                app.world:despawn(transient[index])
                transient[index] = nil
            end
            if expire > 0 then
                local moved: {integer} = {}
                for index = expire + 1, #transient + expire do
                    moved[#moved + 1] = transient[index]
                end
                transient = moved
            end
        end

        local changing = math.floor(TEXTS * CHURN)
        for index = 1, changing do
            -- Spread across the set rather than always the first N, so the
            -- churn is not confined to one archetype.
            local at = ((app.frame * 31 + index * 17) % TEXTS) + 1
            local length = LENGTH
            if RESIZE then
                length = LENGTH - (app.frame + index) % 3
            end
            local item = app.world:getMut(entities[at], text.Text)
            item.text = phrase(app.frame + index, length)
        end

        if app.frame >= WARMUP then
            rewritten = rewritten + app.renderer.rewritten
            glyphs = app.renderer.count
        end
    end,

    quit = function(app: tecs.Application)
        local frames <const> = math.max(1, app.frame - WARMUP)
        print(("%d instances drawn, %d layouts, %.0f instances rewritten "
            .. "per frame")
            :format(glyphs, text.layouts(app.world), rewritten / frames))
        local report = timing.format()
        if report ~= "" then print(report) end
    end,
})
