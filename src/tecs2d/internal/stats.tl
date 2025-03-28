local tecs <const> = require("tecs")
local input <const> = require("tecs2d.internal.input")

local lg <const> = love.graphics
local format <const> = string.format
local collectgarbage <const> = collectgarbage
local getStats <const> = love.graphics.getStats
local getFPS <const> = love.timer.getFPS

local DEFAULT_DEBUG_KEY <const> = "f1"
local DEFAULT_ARCHETYPE_KEY <const> = "f2"
local SAMPLE_FREQUENCY_SECONDS <const> = 1
local GC_FREQUENCY_SECONDS <const> = 8
local DEBUG_OFF <const> = "off"
local DEBUG_ON <const> = "on"

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

        --- The frequency in seconds to run garbage collection.
        gcFrequency: number
    end

    --- Creates a new stats plugin.
    --- @param config The configuration for the stats plugin.
    --- @return A new stats plugin.
    newStatsPlugin: function(config?: Config): tecs.Plugin
end

local function isDebug(_dt: number, w: tecs.World): boolean
    return w:getState(tecs.builtins.Debug) as string ~= DEBUG_OFF
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

        -- Add update system for stats collection
        w:addSystem({
            phase = tecs.phases.Update,
            run = function(dt: number)
                local current: tecs.builtins.Debug.Values = w:getState(tecs.builtins.Debug)

                -- Toggle debug mode on key press
                if input.isKeyReleased(keyBinding) then
                    if current == DEBUG_OFF then
                        w:setState(tecs.builtins.Debug, DEBUG_ON)
                    else
                        w:setState(tecs.builtins.Debug, DEBUG_OFF)
                    end
                end

                if input.isKeyReleased(archetypeBinding) then
                    showArchetypes = not showArchetypes
                end

                -- Only process if debug is enabled
                if current ~= DEBUG_OFF then
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
                        lastMemoryProfile = format(
                            "FPS: %.0f | Lua: %.1f MB | Texture Mem: %.1f MB\n" ..
                            "Draws: %d | Batched: %d\n" ..
                            "Switches - Canvas: %d | Shader: %d\n" ..
                            "E: %d | C: %d | S: %d | A: %d",
                            getFPS(),
                            lastMemoryUsage,
                            textureMemoryMB,
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
            phase = tecs.phases.PostRender,
            runIf = isDebug,
            run = function(_dt: number)
                if lastMemoryProfile == "" then return end
                local prevFont: love.graphics.Font = nil
                if font then
                    prevFont = lg.getFont()
                    lg.setFont(font)
                end

                local r, g, b, a = lg.getColor()
                lg.setColor(1, 1, 1, 1)
                lg.print(lastMemoryProfile, 8, 0)

                if showArchetypes then
                    lg.setColor(0.6, 1, 0, 0.8)
                    local query = w:query({})
                    local i = 1
                    for archetype, length in query() do
                        lg.print(tostring(archetype) .. ": " .. length, 8, 120 + (i * 24))
                        i = i + 1
                    end
                end
                lg.setColor(r, g, b, a)

                if prevFont then
                    lg.setFont(prevFont)
                end
            end
        })

        -- Add system to update graphics stats after rendering
        w:addSystem({
            phase = tecs.phases.PostRender,
            runIf = isDebug,
            run = function(_dt: number)
                getStats(gfxStats)
            end
        })
    end
end

return stats