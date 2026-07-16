-- Stdio MCP server for a Tecs project: serves toolchain tools (check, build,
-- integ, dist), manages the game process (start/stop/restart/status/logs),
-- and proxies every tool of the running game's Streamable HTTP MCP server.
-- One synchronous session: requests are handled in order, and stdout carries
-- only JSON-RPC (all diagnostics go to stderr).

local bridge = {}

local PROTOCOL_VERSION = "2025-06-18"
local READY_TIMEOUT = 15
local LOG_TAIL_BYTES = 8192

local function tailFile(path, bytes)
    local file = io.open(path, "rb")
    if not file then return "" end
    local size = file:seek("end")
    file:seek("set", math.max(0, size - (bytes or LOG_TAIL_BYTES)))
    local content = file:read("*a") or ""
    file:close()
    return content
end

local Server = {}
local serverMt = {__index = Server}

-- ctx supplies everything host-specific; see buildMcpContext in cli.lua.
-- Required: version, json, kernelTools, check(), build(), reexec(task,
-- extra?), loveProcess, loveBin(), setEnv(k, v), unsetEnv(k),
-- readBuildinfo(), log(msg).
function bridge.new(ctx)
    local server = setmetatable({
        ctx = ctx,
        game = nil,          -- {proc, port, url, logPath}
        -- Front-load the full default tool set so it is advertised at
        -- initialize; start_game refreshes it from the live game and only fires
        -- tools/list_changed if the set actually differs. Prefer the user-level
        -- cache (written on the first successful start_game, captures any
        -- project-specific cmd_*); fall back to the manifest vendored into the
        -- payload so even a machine's first-ever start_game does not swap the
        -- whole list; kernel tools are the last resort.
        gameTools = (ctx.readDefaultTools and ctx.readDefaultTools())
            or (ctx.readBundledTools and ctx.readBundledTools())
            or ctx.kernelTools,
    }, serverMt)
    server.tools = server:cliTools()
    return server
end

--------------------------------------------------------------------------------
-- Game process management
--------------------------------------------------------------------------------

local function freePort()
    local socket = require("socket")
    local sock = assert(socket.tcp())
    assert(sock:bind("127.0.0.1", 0))
    local _, port = sock:getsockname()
    sock:close()
    return tonumber(port)
end

function Server:gameRunning()
    return self.game ~= nil and self.game.proc:isRunning()
end

-- Refresh the cached game tool list from a live game. Returns true on success.
function Server:refreshGameTools()
    if not self:gameRunning() then return false end
    local body = self.game.client:request(
        '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}')
    if not body then return false end
    local ok, parsed = pcall(self.ctx.json.parse, body)
    if ok and type(parsed) == "table" and type(parsed.result) == "table"
        and type(parsed.result.tools) == "table" then
        self.gameTools = parsed.result.tools
        return true
    end
    return false
end

function Server:startGame(frozen)
    if self:gameRunning() then
        return {already_running = true, port = self.game.port}
    end
    self.ctx.build()

    local port = freePort()
    local logDir = "build/.tecs-mcp"
    os.execute("mkdir -p '" .. logDir .. "'")
    local logPath = logDir .. "/game-" .. tostring(port) .. ".log"

    -- The CLI runs under dummy SDL drivers; the game needs real ones.
    self.ctx.unsetEnv("SDL_VIDEODRIVER")
    self.ctx.unsetEnv("SDL_AUDIODRIVER")
    local proc = self.ctx.loveProcess.start({
        loveBin = self.ctx.loveBin(),
        appDir = "build",
        logPath = logPath,
        env = {
            TECS_MCP_PORT = tostring(port),
            SDL_MAC_BACKGROUND_APP = "1",
            -- Boot with the freeze already held so the game is inspectable
            -- at frame zero (released with cmd_freeze on=false).
            TECS_BOOT_FROZEN = frozen and "1" or nil,
        },
    })
    self.ctx.setEnv("SDL_VIDEODRIVER", "dummy")
    self.ctx.setEnv("SDL_AUDIODRIVER", "dummy")

    self.game = {
        proc = proc,
        port = port,
        client = self.ctx.mcpClient.new({port = port, timeout = 10}),
        logPath = logPath,
    }
    self.lastLogPath = logPath

    local ready = self.game.client:waitReady(READY_TIMEOUT)
    if ready then
        if self:refreshGameTools() and self.ctx.writeDefaultTools then
            -- Persist the full tool set so future sessions front-load it and
            -- avoid the post-start_game tools/list_changed entirely.
            self.ctx.writeDefaultTools(self.gameTools)
        end
        return {
            port = port,
            pid = proc.pid,
            buildinfo = self.ctx.readBuildinfo(),
            tools = self.gameTools and #self.gameTools or 0,
        }
    end

    local log = tailFile(logPath)
    proc:stop()
    self.game = nil
    error("the game never became ready; log tail:\n" .. log, 0)
