--- Session-section debugger commands: history, agent, step, input tape,
--- context, restart, and quit. They read registry state and the MCP session
--- info resource.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local frameclock <const> = require("tecs2d.internal.frameclock")
local contextreport <const> = require("tecs2d.debug.internal.contextreport")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local record session
    --- The Session-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local stepSchema <const>: cmdargs.Schema = {
    args = {
        n = {default = 1, help = "number of frames to tick"},
        dt = {kind = "number",
            help = "seconds each stepped frame carries (default 1/fps)"},
    },
    positional = {"n"},
}
cmdargs.validate(stepSchema)

function session.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local env <const> = d.env
    local reg <const> = d.reg
    local historyFile <const> = d.historyFile

    return {
        {
            name = "history",
            section = "Session",
            shortHelp = "show the command history (persisted across sessions)",
            examples = {"history", "history clear"},
            subcommands = {
                {
                    name = "clear",
                    shortHelp = "forget the history and delete its file",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local n = #reg.history
                        reg.history = {}
                        love.filesystem.remove(historyFile)
                        return {ok = true, message = "cleared " .. tostring(n) .. " history entries",
                            data = {cleared = n}}
                    end,
                },
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                if #reg.history == 0 then
                    return {ok = true, message = "no history yet", data = {history = reg.history}}
                end
                local popup: {string} = {"history  (newest last; up/down to walk):"}
                local first = math.max(1, #reg.history - 30 + 1)
                for i = first, #reg.history do
                    popup[#popup + 1] = "  " .. reg.history[i]
                end
                return {ok = true, popup = popup, data = {history = reg.history}}
            end,
        },
        {
            name = "agent",
            section = "Session",
            mcp = false,
            shortHelp = "MCP session info and client config",
            examples = {"agent info", "agent connect"},
            subcommands = {
                {
                    name = "info",
                    mcp = false,
                    shortHelp = "show the MCP URL, tool count, and save directory",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local info = w.resources[mcpinfo.KEY]
                        if not info then
                            return {ok = false, code = "no_mcp", message = "agent: MCP plugin not installed"}
                        end
                        local port = info.port()
                        local url = (port ~= 0) and ("http://localhost:" .. tostring(port) .. "/mcp") or "(binding...)"
                        return {ok = true, popup = {
                            "agent session",
                            "  mcp url\t" .. url,
                            "  tools\t" .. tostring(info.toolCount()),
                            "  save dir\t" .. love.filesystem.getSaveDirectory(),
                            "  identity\t" .. tostring(love.filesystem.getIdentity()),
                        }, data = {url = url, port = port, tools = info.toolCount(),
                            saveDir = love.filesystem.getSaveDirectory()}}
                    end,
                },
                {
                    name = "connect",
                    mcp = false,
                    shortHelp = "copy the MCP client config JSON to the clipboard",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local info = w.resources[mcpinfo.KEY]
                        if not info then
                            return {ok = false, code = "no_mcp", message = "agent: MCP plugin not installed"}
                        end
                        local port = info.port()
                        if port == 0 then
                            return {ok = false, code = "not_bound", message = "agent: MCP port not bound yet"}
                        end
                        local cfg = '{"type":"http","url":"http://localhost:' .. tostring(port) .. '/mcp"}'
                        love.system.setClipboardText(cfg)
                        return {ok = true, message = "MCP client config copied to clipboard: " .. cfg,
                            data = {config = cfg, port = port}}
                    end,
                },
            },
        },
        {
            name = "step",
            section = "Session",
            shortHelp = "tick the game forward N frames while otherwise frozen",
            mcpHelp = "Advance gameplay by n frames while gameplay is suspended, then suspend it again. Each stepped frame carries a deterministic dt of 1/fps regardless of display refresh rate; pass dt to override it for this call.",
            schema = stepSchema,
            outputSchema = {
                type = "object",
                properties = {
                    frames = {type = "integer", description = "frames scheduled to tick"},
                    step_dt = {type = "number",
                        description = "seconds each stepped frame will carry"},
                },
                required = {"frames"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local n = math.max(1, math.floor(v.n as number)) as integer
                local dtArg = v.dt as number
                if dtArg ~= nil and dtArg <= 0 then
                    return {ok = false, code = "bad_dt", message = "step: dt must be > 0"}
                end
                if not env.suspension:isSuspended() then
                    return {ok = false, code = "not_frozen", message = "step: not frozen"}
                end

                local data: {string: any} = {frames = n,
                    step_dt = dtArg or frameclock.nominal}

                env.suspension.stepDt = dtArg
                local ok, err = env.suspension:step(n)
                if not ok then
                    return {ok = false, code = "not_frozen", message = "step: " .. err}
                end

                return {ok = true, message = "stepping " .. tostring(n) .. " frame(s)",
                    data = data}
            end,
        },
        {
            name = "context",
            section = "Session",
            overlay = false,
            shortHelp = "the live debugger context: selection, camera, artifacts",
            mcpHelp = "The full debugger context snapshot: selection, marks, notes, mode, freeze state, camera, mouse, grid, rewind status, and the newest artifact entries (snapshots, diffs, profiles, screenshots, recordings). Read-only; call it to orient before driving the other cmd_* tools.",
            annotations = {readOnlyHint = true, idempotentHint = true},
            outputSchema = {
                type = "object",
                properties = {
                    open = {type = "boolean", description = "whether the debugger panel is open"},
                    frozen = {type = "boolean"},
                    mode = {type = "string"},
                    command = {type = "string", description = "the typed command line"},
                    message = {type = "string", description = "the status line"},
                    selected = {type = "array", items = {type = "integer"},
                        description = "selected entity ids"},
                    statsShown = {type = "boolean"},
                    showIds = {type = "boolean"},
                    showBounds = {type = "boolean"},
                    grid = {type = "object",
                        description = "grid size and origin; absent when the grid is off"},
                    rewind = {type = "object",
                        description = "ring status, count, interval, cap, bytes"},
                    diffs = {type = "array", description = "newest diff artifacts"},
                    menu = {type = "object", description = "context-menu open flag and target"},
                    marks = {type = "object", description = "mark name to compact id ranges"},
                    notes = {type = "object", description = "note text to compact id ranges"},
                    snapshots = {type = "array", description = "newest snapshot entries"},
                    profiles = {type = "array", description = "newest profile captures"},
                    screenshots = {type = "array", description = "newest screenshots"},
                    recording = {type = "object", description = "current recording state"},
                    recordings = {type = "array", description = "newest completed recordings"},
                    profileTop = {type = "array", items = {type = "string"},
                        description = "hot spots from the last profile; absent when none"},
                    entityCount = {type = "integer"},
                    input = {type = "object",
                        description = "scripted-input frame, held presses, and recent events; absent when nothing has scripted input"},
                    area = {type = "object",
                        description = "drag-selection rectangle; absent when none"},
                    mouse = {type = "object",
                        description = "pointer position in screen and world space"},
                    camera = {type = "object",
                        description = "camera position, zoom, rotation, and view size"},
                    worldId = {type = "integer",
                        description = "game render world for worldId-aware entity commands"},
                    debugWorldId = {type = "integer",
                        description = "isolated debugger UI render world, when the overlay is installed"},
                },
                required = {"camera", "entityCount", "frozen", "menu", "mode",
                    "mouse", "open", "recording", "rewind", "selected"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                local data = contextreport.build(w, ctx)
                return {ok = true, data = data}
            end,
        },
        {
            name = "restart",
            section = "Session",
            shortHelp = "restart the game process",
            mcpHelp = "Restart the game via love.event.quit(\"restart\"). Unsaved state is lost and the MCP connection drops until the new instance binds. Take cmd_snapshot_save first if the state matters.",
            examples = {"restart"},
            annotations = {destructiveHint = true},
            outputSchema = {
                type = "object",
                properties = {
                    restarting = {type = "boolean"},
                },
                required = {"restarting"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                -- Abort the MCP connection with RST so the restarted
                -- instance can rebind the port immediately.
                local info = w.resources[mcpinfo.KEY]
                if info and info.prepareRestart then info.prepareRestart() end
                love.event.quit("restart")
                return {ok = true, message = "restarting", data = {restarting = true}}
            end,
        },
        {
            name = "quit",
            section = "Session",
            shortHelp = "quit the game",
            mcpHelp = "Quit the game process via a Love quit event. Unsaved state is lost and the MCP connection drops. Take cmd_snapshot_save first if the state matters.",
            outputSchema = {
                type = "object",
                properties = {
                    quitting = {type = "boolean"},
                },
                required = {"quitting"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                love.event.quit()
                return {ok = true, message = "quitting", data = {quitting = true}}
            end,
        },
    }
end

return session
