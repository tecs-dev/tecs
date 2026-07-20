--- Stats HUD: an FPS / memory / world-stat overlay toggled with Ctrl+.
--- Installed by the debug plugin alongside the modal debugger overlay.

local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")
local leader <const> = require("tecs2d.debug.internal.leader")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local lg <const> = love.graphics
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

    -- Backdrop measurement cache: the profile text changes once per sample
    -- period, so the widest line and line count are remeasured only when the
    -- text (or the active font) changes.
    local measuredProfile = ""
    local measuredFont: love.graphics.Font = nil
    local measuredWidth: number = 0
    local measuredLines = 0

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
        phase = tecs.phases.PostRender,
        run = function(_dt: number)
            if not shown or lastMemoryProfile == "" then return end

            lg.push("all")
            lg.origin()

            local textFont = lg.getFont()
            local lineHeight = textFont:getHeight()
            -- Size the backdrop from the text itself: widest line and the
            -- actual line count, so adding a stat line never overflows it.
            if lastMemoryProfile ~= measuredProfile or textFont ~= measuredFont then
                measuredProfile = lastMemoryProfile
                measuredFont = textFont
                measuredWidth = 0
                measuredLines = 0
                for line in (lastMemoryProfile .. "\n"):gmatch("(.-)\n") do
                    measuredLines = measuredLines + 1
                    local lw = textFont:getWidth(line)
                    if lw > measuredWidth then measuredWidth = lw end
                end
            end
            lg.setColor(0, 0, 0, 0.6)
            lg.rectangle("fill", 0, 0, measuredWidth + 16, measuredLines * lineHeight + 8)
            lg.setColor(1, 1, 1, 1)
            lg.print(lastMemoryProfile, 8, 4)

            getStats(gfxStats)
            lg.pop()
        end
    })
end

return stats