end

function Server:stopGame()
    if not self:gameRunning() then
        self.game = nil
        return {already_stopped = true}
    end
    -- Ask nicely over MCP, then escalate to signals.
    pcall(function() self.game.client:tryCall("cmd_quit", nil, 2) end)
    if not self.game.proc:waitExit(5) then
        self.game.proc:stop()
    end
    local result = {stopped = true, log_tail = tailFile(self.game.logPath, 2048)}
    self.game = nil
    return result
end

--------------------------------------------------------------------------------
-- CLI tools
--------------------------------------------------------------------------------

local OBJECT_SCHEMA = {type = "object"}

function Server:cliTools()
    local ctx = self.ctx
    return {
        {
            name = "start_game",
            description = "Build and launch the game with its MCP server on a free port. "
                .. "The game's own tools (screenshot, run_lua, cmd_*, ...) become callable. "
                .. "Pass frozen=true to boot with the freeze already held: the game sits "
                .. "inspectable at frame zero -- stage state, queue input_tape rows, and "
                .. "cmd_step from there; cmd_freeze on=false releases it. Use it for any "
                .. "game that starts acting immediately.",
            inputSchema = {
                type = "object",
                properties = {
                    frozen = {type = "boolean",
                        description = "Start with gameplay frozen at frame zero."},
                },
            },
            handler = function(args)
                return self:startGame(args and args.frozen == true)
            end,
            notifiesToolsChanged = true,
        },
        {
            name = "stop_game",
            description = "Stop the running game (graceful quit, then signals).",
            inputSchema = OBJECT_SCHEMA,
            handler = function()
                return self:stopGame()
            end,
        },
        {
            name = "restart_game",
            description = "Stop the game, rebuild, and start it again. Prefer plain `build` for "
                .. "code changes; the game hot-reloads without restarting.",
            inputSchema = OBJECT_SCHEMA,
            handler = function()
                self:stopGame()
                return self:startGame()
            end,
            notifiesToolsChanged = true,
        },
        {
            name = "game_status",
            description = "Whether the game is running, its port and pid, the build metadata, "
                .. "and a log tail.",
            inputSchema = OBJECT_SCHEMA,
            handler = function()
                local running = self:gameRunning()
                return {
                    running = running,
                    port = running and self.game.port or nil,
                    pid = running and self.game.proc.pid or nil,
                    buildinfo = self.ctx.readBuildinfo(),
                    log_tail = self.game and tailFile(self.game.logPath, 2048)
                        or (self.lastLogPath and tailFile(self.lastLogPath, 2048)),
                }
            end,
        },
        {
            name = "game_logs",
            description = "Tail of the game's captured stdout/stderr; survives crashes.",
            inputSchema = {
                type = "object",
                properties = {
                    bytes = {type = "number", description = "How much to read (default 8192)."},
                },
            },
            handler = function(args)
                local path = (self.game and self.game.logPath) or self.lastLogPath
                if not path then
                    return {log = "", note = "no game has been started in this session"}
                end
                local bytes = math.min(tonumber(args and args.bytes) or LOG_TAIL_BYTES, 65536)
                return {log = tailFile(path, bytes)}
            end,
        },
    }
end

function Server:findCliTool(name)
    for _, tool in ipairs(self.tools) do
        if tool.name == name then return tool end
    end
    return nil
end

--------------------------------------------------------------------------------
-- JSON-RPC dispatch
--------------------------------------------------------------------------------

function Server:respond(id, result)
    return self.ctx.json.serialize({jsonrpc = "2.0", id = id, result = result}, true)
end

function Server:respondError(id, code, message)
    return self.ctx.json.serialize({
        jsonrpc = "2.0",
        id = id == nil and self.ctx.json.NULL or id,
        error = {code = code, message = message},
    }, true)
end

function Server:textResult(id, value, isError)
    local result = {
        content = {{type = "text", text = self.ctx.json.serialize(value, true)}},
    }
    if isError then result.isError = true end
    return self:respond(id, result)
end

