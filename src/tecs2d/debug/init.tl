--- The Debug plugin: an in-game modal debugger overlay plus a stats HUD.
---
--- Adding it enables debug mode automatically:
---   local debug = require("tecs2d.debug")
---   world:addPlugin(debug.new())
---
--- Press Ctrl+/ to open the modal debugger (freeze, select, mark, note, query,
--- step, goto, ...) and Ctrl+. to toggle the FPS / memory stats HUD. When the
--- MCP plugin is also present, agents inspect and drive the debugger through
--- get_debug_context and the registry-derived debug_* command tools.
---
--- Games add their own commands with require("tecs2d.debug.commands").register;
--- a registered command gets schema-parsed arguments, help, Tab completion,
--- and (unless opted out) a debug_<name> MCP tool.

local tecs <const> = require("tecs")
local overlay <const> = require("tecs2d.debug.internal.overlay")
local stats <const> = require("tecs2d.debug.internal.stats")

local record debugplugin
    --- Debug plugin configuration.
    record Config
        --- Modifier held with a toggle key: "ctrl" (default), "alt", "shift",
        --- or "gui"/"cmd"/"super".
        leaderKey: string

        --- Key that, with the leader, toggles the modal debugger (default "/").
        debugToggleKey: string

        --- Key that, with the leader, toggles the stats HUD (default ".").
        statsToggleKey: string

        --- Seconds between graphics/world stat samples.
        sampleFrequency: number

        --- Seconds between Lua heap-size samples.
        gcFrequency: number

        --- ffmpeg executable path/name, used to assemble captured frames into
        --- the output video. Defaults to ffmpeg on PATH.
        recordingFfmpegPath: string

        --- Save-directory subfolder for recording outputs.
        recordingOutputDir: string

        --- Default debugger recording countdown in seconds.
        recordingCountdown: number

        --- Default recording capture FPS (default 30).
        recordingFps: integer

        --- Default recording output scale multiplier (default 1).
        recordingScale: number

        --- Captured image format: "png" (default), "tga", or "jpg".
        recordingFrameFormat: string

        --- Max frames in flight before dropping (default 8).
        recordingRingSize: integer
    end

    --- Create the Debug plugin.
    new: function(config?: Config): tecs.Plugin
end

function debugplugin.new(config?: debugplugin.Config): tecs.Plugin
    local cfg = config or {}
    local leaderKey = cfg.leaderKey or "ctrl"
    local statsToggleKey = cfg.statsToggleKey or "."
    return function(w: tecs.World)
        overlay.install(w, {
            leaderKey = leaderKey,
            debugToggleKey = cfg.debugToggleKey or "/",
            statsToggleKey = statsToggleKey,
            recordingFfmpegPath = cfg.recordingFfmpegPath,
            recordingOutputDir = cfg.recordingOutputDir,
            recordingCountdown = cfg.recordingCountdown,
            recordingFps = cfg.recordingFps,
            recordingScale = cfg.recordingScale,
            recordingFrameFormat = cfg.recordingFrameFormat,
            recordingRingSize = cfg.recordingRingSize,
        })
        stats.install(w, {
            leaderKey = leaderKey,
            statsToggleKey = statsToggleKey,
            sampleFrequency = cfg.sampleFrequency,
            gcFrequency = cfg.gcFrequency,
        })
    end
end

return debugplugin
