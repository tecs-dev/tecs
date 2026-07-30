-- The C host, driven as the executable it is.
--
-- Everything under test here is in the Rust host and none of it is reachable
-- from an `Application` built in this process. The host is the program SDL
-- calls, its four callbacks are what SDL enters, and two of the three
-- properties only happen when SDL dispatches an event into a frame that is
-- already running. So this runs the real binary over `spec/fixtures`, which
-- prints one line per observation, and reads those back.
--
-- One child for all of it. Starting the binary opens a window and a graphics
-- device, and the three properties are independent enough to observe in one
-- pass but not worth three passes.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local platformOS = require("tecs.platform.os")

--- The host binary, found by walking up from the tree the suite was pointed at.
---
--- Walked rather than computed, because the depth differs and only one of the
--- two layouts was ever computed correctly. A build tree has the Lua at
--- `out/<preset>/lua` and the binary at `out/<preset>/bin`, so stripping `/lua`
--- and appending `/bin/tecs` finds it. An installed tree has the Lua at
--- `<prefix>/share/tecs/lua` and the binary at `<prefix>/bin`, which is two
--- levels further up, so the same arithmetic produced
--- `<prefix>/share/tecs/bin/tecs` and a child that never started. What that
--- looked like was the fixture reporting nothing at all, which reads as a
--- program that ran and printed nothing rather than as one that is not there.
---
--- This is the same walk `src/tecs/ffi/loader.tl` does for a sibling library,
--- for the same reason: neither layout is written down here, and a tree that is
--- neither answers nil rather than a path that happens to exist.
local function findHost()
    local directory = (root:gsub("/$", ""))
    for _ = 1, 6 do
        local candidate = directory .. "/bin/tecs"
        local handle = io.open(candidate, "r")
        if handle ~= nil then
            handle:close()
            return directory
        end
        local parent = directory:match("^(.*)/[^/]+$")
        if parent == nil or parent == "" or parent == directory then
            break
        end
        directory = parent
    end
    return nil
end

local out = findHost()

--- Runs the fixture to completion and answers what it printed, as a table of
--- the `key=value` lines it ends with.
---
--- The child is told where the tree is rather than left to inherit it. It is
--- the same tree this process was pointed at, and saying so is what makes the
--- spec independent of how the suite was launched.
local function observations()
    assert.is_not_nil(out, "no bin/tecs above " .. root)
    local run = platformOS.runProcess({
        args = { out .. "/bin/tecs", "--entry", "spec/fixtures/hostlifecycle.lua" },
        env = {
            TECS_LUA = root,
            TECS_LIB = os.getenv("TECS_LIB") or (out .. "/lib"),
            TECS_ASSETS = os.getenv("TECS_ASSETS") or root,
        },
        timeoutMs = 60000,
    })
    run:wait(60000)

    local result = platformOS.processResult(run)
    assert.is_not_nil(result, "the host never started")
    local output = result.output .. "\n" .. result.errorOutput

    local seen = {}
    for key, value in output:gmatch("([%w_]+)=([^\n]+)") do
        seen[key] = value
    end
    assert.are.equal("done", seen.fixture, "the fixture did not run to shutdown; the host said:\n" .. output)
    return seen, output
end

describe("host", function()
    -- The parsed observations, and everything the run wrote: some of what the
    -- host does is a report rather than a value, and a report is only worth
    -- making if something reads it.
    local seen, raw

    setup(function()
        seen, raw = observations()
    end)

    teardown(function()
        platformOS.shutdownProcesses()
    end)

    -- Defect: the arrival stamp dated an event from the pump that delivered it,
    -- so a frame that did not pump was charged to nobody. The fixture presses a
    -- key and then holds the main thread for 60 ms without pumping. Stamped at
    -- delivery the press is 60 ms old before it is seen to have arrived; stamped
    -- from SDL's own timestamp it is as old as it really is.
    it("dates an event from when SDL produced it, not from the pump that found it", function()
        local delta = tonumber(seen.arrivalDelta)
        assert.is_not_nil(delta, "no press was observed")
        assert.is_true(
            delta >= 0.0,
            ("arrival preceded the push by %.3f ms, so the two clocks are not aligned"):format(-delta)
        )
        assert.is_true(
            delta < 10.0,
            ("arrival was %.3f ms after the push; the 60 ms stall is in the stamp"):format(delta)
        )
    end)

    -- Defect: the drain count was zeroed unconditionally when the iteration
    -- returned, so an event copied in during that iteration went with it. SDL
    -- dispatches the six lifecycle events from its event watcher rather than
    -- queueing them, so one pushed from inside a system reaches the host
    -- mid-iteration and is the case that was lost. Two owned batches, swapped at
    -- the top of an iteration, is what makes it survive.
    it("keeps an event that arrived while the previous batch was being drained", function()
        local at = tonumber(seen.backgroundEventFrame)
        assert.is_not_nil(at)
        assert.are.equal(6, at, "the backgrounding pushed during frame 5 was not delivered on frame 6")
    end)

    -- Defect: a game could not save state on being backgrounded, because the
    -- host copied the event and returned. The hook is the answer, and the hard
    -- part is that it must not run here: the event arrives while a system is on
    -- the stack, and re-entering the state from inside `world:update` is worse
    -- than being late.
    it("never re-enters Lua to run a lifecycle hook mid-update", function()
        assert.are.equal("false", seen.reentered, "a hook ran while a system was still on the stack")
    end)

    it("runs the hook it had to refuse at the top of the next iteration", function()
        assert.are.equal(
            6,
            tonumber(seen.backgroundHookFrame),
            "the refused backgrounding hook was dropped rather than replayed"
        )
    end)

    -- A game writing a file wants one write per backgrounding. The second is the
    -- one that would be interrupted. The fixture backgrounds four times over the
    -- run, three of them without a return to the foreground in between, so a
    -- host counting events rather than backgroundings would say four.
    it("dispatches one backgrounding hook per backgrounding, and rearms on the foreground", function()
        assert.are.equal(
            2,
            tonumber(seen.backgroundHookCount),
            "four backgrounding events either collapsed to one or were not deduplicated at all"
        )
    end)

    -- Low memory, backgrounding, foregrounding and termination are separate jobs
    -- with separate deadlines, so they are separate hooks. The fixture writes
    -- three of the six, and the three it leaves out must not be an error.
    it("offers each concern its own hook and tolerates the ones a game omits", function()
        assert.are.equal(1, tonumber(seen.lowMemoryHookCount), "low memory did not reach its own hook")
    end)

    -- Deferral is only honest while there is an iteration left to defer into.
    -- SDL ends the loop as soon as it has dispatched a termination, so recording
    -- the hook for a replay that will never happen is a silent drop; the host
    -- reports it instead.
    it("reports rather than defers a hook it cannot run past termination", function()
        assert.are.equal(
            0,
            tonumber(seen.terminatingHookCount),
            "the termination hook ran, so the run did not end where it should have"
        )
        assert.is_truthy(
            raw:find("_terminating could not run", 1, true),
            "a hook that could never be replayed was recorded rather than reported"
        )
    end)
end)