-- The set of tool names currently advertised (CLI tools plus game tools).
function Server:advertisedNames()
    local names = {}
    for _, tool in ipairs(self.tools) do names[tool.name] = true end
    for _, tool in ipairs(self.gameTools or {}) do names[tool.name] = true end
    return names
end

-- True if the advertised tool names differ from `before`. Used to fire
-- tools/list_changed only when the set actually changes -- with the default
-- tools front-loaded, start_game usually leaves the set identical, so no
-- notification is sent and the client keeps its registration.
function Server:toolNamesChanged(before)
    local after = self:advertisedNames()
    for name in pairs(after) do if not before[name] then return true end end
    for name in pairs(before) do if not after[name] then return true end end
    return false
end

function Server:listTools()
    local listed = {}
    local seen = {}
    for _, tool in ipairs(self.tools) do
        listed[#listed + 1] = {
            name = tool.name,
            description = tool.description,
            inputSchema = tool.inputSchema,
        }
        seen[tool.name] = true
    end
    if self:gameRunning() then
        self:refreshGameTools()
    end
    for _, tool in ipairs(self.gameTools or self.ctx.kernelTools or {}) do
        if not seen[tool.name] then
            listed[#listed + 1] = tool
            seen[tool.name] = true
        end
    end
    return {tools = listed}
end

-- Handle one JSON-RPC line; returns an array of output lines (a response,
-- possibly followed by notifications).
function Server:handleLine(line)
    if line:match("^%s*$") then return {} end
    local ok, message = pcall(self.ctx.json.parse, line)
    if not ok or type(message) ~= "table" then
        return {self:respondError(nil, -32700, "parse error")}
    end
    local id = message.id
    local method = message.method

    if not method then
        return {}
    end
    if method:match("^notifications/") then
        return {}
    end

    if method == "initialize" then
        local requested = message.params and message.params.protocolVersion
        return {self:respond(id, {
            protocolVersion = requested or PROTOCOL_VERSION,
            capabilities = {tools = {listChanged = true}},
            serverInfo = {name = "tecs", version = self.ctx.version},
        })}
    end
    if method == "ping" then
        return {self:respond(id, self.ctx.json.EMPTY_OBJECT)}
    end
    if method == "tools/list" then
        return {self:respond(id, self:listTools())}
    end
    if method == "tools/call" then
        local name = message.params and message.params.name
        if type(name) ~= "string" then
            return {self:respondError(id, -32602, "tools/call requires params.name")}
        end
        local tool = self:findCliTool(name)
        if tool then
            local out = {}
            local before = tool.notifiesToolsChanged and self:advertisedNames() or nil
            local callOk, result = pcall(tool.handler, message.params.arguments)
            if callOk then
                out[#out + 1] = self:textResult(id, result)
                if before and self:toolNamesChanged(before) then
                    out[#out + 1] = self.ctx.json.serialize(
                        {jsonrpc = "2.0", method = "notifications/tools/list_changed"}, true)
                end
                if name == "start_game" or name == "restart_game" then
                    self.lastLogPath = self.game and self.game.logPath or self.lastLogPath
                end
            else
                out[#out + 1] = self:textResult(id, {error = tostring(result)}, true)
            end
            return out
        end
        -- Everything else belongs to the game: forward the raw request.
        if not self:gameRunning() then
            return {self:textResult(id, {
                error = "the game is not running; call start_game first",
            }, true)}
        end
        local body, requestErr = self.game.client:request(line, 30)
        if body and #body > 0 then
            return {body}
        end
        return {self:textResult(id, {
            error = "the game did not answer (" .. tostring(requestErr)
                .. "); check game_status",
        }, true)}
    end

    return {self:respondError(id, -32601, "method not found: " .. tostring(method))}
end

--------------------------------------------------------------------------------
-- Stdio pump
--------------------------------------------------------------------------------

function Server:serve()
    io.stdout:setvbuf("no")
    -- Anything that would write to stdout corrupts the protocol stream.
    local realPrint = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        io.stderr:write(table.concat(parts, "\t") .. "\n")
    end

    self.ctx.log("MCP bridge serving on stdio; project " .. (self.ctx.projectName or ""))
    while true do
        local line = io.stdin:read("*l")
        if line == nil then break end
        local outputs = self:handleLine(line)
        for _, output in ipairs(outputs) do
            io.stdout:write(output, "\n")
        end
    end

    _G.print = realPrint
    if self:gameRunning() then
        self:stopGame()
    end
end

function bridge.serve(ctx)
    bridge.new(ctx):serve()
end

return bridge
