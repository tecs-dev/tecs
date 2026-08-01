-- The tools every build exposes.
--
-- `send_event` is how a debugging session drives input, and the thing worth
-- proving about it is that its schema and the push behind it agree: a field
-- the tool accepts has to arrive in the converted event rather than stopping
-- at the handler. So these go the whole way round, through SDL's own queue.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local mcp = require("tecs.io.mcp")
local events = require("tecs.platform.events")
require("tecs.io.mcp.tools")

local C = sdl.C

local function call(name, args)
    local response = cjson.decode(mcp.dispatch(cjson.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/call",
        params = { name = name, arguments = args },
    })))
    local result = response.result
    assert.is_falsy(
        result.isError,
        name .. " failed: " .. tostring(result.content and result.content[1] and result.content[1].text)
    )
    return result.structuredContent
end

local function pollAll()
    local holder = loader.newArray("SDL_Event[1]")
    local seen = {}
    while C.SDL_PollEvent(holder) ~= false do
        events.drain(holder, 1, function(event)
            seen[#seen + 1] = events.copy(event)
        end)
    end
    return seen
end

describe("mcp send_event", function()
    before_each(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        C.SDL_PumpEvents()
        C.SDL_FlushEvents(0, 0xFFFFFFFF)
    end)

    after_each(function()
        C.SDL_Quit()
    end)

    it("lists the kinds it accepts when given none", function()
        local kinds = {}
        for _, kind in ipairs(call("send_event", {}).kinds) do
            kinds[kind] = true
        end
        assert.is_true(kinds.mouseWheel)
        assert.is_true(kinds.penMotion)
    end)

    it("scrolls, and scrolls the way a natural platform does", function()
        -- The negation lives in the conversion, so the tool asking for a
        -- flipped scroll is asking to see it applied.
        call("send_event", {
            kind = "mouseWheel",
            wheelX = 0.5,
            wheelY = 1.5,
            wheelTicksX = 1,
            wheelTicksY = 2,
            x = 20.0,
            y = 25.0,
        })
        call("send_event", {
            kind = "mouseWheel",
            wheelX = 0.5,
            wheelY = 1.5,
            wheelTicksX = 1,
            wheelTicksY = 2,
            x = 20.0,
            y = 25.0,
            flipped = true,
        })

        local seen = pollAll()
        local ordinary, natural = seen[1], seen[2]
        assert.are.equal("mouseWheel", ordinary.kind)
        assert.are.equal(0.5, ordinary.wheelX)
        assert.are.equal(1.5, ordinary.wheelY)
        assert.are.equal(1, ordinary.wheelTicksX)
        assert.are.equal(2, ordinary.wheelTicksY)
        assert.are.equal(20.0, ordinary.x)
        assert.are.equal(25.0, ordinary.y)

        assert.are.equal(-ordinary.wheelY, natural.wheelY, "the same scroll sent flipped comes back negated")
        assert.are.equal(-ordinary.wheelTicksY, natural.wheelTicksY)
    end)

    it("sends a double click as a double click", function()
        call("send_event", { kind = "mouseDown", button = 1, clicks = 2 })
        assert.are.equal(2, pollAll()[1].clicks)
    end)

    it("sends the whole pen state, barrel buttons and all", function()
        local held = sdl.K.SDL_PEN_INPUT_DOWN + sdl.K.SDL_PEN_INPUT_BUTTON_2
        call("send_event", {
            kind = "penMotion",
            which = 9,
            x = 12.0,
            y = 34.0,
            penState = held,
        })

        local event = pollAll()[1]
        assert.are.equal("penMotion", event.kind)
        assert.are.equal(held, event.penState)
        assert.are.equal(12.0, event.x)
    end)
end)

describe("mcp context", function()
    local tools = require("tecs.io.mcp.tools")
    local tecs = require("tecs")

    setup(function()
        assert(C.SDL_Init(0))
    end)
    teardown(function()
        tools.bind(nil, nil)
        C.SDL_Quit()
    end)

    it("reports what this build is even before a world is bound", function()
        tools.bind(nil, nil)
        local context = call("context", {})
        assert.is_truthy(context.target)
        assert.is_string(context.sandbox)
        assert.is_boolean(context.hotReload)
        assert.are.equal(cjson.null, context.world, "no world is a report, not a failure")
    end)

    it("reports what the bound world holds", function()
        -- Through world:getStats rather than a tally kept beside it, so the
        -- first question an agent asks about a running game is answered by the
        -- tool that says what the build is.
        local world = tecs.ecs.newWorld()
        world:addSystem({ name = "spec.context", phase = tecs.ecs.phases.Update, run = function() end })
        for index = 1, 3 do
            world:spawn(tecs.Transform2D(index, 0, 0, 1, 0, 1, 1))
        end
        world:commit()
        tools.bind(nil, world)

        local reported = call("context", {}).world
        assert.are.equal(3, reported.entities)
        assert.is_true(reported.archetypes >= 1)
        assert.is_true(reported.systems >= 1)

        -- The registry is process-wide and this world is not, so what is
        -- declared has to read differently from what is here. Conflating them
        -- is what makes a component an agent cannot find look like one that
        -- was never registered.
        assert.are.equal(1, reported.components)
        assert.is_true(
            reported.declaredComponents > reported.components,
            "the process declares more than this world carries"
        )
    end)
end)
