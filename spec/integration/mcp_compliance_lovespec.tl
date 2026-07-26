--- Love2D integration suite: boots the compliance fixture app under a real
--- Love binary and drives it over the tecs2d MCP HTTP server.
---
--- Run via `make test-love`. Uses the *_lovespec suffix so the fast headless
--- suite (busted pattern `_spec`) never collects this file.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local mcp_client <const> = require("tecs.testing.mcp_client")
local love_process <const> = require("tecs.testing.love_process")
local png_util <const> = require("tecs.testing.png_util")
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
        pcall(function() app.client:tryCall("cmd_quit", nil, 2) end)
        if not app.proc:waitExit(SHUTDOWN_TIMEOUT) then
            app.proc:stop()
        end
    end
end

--- Run Lua in the app and return the stringified return values (the run_lua
--- tool returns JSON by default; pass lua=true for the tostring form).
local function runLua(app: App, code: string, timeout?: number): {string}
    local result = app.client:call("run_lua", {code = code, lua = true}, timeout)
    return result.values as {string}
end

local function readFrames(app: App): integer
    local values = runLua(app, "return tecsTest.frames")
    return tonumber(values[1]) as integer
end

local function setSuspended(app: App, suspended: boolean)
    local action = suspended and "suspend" or "resume"
    runLua(app, "require('tecs.internal.suspension').ensure(world):"
        .. action .. "('spec') return true")
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
        local size = runLua(app, "return love.graphics.getWidth(), love.graphics.getHeight()")
        luassert.are.equal(320, tonumber(size[1]))
        luassert.are.equal(240, tonumber(size[2]))
    end)

    it("run_lua round-trips multiple return values", function()
        local values = runLua(app, "return 1 + 1, 'two'")
        luassert.are.equal("2", values[1])
        luassert.are.equal("two", values[2])
    end)

    it("run_lua returns JSON values by default", function()
        local result = app.client:call("run_lua", {code = "return {count = 3, tag = 'ok'}"})
        local values = result.values as {any}
        local first = values[1] as {string: any}
        luassert.are.equal(3, first.count as number)
        luassert.are.equal("ok", first.tag as string)
    end)

    it("run_lua sandboxes the filesystem, network, and module loading", function()
        -- love2d and the ECS world stay reachable.
        luassert.are.equal("table", runLua(app, "return type(love.graphics)")[1])
        luassert.are.equal("true",
            runLua(app, "return tostring(require('tecs.gfx') ~= nil)")[1])
        -- Filesystem and process escape hatches are gone from the environment.
        luassert.are.equal("nil", runLua(app, "return type(io)")[1])
        luassert.are.equal("nil", runLua(app, "return type(os.execute)")[1])
        luassert.are.equal("nil", runLua(app, "return type(load)")[1])
        luassert.are.equal("nil", runLua(app, "return type(package)")[1])
        -- os keeps its harmless clock functions.
        luassert.are.equal("function", runLua(app, "return type(os.time)")[1])
        -- require refuses non-framework and process/network/fs subtree modules.
        luassert.are.equal("false", runLua(app, "return tostring((pcall(require, 'io')))")[1])
        luassert.are.equal("false", runLua(app, "return tostring((pcall(require, 'ffi')))")[1])
        luassert.are.equal("false",
            runLua(app, "return tostring((pcall(require, 'tecs.testing.love_process')))")[1])
        -- love escape hatches are stripped, but ordinary love APIs remain.
        luassert.are.equal("nil", runLua(app, "return type(love.thread)")[1])
        luassert.are.equal("nil", runLua(app, "return type(love.filesystem.load)")[1])
        luassert.are.equal("nil", runLua(app, "return type(love.filesystem.mount)")[1])
        luassert.are.equal("nil", runLua(app, "return type(love.filesystem.setRequirePath)")[1])
        luassert.are.equal("nil", runLua(app, "return type(love.system.openURL)")[1])
        luassert.are.equal("nil", runLua(app, "return type(love.event.quit)")[1])
        luassert.are.equal("function", runLua(app, "return type(love.filesystem.read)")[1])
        luassert.are.equal("function", runLua(app, "return type(love.graphics.getWidth)")[1])
    end)

    it("run_lua allows save-dir data writes but refuses code files", function()
        -- Save-directory writes are confined by PhysFS and legitimately useful
        -- (test fixtures, generated assets)...
        luassert.are.equal("true", runLua(app,
            "return tostring(love.filesystem.write('sandbox_probe.bin', 'ok'))")[1])
        luassert.are.equal("ok", runLua(app,
            "return love.filesystem.read('sandbox_probe.bin')")[1])
        luassert.are.equal("true", runLua(app,
            "return tostring(love.filesystem.remove('sandbox_probe.bin'))")[1])
        -- ...but the save dir shadows the source on the require path, so a
        -- written .lua/.tl would execute under the real globals on the next
        -- require. Those paths are refused.
        luassert.are.equal("false", runLua(app,
            "return tostring((pcall(love.filesystem.write, 'evil.lua', 'x')))")[1])
        luassert.are.equal("false", runLua(app,
            "return tostring((pcall(love.filesystem.write, 'sub/EVIL.LUA', 'x')))")[1])
        luassert.are.equal("false", runLua(app,
            "return tostring((pcall(love.filesystem.append, 'evil.tl', 'x')))")[1])
        luassert.are.equal("false", runLua(app,
            "return tostring((pcall(love.filesystem.newFile, 'evil.lua', 'w')))")[1])
    end)

    it("run_lua state persists across calls and _G is the sandbox env", function()
        -- One sandbox environment per process: bare and _G assignments are a
        -- deliberate cross-call stash for multi-step debugging sessions.
        runLua(app, "_G.sandboxStash = 41 bareStash = 1 return true")
        luassert.are.equal("42", runLua(app,
            "return _G.sandboxStash + bareStash")[1])
        luassert.are.equal("42", runLua(app,
            "return sandboxStash + _G.bareStash")[1])
        runLua(app, "_G.sandboxStash = nil bareStash = nil return true")
        -- _G is the sandbox env, not the real global table: denied globals
        -- stay nil through it, and the real _G gained nothing.
        luassert.are.equal("nil", runLua(app, "return type(_G.io)")[1])
        luassert.are.equal("nil", runLua(app, "return type(_G.package)")[1])
        luassert.are.equal("false", runLua(app,
            "return tostring(getmetatable(_G))")[1])
    end)

    it("run_lua modules() reaches loaded game modules but not sealed roots", function()
        -- A loaded framework module resolves live (usable, not a copy).
        luassert.are.equal("table", runLua(app, "return type(modules('tecs.utils.json'))")[1])
        luassert.are.equal("true",
            runLua(app, "return tostring(modules('tecs.utils.json') == require('tecs.utils.json'))")[1])
        -- Sealed roots and the tooling subtrees are refused.
        luassert.are.equal("false", runLua(app, "return tostring((pcall(modules, 'io')))")[1])
        luassert.are.equal("false", runLua(app, "return tostring((pcall(modules, 'package')))")[1])
        luassert.are.equal("false", runLua(app, "return tostring((pcall(modules, 'socket')))")[1])
        luassert.are.equal("false",
            runLua(app, "return tostring((pcall(modules, 'tecs.debug.commands')))")[1])
        -- Never-loaded modules do not load on demand.
        luassert.are.equal("false",
            runLua(app, "return tostring((pcall(modules, 'spec.never.loaded')))")[1])
    end)

    it("snapshots capture and restore love.math random state", function()
        -- Draw after a snapshot, restore, draw again: identical values mean
        -- the RNG state travelled with the snapshot (the replay prerequisite).
        local same = runLua(app, [[
            love.math.setRandomSeed(9942)
            local snap = world:saveSnapshot()
            local a = love.math.random()
            world:loadSnapshot(snap.data or snap)
            local b = love.math.random()
            return tostring(a == b)
        ]], 10)
        luassert.are.equal("true", same[1])
    end)

    it("cmd_resources reads a named resource end to end", function()
        -- Create a named key and set a resource from inside the game...
        runLua(app, "world.resources[require('tecs').newKey('compliance.state')] = {hp = 7}")
        -- ...then read it back by name through the command tool.
        local result = app.client:call("cmd_resources", {name = "compliance.state"})
        luassert.is_true(result.set as boolean, "cmd_resources value read failed")
        luassert.are.equal(7, (result.value as {string: any}).hp as number)
        luassert.are.equal("compliance.state", result.key as string)
    end)

    it("tool results carry structuredContent matching the text envelope", function()
        local response = app.client:rpc("tools/call",
            {name = "ping", arguments = json.EMPTY_OBJECT})
        local result = response.result as {string: any}
        local sc = result.structuredContent as {string: any}
        luassert.is_not_nil(sc, "structuredContent missing from the tool result")
        luassert.is_true(sc.ok as boolean)
        local content = result.content as {{string: any}}
        local envelope = json.parse(content[1].text as string) as {string: any}
        luassert.same(envelope, sc)
    end)

    it("tools/list declares safety annotations", function()
        local response = app.client:rpc("tools/list", {})
        local tools = (response.result as {string: any}).tools as {{string: any}}
        local found: {string: {string: any}} = {}
        for _, t in ipairs(tools) do
            found[t.name as string] = t.annotations as {string: any}
        end
        luassert.is_true(found.ping.readOnlyHint as boolean)
        luassert.is_true(found.cmd_context.readOnlyHint as boolean)
        luassert.is_false(found.cmd_context.destructiveHint as boolean)
        luassert.is_true(found.cmd_despawn.destructiveHint as boolean)
        for _, removed in ipairs({"cmd_fetch", "cmd_capabilities", "cmd_describe",
                "cmd_freeze", "cmd_stats", "cmd_exit",
                "cmd_camera_world", "cmd_camera_screen", "cmd_diff_get",
                "cmd_lua_modules", "cmd_lua_exports", "cmd_lua_eval",
                "cmd_bundles_list", "cmd_bundles_spawn",
                "cmd_states_push", "cmd_states_pop"}) do
            luassert.is_nil(found[removed], removed .. " should not be advertised")
        end
    end)

    it("sees the fixture world state", function()
        local values = runLua(app, "return world:getStats().entities")
        luassert.is_true(tonumber(values[1]) >= 1)
    end)
