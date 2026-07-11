--- Session-section debugger commands: history, agent, capabilities, step,
--- exit, and quit. They read registry state (history, signals, the command
--- list) and the MCP session info resource.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

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
            name = "step",
            section = "Session",
            mcp = false,   -- agents use the step MCP tool (same freeze controller)
            shortHelp = "tick the game forward N frames while otherwise frozen",
            schema = stepSchema,
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
            mcp = false,   -- the quit MCP tool exists
            shortHelp = "quit the game",
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                reg.signals.action = "quit"
                return {ok = true}
            end,
        },
    }
end

return session
