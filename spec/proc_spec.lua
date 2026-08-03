-- Streaming child processes.
--
-- Every fixture is a POSIX program available on the supported desktop test
-- targets. Tests close their processes explicitly; the internal shutdown in
-- teardown is the application-level safety net under test, not routine test
-- ownership.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local Application = require("tecs.Application")
local processModule = require("tecs.internal.process")
local path = require("tecs.io.Path")
local process = require("tecs.io.Process")
local sdl = require("tecs.ffi.sdl3")
local task = require("tecs.internal.taskruntime")
local tecsIO = require("tecs.io")

ffi.cdef([[
    int tecsProcSpecSetenv(const char *, const char *, int) asm("setenv");
]])

local function now()
    return tonumber(sdl.C.SDL_GetTicks())
end

local function trimmed(text)
    return (text:gsub("%s+$", ""))
end

local function newProcess(options)
    local child, reason = process.new(options)
    assert.is_not_nil(child, reason)
    return child
end

local function communicate(options, exchange)
    local child = newProcess(options)
    local result, reason = child:communicate(exchange)
    assert.is_not_nil(result, reason)
    child:close()
    return result
end

local function shell(script, options, exchange)
    local settings = options or {}
    settings.args = { "/bin/sh", "-c", script }
    return communicate(settings, exchange)
end