end)

describe("mcp compliance: suspended step and input tape", function()
    local app: App

    setup(function()
        app = startApp()
        setSuspended(app, true)
    end)

    teardown(function()
        stopApp(app)
    end)

    it("suspension stops gameplay but keeps MCP responsive", function()
        local before = readFrames(app)
        sleep(0.25)
        local after = readFrames(app)
        luassert.are.equal(before, after)
    end)

    it("step advances exactly the requested frames", function()
        local before = readFrames(app)
        app.client:call("cmd_step", {n = 3})
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

    it("stepped frames carry a deterministic 1/fps dt", function()
        -- Stepped frames must NOT carry the measured display-rate dt (1/120 on
        -- a ProMotion Mac), or `step n` means different gameplay time on
        -- different machines. Contract: dt = 1/fps, overridable per call.
        runLua(app, "tecsTest.dtSum = 0 tecsTest.fixedTicks = 0 return true")
        local res = app.client:call("cmd_step", {n = 6})
        luassert.is_true(math.abs((res.step_dt as number) - 1 / 60) < 1e-9,
            "step must echo the effective per-frame dt")
        local ticks = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.fixedTicks")[1]) as integer
            if n >= 6 then return n end
            return nil
        end)
        luassert.are.equal(6, ticks,
            "6 stepped frames at 1/60 dt must produce exactly 6 fixed ticks")
        local sum = tonumber(runLua(app, "return tecsTest.dtSum")[1])
        luassert.is_true(math.abs(sum - 6 / 60) < 1e-9,
            "6 stepped frames must advance exactly 0.1 gameplay seconds, got " .. tostring(sum))

        -- dt= overrides the per-frame dt for this step only.
        runLua(app, "tecsTest.dtSum = 0 tecsTest.fixedTicks = 0 return true")
        local res2 = app.client:call("cmd_step", {n = 2, dt = 0.05})
        luassert.is_true(math.abs((res2.step_dt as number) - 0.05) < 1e-9)
        local ticks2 = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.fixedTicks")[1]) as integer
            if n >= 6 then return n end
            return nil
        end)
        luassert.are.equal(6, ticks2,
            "2 frames of 0.05s are 6 fixed ticks at the 1/60 timestep")
        local sum2 = tonumber(runLua(app, "return tecsTest.dtSum")[1])
        luassert.is_true(math.abs(sum2 - 0.1) < 1e-9,
            "override dt must be carried verbatim, got " .. tostring(sum2))
    end)

    it("send_love_event reaches the Update edge while unfrozen", function()
        -- The old raw love.event.push landed mid-frame with un-defaulted args
        -- (nil scancode), so the latch never set and the edge silently missed.
        -- Routed through the tape it must be consumed on the next live frame,
        -- even in the short-args form.
        local upBefore = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
        setSuspended(app, false)
        local res = app.client:call("send_love_event",
            {event = "keypressed", args = {"up"}})
        luassert.matches("input tape", res.dispatch as string)
        local seen = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
            if n > upBefore then return n end
            return nil
        end)
        luassert.is_true(seen ~= nil and seen > upBefore,
            "unfrozen send_love_event edge never consumed")
        app.client:call("send_love_event", {event = "keyreleased", args = {"up"}})
        setSuspended(app, true)
    end)

    it("a scripted program fires inside the stepped frame's input snapshot", function()
        -- A keypressed/keyreleased pair as a program on the frame clock, then
        -- step across it. The fixture's Update probe counts frames where
        -- input.isKeyPressed("up") was true: it must be exactly one, and the
        -- Tecs KeyPressed event must have fired (lastKey).
        local upBefore = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
        local played = app.client:call("cmd_program_play", {
            clock = "frame",
            steps = {
                {op = "input", event = "keypressed", args = {"up"}},
                {op = "waitSteps", steps = 1},
                {op = "input", event = "keyreleased", args = {"up"}},
            },
        })
        luassert.are.equal(3, played.steps as integer)

        app.client:call("cmd_step", {n = 3})

        local sawUp = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
            if n > upBefore then return n end
            return nil
        end)
        luassert.are.equal(upBefore + 1, sawUp,
            "isKeyPressed must be true for exactly the one stepped frame")
        luassert.are.equal("up", runLua(app, "return tecsTest.lastKey")[1])
        -- The FixedUpdate-phase poll sees the latched edge too: both polling
        -- styles work, in their consuming phase.
        luassert.is_true(tonumber(runLua(app, "return tecsTest.upFixedFrames")[1]) >= 1,
            "FixedUpdate-phase isKeyPressed must see the latched press")

        -- The release step ran too, so the program is done and the context
        -- report shows nothing left held.
        local status = app.client:call("cmd_program_status", {handle = played.handle})
        luassert.are.equal("completed", status.state as string)

        local ctx = app.client:call("cmd_context", {})
        local scripted = ctx.input as {string: any}
        luassert.is_not_nil(scripted, "cmd_context should report scripted input state")
        luassert.are.equal(0, #(scripted.held as {string}))
    end)

    it("a program refuses a step it cannot express", function()
        local pad = app.client:tryCall("cmd_program_play", {
            steps = {{op = "nonsense"}},
        })
        luassert.is_false(pad.ok as boolean, "an unknown op must be refused")
    end)

    it("releasing suspension restores gameplay", function()
        local before = readFrames(app)
        setSuspended(app, false)
        local advanced = eventually(CALL_TIMEOUT, function(): integer
            local frames = readFrames(app)
            if frames > before then return frames end
            return nil
        end)
        luassert.is_true(advanced ~= nil and advanced > before)
    end)
