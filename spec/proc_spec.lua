-- Child processes.
--
-- Every test here runs a real program. The fixtures are the ones a POSIX
-- machine cannot be missing -- /bin/echo, /bin/sh, /bin/cat -- because a test
-- that depends on a tool being installed is a test that fails for a reason
-- nobody changed.
--
-- The blocking calls belong to the worker, so the properties under test are
-- mostly about the boundary: that a run does not hold the caller, that the
-- caller can still end a child it cannot touch, and that teardown does not
-- leave one behind.
--
-- A run is a Future<tecs.platform.os.ProcessResult>, so the four words for how it ended are the
-- ones every other asynchronous thing in the tree uses. The one worth reading
-- twice is that an exit code is not a failure: a child that ran and exited 3
-- settles "ready" carrying a result that says 3, because the code is the
-- answer rather than an error. "failed" is a child that never started and
-- "canceled" is one this process ended.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local Application = require("tecs.Application")
local platformOS = require("tecs.platform.os")
local Future = require("tecs.Future")
local sdl = require("tecs.ffi.sdl3")

ffi.cdef([[
    int tecsProcSpecSetenv(const char *, const char *, int) asm("setenv");
]])

--- Wall-clock milliseconds. `os.clock` measures processor time, and what these
--- tests are about is the time a caller was not spending.
local function now()
    return tonumber(sdl.C.SDL_GetTicks())
end

--- Runs a shell fragment and waits for it.
local function shell(script, options)
    local settings = options or {}
    settings.args = { "/bin/sh", "-c", script }
    return platformOS.runProcess(settings):wait(20000)
end

--- Drops a trailing newline, which every one of these fixtures adds.
local function trimmed(text)
    return (text:gsub("%s+$", ""))
end

--- Pumps until the child behind `run` has started, so a kill has something to
--- land on rather than a task still queued.
local function untilStarted(run)
    local deadline = now() + 20000
    while platformOS.processResult(run).pid == 0 and now() < deadline do
        platformOS.updateProcesses()
    end
    assert.is_true(platformOS.processResult(run).pid > 0, "the child never started")
end

