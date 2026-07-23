--- JSON-RPC envelope and dispatch for the MCP server: response helpers, the
--- shared tool-handler registry, the MCP method router, and the argument
--- validation helpers every handler module shares.

local tecs <const> = require("tecs")
local json <const> = require("tecs.utils.json")
local logging <const> = require("tecs.utils.logging")
local mcpTools <const> = require("tecs2d.mcp.tools")
local schema <const> = require("tecs2d.mcp.internal.schema")
local debugapi <const> = require("tecs2d.debug.context")
local transport <const> = require("tecs2d.mcp.internal.transport")
local state <const> = require("tecs2d.mcp.internal.state")

local log <const> = logging.getLogger("tecs-mcp")

local record rpc
    type Id = string | number
    type Handler = function(args: {string: any}, id: Id)

    --- Shared tool registry: name to handler. Handler modules add their
    --- entries in install().
    handlers: {string: Handler}

    install: function(ctx: state.Context)
    cleanup: function()
    processMessage: function(line: string)
    sendResponse: function(id: Id, result: any)
    sendError: function(id: Id | nil, code: number, message: string)
    sendToolJSON: function(id: Id, payload: {string: any}, isError: boolean)
    sendToolOK: function(id: Id, result: any, meta?: {string: any})
    sendToolError: function(id: Id, code: string, message: string, details?: {string: any})
    requireWorld: function(id: Id): tecs.World
    requireArg: function(args: {string: any}, name: string, id: Id): any
end

-- JSON-RPC error codes
local ERR_PARSE <const> = -32700
local ERR_INVALID_REQUEST <const> = -32600
local ERR_METHOD_NOT_FOUND <const> = -32601
local ERR_INVALID_PARAMS <const> = -32602
local ERR_INTERNAL <const> = -32603

rpc.handlers = {}

local ctx: state.Context = nil
local LATEST_PROTOCOL <const> = "2025-11-25"

function rpc.install(c: state.Context)
    ctx = c
    -- Module state survives a hot reload. Start each installation from the
    -- declared kernel surface so removed handlers cannot remain callable.
    rpc.handlers = {}
end

function rpc.cleanup()
    ctx = nil
    rpc.handlers = {}
end

function rpc.sendResponse(id: rpc.Id, result: any)
    local body = json.serialize({jsonrpc = "2.0", id = id, result = result})
    transport.sendHttpResponse(200, "OK", body)
end

function rpc.sendError(id: rpc.Id | nil, code: number, message: string)
    local body = json.serialize({
        jsonrpc = "2.0",
        id = id or json.NULL,
        error = {code = code, message = message}
    })
    transport.sendHttpResponse(200, "OK", body)
end

function rpc.sendToolJSON(id: rpc.Id, payload: {string: any}, isError: boolean)
    -- Publish the same result through MCP's text content and typed
    -- structuredContent forms.
    rpc.sendResponse(id, {
        content = {{type = "text", text = json.serialize(payload)}},
        structuredContent = payload,
        isError = isError,
    })
end

function rpc.sendToolOK(id: rpc.Id, result: any, meta?: {string: any})
    local payload: {string: any} = {ok = true, result = result}
    if meta then
        payload.meta = meta
    end
    rpc.sendToolJSON(id, payload, false)
end

function rpc.sendToolError(id: rpc.Id, code: string, message: string,
        details?: {string: any})
    local err: {string: any} = {code = code, message = message}
    if details then
        err.details = details
    end
    rpc.sendToolJSON(id, {ok = false, error = err}, true)
end

--- Returns the world when initialized, otherwise reports world_unavailable
--- to the client and returns nil so the handler can early-return.
function rpc.requireWorld(id: rpc.Id): tecs.World
    if ctx and ctx.world then
        return ctx.world
    end
    rpc.sendToolError(id, "world_unavailable", "World not initialized")
    return nil
end

--- Returns args[name], otherwise reports missing_parameter and returns nil
--- so the handler can early-return. Check `== nil` at the call site when
--- the argument can legitimately be false.
function rpc.requireArg(args: {string: any}, name: string, id: rpc.Id): any
    local value = args[name]
    if value == nil then
        rpc.sendToolError(id, "missing_parameter", "Missing '" .. name .. "' parameter")
        return nil
    end
    return value