end)

describe("mcp compliance: boot frozen", function()
    it("TECS_BOOT_FROZEN holds the game at frame zero and permits stepping", function()
        local port = freePort()
        local proc = love_process.start({
            loveBin = loveBin,
            appDir = APP_DIR,
            logPath = LOG_DIR .. "/compliance-frozen-" .. tostring(port) .. ".log",
            env = {
                TECS_MCP_PORT = tostring(port),
                TECS_BOOT_FROZEN = "1",
                SDL_MAC_BACKGROUND_APP = "1",
            },
        })
        local client = mcp_client.new({port = port, timeout = CALL_TIMEOUT})
        local app: App = {proc = proc, client = client}
        local ready = client:waitReady(STARTUP_TIMEOUT)
        luassert.is_true(ready, "frozen app never served MCP")

        -- Startup ran (entities exist) but no gameplay frame has ticked.
        sleep(0.3)
        luassert.are.equal(0, readFrames(app), "boot-frozen game must sit at frame zero")

        -- Stepping works from frame zero...
        app.client:call("cmd_step", {n = 2})
        local stepped = eventually(CALL_TIMEOUT, function(): integer
            local n = readFrames(app)
            if n >= 2 then return n end
            return nil
        end)
        luassert.are.equal(2, stepped)

        stopApp(app)
    end)
end)

