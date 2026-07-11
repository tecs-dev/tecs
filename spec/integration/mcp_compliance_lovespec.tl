--- Love2D integration suite: boots the compliance fixture app under a real
--- LÖVE binary and drives it over the tecs2d MCP HTTP server.
---
--- Run via `make test-love`. Uses the *_lovespec suffix so the fast headless
--- suite (busted pattern `_spec`) never collects this file.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local mcp_client <const> = require("spec.integration.harness.mcp_client")
local love_process <const> = require("spec.integration.harness.love_process")
local png_util <const> = require("spec.integration.harness.png_util")
local json <const> = require("tecs.utils.json")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"
local LOG_DIR <const> = "build/test_deps/love_test_logs"

local STARTUP_TIMEOUT <const> = 10
local CALL_TIMEOUT <const> = 5
local SHUTDOWN_TIMEOUT <const> = 5

local loveBin <const> = os.getenv("LOVE")
-- The socket.d.tl stub types sleep as integer-only; it accepts fractions.
local sleep <const> = socket.sleep as function(number)

local function freePort(): integer
    local sock = socket.tcp()
    sock:bind("127.0.0.1", 0)
    local _, port = sock:getsockname()
    sock:close()
    return tonumber(port) as integer
end

local record App
    proc: love_process.Proc
    client: mcp_client.Client
end

