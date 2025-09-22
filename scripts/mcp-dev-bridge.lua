#!/usr/bin/env luajit
--- tecs MCP dev bridge: stdio-to-HTTP relay for tecs development.
--- Scans ports 19999-20001 to find a running game, forwards all requests.
--- End users should use {"type":"http","url":"http://localhost:19999/mcp"} instead.

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")

local BASE_PORT = tonumber(os.getenv("TECS_MCP_PORT")) or 19999
local PORT_COUNT = 3

local gameUrl = nil

local function log(msg)
    io.stderr:write("[tecs-mcp-dev-bridge] " .. msg .. "\n")
end

local function httpPost(url, body)
    local resp = {}
    local _, code = http.request({
        url = url,
        method = "POST",
        headers = {["content-type"] = "application/json", ["content-length"] = tostring(#body)},
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp),
        redirect = false,
    })
    return table.concat(resp), code
end

local function discover()
    for i = 0, PORT_COUNT - 1 do
        local port = BASE_PORT + i
        local url = "http://127.0.0.1:" .. port .. "/mcp"
        local _, code = httpPost(url, '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}')
        if code == 200 then
            log("Found game at port " .. port)
            return url
        end
    end
    return nil
end

log("Scanning ports " .. BASE_PORT .. "-" .. (BASE_PORT + PORT_COUNT - 1))

while true do
    local line = io.read("*l")
    if not line then break end

    if not gameUrl then gameUrl = discover() end

    if not gameUrl then
        -- Retry once after a short wait (game might be starting)
        socket.sleep(1)
        gameUrl = discover()
    end

    if not gameUrl then
        local id = line:match('"id"%s*:%s*(%d+)') or "null"
        io.stdout:write('{"jsonrpc":"2.0","id":' .. id .. ',"error":{"code":-32000,"message":"No game found"}}\n')
    else
        local body, code = httpPost(gameUrl, line)
        if code == 200 or code == 202 then
            if #body > 0 then io.stdout:write(body .. "\n") end
        else
            -- Game may have restarted; rediscover on next request
            gameUrl = nil
            local id = line:match('"id"%s*:%s*(%d+)') or "null"
            io.stdout:write('{"jsonrpc":"2.0","id":' .. id .. ',"error":{"code":-32000,"message":"Game unavailable"}}\n')
        end
    end
end