describe("mcp compliance: rewind replay", function()
    local app: App

    setup(function()
        app = startApp()
    end)

    teardown(function()
        stopApp(app)
    end)

    it("replays recorded input deterministically from a ring entry", function()
        -- A huge interval means the immediate first capture is the only
        -- entry, so the recorded press lands strictly after the anchor.
        app.client:call("cmd_rewind_start", {interval = 60, cap = 5})
        local captured = eventually(CALL_TIMEOUT, function(): integer
            local listed = app.client:call("cmd_rewind_list")
            local entries = listed.entries as {any}
            if entries and #entries >= 1 then return #entries end
            return nil
        end)
        luassert.are.equal(1, captured)

        -- A real keypress after the anchor: consumed live, and recorded.
        app.client:call("send_love_event", {event = "keypressed", args = {"up", "up", false}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"up", "up"}})
        local up1 = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
            if n >= 1 then return n end
            return nil
        end)
        luassert.are.equal(1, up1)

        -- Suspend and replay the recorded window: the press must fire once
        -- more, through the real input path, on its original frame.
        setSuspended(app, true)
        local result = app.client:call("cmd_rewind_replay", {ref = "latest"})
        luassert.is_true((result.events as integer) >= 2,
            "recorded press+release rows expected in the replay window")

        local up2 = eventually(CALL_TIMEOUT, function(): integer
            local n = tonumber(runLua(app, "return tecsTest.upFrames")[1]) as integer
            if n > up1 then return n end
            return nil
        end)
        luassert.are.equal(up1 + 1, up2,
            "replay must re-fire the recorded press exactly once")

        setSuspended(app, false)
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
            local gfx = require("tecs.gfx")
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

