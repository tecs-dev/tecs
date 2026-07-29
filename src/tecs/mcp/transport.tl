--- The SDL-thread bridge to Rust's official RMCP Streamable HTTP server.
---
--- Rust owns the listener, HTTP, sessions, protocol negotiation and JSON-RPC.
--- A bounded queue carries only engine-facing tool calls here. `poll` drains
--- one on the SDL thread, and `respond` completes the Rust task waiting for
--- it. No Rust thread ever enters LuaJIT.

local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")

local C <const> = rust.C
local LOGGER <const> = log.get("tecs.mcp")

local record transport
    --- One tool call borrowed from Rust until `respond` consumes it.
    record Request
        --- The registered, externally typed MCP tool name.
        name: string
        --- A JSON object encoded by RMCP from the call's arguments.
        arguments: string
        --- Private. Rust allocation consumed by `respond`.
        _handle: loader.CPtr
    end

    --- A loopback-only Streamable HTTP server at `/mcp`.
    record Server
        --- The TCP port bound on `127.0.0.1`.
        port: integer
        --- Private. Rust server allocation, nil after `destroy`.
        _handle: loader.CPtr
        --- Private. Set by `destroy`.
        _destroyed: boolean
        --- Private. Reused byte-count out parameter.
        _length: loader.CArray
    end
end

local ServerMT <const>: metatable<transport.Server> = {__index = transport.Server}

local function reason(): string
    return loader.toString(C.tecsRustError())
end

local function requestBytes(self: transport.Server, request: loader.CPtr, read: loader.CValue): string
    self._length[0] = 0
    local bytes <const> = read(request, self._length)
    return loader.toBytes(bytes, tonumber(self._length[0]) as integer)
end

--- Starts RMCP at `http://127.0.0.1:<port>/mcp`.
---
--- `toolsJSON` is a snapshot of the dynamic Lua registry. Later registrations
--- are sent through `setTools`.
function transport.listen(port: integer, toolsJSON: string): transport.Server
    local handle <const> = C.tecsMcpServerCreate(port, toolsJSON, #toolsJSON) as loader.CPtr
    if handle == nil then
        error(("tecs: cannot listen on port %d: %s"):format(port, reason()), 2)
    end
    local self = setmetatable({} as transport.Server, ServerMT)
    self.port = port
    self._handle = handle
    self._destroyed = false
    self._length = loader.newArray("size_t[1]")
    LOGGER:info("listening at http://127.0.0.1:%d/mcp", port)
    return self
end

--- Replaces the tool descriptions served by RMCP.
function transport.Server:setTools(toolsJSON: string)
    if self._destroyed then
        return
    end
    if not C.tecsMcpServerSetTools(self._handle, toolsJSON, #toolsJSON) then
        error("tecs: cannot update MCP tools: " .. reason(), 2)
    end
end

--- Takes and handles at most one queued tool call without waiting.
---
--- Protocol-only traffic, including initialize and tools/list, never crosses
--- this boundary and therefore does not make `poll` answer true.
function transport.Server:poll(handler: function(transport.Request)): boolean
    if self._destroyed then
        return false
    end
    local handle <const> = C.tecsMcpServerNext(self._handle) as loader.CPtr
    if handle == nil then
        return false
    end
    local request: transport.Request = {
        name = requestBytes(self, handle, C.tecsMcpRequestName),
        arguments = requestBytes(self, handle, C.tecsMcpRequestArguments),
        _handle = handle,
    }
    local ok, failure = pcall(handler, request) as (boolean, any)
    if not ok and request._handle ~= nil then
        local message <const> = tostring(failure)
        C.tecsMcpRequestRespond(request._handle, message, #message, true, false)
        request._handle = nil
    end
    if not ok then
        LOGGER:error("tool dispatch failed: %s", tostring(failure))
    end
    return true
end

--- Completes a queued tool call and consumes its Rust request allocation.
function transport.Server:respond(request: transport.Request, payload: string, isError: boolean, crashed: boolean)
    if request._handle == nil then
        return
    end
    C.tecsMcpRequestRespond(request._handle, payload, #payload, isError, crashed)
    request._handle = nil
end

--- Releases the server. Safe to call repeatedly.
function transport.Server:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.tecsMcpServerDestroy(self._handle)
    self._handle = nil
end

return transport
