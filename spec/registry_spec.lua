-- The native API registry.
--
-- `ffi.load` needs a shared object and a working `dlopen`. iOS has neither, so
-- a library reached only that way is a library that cannot be called there.
-- The registry is a table of function pointers taken at build time, and these
-- tests check that the engine really goes through it when one is present.
--
-- The specs themselves run under plain luajit, where nothing installed a
-- registry, so the registry path is exercised inside a worker: the worker
-- library installs one into every state it starts.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local loader = require("tecs.ffi.loader")
local workers = require("tecs.workers")

local PRELUDE = ('package.path = "%s/?.lua;%s/?/init.lua;" .. package.path\n')
    :format(root, root)

describe("ffi registry", function()
    it("falls back to dynamic loading when no host installed one", function()
        -- This process has no host, so the engine must still resolve its
        -- libraries the development way.
        assert.is_nil(_G.__tecsRegistry)
        assert.is_false(loader.isStatic("sdl3"))

        local sdl = require("tecs.ffi.sdl3")
        assert.is_not_nil(sdl.C.SDL_GetError)
    end)

    it("resolves through the registry inside a worker", function()
        local worker = workers.spawn({ source = PRELUDE .. [[
local loader = require("tecs.ffi.loader")
local workers = require("tecs.workers")
local self = workers.current()

while true do
    local task = self:receive()
    if task == nil then break end

    local sdl = require("tecs.ffi.sdl3")
    self:send({
        installed = _G.__tecsRegistry ~= nil,
        static = loader.isStatic("sdl3"),
        path = sdl.path,
        -- A call through the table, to prove the pointers are live rather
        -- than merely present.
        ticks = tonumber(sdl.C.SDL_GetTicks()) >= 0,
        -- An enum constant, which the table does not hold. Those resolve
        -- through the FFI's own namespace, and the engine must find both
        -- through one handle.
        quitKind = tonumber(sdl.C.SDL_EVENT_QUIT),
    })
end
]] })

        worker:send({ go = true })
        local result = worker:receive(4000)
        worker:stop()

        assert.is_not_nil(result, "the worker never answered")
        assert.is_true(result.installed, "a worker state must get a registry")
        assert.is_true(result.static, "and resolve through it")
        assert.are.equal("(registry)", result.path)
        assert.is_true(result.ticks, "a call through the table must work")
        assert.are.equal(0x100, result.quitKind,
            "constants must resolve through the same handle as functions")
    end)

    it("reaches Box2D through the registry too", function()
        -- Every library the engine links gets a table, not just SDL.
        local worker = workers.spawn({ source = PRELUDE .. [[
local loader = require("tecs.ffi.loader")
local workers = require("tecs.workers")
local World = require("tecs.physics.World")
local self = workers.current()

while true do
    local task = self:receive()
    if task == nil then break end
    -- Simulating proves the pointers are the real functions, not a table
    -- that merely has the right shape.
    local world = World.create({ gravity = { x = 0, y = -10 } })
    local body = world:createBody({ type = "dynamic", position = { x = 0, y = 0 } })
    World.addCircle(body, 0.5, { density = 1 })
    for _ = 1, 60 do world:step(1 / 60) end
    local _, y = World.getPosition(body)
    world:destroy()

    self:send({ static = loader.isStatic("box2d"), fell = y < -4 })
end
]] })

        worker:send({ go = true })
        local result = worker:receive(4000)
        worker:stop()

        assert.is_not_nil(result, "the worker never answered")
        assert.is_true(result.static)
        assert.is_true(result.fell, "gravity must act through the table")
    end)
end)
