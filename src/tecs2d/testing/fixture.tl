--- Shared boot/drive helpers for Love2D integration specs: starts a fixture
--- app under a real LÖVE binary on a free port, hands back an MCP client,
--- and provides the common probe utilities (run_lua, pixel sampling,
--- eventually-polling).

local socket <const> = require("socket")
local mcp_client <const> = require("tecs2d.testing.mcp_client")
local love_process <const> = require("tecs2d.testing.love_process")

local LOG_DIR <const> = "build/test_deps/love_test_logs"
local STARTUP_TIMEOUT <const> = 10
local CALL_TIMEOUT <const> = 5
local SHUTDOWN_TIMEOUT <const> = 5

-- The socket.d.tl stub types sleep as integer-only; it accepts fractions.
local sleep <const> = socket.sleep as function(number)

local record fixture
    record App
        proc: love_process.Proc
        client: mcp_client.Client
    end

    callTimeout: number

    start: function(appDir: string): App
    stop: function(app: App)
    runLua: function(app: App, code: string, timeout?: number): {string}
    probePixels: function(app: App, points: {{number, number}}): {{number}}
    --- Poll `fn` until it returns a truthy value or the deadline passes;
    --- returns the last value either way. Return nil or false from the poll
    --- while waiting.
    eventually: function<T>(seconds: number, fn: function(): T): T
end

fixture.callTimeout = CALL_TIMEOUT

local function freePort(): integer
    local sock = socket.tcp()
    sock:bind("127.0.0.1", 0)
    local _, port = sock:getsockname()
    sock:close()
    return tonumber(port) as integer
end

function fixture.start(appDir: string): fixture.App
    local loveBin = os.getenv("LOVE")
    if not loveBin or loveBin == "" then
        error("LOVE env var not set; run via `make test-love`")
    end
    os.execute("mkdir -p '" .. LOG_DIR .. "'")

    local appName = appDir:match("([^/]+)/?$") or "app"
    local port = freePort()
    local proc = love_process.start({
        loveBin = loveBin,
        appDir = appDir,
        logPath = LOG_DIR .. "/" .. appName .. "-" .. tostring(port) .. ".log",
        env = {
            TECS_MCP_PORT = tostring(port),
            -- On macOS, run as a background app: the window opens without
            -- stealing focus from whatever the developer is doing. Rendering
            -- and screenshot capture are unaffected. Ignored on other OSes.
            SDL_MAC_BACKGROUND_APP = "1",
        },
    })
    local client = mcp_client.new({port = port, timeout = CALL_TIMEOUT})

    local ready, readyErr = client:waitReady(STARTUP_TIMEOUT)
    if not ready then
        proc:stop()
        error("fixture app never became ready: " .. tostring(readyErr) ..
            "\n--- app output ---\n" .. proc:readLog())
    end
    return {proc = proc, client = client}
end

function fixture.stop(app: fixture.App)
    if not app then return end
    if app.proc:isRunning() then
        pcall(function() app.client:tryCall("cmd_quit", nil, 2) end)
        if not app.proc:waitExit(SHUTDOWN_TIMEOUT) then
            app.proc:stop()
        end
    end
end

--- Run Lua in the app and return the stringified return values. (The run_lua
--- tool returns JSON by default; the fixture requests the Lua form so specs keep
--- getting plain strings. Call the tool directly with lua=false for JSON.)
function fixture.runLua(app: fixture.App, code: string, timeout?: number): {string}
    local result = app.client:call("run_lua", {code = code, lua = true}, timeout)
    return result.values as {string}
end

--- Probe framebuffer pixels through the sample_pixels MCP tool. `points`
--- are {fx, fy} fractions of the framebuffer size; returns one {r, g, b}
--- triple (0..1) per point.
function fixture.probePixels(app: fixture.App, points: {{number, number}}): {{number}}
    local requestPoints: {{string: number}} = {}
    for i = 1, #points do
        requestPoints[i] = {x = points[i][1], y = points[i][2]}
    end
    local result = app.client:call("sample_pixels",
        {points = requestPoints, normalized = true}, 10)
    local pixels = result.pixels as {{string: number}}
    if pixels is nil then
        error("sample_pixels returned no pixels")
    end

    local triples: {{number}} = {}
    for i = 1, #points do
        local pixel = pixels[i]
        triples[i] = {pixel.r, pixel.g, pixel.b}
    end
    return triples
end

--- Poll `fn` until it returns a non-nil value or the deadline passes.
function fixture.eventually<T>(seconds: number, fn: function(): T): T
    local deadline = socket.gettime() + seconds
    local last: T
    while socket.gettime() < deadline do
        last = fn()
        -- Truthy, not just non-nil: a poll written as `return cond` yields
        -- false while waiting, and returning that on the first poll (as the
        -- old non-nil check did) failed the test before the game advanced.
        if last then return last end
        sleep(0.05)
    end
    return last
end

return fixture
