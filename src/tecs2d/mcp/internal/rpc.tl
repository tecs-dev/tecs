--- JSON-RPC envelope and dispatch for the MCP server: response helpers, the
--- shared tool-handler registry, the MCP method router, and the argument
--- validation helpers every handler module shares.

local tecs <const> = require("tecs")
local json <const> = require("tecs.utils.json")
local logging <const> = require("tecs.utils.logging")
local mcpTools <const> = require("tecs2d.mcp.tools")
local debugapi <const> = require("tecs2d.debug.context")
local transport <const> = require("tecs2d.mcp.internal.transport")
local state <const> = require("tecs2d.mcp.internal.state")

local log <const> = logging.getLogger("tecs-mcp")

local record rpc
    type Handler = function(args: {string: any}, id: number)

    --- Shared tool registry: name to handler. Handler modules add their
    --- entries in install().
    handlers: {string: Handler}

    install: function(ctx: state.Context)
    processMessage: function(line: string)
    sendResponse: function(id: number, result: any)
    sendError: function(id: number | nil, code: number, message: string)
    sendToolJSON: function(id: number, payload: {string: any}, isError: boolean)
    sendToolOK: function(id: number, result: any, meta?: {string: any})
    sendToolError: function(id: number, code: string, message: string, details?: {string: any})
    requireWorld: function(id: number): tecs.World
    requireArg: function(args: {string: any}, name: string, id: number): any
end

-- JSON-RPC error codes
local ERR_PARSE <const> = -32700
local ERR_METHOD_NOT_FOUND <const> = -32601
local ERR_INVALID_PARAMS <const> = -32602
local ERR_INTERNAL <const> = -32603

rpc.handlers = {}

local ctx: state.Context = nil

