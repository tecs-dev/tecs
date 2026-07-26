-- tecs runs with no window and no GPU device.
--
-- This is a supported way to use it rather than a side effect. A resource
-- pipeline, a command line tool, a simulation server or a test wants worlds,
-- components, queries, worker threads and physics without ever opening a
-- window. So headless means no window and no device; it does not mean no
-- native code. Workers, physics, logging and asset decoding stay available,
-- because those are most of what a tool is for.
--
-- Two properties, and they pull in opposite directions:
--
--  * A tool that only wants the ECS must not be made to find a graphics stack.
--    `require("tecs")` therefore loads no engine module, and the engine half of
--    the surface resolves on first use.
--  * A tool that does want workers or physics must get them, working, with no
--    window in sight.
--
-- The first is checked in a fresh process with the library paths stripped,
-- because another spec in this run has already loaded the engine and asking
-- `package.loaded` here would answer about this process rather than a tool's.

local lua = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
local lib = os.getenv("TECS_LIB") or "out/macos-arm64-dev/lib"

--- Runs a chunk in a fresh interpreter with only the compiled tree on its
--- path, and returns its combined output. `libraries` decides whether the
--- process can find the native libraries at all.
---
--- The chunk goes through a file rather than `-e`. Quoting it into a shell
--- command turns its newlines into line continuations, and a chunk whose lines
--- are joined has its first comment swallow everything after it, which reads as
--- a program that ran and printed nothing.
local function run(chunk, libraries)
    local path = os.tmpname()
    local file = assert(io.open(path, "w"))
    file:write(chunk)
    file:close()

    local command = table.concat({
        libraries and ("TECS_LIB=%q"):format(lib) or "env -u TECS_LIB",
        ("LUA_PATH='%s/?.lua;%s/?/init.lua;;'"):format(lua, lua),
        "luajit", path, "2>&1",
    }, " ")
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a")
    pipe:close()
    os.remove(path)
    return output
end

describe("tecs headless", function()
    describe("with no native libraries reachable", function()
        it("builds and queries a world", function()
            local output = run([[
                local tecs = require("tecs")
                local world = tecs.newWorld()
                local Tag = tecs.newTagComponent({ name = "Headless" })
                local Transform = tecs.builtins.Transform
                local entity = world:spawn(Transform(10, 20), Tag)
                world:update(1 / 60)

                local matched = 0
                local query = world:query({ include = { Transform, Tag } })
                for _, length in query:iter() do matched = matched + length end

                local transform = world:get(entity, Transform)
                print(("ok %d %d %d %d")
                    :format(entity, transform.x, transform.y, matched))
            ]], false)
            assert.are.equal("ok 1 10 20 1\n", output)
        end)

        -- The property that keeps the one above true. A module added to the
        -- eager half of the surface would break a pure ECS tool, and would do
        -- it silently: everything still works on a developer's machine, where
        -- the libraries are installed.
        it("loads no engine module until one is named", function()
            local output = run([[
                require("tecs")
                local engine = {
                    "tecs.Application", "tecs.Renderer", "tecs.workers",
                    "tecs.assets", "tecs.physics", "tecs.mcp",
                    "tecs.gpu.Device", "tecs.ffi.sdl3", "tecs.ffi.box2d",
                }
                local loaded = {}
                for _, name in ipairs(engine) do
                    if package.loaded[name] ~= nil then
                        loaded[#loaded + 1] = name
                    end
                end
                print(#loaded == 0 and "none" or table.concat(loaded, " "))
            ]], false)
            assert.are.equal("none\n", output)
        end)

        it("reports a mistyped engine name as nil", function()
            -- The names are listed rather than derived from a module path, so a
            -- typo answers nil here instead of raising out of `require` about a
            -- module nobody meant to ask for.
            local output = run([[
                local tecs = require("tecs")
                print(tostring(tecs.Aplication) .. " " ..
                    tostring(tecs.nosuchthing))
            ]], false)
            assert.are.equal("nil nil\n", output)
        end)
    end)

    describe("with the native libraries, and still no window", function()
        it("simulates physics across its thread pool", function()
            -- No device, no window, and the solver's threads running: a
            -- headless simulation is a supported thing to build.
            local output = run([[
                local tecs = require("tecs")
                local world = tecs.newWorld()
                world:addPlugin(tecs.physics.plugin({
                    gravity = { 0, 980 }, workerCount = 2,
                }))
                local Transform = tecs.components.Transform
                local entity = world:spawn(Transform(0, 0, 0, 1, 0, 10, 10))
                tecs.physics.attach(world, entity, {
                    type = "dynamic", halfWidth = 5, halfHeight = 5,
                    density = 1.0,
                })
                for _ = 1, 60 do world:update(1 / 60) end
                -- One second of that gravity, so it is a long way down.
                print(world:get(entity, Transform).y > 400 and "fell" or "stuck")
            ]], true)
            assert.are.equal("fell\n", output)
        end)

        it("finds its libraries with nothing in the environment", function()
            -- The build system sets TECS_LIB, so every other test here is told
            -- where to look. A tool is not: it is unpacked under a prefix
            -- nobody chose in advance and run by whoever installed it. The
            -- loader answers by walking up from wherever it was itself loaded,
            -- and the libraries carry a loader-relative runtime path so one
            -- resolves its siblings even though the process belongs to a plain
            -- interpreter rather than to the engine's own host.
            local output = run([[
                local tecs = require("tecs")
                local worker = tecs.workers.spawn({
                    source = "local s = require('tecs.workers').current()" ..
                        " s:send(s:receive(3000) + 1)",
                })
                worker:send(41)
                print(worker:receive(3000))
                worker:stop()
            ]], false)
            assert.are.equal("42\n", output)
        end)

        it("runs work on a worker thread", function()
            -- What a resource pipeline is: fan work out, collect answers, no
            -- graphics anywhere in it.
            local output = run([[
                local tecs = require("tecs")
                local worker = tecs.workers.spawn({ source = [==[
                    local workers = require("tecs.workers")
                    local self = workers.current()
                    local job = self:receive(4000)
                    self:send({ name = job.name, size = #job.name * job.scale })
                ]==] })
                worker:send({ name = "atlas.png", scale = 3 })
                local reply = worker:receive(4000)
                worker:stop()
                print(reply.name .. " " .. reply.size)
            ]], true)
            assert.are.equal("atlas.png 27\n", output)
        end)
    end)
end)
