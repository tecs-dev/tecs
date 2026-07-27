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

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local Application = require("tecs.Application")
local proc = require("tecs.platform.proc")
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
    return proc.run(settings):wait(20000)
end

--- Drops a trailing newline, which every one of these fixtures adds.
local function trimmed(text)
    return (text:gsub("%s+$", ""))
end

describe("proc", function()
    teardown(function()
        proc.shutdown()
    end)

    it("runs a program and answers its output and exit code", function()
        local run = proc.run({ args = { "/bin/echo", "hello", "child" } })
        assert.are.equal("running", run.status)
        assert.is_true(run:isRunning())

        run:wait(20000)
        assert.are.equal("exited", run.status)
        assert.are.equal(0, run.exitCode)
        assert.are.equal("hello child", trimmed(run.output))
        assert.is_true(run:succeeded())
        assert.is_false(run:isRunning())
        assert.is_nil(run.error)
        assert.is_true(run.pid > 0, "a started child reports its process id")
    end)

    it("keeps error output apart from output, and reports a failing exit", function()
        local run = shell("echo written; echo complained 1>&2; exit 3")
        assert.are.equal("exited", run.status)
        assert.are.equal(3, run.exitCode)
        assert.are.equal("written", trimmed(run.output))
        assert.are.equal("complained", trimmed(run.errorOutput))
        assert.is_false(run:succeeded(), "a non-zero exit is not success")
    end)

    it("folds error output into output when asked", function()
        local run = shell("echo complained 1>&2", { mergeStderr = true })
        assert.are.equal("exited", run.status)
        assert.are.equal("complained", trimmed(run.output))
        assert.are.equal("", run.errorOutput)
    end)

    it("reports a program it cannot start as a status, not a raise", function()
        local run = proc.run({ args = { "/no/such/tecs-program" } })
        run:wait(20000)
        assert.are.equal("failed", run.status)
        assert.is_string(run.error)
        assert.is_true(#run.error > 0, "a failure says what went wrong")
        assert.is_false(run:succeeded())
    end)

    it("runs the child in a given working directory", function()
        local run = shell("pwd", { cwd = "/" })
        assert.are.equal("exited", run.status)
        assert.are.equal("/", trimmed(run.output))
    end)

    it("inherits the environment and lets a variable be set over it", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local inherited = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            env = { TECS_PROC_EXTRA = "added" },
        })
        assert.are.equal("[parent][added]", trimmed(inherited.output))
    end)

    it("gives the child only what it is handed when the environment is cleared", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local cleared = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            clearEnv = true,
            env = { TECS_PROC_EXTRA = "only" },
        })
        assert.are.equal("[][only]", trimmed(cleared.output))
    end)

    it("feeds bytes to the child and closes its input", function()
        -- cat reads to end of input, so this only returns if the input pipe
        -- was closed once the bytes were through.
        local run = proc.run({
            args = { "/bin/cat" },
            input = "fed through a pipe\n",
        }):wait(20000)
        assert.are.equal("exited", run.status)
        assert.are.equal("fed through a pipe", trimmed(run.output))
    end)

    it("does not hold the caller while the child runs", function()
        local slow = proc.run({ args = { "/bin/sh", "-c", "sleep 1; echo late" } })

        -- A frame's worth of polling, over and over, while the child sleeps.
        -- Every pass has to come straight back: the blocking wait and the
        -- blocking read are the worker's, not this thread's.
        local polls = 0
        local pollStart = now()
        while now() - pollStart < 200 do
            proc.update()
            polls = polls + 1
        end
        assert.is_true(slow:isRunning(), "the child is still going")
        assert.is_true(polls > 200, "polling is cheap: " .. polls .. " passes in 200ms")

        slow:wait(20000)
        assert.are.equal("exited", slow.status)
        assert.are.equal("late", trimmed(slow.output))
    end)

    it("runs several children at once on one worker", function()
        -- Children that keep going until they are killed, so what is measured
        -- is that four of them exist together rather than how fast a machine
        -- happens to start them.
        local runs = {}
        for index = 1, 4 do
            runs[index] = proc.run({ args = { "/bin/sh", "-c", "sleep 30" } })
        end

        -- A child reports its process id as soon as it is started, so four
        -- ids alongside four "running" is the overlap itself rather than a
        -- clock reading that says it probably happened.
        local deadline = now() + 20000
        local live
        repeat
            proc.update()
            live = 0
            for index = 1, 4 do
                if runs[index].pid > 0 and runs[index]:isRunning() then
                    live = live + 1
                end
            end
        until live == 4 or now() > deadline
        assert.are.equal(4, live, "four children have to be running at once")

        local seen = {}
        for index = 1, 4 do
            assert.is_nil(seen[runs[index].pid], "each child is its own process")
            seen[runs[index].pid] = true
            runs[index]:kill(true)
        end

        for index = 1, 4 do
            runs[index]:wait(20000)
            assert.are.equal("killed", runs[index].status)
        end
    end)

    it("kills a child on request", function()
        local run = proc.run({ args = { "/bin/sh", "-c", "sleep 30" } })
        -- The kill is a message to the worker, so the child has to exist
        -- before it lands; the worker starts it before it reads the next
        -- message, so ordering is the channel's rather than a sleep's.
        run:kill(true)
        run:wait(20000)
        assert.are.equal("killed", run.status)
        assert.are.equal("killed", run.error)
        assert.is_false(run:succeeded())
    end)

    it("kills a child that outruns its timeout", function()
        local started = now()
        local run = proc.run({
            args = { "/bin/sh", "-c", "sleep 30" },
            timeoutMs = 200,
        }):wait(20000)
        assert.are.equal("killed", run.status)
        assert.are.equal("timed out", run.error)
        assert.is_true(now() - started < 5000, "the timeout is what ended it")
    end)

    it("keeps what a child wrote before it was killed", function()
        local run = proc.run({
            args = { "/bin/sh", "-c", "echo spoke; sleep 30" },
            timeoutMs = 500,
        }):wait(20000)
        assert.are.equal("killed", run.status)
        assert.are.equal("spoke", trimmed(run.output))
    end)

    it("reads more than a pipe will hold without deadlocking", function()
        -- A child writing past the pipe buffer stops until someone reads. The
        -- worker reads as it polls, which is what keeps this from hanging.
        local run = shell("for i in $(seq 1 8000); do echo " .. ("x"):rep(40) .. "; done")
        assert.are.equal("exited", run.status)
        assert.are.equal(8000 * 41, #run.output, "every byte past the pipe buffer arrives")
    end)

    it("refuses a run with nothing to run", function()
        assert.has_error(function()
            proc.run({ args = {} })
        end)
        assert.has_error(function()
            proc.run({ args = { "/bin/echo", 7 } })
        end)
    end)

    it("kills a child that is still running at shutdown, and returns", function()
        local run = proc.run({ args = { "/bin/sh", "-c", "trap '' TERM; sleep 60" } })
        -- Started, so shutdown has something to end rather than a queued task.
        while run.pid == 0 do
            proc.update()
        end

        local started = now()
        proc.shutdown()
        local elapsed = now() - started

        assert.are.equal("killed", run.status, "teardown ends a child, it does not detach it")
        assert.is_false(proc.installed(), "the worker is joined")
        assert.is_true(elapsed < 5000, "teardown is bounded: " .. elapsed .. "ms")

        -- And the module still works afterwards: the next run installs again.
        local after = proc.run({ args = { "/bin/echo", "again" } }):wait(20000)
        assert.are.equal("again", trimmed(after.output))
    end)

    it("runs a child with no SDL subsystem initialised", function()
        -- Proved from inside a fresh interpreter rather than from here, where
        -- another spec in this run has already brought up video. The child
        -- requires the whole surface, runs a child of its own, and then asks
        -- what SDL has initialised; the answer has to be nothing.
        local script = os.tmpname()
        local file = assert(io.open(script, "w"))
        file:write(([[
            package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;;"
            local tecs = require("tecs")
            local run = tecs.proc.run({ args = { "/bin/echo", "headless" } })
            run:wait(20000)
            local sdl = require("tecs.ffi.sdl3")
            print(("%%d %%s %%s"):format(
                tonumber(sdl.C.SDL_WasInit(0)), run.status,
                (run.output:gsub("%%s+$", ""))))
            tecs.proc.shutdown()
        ]]):format(root, root))
        file:close()

        local run = proc.run({ args = { "luajit", script } }):wait(30000)
        os.remove(script)

        assert.are.equal("exited", run.status, run.errorOutput)
        assert.are.equal("0 exited headless", trimmed(run.output))
    end)

    describe("through the application lifecycle", function()
        --- An application with a window small enough to be cheap and no log.
        local function build(config)
            config.window = { title = "proc", width = 64, height = 64 }
            config.logFile = ""
            return Application.create(config)
        end

        it("resolves a run without the game pumping it", function()
            local run
            local app = build({
                plugin = function()
                    run = proc.run({ args = { "/bin/echo", "framed" } })
                end,
            })
            assert.is_true(app:_init())
            assert.are.equal("running", run.status)

            -- Nothing in this application waits on the run, so only the loop's
            -- own call can move it.
            for _ = 1, 400 do
                if not run:isRunning() then
                    break
                end
                app:_iterate(nil, 0, nil)
            end

            assert.are.equal("exited", run.status, "the loop never drained the runner")
            assert.are.equal("framed", trimmed(run.output))
            app:_shutdown()
        end)

        it("ends a child and stops the runner at shutdown", function()
            local run
            local app = build({
                plugin = function()
                    run = proc.run({ args = { "/bin/sh", "-c", "sleep 60" } })
                end,
            })
            assert.is_true(app:_init())
            while run.pid == 0 do
                proc.update()
            end

            assert.is_true(app:_shutdown())
            assert.are.equal("killed", run.status, "the child outlived the application")
            assert.is_false(proc.installed(), "the runner thread outlived the application")
        end)
    end)
end)