describe("streaming processes", function()
    teardown(function()
        processModule.shutdown()
    end)

    it("captures output and reports the exit", function()
        local result = communicate({ args = { "/bin/echo", "hello", "child" } })

        assert.are.equal("hello child", trimmed(result.output))
        assert.are.equal("", result.errorOutput)
        assert.are.equal(0, result.exit.exitCode)
        assert.is_false(result.exit.killed)
        assert.is_false(result.exit.timedOut)
        assert.is_true(result.exit:succeeded())
        assert.is_true(result:succeeded())
    end)

    it("keeps standard error separate and preserves nonzero exits", function()
        local result = shell("echo written; echo complained 1>&2; exit 3")

        assert.are.equal("written", trimmed(result.output))
        assert.are.equal("complained", trimmed(result.errorOutput))
        assert.are.equal(3, result.exit.exitCode)
        assert.is_false(result:succeeded())
    end)

    it("merges standard error into standard output", function()
        local result = shell("echo complained 1>&2", { stderr = "stdout" })

        assert.are.equal("complained", trimmed(result.output))
        assert.are.equal("", result.errorOutput)
    end)

    it("returns a creation failure without allocating a process", function()
        local child, reason = process.new({ args = { "/no/such/tecs-program" } })

        assert.is_nil(child)
        assert.is_string(reason)
        assert.is_true(#reason > 0)
    end)

    it("validates programmer input by raising", function()
        assert.has_error(function()
            process.new({ args = {} })
        end)
        assert.has_error(function()
            process.new({ args = { "/bin/echo", 7 } })
        end)
        assert.has_error(function()
            process.new({ args = { "/bin/echo" }, stderr = "invalid" })
        end)
    end)

    it("runs in the requested working directory", function()
        local result = shell("pwd", { cwd = path.new("/") })

        assert.are.equal("/", trimmed(result.output))
    end)

    it("inherits and overlays environment variables", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local result = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            env = { TECS_PROC_EXTRA = "added" },
        })

        assert.are.equal("[parent][added]", trimmed(result.output))
    end)

    it("can replace the complete environment", function()
        ffi.C.tecsProcSpecSetenv("TECS_PROC_MARKER", "parent", 1)

        local result = shell("echo [$TECS_PROC_MARKER][$TECS_PROC_EXTRA]", {
            clearEnv = true,
            env = { TECS_PROC_EXTRA = "only" },
        })

        assert.are.equal("[][only]", trimmed(result.output))
    end)

    it("feeds a complete string and sends EOF", function()
        local result = communicate({ args = { "/bin/cat" } }, {
            input = "fed through a pipe\n",
        })

        assert.are.equal("fed through a pipe", trimmed(result.output))
    end)

    it("feeds buffers and retained views without string conversion", function()
        local bytes = tecsIO.newBuffer("buffer input")
        local fromBuffer = communicate({ args = { "/bin/cat" } }, { input = bytes })
        local view = bytes:view(7)
        local fromView = communicate({ args = { "/bin/cat" } }, { input = view })

        assert.are.equal("buffer input", fromBuffer.output)
        assert.are.equal("input", fromView.output)

        view:close()
        bytes:close()
    end)

    it("streams interactively through ordinary reader and writer methods", function()
        local child = newProcess({ args = { "/bin/cat" } })
        local written, writeReason = child.stdin:write("request\n")
        assert.is_true(written, writeReason)
        local closed, closeReason = child.stdin:close()
        assert.is_true(closed, closeReason)

        local reply, readReason = child.stdout:read(64)
        assert.are.equal("request\n", reply, readReason)
        assert.are.equal("", child.stdout:read(64))

        local exit = child:wait()
        assert.are.equal(0, exit.exitCode)

        child:close()
    end)

    it("does not expose a second nonblocking pipe API", function()
        local child = newProcess({ args = { "/bin/echo", "one reader" } })
        assert.is_nil(child.stdout.readAvailable)
        assert.is_nil(child.stdout.readAvailableInto)
        assert.is_nil(child.stdin.writeAvailable)
        assert.is_nil(child.stdin.writeAvailableFrom)
        assert.is_nil(child.stdin.writeAvailableView)
        child:close()
    end)

    it("reads directly into a reusable buffer", function()
        local child = newProcess({ args = { "/bin/echo", "direct" } })
        local destination = tecsIO.newBuffer("prefix:")
        local got, reason = child.stdout:readInto(destination, destination:length(), 64)

        assert.are.equal(7, got, reason)
        assert.are.equal("prefix:direct\n", destination:getString())

        child:close()
        destination:close()
    end)

    it("drains output larger than an operating-system pipe", function()
        local line = ("x"):rep(40)
        local result = shell("i=0; while [ $i -lt 8000 ]; do printf '" .. line .. "\\n'; i=$((i + 1)); done")

        assert.are.equal(8000 * 41, #result.output)
    end)

    it("enforces the combined capture limit", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "printf 123456789" } })
        local result, reason = child:communicate({ maxOutputBytes = 4 })

        assert.is_nil(result)
        assert.are.equal("process output exceeds the configured maximum", reason)
        assert.is_false(child:isRunning())
        child:close()
    end)

    it("supports inherited and discarded endpoints", function()
        local child = newProcess({
            args = { "/bin/sh", "-c", "exit 0" },
            stdin = "null",
            stdout = "null",
            stderr = "null",
        })

        assert.is_nil(child.stdin)
        assert.is_nil(child.stdout)
        assert.is_nil(child.stderr)

        local result, reason = child:communicate()
        assert.is_not_nil(result, reason)
        assert.are.equal("", result.output)
        assert.are.equal("", result.errorOutput)
        child:close()
    end)

    it("terminates a child at its deadline", function()
        local started = now()
        local child = newProcess({
            args = { "/bin/sh", "-c", "sleep 30" },
            timeoutMs = 100,
        })
        local exit = child:wait()

        assert.is_true(exit.killed)
        assert.is_true(exit.timedOut)
        assert.is_false(exit:succeeded())
        assert.is_true(now() - started < 5000)
        child:close()
    end)

    it("kills and reaps a child explicitly", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        local killed, reason = child:kill(true)
        assert.is_true(killed, reason)

        local exit = child:wait()
        assert.is_true(exit.killed)
        child:close()
    end)

    it("waits for several process exits", function()
        local children = {
            newProcess({ args = { "/bin/sh", "-c", "sleep 0.1; exit 1" } }),
            newProcess({ args = { "/bin/sh", "-c", "exit 2" } }),
            newProcess({ args = { "/bin/sh", "-c", "exit 3" } }),
        }
        local exits = {
            children[1]:wait(),
            children[2]:wait(),
            children[3]:wait(),
        }

        assert.are.equal(1, exits[1].exitCode)
        assert.are.equal(2, exits[2].exitCode)
        assert.are.equal(3, exits[3].exitCode)

        for _, child in ipairs(children) do
            child:close()
        end
    end)

    it("keeps the exit for a later wait after one waiter is canceled", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 0.1; exit 7" } })
        local scheduler = task.newScheduler()
        local waiting = scheduler:spawnImmediate(function()
            return child:wait()
        end)

        assert.are.equal("pending", waiting.status)
        waiting:cancel("spec cancellation")
        scheduler:step()
        assert.are.equal("canceled", waiting.status)

        local exit = child:wait()
        assert.are.equal(7, exit.exitCode)
        assert.is_false(exit.killed)
        child:close()
    end)

    it("delivers the exit to a second waiter when the first is canceled", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 0.1; exit 5" } })
        local scheduler = task.newScheduler()
        local first = scheduler:spawnImmediate(function()
            return child:wait()
        end)
        local second = scheduler:spawnImmediate(function()
            return child:wait()
        end)

        first:cancel("spec cancellation")
        for _ = 1, 5000 do
            processModule.poll()
            scheduler:step()
            if second.status ~= "pending" then
                break
            end
            sdl.C.SDL_Delay(1)
        end

        assert.are.equal("canceled", first.status)
        assert.are.equal("ready", second.status, second.error)
        assert.are.equal(5, second.value.exitCode)
        child:close()
    end)

    it("ends a pipe read the child never satisfies", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        child.stdout:setTimeout(50)

        local started = now()
        local bytes, reason = child.stdout:read(16)

        assert.is_nil(bytes)
        assert.is_string(reason)
        assert.is_true(now() - started < 5000)
        assert.is_true(child:kill(true))
        child:wait()
        child:close()
    end)

    it("ends a suspended pipe read at the same bound", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        child.stdout:setTimeout(50)
        local scheduler = task.newScheduler()
        local reading = scheduler:spawnImmediate(function()
            local bytes, reason = child.stdout:read(16)
            return { bytes = bytes, reason = reason }
        end)

        assert.are.equal("pending", reading.status)
        for _ = 1, 5000 do
            processModule.poll()
            scheduler:step()
            if reading.status ~= "pending" then
                break
            end
            sdl.C.SDL_Delay(1)
        end

        assert.are.equal("ready", reading.status, reading.error)
        assert.is_nil(reading.value.bytes)
        assert.is_string(reading.value.reason)
        assert.is_true(child:kill(true))
        child:wait()
        child:close()
    end)

    it("validates a reader timeout by raising", function()
        local child = newProcess({ args = { "/bin/echo", "bounded" } })

        assert.has_error(function()
            child.stdout:setTimeout(-1)
        end)
        assert.has_error(function()
            child.stdout:setTimeout(1.5)
        end)

        child:close()
    end)

    it("closing a process closes its endpoints and makes its exit available", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        local input = child.stdin
        local output = child.stdout

        child:close()

        assert.is_true(input:isClosed())
        assert.is_true(output:isClosed())
        assert.is_true(child:wait().killed)
    end)

    it("runs without initializing an SDL subsystem", function()
        local script = os.tmpname()
        local file = assert(io.open(script, "w"))
        file:write(([[
            package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;;"
            local tecs = require("tecs")
            local child, reason = tecs.io.Process.new({args = {"/bin/echo", "headless"}})
            if child == nil then error(reason) end
            local result, communicateReason = child:communicate()
            if result == nil then error(communicateReason) end
            local sdl = require("tecs.ffi.sdl3")
            print(("%%d %%s"):format(
                tonumber(sdl.C.SDL_WasInit(0)),
                (result.output:gsub("%%s+$", ""))))
            child:close()
        ]]):format(root, root))
        file:close()

        local result = communicate({ args = { "luajit", script } })
        os.remove(script)

        assert.are.equal("0 headless", trimmed(result.output), result.errorOutput)
    end)

    describe("through the application lifecycle", function()
        local function build(config)
            config.window = { title = "process", width = 64, height = 64 }
            return Application.newApplication(config)
        end

        it("polls a process once per host iteration", function()
            local child
            local app = build({
                plugin = function()
                    child = newProcess({ args = { "/bin/sh", "-c", "sleep 0.05" } })
                end,
            })
            assert.is_true(app:_init())

            for _ = 1, 400 do
                if not child:isRunning() then
                    break
                end
                app:_iterate(nil, 0, nil)
            end

            assert.is_false(child:isRunning())
            child:close()
            app:_shutdown()
        end)

        it("closes every live process during shutdown", function()
            local child
            local app = build({
                plugin = function()
                    child = newProcess({ args = { "/bin/sh", "-c", "sleep 60" } })
                end,
            })
            assert.is_true(app:_init())

            assert.is_true(app:_shutdown())
            assert.is_true(child:wait().killed)
        end)
    end)
end)