describe("mcp compliance: crash handling", function()
    it("keeps answering with game_crashed after a gameplay error", function()
        local app = startApp()
        -- Trip the app's deliberate-crash system on the next Update frame.
        runLua(app, "tecsTest.crash = true return true")

        -- The error handler keeps pumping the transport: ping still answers,
        -- now carrying the crash marker and traceback.
        local crashed = eventually(CALL_TIMEOUT, function(): boolean
            local ok, p = pcall(function(): {string: any}
                return app.client:call("ping")
            end)
            if ok and (p as {string: any}).crashed == true then return true end
            return nil
        end)
        luassert.is_true(crashed == true, "ping never reported the crash")
        local p = app.client:call("ping")
        luassert.matches("deliberate test crash", p.error as string)

        -- World tools answer game_crashed immediately instead of hanging.
        local okCall, err = pcall(function()
            app.client:call("run_lua", {code = "return 1"})
        end)
        luassert.is_false(okCall)
        luassert.matches("game_crashed", tostring(err))
        luassert.matches("deliberate test crash", tostring(err))

        -- The traceback landed in the log ring, still served by get_logs.
        local logs = app.client:call("get_logs", {contains = "deliberate test crash"})
        luassert.is_true((logs.returned as integer) >= 1,
            "crash traceback not found in the log ring")

        -- And the process still exits cleanly on quit.
        app.client:tryCall("send_love_event", {event = "quit"}, 2)
        local exited = app.proc:waitExit(SHUTDOWN_TIMEOUT)
        if not exited then app.proc:stop() end
        luassert.is_true(exited, "crashed app did not exit on quit")
    end)
end)

describe("mcp compliance: shutdown", function()
    it("quit exits the process cleanly", function()
        local app = startApp()
        app.client:tryCall("cmd_quit", nil, 2)
        local exited = app.proc:waitExit(SHUTDOWN_TIMEOUT)
        if not exited then
            app.proc:stop()
        end
        luassert.is_true(exited, "app did not exit after quit:\n" .. app.proc:readLog())
    end)
end)
