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
local Future = require("tecs.Future")
local processModule = require("tecs.internal.process")
local path = require("tecs.io.path")
local process = require("tecs.io.process")
local runtime = require("tecs.runtime")
local sdl = require("tecs.ffi.sdl3")
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
        local result = shell("pwd", { cwd = path.newPath("/") })

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

        local exit = child.finished:wait(20000)
        assert.are.equal("ready", exit.status, exit.error)
        assert.are.equal(0, exit.value.exitCode)

        child:close()
    end)

    it("reports no-data separately from EOF in nonblocking reads", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 0.1; printf ready" } })
        local bytes, reason = child.stdout:readAvailable()
        assert.is_nil(bytes)
        assert.is_nil(reason)

        local received = ""
        local deadline = now() + 20000
        while now() < deadline do
            runtime.poll()
            bytes, reason = child.stdout:readAvailable()
            assert.is_nil(reason)
            if bytes == "" then
                break
            elseif bytes ~= nil then
                received = received .. bytes
            end
        end

        assert.are.equal("ready", received)
        assert.is_true(child.stdout:isEOF())
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

    it("moves available pipe bytes directly between reusable buffers", function()
        local child = newProcess({ args = { "/bin/cat" } })
        local source = tecsIO.newBuffer("nonblocking buffer")
        local destination = tecsIO.newBuffer()
        local sent = 0
        local deadline = now() + 20000

        while sent < source:length() and now() < deadline do
            local wrote, writeReason = child.stdin:writeAvailableFrom(source, sent)
            assert.is_nil(writeReason)
            if wrote ~= nil then
                sent = sent + wrote
            else
                runtime.poll()
            end
        end
        child.stdin:close()

        while now() < deadline do
            local got, readReason = child.stdout:readAvailableInto(destination, destination:length(), 64)
            assert.is_nil(readReason)
            if got == 0 then
                break
            elseif got == nil then
                runtime.poll()
            end
        end

        assert.are.equal(source:length(), sent)
        assert.are.equal(source:getString(), destination:getString())

        child:close()
        destination:close()
        source:close()
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
        local exit = child.finished:wait(20000)

        assert.are.equal("ready", exit.status, exit.error)
        assert.is_true(exit.value.killed)
        assert.is_true(exit.value.timedOut)
        assert.is_false(exit.value:succeeded())
        assert.is_true(now() - started < 5000)
        child:close()
    end)

    it("kills and reaps a child explicitly", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        local killed, reason = child:kill(true)
        assert.is_true(killed, reason)

        local exit = child.finished:wait(20000)
        assert.are.equal("ready", exit.status, exit.error)
        assert.is_true(exit.value.killed)
        child:close()
    end)

    it("joins several process-exit futures", function()
        local children = {
            newProcess({ args = { "/bin/sh", "-c", "sleep 0.1; exit 1" } }),
            newProcess({ args = { "/bin/sh", "-c", "exit 2" } }),
            newProcess({ args = { "/bin/sh", "-c", "exit 3" } }),
        }
        local joined = Future.all({
            children[1].finished,
            children[2].finished,
            children[3].finished,
        }):wait(20000)

        assert.are.equal("ready", joined.status, joined.error)
        assert.are.equal(1, joined.value[1].exitCode)
        assert.are.equal(2, joined.value[2].exitCode)
        assert.are.equal(3, joined.value[3].exitCode)

        for _, child in ipairs(children) do
            child:close()
        end
    end)

    it("closing a process closes its endpoints and settles its future", function()
        local child = newProcess({ args = { "/bin/sh", "-c", "sleep 30" } })
        local input = child.stdin
        local output = child.stdout

        child:close()

        assert.is_true(input:isClosed())
        assert.is_true(output:isClosed())
        assert.are.equal("ready", child.finished.status)
        assert.is_true(child.finished.value.killed)
    end)

    it("runs without initializing an SDL subsystem", function()
        local script = os.tmpname()
        local file = assert(io.open(script, "w"))
        file:write(([[
            package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;;"
            local tecs = require("tecs")
            local child, reason = tecs.io.process.new({args = {"/bin/echo", "headless"}})
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

        it("polls a process future once per host iteration", function()
            local child
            local app = build({
                plugin = function()
                    child = newProcess({ args = { "/bin/sh", "-c", "sleep 0.05" } })
                end,
            })
            assert.is_true(app:_init())

            for _ = 1, 400 do
                if child.finished.status ~= "pending" then
                    break
                end
                app:_iterate(nil, 0, nil)
            end

            assert.are.equal("ready", child.finished.status)
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
            assert.are.equal("ready", child.finished.status)
            assert.is_true(child.finished.value.killed)
        end)
    end)
end)
