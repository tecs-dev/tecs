--- The Debug plugin: an in-game modal debugger overlay plus a stats HUD.
---
--- Adding it enables debug mode automatically:
---   local debug = require("tecs2d.debug")
---   world:addPlugin(debug.new())
---
--- Press Ctrl+/ to open the modal debugger (freeze, select, mark, note, query,
--- step, goto, ...) and Ctrl+. to toggle the FPS / memory stats HUD. When the
--- MCP plugin is also present, agents inspect and drive the debugger through
--- the registry-derived cmd_* command tools (cmd_context, cmd_select, ...).
---
--- Games add their own commands with require("tecs2d.debug.commands").register;
--- a registered command gets schema-parsed arguments, help, Tab completion,
--- and (unless opted out) a cmd_<name> MCP tool.

local tecs <const> = require("tecs")
local logtap <const> = require("tecs2d.internal.logtap")
local buildinfo <const> = require("tecs2d.buildinfo")
local leader <const> = require("tecs2d.debug.internal.leader")
local overlay <const> = require("tecs2d.debug.internal.overlay")
local stats <const> = require("tecs2d.debug.internal.stats")
local toolworld <const> = require("tecs2d.debug.internal.toolworld")

local record debugplugin
    enum LeaderKey
        "ctrl"
        "alt"
        "shift"
        "gui"
        "cmd"
        "super"
    end

    enum RecordingFrameFormat
        "png"
        "tga"
        "jpg"
        "bmp"
    end

    --- Debug plugin configuration.
    record Config
        --- Modifier held with a toggle key: "ctrl" (default), "alt", "shift",
        --- or "gui"/"cmd"/"super".
        leaderKey: LeaderKey

        --- Key that, with the leader, toggles the modal debugger (default "/").
        debugToggleKey: string

        --- Key that, with the leader, toggles the stats HUD (default ".").
        statsToggleKey: string

        --- Seconds between graphics/world stat samples.
        sampleFrequency: number

        --- Seconds between Lua heap-size samples.
        gcFrequency: number

        --- Logical height above which debugger UI scales with the host window.
        --- It stays at authored size on shorter windows. Defaults to 1080.
        uiHeight: number

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

        --- Captured image format: "png" (default), "tga", "jpg", or "bmp".
        recordingFrameFormat: RecordingFrameFormat

        --- Max frames in flight before dropping (default 8).
        recordingRingSize: integer

        --- Keep the debugger in builds packaged by `tecs dist`. By default
        --- the plugin is a no-op when tecs2d.buildinfo reports a distributed
        --- build.
        enableInDist: boolean
    end

    --- Create the Debug plugin.
    new: function(config?: Config): tecs.Plugin
end

function debugplugin.new(config?: debugplugin.Config): tecs.Plugin
    -- Distributed builds do not install the debugger unless the game opts in.
    if not buildinfo.isDev() and not (config and config.enableInDist) then
        return function(_w: tecs.World) end
    end

    local cfg = config or {}
    local leaderKey = cfg.leaderKey or "ctrl"
    if not leader.isValid(leaderKey) then
        error("debug: unknown leaderKey '" .. leaderKey ..
            "'; use ctrl, alt, shift, or gui/cmd/super")
    end
    local statsToggleKey = cfg.statsToggleKey or "."
    return function(w: tecs.World)
        logtap.install()
        toolworld.install(w, cfg.uiHeight or 1080)
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
