local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")

local lg <const> = love.graphics
local format <const> = string.format
local collectgarbage <const> = collectgarbage
local getStats <const> = love.graphics.getStats
local getFPS <const> = love.timer.getFPS

local DEFAULT_DEBUG_KEY <const> = "f1"
local DEFAULT_ARCHETYPE_KEY <const> = "f2"
local SAMPLE_FREQUENCY_SECONDS <const> = 1
local GC_FREQUENCY_SECONDS <const> = 8

--- Provides debug information about the game.
local record stats
    --- The configuration for the stats plugin.
    record Config
        --- The font to use to draw the debug information.
        font: love.graphics.Font

        --- The key binding to toggle the debug information.
        keyBinding: string

        --- The key binding to toggle showing active archetypes.
        archetypeBinding: string

        --- The frequency in seconds to sample the memory usage.
        sampleFrequency: number

        --- The frequency in seconds to sample the Lua heap size and world stats.
        gcFrequency: number
    end

    --- Creates a new stats plugin.
    --- @param config The configuration for the stats plugin.
    --- @return A new stats plugin.
    newStatsPlugin: function(config?: Config): tecs.Plugin
end

-- Module-level debug state (shared across all worlds using this plugin)
local _debugEnabled = false

local function isDebug(_dt: number, _w: tecs.World): boolean
    return _debugEnabled
end

function stats.newStatsPlugin(config?: stats.Config): tecs.Plugin
    config = config or {}
    local font = config.font
    local keyBinding = config.keyBinding or DEFAULT_DEBUG_KEY
    local archetypeBinding = config.archetypeBinding or DEFAULT_ARCHETYPE_KEY
    local sampleFrequency = config.sampleFrequency or SAMPLE_FREQUENCY_SECONDS
    local gcFrequency = config.gcFrequency or GC_FREQUENCY_SECONDS
    local gfxStats = getStats()
    local showArchetypes = false

    return function(w: tecs.World)
        local lastMemoryProfile = ""
        local lastMemoryUsage: number = 0
        local lastMemoryProfileTime = sampleFrequency
        local lastGCTime = gcFrequency
        local lastStats = {}
        w:getStats(lastStats)

        -- Query for archetype display (created once, not per-frame)
        local archetypeQuery = w:query({ name = "stats.Archetypes" })

        -- Add update system for stats collection
        w:addSystem({
            name = "stats.Collect",
            phase = tecs.phases.Update,
            run = function(dt: number)
                -- Toggle debug mode on key press
                if input.isKeyReleased(keyBinding) then
                    _debugEnabled = not _debugEnabled
                end

                if input.isKeyReleased(archetypeBinding) then
                    showArchetypes = not showArchetypes
                end

                -- Only process if debug is enabled
                if _debugEnabled then
                    -- Update garbage collection timer
                    lastGCTime = lastGCTime + dt
                    if lastGCTime >= gcFrequency then
                        lastMemoryUsage = collectgarbage("count") / 1024
                        lastGCTime = 0
                        w:getStats(lastStats)
                    end

                    -- Update stats display timer
                    lastMemoryProfileTime = lastMemoryProfileTime + dt
                    if lastMemoryProfileTime >= sampleFrequency then
                        -- Update world stats on each sample, not just during GC
                        w:getStats(lastStats)
                        local textureMemoryMB = gfxStats.texturememory / 1024 / 1024
                        -- Love2D 12 adds buffer stats (buffers, buffermemory)
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
            end
        })

        -- Add render system for stats display
        w:addSystem({
            name = "stats.Render",
            phase = tecs.phases.PostRender,
            runIf = isDebug,
            run = function(_dt: number)
                if lastMemoryProfile == "" then return end

                -- Push clean graphics state for UI overlay
                lg.push("all")
                lg.origin()

                if font then
                    lg.setFont(font)
                end

                -- Draw background tint
                local textFont = font or lg.getFont()
                local lineHeight = textFont:getHeight()
                local textWidth = textFont:getWidth(lastMemoryProfile)
                local numLines = 4
                lg.setColor(0, 0, 0, 0.6)
                lg.rectangle("fill", 0, 0, textWidth + 16, numLines * lineHeight + 8)

                lg.setColor(1, 1, 1, 1)
                lg.print(lastMemoryProfile, 8, 4)

                if showArchetypes then
                    lg.setColor(0.6, 1, 0, 0.8)
                    local i = 1
                    for archetype, length in archetypeQuery:iter() do
                        lg.print(tostring(archetype) .. ": " .. length, 8, 120 + (i * 24))
                        i = i + 1
                    end
                end

                lg.pop()
            end
        })

        -- Add system to update graphics stats after rendering
        w:addSystem({
            name = "stats.GfxStats",
            phase = tecs.phases.PostRender,
            runIf = isDebug,
            run = function(_dt: number)
                getStats(gfxStats)
            end
        })
    end
end

return stats