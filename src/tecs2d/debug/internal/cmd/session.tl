--- Session-section debugger commands: history, agent, capabilities, freeze,
--- step, stats, context, restart, exit, and quit. They read registry state
--- (history, signals, the command list) and the MCP session info resource.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local contextreport <const> = require("tecs2d.debug.internal.contextreport")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format

local record session
    --- The Session-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local stepSchema <const>: cmdargs.Schema = {
    args = { n = {default = 1, help = "number of frames to tick"} },
    positional = {"n"},
}
cmdargs.validate(stepSchema)

function session.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local env <const> = d.env
    local reg <const> = d.reg
    local pipeline <const> = d.pipeline
    local componentFor <const> = d.componentFor
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
                    aliases = {"rm"},
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
            shortHelp = "MCP session info and client config",
            examples = {"agent info", "agent connect"},
            subcommands = {
                {
                    name = "info",
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
            name = "capabilities",
            section = "Session",
            shortHelp = "installed plugins, command families, and host features",
            mcpHelp = "What this game session supports: installed plugins (render pipeline, physics, tilemaps, controllers, audio, assets, recorder), command sections with counts, capture facilities, host OS, and the MCP port. Call once after connecting to learn which tool families apply.",
            examples = {"capabilities"},
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                -- Plugin presence by resource probe, never by requiring the
                -- plugin modules (that would register their components). The
                -- plugin modules double as their resource keys, and a module
                -- absent from package.loaded cannot have been installed.
                local function pluginInstalled(modname: string): boolean
                    local key = package.loaded[modname]
                    return key ~= nil and w.resources[key as tecs.Key<any>] ~= nil
                end
                local tilemapComp = componentFor("Tilemap")
                local tilemapCount = 0
                if tilemapComp then
                    w:forEachArchetype(function(arch: tecs.Archetype)
                        local col = arch:get(tilemapComp)
                        if col then
                            tilemapCount = tilemapCount + (arch.entities[0] as integer)
                        end
                    end)
                end
                local plugins: {string: any} = {
                    pipeline = pipeline() ~= nil,
                    physics = pluginInstalled("tecs2d.physics"),
                    tilemaps = tilemapCount,
                    controllers = pluginInstalled("tecs2d.controller"),
                    assets = pluginInstalled("tecs2d.assets"),
                    audio = pluginInstalled("tecs2d.audio"),
                    recorder = env.recorder ~= nil,
                }
                local sections: {string: integer} = {}
                for _, c in ipairs(reg.list) do
                    local section = c.section or "Custom"
                    sections[section] = (sections[section] or 0) + 1
                end
                local osName = love.system.getOS()
                local info = w.resources[mcpinfo.KEY]
                local popup: {string} = {"capabilities:"}
                local names: {string} = {}
                for nm in pairs(plugins) do names[#names + 1] = nm end
                table.sort(names)
                for _, nm in ipairs(names) do
                    popup[#popup + 1] = "  " .. nm .. "\t" .. tostring(plugins[nm])
                end
                popup[#popup + 1] = "  commands\t" .. tostring(#reg.list)
                popup[#popup + 1] = "  host\t" .. tostring(osName)
                return {ok = true, popup = popup, data = {
                    plugins = plugins,
                    commands = {count = #reg.list, sections = sections},
                    capture = {snapshots = true, diff = true, rewind = ctx.rewind.status},
                    host = {os = osName,
                        posix = osName == "OS X" or osName == "Linux"},
                    mcp = info and {port = info.port(), tools = info.toolCount()} or nil,
                }}
            end,
        },
        {
            name = "freeze",
            section = "Session",
            shortHelp = "freeze or unfreeze gameplay under the operator's hold",
            mcpHelp = "Freeze gameplay through the shared freeze controller under the \"operator\" hold: on=true acquires, on=false releases, omit toggles. Rendering, input, and tools keep running; the world stays frozen while any other holder (the open debugger panel) remains. Returns the resulting frozen state. Use cmd_step to advance frames while frozen.",
            schema = d.onOffSchema,
            examples = {"freeze", "freeze on", "freeze off"},
            annotations = {idempotentHint = true},
            outputSchema = {
                type = "object",
                properties = {
                    frozen = {type = "boolean",
                        description = "whether gameplay is frozen after the call (any holder)"},
                },
                required = {"frozen"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local fz = env.freeze
                local want = v.on as boolean
                if want == nil then want = not fz:heldBy("operator") end
                if want then
                    fz:acquire("operator")
                else
                    fz:release("operator")
                end
                local frozen = fz:isFrozen()
                local msg: string
                if want then
                    msg = "frozen"
                elseif frozen then
                    msg = "operator hold released; still frozen by another holder"
                else
                    msg = "resumed"
                end
                return {ok = true, message = msg, data = {frozen = frozen}}
            end,
        },
        {
            name = "step",
            section = "Session",
            shortHelp = "tick the game forward N frames while otherwise frozen",
            mcpHelp = "Advance gameplay by n frames while the freeze controller is held, then freeze again. Fails when nothing holds the freeze; acquire it with cmd_freeze on=true first.",
            schema = stepSchema,
            outputSchema = {
                type = "object",
                properties = {
                    frames = {type = "integer", description = "frames scheduled to tick"},
                },
                required = {"frames"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local n = math.max(1, math.floor(v.n as number)) as integer
                local ok, err = env.freeze:step(n)
                if not ok then
                    return {ok = false, code = "not_frozen", message = "step: " .. err}
                end
                return {ok = true, message = "stepping " .. tostring(n) .. " frame(s)",
                    data = {frames = n}}
            end,
        },
        {
            name = "stats",
            section = "Session",
            shortHelp = "world stats: entities, archetypes, memory, fps, window",
            mcpHelp = "World and host stats in one call: entity, archetype, component, and system counts, Lua memory in KB and MB, the current FPS, and the window size in pixels. Read-only; use it as a quick health check.",
            examples = {"stats"},
            annotations = {readOnlyHint = true, idempotentHint = true},
            outputSchema = {
                type = "object",
                properties = {
                    entities = {type = "integer", description = "live entity count"},
                    archetypes = {type = "integer"},
                    components = {type = "integer", description = "registered component types"},
                    systems = {type = "integer"},
                    memoryKB = {type = "number", description = "Lua heap from collectgarbage"},
                    memoryMB = {type = "number"},
                    fps = {type = "integer", description = "frames per second"},
                    window = {type = "object", properties = {
                        width = {type = "integer"},
                        height = {type = "integer"},
                    }, description = "window size in pixels"},
                },
                required = {"archetypes", "components", "entities", "fps",
                    "memoryKB", "memoryMB", "systems", "window"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                local s = w:getStats()
                local memoryKB = collectgarbage("count")
                local fps = love.timer.getFPS()
                local width = love.graphics.getWidth()
                local height = love.graphics.getHeight()
                return {ok = true, popup = {
                    "stats",
                    "  entities\t" .. tostring(s.entities),
                    "  archetypes\t" .. tostring(s.archetypes),
                    "  components\t" .. tostring(s.components),
                    "  systems\t" .. tostring(s.systems),
                    format("  memory\t%.1f KB (%.2f MB)", memoryKB, memoryKB / 1024),
                    "  fps\t" .. tostring(fps),
                    format("  window\t%dx%d", math.floor(width), math.floor(height)),
                }, data = {entities = s.entities, archetypes = s.archetypes,
                    components = s.components, systems = s.systems,
                    memoryKB = memoryKB, memoryMB = memoryKB / 1024, fps = fps,
                    window = {width = width, height = height}}}
            end,
        },
        {
            name = "context",
            section = "Session",
            shortHelp = "the live debugger context: selection, camera, artifacts",
            mcpHelp = "The full debugger context snapshot: selection, marks, notes, mode, freeze state, camera, mouse, grid, rewind status, and the newest artifact entries (snapshots, diffs, profiles, screenshots, recordings). Read-only; call it to orient before driving the other cmd_* tools.",
            examples = {"context"},
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
                    area = {type = "object",
                        description = "drag-selection rectangle; absent when none"},
                    mouse = {type = "object",
                        description = "pointer position in screen and world space"},
                    camera = {type = "object",
                        description = "camera position, zoom, rotation, and view size"},
                },
                required = {"camera", "entityCount", "frozen", "menu", "mode",
                    "mouse", "open", "recording", "rewind", "selected"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                local data = contextreport.build(w, ctx)
                return {ok = true, popup = {
                    "context",
                    "  selected\t" .. tostring(#ctx.selected),
                    "  mode\t" .. ((ctx.mode ~= "") and ctx.mode or "(none)"),
                    "  frozen\t" .. (ctx.frozen and "yes" or "no"),
                    format("  camera\t%.1f, %.1f  z%.2f", ctx.cameraX, ctx.cameraY, ctx.cameraZoom),
                }, data = data}
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
            name = "exit",
            section = "Session",
            mcp = false,
            shortHelp = "close the debugger (same as the toggle key)",
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                reg.signals.action = "exit"
                return {ok = true, message = ""}
            end,
        },
        {
            name = "quit",
            section = "Session",
            shortHelp = "quit the game",
            mcpHelp = "Quit the game process via a LÖVE quit event. Unsaved state is lost and the MCP connection drops. Take cmd_snapshot_save first if the state matters.",
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