describe("proc", function()
    teardown(function()
        platformOS.shutdownProcesses()
    end)

    it("runs a program and answers its output and exit code", function()
        local run = platformOS.runProcess({ args = { "/bin/echo", "hello", "child" } })
        assert.are.equal("pending", run.status)

        run:wait(20000)
        assert.are.equal("ready", run.status)
        assert.is_nil(run.error)

        local result = run.value
        assert.are.equal(0, result.exitCode)
        assert.are.equal("hello child", trimmed(result.output))
        assert.is_true(result:succeeded())
        assert.is_true(result.pid > 0, "a started child reports its process id")
        assert.are.same({ "/bin/echo", "hello", "child" }, result.args)
        assert.are.equal(result, platformOS.processResult(run), "the future carries the record it filled in")
    end)

    -- The distinction the four states exist to make. A tool whose exit code is
    -- data must not have every non-zero exit propagate as a failure through
    -- `map`, so a child that ran is "ready" whatever it reported.
    it("keeps error output apart from output, and reports a failing exit", function()
        local run = shell("echo written; echo complained 1>&2; exit 3")
        assert.are.equal("ready", run.status, "an exit code is an answer, not a failure")
        assert.are.equal(3, run.value.exitCode)
        assert.are.equal("written", trimmed(run.value.output))
        assert.are.equal("complained", trimmed(run.value.errorOutput))
        assert.is_false(run.value:succeeded(), "a non-zero exit is not success")
    end)

    it("folds error output into output when asked", function()
        local run = shell("echo complained 1>&2", { mergeStderr = true })
        assert.are.equal("ready", run.status)
        assert.are.equal("complained", trimmed(run.value.output))
        assert.are.equal("", run.value.errorOutput)
    end)

    it("reports a program it cannot start as a status, not a raise", function()
        local run = platformOS.runProcess({ args = { "/no/such/tecs-program" } })
        run:wait(20000)
        assert.are.equal("failed", run.status, "a child that never started is the failure case")
        assert.is_string(run.error)
        assert.is_true(#run.error > 0, "a failure says what went wrong")
        assert.has_error(function()
            return run.value
        end)
    end)

    it("runs the child in a given working directory", function()
        local run = shell("pwd", { cwd = "/" })
        assert.are.equal("ready", run.status)
        assert.are.equal("/", trimmed(run.value.output))
    end)

    it("inherits the environment and lets a variable be set over it", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local inherited = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            env = { TECS_PROC_EXTRA = "added" },
        })
        assert.are.equal("[parent][added]", trimmed(inherited.value.output))
    end)

    it("gives the child only what it is handed when the environment is cleared", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local cleared = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            clearEnv = true,
            env = { TECS_PROC_EXTRA = "only" },
        })
        assert.are.equal("[][only]", trimmed(cleared.value.output))
    end)

    it("feeds bytes to the child and closes its input", function()
        -- cat reads to end of input, so this only returns if the input pipe
        -- was closed once the bytes were through.
        local run = platformOS
            .runProcess({
                args = { "/bin/cat" },
                input = "fed through a pipe\n",
            })
            :wait(20000)
        assert.are.equal("ready", run.status)
        assert.are.equal("fed through a pipe", trimmed(run.value.output))
    end)

    it("does not hold the caller while the child runs", function()
        local slow = platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 1; echo late" } })

        -- A frame's worth of polling, over and over, while the child sleeps.
        -- Every pass has to come straight back: the blocking wait and the
        -- blocking read are the worker's, not this thread's.
        local polls = 0
        local pollStart = now()
        while now() - pollStart < 200 do
            platformOS.updateProcesses()
            polls = polls + 1
        end
        assert.are.equal("pending", slow.status, "the child is still going")
        assert.is_true(polls > 200, "polling is cheap: " .. polls .. " passes in 200ms")

        slow:wait(20000)
        assert.are.equal("ready", slow.status)
        assert.are.equal("late", trimmed(slow.value.output))
    end)

    it("runs several children at once on one worker", function()
        -- Children that keep going until they are killed, so what is measured
        -- is that four of them exist together rather than how fast a machine
        -- happens to start them.
        local runs = {}
        for index = 1, 4 do
            runs[index] = platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        end

        -- A child reports its process id as soon as it is started, so four ids
        -- alongside four pending futures is the overlap itself rather than a
        -- clock reading that says it probably happened.
        local deadline = now() + 20000
        local live
        repeat
            platformOS.updateProcesses()
            live = 0
            for index = 1, 4 do
                if platformOS.processResult(runs[index]).pid > 0 and runs[index].status == "pending" then
                    live = live + 1
                end
            end
        until live == 4 or now() > deadline
        assert.are.equal(4, live, "four children have to be running at once")

        local seen = {}
        for index = 1, 4 do
            local pid = platformOS.processResult(runs[index]).pid
            assert.is_nil(seen[pid], "each child is its own process")
            seen[pid] = true
            platformOS.killProcess(runs[index], true)
        end

        for index = 1, 4 do
            runs[index]:wait(20000)
            assert.are.equal("canceled", runs[index].status)
        end
    end)

    -- What replaces waiting on the module's own list of runs: the join every
    -- other subsystem uses, keeping input order whatever order they finish in.
    it("waits for several runs through one join", function()
        local runs = {
            platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 0.3; echo first" } }),
            platformOS.runProcess({ args = { "/bin/echo", "second" } }),
            platformOS.runProcess({ args = { "/bin/echo", "third" } }),
        }
        local joined = Future.all(runs):wait(20000)

        assert.are.equal("ready", joined.status)
        assert.are.equal(0, platformOS.pendingProcesses())
        assert.are.equal("first", trimmed(joined.value[1].output))
        assert.are.equal("second", trimmed(joined.value[2].output))
        assert.are.equal("third", trimmed(joined.value[3].output))
    end)

    it("composes a run into what the caller actually wanted", function()
        local text = platformOS
            .runProcess({ args = { "/bin/echo", "composed" } })
            :map(function(result)
                return trimmed(result.output)
            end)
            :wait(20000)

        assert.are.equal("ready", text.status)
        assert.are.equal("composed", text.value)
    end)

    it("kills a child on request", function()
        local run = platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        -- The kill is a message to the worker, so the child has to exist
        -- before it lands; the worker starts it before it reads the next
        -- message, so ordering is the channel's rather than a sleep's.
        platformOS.killProcess(run, true)
        run:wait(20000)
        assert.are.equal("canceled", run.status, "this process ended it")
        assert.are.equal("killed", run.error)
    end)

    -- The other spelling, and the one that counts holders. A run nothing else
    -- is watching ends when its last consumer gives it up.
    it("ends a child when the last holder of its future cancels", function()
        local run = platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        untilStarted(run)

        run:cancel()
        assert.are.equal("canceled", run.status)

        -- And the kill really went out: the worker stops holding the child.
        local deadline = now() + 20000
        while platformOS.pendingProcesses() > 0 and now() < deadline do
            platformOS.updateProcesses()
        end
        assert.are.equal(0, platformOS.pendingProcesses(), "the runner is still holding the child")
    end)

    it("keeps the child for another holder when one gives up", function()
        local run = platformOS.runProcess({ args = { "/bin/echo", "shared" } })
        run._watchers = run._watchers + 1

        run:cancel()
        assert.are.equal("pending", run.status, "a shared run was ended by one holder")

        run:wait(20000)
        assert.are.equal("ready", run.status)
        assert.are.equal("shared", trimmed(run.value.output))
    end)

    it("kills a child that outruns its timeout", function()
        local started = now()
        local run = platformOS
            .runProcess({
                args = { "/bin/sh", "-c", "sleep 30" },
                timeoutMs = 200,
            })
            :wait(20000)
        assert.are.equal("canceled", run.status)
        assert.are.equal("timed out", run.error)
        assert.is_true(now() - started < 5000, "the timeout is what ended it")
    end)

    -- A killed child settles with no value, because there is no answer to the
    -- question it was asked. What it managed to say before it was stopped is
    -- still worth having, and it is on the record the run filled in.
    it("keeps what a child wrote before it was killed", function()
        local run = platformOS
            .runProcess({
                args = { "/bin/sh", "-c", "echo spoke; sleep 30" },
                timeoutMs = 500,
            })
            :wait(20000)
        assert.are.equal("canceled", run.status)
        assert.has_error(function()
            return run.value
        end)
        assert.are.equal("spoke", trimmed(platformOS.processResult(run).output))
    end)

    it("reads more than a pipe will hold without deadlocking", function()
        -- A child writing past the pipe buffer stops until someone reads. The
        -- worker reads as it polls, which is what keeps this from hanging.
        local run = shell("for i in $(seq 1 8000); do echo " .. ("x"):rep(40) .. "; done")
        assert.are.equal("ready", run.status)
        assert.are.equal(8000 * 41, #run.value.output, "every byte past the pipe buffer arrives")
    end)

    it("refuses a run with nothing to run", function()
        assert.has_error(function()
            platformOS.runProcess({ args = {} })
        end)
        assert.has_error(function()
            platformOS.runProcess({ args = { "/bin/echo", 7 } })
        end)
    end)

    it("kills a child that is still running at shutdown, and returns", function()
        local run = platformOS.runProcess({ args = { "/bin/sh", "-c", "trap '' TERM; sleep 60" } })
        untilStarted(run)

        local started = now()
        platformOS.shutdownProcesses()
        local elapsed = now() - started

        assert.are.equal("canceled", run.status, "teardown ends a child, it does not detach it")
        assert.is_false(platformOS.processRunnerInstalled(), "the worker is joined")
        assert.is_true(elapsed < 5000, "teardown is bounded: " .. elapsed .. "ms")

        -- And the module still works afterwards: the next run installs again.
        local after = platformOS.runProcess({ args = { "/bin/echo", "again" } }):wait(20000)
        assert.are.equal("again", trimmed(after.value.output))
    end)

    -- The defect the duplicated shutdown carried: `pending` was cleared
    -- whatever state it was in, so a child the kernel had not reaped left its
    -- handle reading "running" for the rest of the process, against a runner
    -- that no longer existed and would never answer. Nothing in flight may
    -- outlive shutdown unsettled, by whichever branch it got there.
    it("leaves nothing pending after shutdown", function()
        local runs = {}
        for index = 1, 3 do
            runs[index] = platformOS.runProcess({ args = { "/bin/sh", "-c", "trap '' TERM; sleep 60" } })
        end
        untilStarted(runs[3])

        platformOS.shutdownProcesses()

        assert.are.equal(0, platformOS.pendingProcesses())
        for index = 1, 3 do
            assert.are.equal(
                "canceled",
                runs[index].status,
                "a run outlived the runner still reading as though it were going"
            )
        end
    end)

    it("runs a child with no SDL subsystem initialized", function()
        -- Proved from inside a fresh interpreter rather than from here, where
        -- another spec in this run has already brought up video. The child
        -- requires the whole surface, runs a child of its own, and then asks
        -- what SDL has initialized; the answer has to be nothing.
        local script = os.tmpname()
        local file = assert(io.open(script, "w"))
        file:write(([[
            package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;;"
            local tecs = require("tecs")
            local run = tecs.platform.os.runProcess({ args = { "/bin/echo", "headless" } })
            run:wait(20000)
            local sdl = require("tecs.ffi.sdl3")
            print(("%%d %%s %%s"):format(
                tonumber(sdl.C.SDL_WasInit(0)), run.status,
                (run.value.output:gsub("%%s+$", ""))))
            tecs.platform.os.shutdownProcesses()
        ]]):format(root, root))
        file:close()

        local run = platformOS.runProcess({ args = { "luajit", script } }):wait(30000)
        os.remove(script)

        assert.are.equal("ready", run.status, run.error)
        assert.are.equal("0 ready headless", trimmed(run.value.output))
    end)

    describe("through the application lifecycle", function()
        --- An application with a window small enough to be cheap. Neither
        --- `logFile` nor `debug` is set, so no log file is written.
        local function build(config)
            config.window = { title = "proc", width = 64, height = 64 }
            return Application.newApplication(config)
        end

        it("resolves a run without the game pumping it", function()
            local run
            local app = build({
                plugin = function()
                    run = platformOS.runProcess({ args = { "/bin/echo", "framed" } })
                end,
            })
            assert.is_true(app:_init())
            assert.are.equal("pending", run.status)

            -- Nothing in this application waits on the run, so only the loop's
            -- own call can move it.
            for _ = 1, 400 do
                if run.status ~= "pending" then
                    break
                end
                app:_iterate(nil, 0, nil)
            end

            assert.are.equal("ready", run.status, "the loop never drained the runner")
            assert.are.equal("framed", trimmed(run.value.output))
            app:_shutdown()
        end)

        it("ends a child and stops the runner at shutdown", function()
            local run
            local app = build({
                plugin = function()
                    run = platformOS.runProcess({ args = { "/bin/sh", "-c", "sleep 60" } })
                end,
            })
            assert.is_true(app:_init())
            untilStarted(run)

            assert.is_true(app:_shutdown())
            assert.are.equal("canceled", run.status, "the child outlived the application")
            assert.is_false(platformOS.processRunnerInstalled(), "the runner thread outlived the application")
        end)
    end)
end)
