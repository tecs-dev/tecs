--[=[
MCP debug server and tool registry.

## Server lifecycle

Set `Application.Config.mcpPort` for the built-in server. A custom host can
call `listen`, call `Server:poll` once per frame, and call
`Server:destroy` at teardown. The listener accepts loopback connections only.
Each call to `poll` runs at most one queued handler. The handler sees a
committed world, but it must return quickly because the frame cannot end until
it does.

## Custom tools

```teal
local placed <const> = world:query({include = {tecs.Transform}})

tecs.mcp.register({
    name = "placed_count",
    description = "Count entities that carry a Transform",
    inputSchema = {["type"] = "object", properties = {}},
    readOnly = true,
    handler = function(_arguments: {string: any}): {string: any}
        return {count = placed:count()}
    end,
})
```

The registry produces both the advertised tool list and dispatch table. Tool
handlers can use the world captured when the game registers them.

## World inspection

Start with `components_info`, `query`, and `info`. Use `modify` for a partial
component update and `set` for a complete value or a missing component.
`modify` skips entities without the component and marks changed columns dirty.
Prefer these structured tools to `run_lua`; the Lua sandbox limits accidents
but does not create a security boundary.

## Crash access

The server keeps polling after an uncaught gameplay error. `ping`, `context`,
`get_logs`, and `send_event` remain available; tools that touch the world
report the stored traceback instead.
]=]
-- Implementation details:
-- The Rust RMCP service owns HTTP, sessions, JSON-RPC, and SSE. Tool calls
-- cross a bounded queue of 64 entries and return through one-shot reply
-- channels. `poll` is the only path from that queue into Lua, so protocol
-- workers never enter LuaJIT.

local data <const> = require("tecs.data")
local log <const> = require("tecs.log")
local transport <const> = require("tecs.mcp.transport")

local LOGGER <const> = log.get("tecs.mcp")

--- JSON-RPC error codes used by the socket-free compatibility dispatcher.
local PARSE_ERROR <const> = -32700
local INVALID_REQUEST <const> = -32600
local METHOD_NOT_FOUND <const> = -32601

local record mcp
    --- Defines the decoded arguments a tool receives and the structured
    --- content it returns.
    type Handler = function(arguments: {string: any}): {string: any}

    --- Describes one registered tool and its handler.
    record Tool
        --- Caller-writable. This is the name an agent calls and the registry
        --- key. Established MCP tool names follow the protocol ecosystem's
        --- spelling, including `run_lua` and `send_event`, so they use
        --- snake_case where the rest of this tree uses camelCase. This
        --- Do not rename this compatibility surface. Required.
        name: string
        --- Caller-writable. This is one line shown to the agent alongside the
        --- name. Optional; nil is sent as an empty string rather than omitted.
        description: string
        --- Caller-writable. This JSON Schema describes the arguments and is
        --- sent verbatim in the tool list.
        inputSchema: {string: any}
        --- Caller-writable. This handler runs synchronously inside `poll`.
        --- Required; its absence raises at registration rather than at call
        --- time.
        handler: Handler
        --- Caller-writable. This declares whether the tool only reads state so
        --- an agent can judge a call before making it.
        readOnly: boolean
        --- Caller-writable. This declares whether a call changes state that a
        --- caller would not want changed without asking. Optional, false when
        --- nil. Advisory, like
        --- `readOnly`: the server reports both values to the agent and enforces
        --- neither, so a tool declared read-only may still write.
        destructive: boolean
        --- Caller-writable. This allows the tool to remain callable after the
        --- game has crashed. False by default,
        --- because a crashed world cannot answer anything about itself, and a
        --- tool that read it would return nonsense rather than an error.
        whenCrashed: boolean
    end

    --- Represents a listening MCP endpoint. It answers only while something
    --- calls `poll`.
    record Server
        --- Read-only. This is the bound TCP port, which is 7100 when `listen`
        --- was given none.
        port: integer
        --- Engine-owned. Stores the server transport. Ordinary game code
        --- should ignore this field.
        _transport: transport.Server
        --- Engine-owned. Stores the last encoded tool registry. Ordinary game
        --- code should ignore this field.
        _toolsJSON: string
        --- Engine-owned. Reports whether `destroy` has stopped the server.
        --- Ordinary game code should ignore this field.
        _destroyed: boolean
    end