-- Toggle the keep-socket-open flag for a deferred command response (the same
-- mechanism run_lua's queued op uses).
local function ctxPendingWorldOp(v: boolean)
    if ctx then ctx.pendingWorldOpResponse = v end
end

function rpc.install(c: state.Context)
    ctx = c
end

function rpc.sendResponse(id: number, result: any)
    local body = json.serialize({jsonrpc = "2.0", id = id, result = result})
    transport.sendHttpResponse(200, "OK", body)
end

function rpc.sendError(id: number | nil, code: number, message: string)
    local body = json.serialize({
        jsonrpc = "2.0",
        id = id,
        error = {code = code, message = message}
    })
    transport.sendHttpResponse(200, "OK", body)
end

function rpc.sendToolJSON(id: number, payload: {string: any}, isError: boolean)
    -- The payload rides twice: serialized text for older clients, and the
    -- same object as structuredContent for clients that consume typed
    -- results directly.
    rpc.sendResponse(id, {
        content = {{type = "text", text = json.serialize(payload)}},
        structuredContent = payload,
        isError = isError,
    })
end

function rpc.sendToolOK(id: number, result: any, meta?: {string: any})
    local payload: {string: any} = {ok = true, result = result}
    if meta then
        payload.meta = meta
    end
    rpc.sendToolJSON(id, payload, false)
end

function rpc.sendToolError(id: number, code: string, message: string, details?: {string: any})
    local err: {string: any} = {code = code, message = message}
    if details then
        err.details = details
    end
    rpc.sendToolJSON(id, {ok = false, error = err}, true)
end

--- Returns the world when initialized, otherwise reports world_unavailable
--- to the client and returns nil so the handler can early-return.
function rpc.requireWorld(id: number): tecs.World
    if ctx and ctx.world then
        return ctx.world
    end
    rpc.sendToolError(id, "world_unavailable", "World not initialized")
    return nil
end

--- Returns args[name], otherwise reports missing_parameter and returns nil
--- so the handler can early-return. Check `== nil` at the call site when
--- the argument can legitimately be false.
function rpc.requireArg(args: {string: any}, name: string, id: number): any
    local value = args[name]
    if value == nil then
        rpc.sendToolError(id, "missing_parameter", "Missing '" .. name .. "' parameter")
        return nil
    end
    return value
end

-- MCP method handlers
local function handleInitialize(id: number, params: {string:any})
    local clientVersion = type(params) == "table" and params.protocolVersion as string or "2024-11-05"
    rpc.sendResponse(id, {
        protocolVersion = clientVersion,
        capabilities = {tools = {listChanged = false}},
        serverInfo = {name = "tecs-mcp", version = "1.0.0"}
    })
end

local function handleToolsList(id: number)
    -- Compose lazily per request: the debug plugin may install (and register
    -- its commands) after the MCP server starts, in either plugin order, and
    -- games may register custom commands at any time.
    local world = ctx and ctx.world
    local derived = world and debugapi.commandTools(world)
    local toolsJSON: string
    if derived and #derived > 0 then
        local all: {any} = {}
        for i = 1, #mcpTools.list do all[#all + 1] = mcpTools.list[i] end
        for i = 1, #derived do all[#all + 1] = derived[i] end
        toolsJSON = json.serialize(all)
    else
        toolsJSON = mcpTools.toJSON()
    end
    transport.sendHttpResponse(200, "OK",
        '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"result":{"tools":' .. toolsJSON .. '}}')
end

--- Dispatch a registry-derived cmd_* tool call. Returns false when the name
--- is not a debugger command tool (so the caller reports unknown-tool).
local function callCommandTool(toolName: string, args: {string:any}, id: number): boolean
    if toolName:sub(1, 4) ~= "cmd_" then return false end
    local world = rpc.requireWorld(id)
    if not world then return true end
    local result, err = debugapi.invokeCommand(world, toolName, args)
    if not result then
        if err == "disabled" then
            rpc.sendToolError(id, "debugger_disabled",
                "Debugger tools require the debug plugin (require(\"tecs2d.debug\").new()).")
        else
            rpc.sendError(id, ERR_INVALID_PARAMS, err)
        end
        return true
    end
    if result.ok == false then
        rpc.sendToolError(id, result.code or "command_failed", result.message or "command failed")
        return true
    end
    local payload: {string: any} = {}
    if result.data then
        for k, v in pairs(result.data) do payload[k] = v end
    end
    -- Guarded: a nil assignment would delete a message field the command's
    -- data provides (cmd_context carries the overlay status line there).
    if result.message ~= nil then
        payload.message = result.message
    end
    -- A deferred command answers later (cmd_step's wait/lua form): keep the
    -- client socket open (same flag run_lua's queued op uses) and hand the
    -- command respond/fail closures bound to this request id. The immediate
    -- payload rides along as the base of the eventual response.
    if result.deferred then
        ctxPendingWorldOp(true)
        local answered = false
        local respond = function(extra: {string: any})
            if answered then return end
            answered = true
            if extra then
                for k, v in pairs(extra) do payload[k] = v end
            end
            rpc.sendToolOK(id, payload)
            ctxPendingWorldOp(false)
        end
        local failWith = function(code: string, message: string)
            if answered then return end
            answered = true
            rpc.sendToolError(id, code or "command_failed", message or "command failed")
            ctxPendingWorldOp(false)
        end
        local okd, derr = pcall(result.deferred, respond, failWith) as (boolean, any)
        if not okd and not answered then
            failWith("deferred_failed", tostring(derr))
        end
        return true
    end
    rpc.sendToolOK(id, payload)
    return true
end

local function handleToolsCall(id: number, params: {string:any})
    if type(params) ~= "table" then
        rpc.sendError(id, ERR_INVALID_PARAMS, "params must be an object")
        return
    end
    local toolName = params.name
    if type(toolName) ~= "string" then
        rpc.sendError(id, ERR_INVALID_PARAMS, "params.name must be a string")
        return
    end
    local args = (params.arguments as {string:any}) or {}
    -- Crashed mode: the world is broken, so every world-touching tool gets a
    -- clear answer instead of running against wreckage. ping still reports
    -- (with the crash marker) and get_logs still serves the ring, which
    -- holds the full traceback.
    if ctx and ctx.crashed and toolName ~= "ping" and toolName ~= "get_logs"
        and toolName ~= "send_love_event" then
        rpc.sendToolError(id, "game_crashed",
            "the game crashed and needs a restart (restart_game, or fix + "
            .. "start_game). Traceback:\n" .. ctx.crashed)
        return
    end
    local handler = rpc.handlers[toolName as string]
    if not handler then
        local ok, ret = pcall(callCommandTool, toolName as string, args, id) as (boolean, any)
        if not ok then
            local errStr = tostring(ret)
            log:error("Tool execution failed: %s", errStr)
            rpc.sendError(id, ERR_INTERNAL, "Tool execution failed: " .. errStr)
        elseif ret == false then
            rpc.sendError(id, ERR_INVALID_PARAMS, "Unknown tool: " .. tostring(toolName))
        end
        return
    end
    local ok, err = pcall(handler, args, id) as (boolean, any)
    if not ok then
        local errStr = tostring(err)
        log:error("Tool execution failed: %s", errStr)
        rpc.sendError(id, ERR_INTERNAL, "Tool execution failed: " .. errStr)
    end
end

-- Process one MCP message
function rpc.processMessage(line: string)
    local ok, msg = pcall(json.parse, line)
    if not ok then
        rpc.sendError(nil, ERR_PARSE, "Parse error")
        return
    end

    -- Valid JSON is not necessarily an object (e.g. a bare number or bool);
    -- guard before indexing so a malformed envelope can't crash the frame.
    if type(msg) ~= "table" then
        rpc.sendError(nil, ERR_PARSE, "Request must be a JSON object")
        return
    end
    local parsed = msg as {string:any}
    local method = parsed.method as string
    local id = parsed.id as number

    if method == "initialize" then
        handleInitialize(id, parsed.params as {string:any})
    elseif method == "notifications/initialized" then
        transport.sendHttpAccepted()
        return
    elseif method == "tools/list" then
        handleToolsList(id)
    elseif method == "tools/call" then
        handleToolsCall(id, parsed.params as {string:any})
    else
        rpc.sendError(id, ERR_METHOD_NOT_FOUND, "Method not found: " .. tostring(method))
    end
end

return rpc
