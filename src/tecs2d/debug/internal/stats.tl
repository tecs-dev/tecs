--- Stats HUD: an FPS / memory / world-stat overlay toggled with Ctrl+.
--- Installed by the debug plugin alongside the modal debugger overlay.

local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")
local leader <const> = require("tecs2d.debug.internal.leader")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local lg <const> = require("tecs2d.debug.internal.debugdraw")
local format <const> = string.format
local collectgarbage <const> = collectgarbage
local getStats <const> = love.graphics.getStats
local getFPS <const> = love.timer.getFPS

local SAMPLE_FREQUENCY_SECONDS <const> = 1
local GC_FREQUENCY_SECONDS <const> = 8

local record stats
    record Options
        --- Leader modifier held with the toggle key (default "ctrl").
        leaderKey: string

        --- Key that, with the leader, toggles the HUD (default ".").
        statsToggleKey: string

        --- Seconds between graphics/world stat samples.
        sampleFrequency: number

        --- Seconds between Lua heap-size samples.
        gcFrequency: number
    end

    --- Install the stats HUD systems on a world.
    install: function(w: tecs.World, opts: Options)
end

function stats.install(w: tecs.World, opts: stats.Options)
    local leaderKey = opts.leaderKey
    local statsToggleKey = opts.statsToggleKey
    local sampleFrequency = opts.sampleFrequency or SAMPLE_FREQUENCY_SECONDS
    local gcFrequency = opts.gcFrequency or GC_FREQUENCY_SECONDS
    local gfxStats = getStats()
    local shown = false
    -- Publish visibility on the shared context so agents (and tests) see it.
    local ctx = w.resources[debugcontext.KEY]

    local lastMemoryProfile = ""
    local lastMemoryUsage: number = 0
    local lastMemoryProfileTime = sampleFrequency
    local lastGCTime = gcFrequency
    local lastStats = {}
    w:getStats(lastStats)

    -- Leader + statsToggleKey toggles the HUD. Read at the game layer (stack 0),
    -- so an open debugger command line suppresses the toggle.
    local function toggledOn(): boolean
        return leader.isDown(input.base.view, leaderKey)
            and input.isKeyPressed(statsToggleKey)
    end

    w:addSystem({
        name = "debug.StatsCollect",
        phase = tecs.phases.RenderFirst,
        run = function(dt: number)
            if toggledOn() then
                shown = not shown
                if ctx then ctx.statsShown = shown end
            end
            if not shown then return end

            lastGCTime = lastGCTime + dt
            if lastGCTime >= gcFrequency then
                lastMemoryUsage = collectgarbage("count") / 1024
                lastGCTime = 0
            end

            lastMemoryProfileTime = lastMemoryProfileTime + dt
            if lastMemoryProfileTime >= sampleFrequency then
                w:getStats(lastStats)
                local textureMemoryMB = gfxStats.texturememory / 1024 / 1024
                local gfxStatsTable = gfxStats as {string: number}
                local bufferMemoryMB = (gfxStatsTable["buffermemory"] or 0) / 1024 / 1024
                local bufferCount = gfxStatsTable["buffers"] or 0
                lastMemoryProfile = format(
                    "FPS: %.0f | Lua: %.1f MB | Tex: %.1f MB | Buf: %.1f MB (%d)\n" ..
                    "Draws: %d | Batched: %d\n" ..
                    "Switches - Canvas: %d | Shader: %d\n" ..
                    "E: %d | C: %d | S: %d | A: %d",
                    getFPS(),
                    lastMemoryUsage,
                    textureMemoryMB,
                    bufferMemoryMB,
                    bufferCount,
                    gfxStats.drawcalls,
                    gfxStats.drawcallsbatched,
                    gfxStats.canvasswitches,
                    gfxStats.shaderswitches,
                    lastStats.entities,
                    lastStats.components,
                    lastStats.systems,
                    lastStats.archetypes
                )
                lastMemoryProfileTime = 0
            end
        end
    })

    w:addSystem({
        name = "debug.StatsRender",
        phase = tecs.phases.RenderLast,
        run = function(_dt: number)
            if not shown or lastMemoryProfile == "" then
                lg.releaseOwner("stats")
                return
            end

            lg.beginOwner("stats")
            lg.setColor(1, 1, 1, 1)
            lg.fitText("panel", lastMemoryProfile, 0, 0, 8, 4,
                {0, 0, 0, 0.6})

            getStats(gfxStats)
            lg.endOwner()
        end
    })
end

return stats