end

local ServerMT <const>: metatable<mcp.Server> = {__index = mcp.Server}

local tools <const>: {string: mcp.Tool} = {}
local order <const>: {string} = {}

--- Traceback of a gameplay crash, once one has happened.
---
--- The server outliving the game is the point. An agent that was debugging
--- something up to the moment it broke should get the reason, not a refused
--- connection, and the tools that do not touch the world keep working so it
--- can still read the log and ask what the build was.
local crashed: string = nil

--- Records a crash. Every subsequent world-touching call reports it.
---
--- @param traceback Stored as given and handed back verbatim by `crashed`,
---     and sent as the whole body of the error a blocked tool answers with.
---     Passing nil clears the crashed state and lets every tool run again.
function mcp.setCrashed(traceback: string)
    crashed = traceback
end

--- Returns the crash traceback, or nil while the game is healthy.
---
--- @return nil means no code has recorded a crash. Nothing here polls the game
---     to confirm that it remains healthy.
function mcp.crashed(): string
    return crashed
end

--- Registers a tool. Re-registering a name replaces it.
---
--- Replacing keeps the name's original position in the list, so the order a
--- client sees is first-registration order rather than last.
---
--- @param tool Stored by reference and never copied, so mutating the table
---     afterwards changes what the server dispatches and reports. `name` and
---     The call requires `name` and `handler` and raises when either is absent;
---     the rest may be nil.
function mcp.register(tool: mcp.Tool)
    if tool.name == nil or tool.handler == nil then
        error("tecs: a tool needs a name and a handler", 2)
    end
    if tools[tool.name] == nil then
        order[#order + 1] = tool.name
    end
    tools[tool.name] = tool
end

--- Returns every registered tool in registration order.
---
--- @return A fresh list each call, so the caller may keep it. The
---     [`Tool`](tealdoc:tecs.mcp.Tool)
---     values in it are the registered tables themselves rather than copies,
---     so writing to one writes to the registry.
function mcp.tools(): {mcp.Tool}
    local list: {mcp.Tool} = {}
    for index = 1, #order do
        list[index] = tools[order[index]]
    end
    return list
end

--- The tool list as MCP describes it.
local function describe(): {any}
    local list: {any} = {}
    for _, tool in ipairs(mcp.tools()) do
        list[#list + 1] = {
            name = tool.name,
            description = tool.description or "",
            inputSchema = tool.inputSchema or {type = "object", properties = data.empty_array},
            annotations = {
                readOnlyHint = tool.readOnly == true,
                destructiveHint = tool.destructive == true,
                --- Not an MCP annotation; ours, so an agent can tell which
                --- tools remain after a crash without calling them.
                whenCrashedHint = tool.whenCrashed == true,
            },
        }
    end
    -- An empty list has to say so, or it encodes as an object and a client
    -- parsing it strictly rejects the response.
    if #list == 0 then
        return data.empty_array as {any}
    end
    return list
end

local function reply(id: any, result: {string: any}): string
    return data.encodeJSON({jsonrpc = "2.0", id = id, result = result})
end

local function fail(id: any, code: integer, message: string): string
    return data.encodeJSON(
        {
            jsonrpc = "2.0",
            id = id,
            error = {code = code, message = message},
        }
    )
end

--- Runs one JSON-RPC request and returns the response text.
---
--- Lets tests exercise the protocol without a socket, which covers most of
--- the failure surface.
---
--- The three methods answered, `initialize`, `tools/list` and `tools/call`,
--- use the names from the MCP specification, which this tree must not
--- rename. Anything else is a method-not-found error.
---
--- When a handler raises, the server sets `isError` for the agent and
--- continues. A handler may return nil, which produces an empty
--- `structuredContent`.
---
--- @param text One JSON-RPC request object. The server does not support a
---     batch, which decodes as a JSON array with no `method` and produces an
---     invalid-request error rather than dispatching each element.
--- @return Always a response as JSON text, never nil, and never a raise, since
---     the response reports bad input in-band. The server still answers a
---     request with no `id`, omitting the `id` field from the response.
function mcp.dispatch(text: string): string
    local ok, decoded = pcall(data.decodeJSON, text)
    if not ok then
        return fail(data.null, PARSE_ERROR, "invalid JSON")
    end

    local request = decoded as {string: any}
    local id = request.id
    local method = request.method as string
    if method == nil then
        return fail(id, INVALID_REQUEST, "no method")
    end

    if method == "initialize" then
        return reply(
            id,
            {
                protocolVersion = "2025-06-18",
                capabilities = {tools = {}},
                serverInfo = {name = "tecs", version = "0.1.0"},
            }
        )
    elseif method == "tools/list" then
        return reply(id, {tools = describe()})
    elseif method == "tools/call" then
        local params = (request.params or {}) as {string: any}
        local name = params.name as string
        local tool = name ~= nil and tools[name] or nil
        if tool == nil then
            return fail(id, METHOD_NOT_FOUND, ("no tool named '%s'"):format(tostring(name)))
        end

        if crashed ~= nil and not tool.whenCrashed then
            return reply(
                id,
                {
                    isError = true,
                    crashed = true,
                    content = {{type = "text", text = crashed}},
                }
            )
        end

        local arguments = (params.arguments or {}) as {string: any}
        -- A tool that raises must not take the server with it: the agent is
        -- told, the frame carries on.
        local called, payload = pcall(tool.handler, arguments)
        if not called then
            LOGGER:warn("tool %s failed: %s", name, tostring(payload))
            return reply(
                id,
                {
                    isError = true,
                    content = {{type = "text", text = tostring(payload)}},
                }
            )
        end

        local structured = (payload or {}) as {string: any}
        return reply(
            id,
            {
                structuredContent = structured,
                content = {{type = "text", text = data.encodeJSON(structured)}},
            }
        )
    end

    return fail(id, METHOD_NOT_FOUND, ("no method '%s'"):format(method))
end

--- Starts the server on `port`.
---
--- @param port Defaults to 7100. A port already in use raises rather than
---     selecting another port, since a debugger could not find a moved server.
--- @return Listening, but answering nothing until something calls `poll`.
function mcp.listen(port?: integer): mcp.Server
    local self = setmetatable({} as mcp.Server, ServerMT)
    self.port = port or 7100
    self._toolsJSON = data.encodeJSON(describe())
    self._transport = transport.listen(self.port, self._toolsJSON)
    self._destroyed = false
    return self
end

--- Answers at most one tool call. Call once per frame.
---
--- @return True when one tool handler ran. Protocol-only traffic does not
---     count. False when no tool call is waiting or after destruction.
function mcp.Server:poll(): boolean
    if self._destroyed then
        return false
    end
    -- Tool tables are stored by reference, so a caller may mutate one without
    -- going back through `register`. Comparing the encoded registry preserves
    -- that contract for the Rust-side list.
    local toolsJSON <const> = data.encodeJSON(describe())
    if self._toolsJSON ~= toolsJSON then
        self._transport:setTools(toolsJSON)
        self._toolsJSON = toolsJSON
    end
    return self._transport:poll(
        function(request: transport.Request)
            local tool <const> = tools[request.name]
            if tool == nil then
                self._transport:respond(request, "no tool named '" .. request.name .. "'", true, false)
                return
            end

            if crashed ~= nil and not tool.whenCrashed then
                self._transport:respond(request, crashed, true, true)
                return
            end

            local decoded, arguments = pcall(data.decodeJSON, request.arguments)
            if not decoded then
                self._transport:respond(request, "invalid tool arguments", true, false)
                return
            end
            local called, payload = pcall(tool.handler, arguments as {string: any})
            if not called then
                LOGGER:warn("tool %s failed: %s", request.name, tostring(payload))
                self._transport:respond(request, tostring(payload), true, false)
                return
            end
            self._transport:respond(request, data.encodeJSON(payload or {}), false, false)
        end
    )
end

--- Releases the server. Safe to call more than once.
---
--- One way: the port is given up and the server cannot be made to listen
--- again. The tool registry is module-wide and is left untouched, so a later
--- `listen` answers the same tools.
function mcp.Server:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self._transport:destroy()
end

return mcp
