-- The typed event stream.
--
-- This is the conversion every platform shares, so a mistake here is a mistake
-- everywhere. The tests build real SDL_Event values and check what the engine
-- reports for them, because the whole point of the layer is that nothing above
-- it ever sees the union.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local events = require("tecs.platform.events")

local C = sdl.C

-- A queue the host would have filled, so drain sees what it sees live.
local function queueOf(fill, count)
    local queue = loader.newArray("SDL_Event[?]", count or 1)
    fill(queue)
    return queue, count or 1
end

local function drainOne(queue, count)
    local seen = {}
    events.drain(queue, count, function(event)
        seen[#seen + 1] = events.copy(event)
    end)
    return seen
end

describe("platform.events", function()
    after_each(function()
        events.source = nil
    end)

    it("names every kind it recognises", function()
        local kinds = {}
        for _, kind in ipairs(events.kinds()) do kinds[kind] = true end

        -- Desktop and mobile lifecycle share one vocabulary.
        assert.is_true(kinds.quit)
        assert.is_true(kinds.keyDown)
        assert.is_true(kinds.mouseMotion)
        assert.is_true(kinds.controllerAxis)
        assert.is_true(kinds.appWillEnterBackground)
        assert.is_true(kinds.appDidEnterForeground)
        assert.is_true(kinds.lowMemory)
        assert.is_true(kinds.fingerDown)
    end)

    it("converts a key press, including the repeat flag", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 44
            q[0].key.down = true
            q[0].key["repeat"] = true
        end)

        local seen = drainOne(queue, count)
        assert.are.equal(1, #seen)
        assert.are.equal("keyDown", seen[1].kind)
        assert.are.equal(44, seen[1].scancode)
        assert.is_true(seen[1].repeated,
            "a repeat must be distinguishable from a fresh press")
    end)

    it("converts mouse motion with its delta", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_MOUSE_MOTION
            q[0].motion.x = 120.0
            q[0].motion.y = 80.0
            q[0].motion.xrel = -4.0
            q[0].motion.yrel = 2.0
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("mouseMotion", event.kind)
        assert.are.equal(120.0, event.x)
        assert.are.equal(80.0, event.y)
        assert.are.equal(-4.0, event.dx)
        assert.are.equal(2.0, event.dy)
    end)

    it("scales a controller axis into minus one to one", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_GAMEPAD_AXIS_MOTION
            q[0].gaxis.axis = 1
            q[0].gaxis.value = -32767
            q[0].gaxis.which = 3
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("controllerAxis", event.kind)
        assert.are.equal(1, event.axis)
        assert.is_true(math.abs(event.value + 1.0) < 0.001)
        assert.are.equal(3, event.which)
    end)

    it("reports lifecycle events with their own kinds", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_WILL_ENTER_BACKGROUND
        end)
        assert.are.equal("appWillEnterBackground", drainOne(queue, count)[1].kind)
    end)

    it("carries a touch finger as an exact opaque identity", function()
        -- A finger id is 64 bits. Reporting it as a number would round, and two
        -- distinct fingers could collapse into one.
        events.setTouchScale(800, 600)
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_FINGER_DOWN
            q[0].tfinger.fingerID = 9007199254740995ULL
            q[0].tfinger.x = 0.5
            q[0].tfinger.y = 0.25
            q[0].tfinger.pressure = 0.75
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("fingerDown", event.kind)
        assert.is_string(event.finger)
        assert.is_truthy(event.finger:find("9007199254740995"),
            "the identity must survive exactly, not as a rounded double")
        -- Touch arrives normalised and is reported in window units.
        assert.are.equal(400.0, event.x)
        assert.are.equal(150.0, event.y)
        assert.is_true(math.abs(event.pressure - 0.75) < 0.001)
    end)

    it("surfaces an unrecognised SDL event rather than dropping it", function()
        -- Upgrading SDL must not silently discard new input.
        local queue, count = queueOf(function(q)
            q[0].type = 0x7FFE
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("unknown", event.kind)
        assert.are.equal(0x7FFE, event.sdlType)
    end)

    it("delivers a queue in arrival order", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 1
            q[1].type = C.SDL_EVENT_KEY_DOWN
            q[1].key.scancode = 2
            q[2].type = C.SDL_EVENT_KEY_UP
            q[2].key.scancode = 1
        end, 3)

        local seen = drainOne(queue, count)
        assert.are.equal(3, #seen)
        assert.are.equal(1, seen[1].scancode)
        assert.are.equal(2, seen[2].scancode)
        assert.are.equal("keyUp", seen[3].kind)
    end)

    it("reuses one record, so retaining requires a copy", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 10
            q[1].type = C.SDL_EVENT_KEY_DOWN
            q[1].key.scancode = 20
        end, 2)

        local held = {}
        events.drain(queue, count, function(event) held[#held + 1] = event end)

        -- Both references are the same pooled record, which is why copy exists.
        assert.are.equal(held[1], held[2])
        assert.are.equal(20, held[1].scancode,
            "the retained reference shows the last event, not the first")
    end)

    it("lets a replay driver stand in for the queue", function()
        -- Replay substitutes the source rather than synthesising SDL unions,
        -- which is what keeps a recorded session reproducible.
        events.source = function(handler)
            handler({ kind = "keyDown", scancode = 99, repeated = false })
            handler({ kind = "quit" })
        end

        local seen = {}
        events.drain(nil, 0, function(event) seen[#seen + 1] = event.kind end)
        assert.are.same({ "keyDown", "quit" }, seen)
    end)

    it("pushes a synthetic event in the engine's own vocabulary", function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        C.SDL_PumpEvents()
        C.SDL_FlushEvents(0, 0xFFFFFFFF)

        events.push("keyDown", { scancode = 77 })

        -- Read back through SDL to confirm it really entered the queue.
        local holder = loader.newArray("SDL_Event[1]")
        assert.is_true(C.SDL_PollEvent(holder) ~= false)
        assert.are.equal(tonumber(C.SDL_EVENT_KEY_DOWN), tonumber(holder[0].type))
        assert.are.equal(77, tonumber(holder[0].key.scancode))

        assert.is_false(pcall(function() events.push("notAKind", {}) end))
        C.SDL_Quit()
    end)
end)
