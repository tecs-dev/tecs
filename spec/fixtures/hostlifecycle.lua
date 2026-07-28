-- An application the host spec drives, run by the real `tecs` executable.
--
-- Everything under test lives in `native/host.c`, and none of it is reachable
-- from an `Application` built in process: the host is the executable, its
-- callbacks are what SDL enters, and most of what is being checked only happens
-- when SDL dispatches an event into a frame that is already running. So this is
-- a real run of the real binary, printing one line per observation for the spec
-- to read back.
--
-- Every lifecycle event here arrives the way a platform's does. SDL dispatches
-- the six from its event watcher rather than queueing them, and the watcher runs
-- on the thread that pushed, so `events.push` from inside a system reaches
-- `SDL_AppEvent` synchronously, mid-frame, with the Lua state already active.
-- That is exactly the case the guard exists for, and it is also why nothing here
-- can reach the host's inline dispatch: from Lua, Lua is always active.

local root = os.getenv("TECS_LUA") or __tecsContent or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local events = require("tecs.platform.events")
local clock = require("tecs.platform.clock")

-- An upper bound, not the length of the run: pushing `terminating` is what ends
-- it, and that happens well before this.
local FRAMES = 40

-- How long the frame that injects a key press holds the main thread, in
-- seconds. Long enough that an arrival stamped by the next pump is
-- unmistakably later than one stamped where SDL produced the event.
local STALL = 0.060

--- Busy, not asleep. The point is a main thread that is not pumping, which is
--- what a long update or a blocked swapchain acquire looks like from outside.
local function stall()
    local until_ = clock.now() + STALL
    while clock.now() < until_ do
    end
end

local frame = 0

-- What each observation saw, printed at shutdown so the ordering of the run is
-- not tangled up with the ordering of the output.
local pushedAt = nil
local arrivalDelta = nil
local backgroundEventFrame = nil
local backgroundHookFrame = nil
local backgroundHookCount = 0
local lowMemoryHookCount = 0
local terminatingHookCount = 0
local reentered = false

-- True only while a system is running, which is when the Lua state is one the
-- host must refuse to enter a second time.
local inUpdate = false

return tecs.application({
    window = { title = "hostlifecycle", width = 64, height = 64 },
    logFile = "",
    maxFrames = FRAMES,

    plugin = function(world, app)
        -- The hooks the host offers. Set on the instance because that is what a
        -- game does today: the host looks the method up on the application it
        -- was handed, so a field and a method are the same thing to it.
        app._willEnterBackground = function()
            backgroundHookCount = backgroundHookCount + 1
            if backgroundHookFrame == nil then
                backgroundHookFrame = frame
            end
            if inUpdate then
                reentered = true
            end
        end

        app._lowMemory = function()
            lowMemoryHookCount = lowMemoryHookCount + 1
            if inUpdate then
                reentered = true
            end
        end

        app._terminating = function()
            terminatingHookCount = terminatingHookCount + 1
        end

        -- Deliberately no `_didEnterBackground`, `_willEnterForeground` or
        -- `_didEnterForeground`. A hook a game did not write must not be an
        -- error, and a run that failed here would say so.

        world:observe(0, events.on.keyDown, function(event)
            if pushedAt ~= nil and arrivalDelta == nil and event.arrival ~= nil then
                arrivalDelta = (event.arrival - pushedAt) * 1000.0
            end
        end)

        world:observe(0, events.on.appWillEnterBackground, function()
            if backgroundEventFrame == nil then
                backgroundEventFrame = frame
            end
            -- The engine suspends simulation on this event, which would stop
            -- the frame counter and with it the rest of the schedule below.
            -- What is under test is the host, not that policy, so the fixture
            -- keeps running.
            app.suspended = false
        end)

        world:addSystem({
            name = "fixture.Stimulus",
            phase = tecs.phases.Update,
            run = function()
                inUpdate = true

                if frame == 2 then
                    -- The press, then a frame that does not pump. An arrival
                    -- stamped where the next pump found the event charges the
                    -- press for the stall; the event's own stamp does not.
                    pushedAt = clock.now()
                    events.push("keyDown", { scancode = 44 })
                    stall()
                elseif frame == 5 then
                    -- Straight into `SDL_AppEvent`, from inside a system. The
                    -- host must not answer these by re-entering this state, and
                    -- it must not drop the copies it took when the iteration
                    -- ends. Two backgroundings in one iteration are one
                    -- backgrounding.
                    events.push("appWillEnterBackground", {})
                    events.push("appWillEnterBackground", {})
                    events.push("lowMemory", {})
                elseif frame == 8 then
                    -- A third, in an iteration of its own and with no return to
                    -- the foreground in between. Still the same backgrounding,
                    -- so still no second save.
                    events.push("appWillEnterBackground", {})
                elseif frame == 11 then
                    events.push("appDidEnterForeground", {})
                elseif frame == 14 then
                    -- A new backgrounding, because the foreground ended the
                    -- previous one. This one does get its save.
                    events.push("appWillEnterBackground", {})
                elseif frame == 17 then
                    -- Nothing is deferred past this: SDL ends the loop as soon
                    -- as it has dispatched, so there is no iteration left to
                    -- replay a refused hook into. The host says so instead.
                    events.push("terminating", {})
                end

                inUpdate = false
            end,
        })

        world:addSystem({
            name = "fixture.Frame",
            phase = tecs.phases.Last,
            run = function()
                frame = frame + 1
            end,
        })

        world:addSystem({
            name = "fixture.Report",
            phase = tecs.phases.Shutdown,
            run = function()
                print(("arrivalDelta=%.3f"):format(arrivalDelta or -1.0))
                print(("backgroundEventFrame=%d"):format(backgroundEventFrame or -1))
                print(("backgroundHookFrame=%d"):format(backgroundHookFrame or -1))
                print(("backgroundHookCount=%d"):format(backgroundHookCount))
                print(("lowMemoryHookCount=%d"):format(lowMemoryHookCount))
                print(("terminatingHookCount=%d"):format(terminatingHookCount))
                print(("lastFrame=%d"):format(frame))
                print(("reentered=%s"):format(tostring(reentered)))
                print("fixture=done")
            end,
        })
    end,
})