end

-- MCP method handlers
local function handleInitialize(id: rpc.Id, params: {string:any})
    if type(params) ~= "table"
            or type(params.protocolVersion) ~= "string"
            or type(params.capabilities) ~= "table"
            or type(params.clientInfo) ~= "table" then
        rpc.sendError(id, ERR_INVALID_PARAMS,
            "initialize requires protocolVersion, capabilities, and clientInfo")
        return
    end
    rpc.sendResponse(id, {
        protocolVersion = LATEST_PROTOCOL,
        capabilities = {tools = {listChanged = false}},
        serverInfo = {name = "tecs-mcp", version = "1.0.0"}
    })
end

local function handleToolsList(id: rpc.Id)
    -- Compose lazily per request: the debug plugin may install (and register
    -- its commands) after the MCP server starts, in either plugin order, and
    -- games may register custom commands at any time.
    local world = ctx and ctx.world
    local derived = world and debugapi.commandTools(world)
    local all: {any}
    if derived and #derived > 0 then
        all = {}
        for i = 1, #mcpTools.list do all[#all + 1] = mcpTools.list[i] end
        for i = 1, #derived do all[#all + 1] = derived[i] end
    else
        all = mcpTools.list as {any}
    end
    rpc.sendResponse(id, {tools = all})
end

--- Dispatch a registry-derived cmd_* tool call. Returns false when the name
--- is not a debugger command tool (so the caller reports unknown-tool).
local function callCommandTool(toolName: string, args: {string:any},
        id: rpc.Id): boolean
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
    rpc.sendToolOK(id, payload)
    return true
end

local function handleToolsCall(id: rpc.Id, params: {string:any})
    if type(params) ~= "table" then
        rpc.sendError(id, ERR_INVALID_PARAMS, "params must be an object")
        return
    end
    local toolName = params.name
    if type(toolName) ~= "string" then
        rpc.sendError(id, ERR_INVALID_PARAMS, "params.name must be a string")
        return
    end
    if params.arguments ~= nil and type(params.arguments) ~= "table" then
        rpc.sendError(id, ERR_INVALID_PARAMS,
            "params.arguments must be an object")
        return
    end
    local args = (params.arguments as {string:any})
        or (json.EMPTY_OBJECT as {string:any})
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
    local definition = mcpTools.byName[toolName as string]
    local validationError = schema.validate(args, definition.inputSchema)
    if validationError then
        rpc.sendToolError(id, "invalid_arguments", validationError)
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
        rpc.sendError(nil, ERR_INVALID_REQUEST,
            "Request must be a JSON object")
        return
    end
    local parsed = msg as {string:any}
    if parsed.jsonrpc ~= "2.0" or type(parsed.method) ~= "string" then
        rpc.sendError(nil, ERR_INVALID_REQUEST,
            "Request must contain jsonrpc='2.0' and a string method")
        return
    end
    local method = parsed.method as string
    local rawId = parsed.id
    local id: rpc.Id = nil
    if rawId == json.NULL then
        rpc.sendError(nil, ERR_INVALID_REQUEST,
            "Request id must be a string or number")
        return
    elseif type(rawId) == "string" or type(rawId) == "number" then
        id = rawId as rpc.Id
    elseif rawId ~= nil then
        rpc.sendError(nil, ERR_INVALID_REQUEST,
            "Request id must be a string or number")
        return
    end

    -- JSON-RPC notifications have no response body. MCP's HTTP transport
    -- acknowledges them with 202 so the client can release the request.
    if id == nil then
        transport.sendHttpAccepted()
        return
    end

    if method == "initialize" then
        handleInitialize(id, parsed.params as {string:any})
    elseif method == "tools/list" then
        if parsed.params ~= nil and type(parsed.params) ~= "table" then
            rpc.sendError(id, ERR_INVALID_PARAMS,
                "tools/list params must be an object")
            return
        end
        handleToolsList(id)
    elseif method == "tools/call" then
        handleToolsCall(id, parsed.params as {string:any})
    else
        rpc.sendError(id, ERR_METHOD_NOT_FOUND, "Method not found: " .. tostring(method))
    end
end

return rpc
