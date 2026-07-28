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
--    `require("tecs")` therefore loads no engine module: `tecs.ecs` is the only
--    field there up front, and every other module resolves on first use.
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
        "luajit",
        path,
        "2>&1",
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
            local output = run(
                [[
                local tecs = require("tecs")
                local world = tecs.ecs.newWorld()
                local Tag = tecs.ecs.newTagComponent({ name = "Headless" })
                local Transform = tecs.ecs.builtins.Transform
                local entity = world:spawn(Transform(10, 20), Tag)
                world:update(1 / 60)

                local matched = 0
                local query = world:query({ include = { Transform, Tag } })
                for _, length in query:iter() do matched = matched + length end

                local transform = world:get(entity, Transform)
                print(("ok %d %d %d %d")
                    :format(entity, transform.x, transform.y, matched))
            ]],
                false
            )
            assert.are.equal("ok 1 10 20 1\n", output)
        end)

        -- The property that keeps the one above true. A module required
        -- eagerly by `tecs.ecs` would break a pure ECS tool, and would do it
        -- silently: everything still works on a developer's machine, where the
        -- libraries are installed.
        it("builds a world through the ECS half alone", function()
            -- The module engine code requires, reached first and on its own.
            -- Through `tecs` this always works, because that requires the
            -- compatibility shim before anything else; this has to stand up
            -- without it having been asked for. A fresh interpreter is the
            -- only place a load-order fault like that appears.
            local output = run(
                [[
                local ecs = require("tecs.ecs")
                local world = ecs.newWorld()
                local Marker = ecs.newComponent({
                    name = "HalfOnly",
                    container = {},
                    fields = { "value" },
                    defaults = { 0 },
                })
                local entity = world:spawn(Marker(7))
                world:update(1 / 60)
                print(("ok %d"):format(world:get(entity, Marker).value))
            ]],
                false
            )
            assert.are.equal("ok 7\n", output)
        end)

        it("loads no engine module until one is named", function()
            local output = run(
                [[
                require("tecs")
                local engine = {
                    "tecs.Application", "tecs.Renderer", "tecs.workers",
                    "tecs.assets", "tecs.physics", "tecs.mcp",
                    "tecs.gpu.Device", "tecs.ffi.sdl3", "tecs.ffi.box2d",
                    "tecs.data", "tecs.platform.system",
                    "tecs.platform.filesystem", "tecs.platform.watch",
                }
                local loaded = {}
                for _, name in ipairs(engine) do
                    if package.loaded[name] ~= nil then
                        loaded[#loaded + 1] = name
                    end
                end
                print(#loaded == 0 and "none" or table.concat(loaded, " "))
            ]],
                false
            )
            assert.are.equal("none\n", output)
        end)

        -- The same property one level down, which is where it stops being
        -- free. A module inside another module is reached through a table
        -- named for the parent, and the obvious way to build that table is to
        -- require its members as it is built. That would load the whole of
        -- `tecs.gfx` the moment a tool asked about layer bands, and every one
        -- of the others reaches SDL through the FFI.
        it("loads one module under a namespace and none of its siblings", function()
            local output = run(
                [[
                local tecs = require("tecs")
                local named = tecs.gfx
                local eager = package.loaded["tecs.gfx.layers"] ~= nil
                local layers = tecs.gfx.layers

                -- Everything else that lives under src/tecs/gfx, plus the two
                -- modules a graphics stack starts with.
                local siblings = {
                    "tecs.gfx.Camera", "tecs.gfx.animation", "tecs.gfx.particles",
                    "tecs.gfx.text", "tecs.Renderer", "tecs.ffi.sdl3",
                }
                local loaded = {}
                for _, name in ipairs(siblings) do
                    if package.loaded[name] ~= nil then
                        loaded[#loaded + 1] = name
                    end
                end

                print(("%s %s %s %s"):format(
                    type(named),
                    tostring(eager),
                    tostring(rawequal(layers, require("tecs.gfx.layers"))),
                    #loaded == 0 and "none" or table.concat(loaded, " ")))
            ]],
                false
            )
            -- Naming the namespace loads nothing, reading one member loads
            -- that member and answers with the module itself, and no sibling
            -- came with it.
            assert.are.equal("table false true none\n", output)
        end)

        -- And the same property where the parent is a module rather than a
        -- table built for the name. `tecs.filesystem` is the module itself, so
        -- naming it loads that module and nothing else: the watcher below it
        -- polls on a timer and reaches SDL, and a program that reads a file has
        -- not asked for one.
        it("hangs a module under a module without loading it", function()
            local output = run(
                [[
                local tecs = require("tecs")
                local filesystem = tecs.filesystem
                local eager = package.loaded["tecs.platform.watch"] ~= nil
                local watch = tecs.filesystem.watch

                print(("%s %s %s %s"):format(
                    tostring(rawequal(filesystem, require("tecs.platform.filesystem"))),
                    tostring(eager),
                    tostring(rawequal(watch, require("tecs.platform.watch"))),
                    tostring(tecs.filesystem.nosuchthing)))
            ]],
                false
            )
            -- The name is the module, the watcher did not come with it, and
            -- reading it answers with the module rather than a copy.
            assert.are.equal("true false true nil\n", output)
        end)

        it("reports a mistyped engine name as nil", function()
            -- The names are listed rather than derived from a module path, so a
            -- typo answers nil here instead of raising out of `require` about a
            -- module nobody meant to ask for.
            local output = run(
                [[
                local tecs = require("tecs")
                print(tostring(tecs.Aplication) .. " " ..
                    tostring(tecs.nosuchthing))
            ]],
                false
            )
            assert.are.equal("nil nil\n", output)
        end)
    end)

    describe("with the native libraries, and still no window", function()
        it("simulates physics across its thread pool", function()
            -- No device, no window, and the solver's threads running: a
            -- headless simulation is a supported thing to build.
            local output = run(
                [[
                local tecs = require("tecs")
                local world = tecs.ecs.newWorld()
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
            ]],
                true
            )
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
            local output = run(
                [[
                local tecs = require("tecs")
                local worker = tecs.workers.spawn({
                    source = "local s = require('tecs.workers').current()" ..
                        " s:send(s:receive(3000) + 1)",
                })
                worker:send(41)
                print(worker:receive(3000))
                worker:stop()
            ]],
                false
            )
            assert.are.equal("42\n", output)
        end)

        it("runs work on a worker thread", function()
            -- What a resource pipeline is: fan work out, collect answers, no
            -- graphics anywhere in it.
            local output = run(
                [[
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
            ]],
                true
            )
            assert.are.equal("atlas.png 27\n", output)
        end)
    end)
end)
