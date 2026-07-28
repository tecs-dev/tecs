-- Every phase a game can register a system in actually runs.
--
-- This exists because four of them did not. `Application` never called
-- `world:startup` or `world:shutdown`, so a system registered in `PreStartup`,
-- `Startup`, `PostStartup`, `PreShutdown`, `Shutdown` or `PostShutdown` was
-- accepted, listed by the debug server, and silently never run. Nothing said
-- so, and nothing could: the phases existed, the systems existed, and the only
-- missing thing was a pair of calls in the lifecycle.
--
-- A spec naming those six would stop that bug coming back and would stop
-- nothing else. So this one names none of them. It takes the phase list from
-- the phases module, registers a marker in every phase in it, drives a real
-- application through its whole lifecycle, and reports the ones that never
-- fired. A phase added later is covered the day it is added.
--
-- `phases.index` is the enumeration to take, and it is the module's own answer
-- rather than a guess: `addPhases` walks the group tree and appends only the
-- phases with no children, assigning each a position as it goes. So a phase in
-- `index` is a leaf, and a group like `MainGroup` or `ShutdownGroup` is not in
-- it. `Draw` is not in it either, which is correct and worth being explicit
-- about: it is in no group and has no position because it is invoked during
-- G-buffer rendering rather than dispatched as a sequential phase, so a marker
-- in it would be reporting on something this lifecycle does not do.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Application = require("tecs.Application")
local phases = require("tecs.internal.phases")
local time = require("tecs.platform.time")

-- Enough iterations that the fixed phases are reached whatever the frame rate,
-- with dt pinned below so they are reached by arithmetic rather than by luck.
local ITERATIONS = 8

describe("phases", function()
    it("runs a system in every phase a game can register one in", function()
        local ran = {}
        local plugin = function(world)
            for index = 1, #phases.index do
                local phase = phases.index[index]
                world:addSystem({
                    name = "spec.Mark." .. phase.name,
                    phase = phase,
                    run = function()
                        ran[phase.name] = true
                    end,
                })
            end
        end

        local app = Application.newApplication({
            window = { title = "phases", width = 64, height = 64 },
            plugin = plugin,
        })

        -- A fixed step is released when the accumulator crosses it, so a run
        -- of frames faster than the step would report FixedFirst through
        -- FixedLast as dead and be wrong about it. Pinning dt to two steps
        -- makes that arithmetic rather than a race with the machine.
        local previous = time.provider
        time.provider = function()
            return time.nominal * 2.0
        end

        finally(function()
            time.provider = previous
        end)

        assert.is_true(app:_init())
        for _ = 1, ITERATIONS do
            app:_iterate(nil, 0, nil)
        end
        assert.is_true(app:_shutdown())

        -- Named, not counted. "PostShutdown never ran" is a minute of someone
        -- else's time and "a phase did not run" is an hour of it.
        local dead = {}
        for index = 1, #phases.index do
            local name = phases.index[index].name
            if not ran[name] then
                dead[#dead + 1] = name
            end
        end

        assert.are.equal(0, #dead, "phases that never ran: " .. table.concat(dead, ", "))
    end)
end)