local function startApp(): App
    if not loveBin or loveBin == "" then
        error("LOVE env var not set; run via `make test-love`")
    end
    os.execute("mkdir -p '" .. LOG_DIR .. "'")

    local port = freePort()
    local proc = love_process.start({
        loveBin = loveBin,
        appDir = APP_DIR,
        logPath = LOG_DIR .. "/compliance-" .. tostring(port) .. ".log",
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

local function stopApp(app: App)
    if not app then return end
    if app.proc:isRunning() then
        pcall(function() app.client:tryCall("quit", nil, 2) end)
        if not app.proc:waitExit(SHUTDOWN_TIMEOUT) then
            app.proc:stop()
        end
    end
end

--- Run Lua in the app and return the stringified return values.
local function runLua(app: App, code: string, timeout?: number): {string}
    local result = app.client:call("run_lua", {code = code}, timeout)
    return result.values as {string}
end

local function readFrames(app: App): integer
    local values = runLua(app, "return tecsTest.frames")
    return tonumber(values[1]) as integer
end

--- Poll `fn` until it returns a non-nil value or the deadline passes.
local function eventually<T>(seconds: number, fn: function(): T): T
    local deadline = socket.gettime() + seconds
    local last: T
    while socket.gettime() < deadline do
        last = fn()
        if last ~= nil then return last end
        sleep(0.05)
    end
    return last
end

--- Probe framebuffer pixels through the sample_pixels MCP tool. `points`
--- are {fx, fy} fractions of the framebuffer size; returns one {r, g, b}
--- triple (0..1) per point.
local function probePixels(app: App, points: {{number, number}}): {{number}}
    local requestPoints: {{string: number}} = {}
    for i = 1, #points do
        requestPoints[i] = {x = points[i][1], y = points[i][2]}
    end
    local result = app.client:call("sample_pixels",
        {points = requestPoints, normalized = true}, 10)
    local pixels = result.pixels as {{string: number}}
    luassert.is_table(pixels, "sample_pixels returned no pixels")

    local triples: {{number}} = {}
    for i = 1, #points do
        local pixel = pixels[i]
        triples[i] = {pixel.r, pixel.g, pixel.b}
    end
    return triples
end

describe("mcp compliance: boot and introspection", function()
    local app: App

    setup(function()
        app = startApp()
    end)

    teardown(function()
        stopApp(app)
    end)

    it("answers ping", function()
        local result = app.client:call("ping")
        luassert.is_true(result.running as boolean)
    end)

    it("reports the configured window size", function()
        local result = app.client:call("get_window_size")
        luassert.are.equal(320, result.width as number)
        luassert.are.equal(240, result.height as number)
    end)

    it("run_lua round-trips multiple return values", function()
        local values = runLua(app, "return 1 + 1, 'two'")
        luassert.are.equal("2", values[1])
        luassert.are.equal("two", values[2])
    end)

    it("tool results carry structuredContent matching the text envelope", function()
        local response = app.client:rpc("tools/call", {name = "ping", arguments = {}})
        local result = response.result as {string: any}
        local sc = result.structuredContent as {string: any}
        luassert.is_not_nil(sc, "structuredContent missing from the tool result")
        luassert.is_true(sc.ok as boolean)
        local content = result.content as {{string: any}}
        local envelope = json.parse(content[1].text as string) as {string: any}
        luassert.same(envelope, sc)
    end)

    it("sees the fixture world state", function()
        local stats = app.client:call("get_stats")
        luassert.is_true((stats.entities as number) >= 1)
        local values = runLua(app, "return world:getStats().entities")
        luassert.is_true(tonumber(values[1]) >= 1)
    end)
end)

describe("mcp compliance: pause, step, resume", function()
    local app: App

    setup(function()
        app = startApp()
    end)

    teardown(function()
        stopApp(app)
    end)

    it("pause freezes gameplay but keeps MCP responsive", function()
        app.client:call("pause")
        local before = readFrames(app)
        sleep(0.25)
        local after = readFrames(app)
        luassert.are.equal(before, after)
    end)

    it("step advances exactly the requested frames", function()
        local before = readFrames(app)
        app.client:call("step", {frames = 3})
        local stepped = eventually(CALL_TIMEOUT, function(): integer
            local frames = readFrames(app)
            if frames >= before + 3 then return frames end
            return nil
        end)
        luassert.are.equal(before + 3, stepped)
        -- Still paused afterwards: no further frames accumulate.
        sleep(0.25)
        luassert.are.equal(before + 3, readFrames(app))
    end)

    it("resume restores gameplay", function()
        local before = readFrames(app)
        app.client:call("resume")
        local advanced = eventually(CALL_TIMEOUT, function(): integer
            local frames = readFrames(app)
            if frames > before then return frames end
            return nil
        end)
        luassert.is_true(advanced ~= nil and advanced > before)
    end)
end)

describe("mcp compliance: rendering", function()
    local app: App

    setup(function()
        app = startApp()
    end)

    teardown(function()
        stopApp(app)
    end)

    it("screenshot returns a valid PNG matching the pixel dimensions", function()
        local pixelDims = runLua(app, "return love.graphics.getPixelWidth(), love.graphics.getPixelHeight()")
        local base64 = app.client:screenshot()
        local header, headerErr = png_util.parseHeader(png_util.base64Decode(base64))
        luassert.is_table(header, tostring(headerErr))
        luassert.are.equal(tonumber(pixelDims[1]), header.width)
        luassert.are.equal(tonumber(pixelDims[2]), header.height)
    end)

    it("region screenshot crops to the requested size", function()
        local base64 = app.client:screenshot({x = 0, y = 0, width = 64, height = 32})
        local header, headerErr = png_util.parseHeader(png_util.base64Decode(base64))
        luassert.is_table(header, tostring(headerErr))
        luassert.are.equal(64, header.width)
        luassert.are.equal(32, header.height)
    end)

    it("sample_pixels reports framebuffer size and clamps out-of-range points", function()
        local pixelDims = runLua(app, "return love.graphics.getPixelWidth(), love.graphics.getPixelHeight()")
        local result = app.client:call("sample_pixels",
            {points = {{x = 99999, y = 99999}}}, 10)
        local width = tonumber(pixelDims[1])
        local height = tonumber(pixelDims[2])
        luassert.are.equal(width, result.width as number)
        luassert.are.equal(height, result.height as number)
        local pixel = (result.pixels as {{string: number}})[1]
        luassert.are.equal(width - 1, pixel.x)
        luassert.are.equal(height - 1, pixel.y)
    end)

    it("renders the red center rectangle on a dark background", function()
        local probes = probePixels(app, {{0.5, 0.5}, {0.02, 0.02}})
        local center, corner = probes[1], probes[2]
        local tolerance = 0.06
        luassert.is_true(center[1] > 1 - tolerance, "center red channel: " .. tostring(center[1]))
        luassert.is_true(center[2] < tolerance, "center green channel: " .. tostring(center[2]))
        luassert.is_true(center[3] < tolerance, "center blue channel: " .. tostring(center[3]))
        luassert.is_true(corner[1] < tolerance, "corner red channel: " .. tostring(corner[1]))
        luassert.is_true(corner[2] < tolerance, "corner green channel: " .. tostring(corner[2]))
        luassert.is_true(corner[3] < tolerance, "corner blue channel: " .. tostring(corner[3]))
    end)

    it("run_lua scene changes show up in pixel probes", function()
        -- Spawn a green rect left of center (world 80,120 -> fraction 0.25, 0.5)
        -- away from the red fixture rect so no depth ordering is involved.
        runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(80, 120, 0, 1), gfx.Rectangle(60, 60), gfx.Color(0, 1, 0, 1))
            return true
        ]])
        local green = eventually(CALL_TIMEOUT, function(): {number}
            local probe = probePixels(app, {{0.25, 0.5}})[1]
            if probe[2] > 0.9 then return probe end
            return nil
        end)
        luassert.is_table(green, "probe point never turned green after run_lua spawn")
        luassert.is_true(green[1] < 0.06, "probe red channel: " .. tostring(green[1]))
    end)
end)

describe("mcp compliance: love events", function()
    local app: App

    setup(function()
        app = startApp()
    end)

    teardown(function()
        stopApp(app)
    end)

    it("send_love_event dispatches keypressed to the game", function()
        app.client:call("send_love_event", {event = "keypressed", args = {"a", "a", false}})
        local lastKey = eventually(CALL_TIMEOUT, function(): string
            local values = runLua(app, "return tecsTest.lastKey")
            if values[1] == "a" then return values[1] end
            return nil
        end)
        luassert.are.equal("a", lastKey)
    end)
end)

describe("mcp compliance: shutdown", function()
    it("quit exits the process cleanly", function()
        local app = startApp()
        app.client:tryCall("quit", nil, 2)
        local exited = app.proc:waitExit(SHUTDOWN_TIMEOUT)
        if not exited then
            app.proc:stop()
        end
        luassert.is_true(exited, "app did not exit after quit:\n" .. app.proc:readLog())
    end)
end)
