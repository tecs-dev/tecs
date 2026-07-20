require("busted")

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local love2d_mock <const> = require("spec.love2d.love2d_mock")

local record RunTestComp is tecs.Component
    value: integer
    metamethod __call: function(self, value: integer): RunTestComp
end

local RunTest: RunTestComp = tecs.newComponent({
    name = "RunSpecHotReloadComponent",
    container = RunTestComp,
    fields = {
        value = {type = "integer"},
    },
})

local function installTecs2dStubs()
    package.loaded["tecs2d"] = nil
    local escapePressed = false
    package.loaded["tecs2d.input"] = {
        setEscapePressed = function(value: boolean)
            escapePressed = value
        end,
        isKeyPressed = function(key: string): boolean
            return key == "escape" and escapePressed
        end,
        update = function() end,
        bindWorld = function(_world: tecs.World) end,
        enterFixedPhase = function() end,
        exitFixedPhase = function() end,
    }
    package.loaded["tecs2d.internal.handlers"] = nil
    package.loaded["tecs2d.gfx"] = {
        PIPELINE = {},
        newPipeline = function(config: {string:any}): any
            local pipeline = {
                _time = 0,
                getTimeScale = function(_self): number return 1 end,
                getTime = function(self): number return self._time or 0 end,
            }
            config.world.resources[{}] = pipeline
            return pipeline
        end,
    }
    package.loaded["tecs2d.assets"] = {
        new = function(_root: string): any
            return {
                update = function() end,
                shutdown = function() end,
            }
        end,
    }
    package.loaded["tecs2d.audio"] = {
        plugin = function(): tecs.Plugin
            return function(_world: tecs.World) end
        end,
    }
    package.loaded["tecs2d.controller"] = {
        plugin = function(): tecs.Plugin
            return function(_world: tecs.World) end
        end,
    }
    package.loaded["tecs2d.tween"] = {
        plugin = function(_world: tecs.World) end,
    }
    package.loaded["tecs2d.tiled"] = {
        plugin = function(_world: tecs.World) end,
    }
    package.loaded["tecs2d.ui"] = {
        plugin = function(_world: tecs.World) end,
    }
end

local function makeFilesystem(files: {string: string}, modtimes: {string: number})
    local fs = love2d_mock.filesystem as {string: any}
    fs.read = function(path: string): string
        return files[path]
    end
    fs.getInfo = function(path: string): any
        local mt = modtimes[path]
        if mt == nil and files[path] == nil then
            return nil
        end
        return {modtime = mt or 1}
    end
    fs.write = function(path: string, contents: string): boolean, string
        files[path] = contents
        modtimes[path] = modtimes[path] or 1
        return true, nil
    end
    fs.remove = function(path: string): boolean, string
        files[path] = nil
        modtimes[path] = nil
        return true, nil
    end
end

local function countRunTest(world: tecs.World): integer, integer
    local q = world:query({include = {RunTest}})
    local count = 0
    local value = 0
    for arch, len in q:iter() do
        local comps = arch:get(RunTest) as {RunTest}
        for i = 1, len do
            count = count + 1
            value = comps[i].value or 0
        end
    end
    return count, value
end

describe("tecs2d.run hotReload", function()
    local files: {string: string}
    local modtimes: {string: number}

    before_each(function()
        files = {}
        modtimes = {}
        makeFilesystem(files, modtimes)
        installTecs2dStubs()

        local globalEnv = _G as {string:any}
        globalEnv["love"] = love2d_mock
        globalEnv["arg"] = {}
        love2d_mock.arg = {
            parseGameArguments = function(a: {string}): {string}
                return a
            end,
        }
        love2d_mock.load = nil
        love2d_mock.draw = nil
        love2d_mock.update = nil
        love2d_mock.quit = function(): boolean return false end
        love2d_mock.timer.currentTime = 0
        love2d_mock.timer.step = function(): number
            love2d_mock.timer.currentTime = love2d_mock.timer.currentTime + 0.1
            return 0.1
        end
        love2d_mock.event.poll = function(): function(): string, any, any, any, any, any
            return function(): string, any, any, any, any, any
                return nil
            end
        end
    end)

    after_each(function()
        package.loaded["tecs2d"] = nil
        package.loaded["tecs2d.input"] = nil
        package.loaded["tecs2d.internal.handlers"] = nil
        package.loaded["tecs2d.gfx"] = nil
        package.loaded["tecs2d.assets"] = nil
        package.loaded["tecs2d.audio"] = nil
        package.loaded["tecs2d.controller"] = nil
        package.loaded["tecs2d.tween"] = nil
        package.loaded["tecs2d.tiled"] = nil
        package.loaded["tecs2d.ui"] = nil
        package.loaded["run_spec.baseline"] = nil
        package.loaded["run_spec.reloadable"] = nil
    end)

    it("restores hot reload snapshots between Startup and PostStartup", function()
        local snapshotWorld = tecs.newWorld()
        snapshotWorld:spawn(tecs.builtins.Key("run-spec.subject"), RunTest(9))
        snapshotWorld:commit()
        files[".tecs-hot-reload.snapshot"] = tostring(snapshotWorld:saveSnapshot().buffer)
        modtimes[".tecs-hot-reload.snapshot"] = 10

        local observedWorld: tecs.World = nil
        local order: {string} = {}
        local postCount = 0
        local postValue = 0
        local reboundId = 0

        local tecs2d = require("tecs2d")
        local runner = tecs2d.run({
            fps = 60,
            hotReload = {
                enabled = true,
                snapshotPath = ".tecs-hot-reload.snapshot",
                stampPath = "build/.tecs-reload-stamp",
            },
            game = function(world: tecs.World)
                observedWorld = world
                world:addSystem({
                    name = "run-spec.pre",
                    phase = tecs.phases.PreStartup,
                    run = function() order[#order + 1] = "pre" end,
                })
                world:addSystem({
                    name = "run-spec.start",
                    phase = tecs.phases.Startup,
                    run = function()
                        order[#order + 1] = "startup"
                        world:spawn(RunTest(1))
                        world:commit()
                    end,
                })
                world:addSystem({
                    name = "run-spec.post",
                    phase = tecs.phases.PostStartup,
                    run = function()
                        order[#order + 1] = "post"
                        reboundId = world:requireKey("run-spec.subject")
                        postCount, postValue = countRunTest(world)
                    end,
                })
            end,
            render = {},
        })

        runner()

        luassert.same({"pre", "startup", "post"}, order)
        luassert.equals(1, postCount)
        luassert.equals(0, postValue)
        luassert.is_true(reboundId ~= 0)
        luassert.is_not_nil(observedWorld)
        luassert.equals(reboundId, observedWorld:requireKey("run-spec.subject"))
        luassert.is_true(observedWorld:isAlive(reboundId))
        luassert.is_nil(files[".tecs-hot-reload.snapshot"])
    end)

    it("polls one stamp file and restarts once after debounce", function()
        modtimes["build/.tecs-reload-stamp"] = 1
        local shutdownCalled = false

        local tecs2d = require("tecs2d")
        local runner = tecs2d.run({
            fps = 60,
            hotReload = {
                enabled = true,
                snapshotPath = ".tecs-hot-reload.snapshot",
                stampPath = "build/.tecs-reload-stamp",
                pollInterval = 0.1,
                debounce = 0.2,
            },
            game = function(world: tecs.World)
                world:addSystem({
                    name = "run-spec.shutdown",
                    phase = tecs.phases.Shutdown,
                    run = function() shutdownCalled = true end,
                })
            end,
            render = {},
        })
        local loop = runner()

        luassert.is_nil(loop())
        modtimes["build/.tecs-reload-stamp"] = 2
        luassert.is_nil(loop())
        luassert.equals("restart", loop())
        luassert.is_true(shutdownCalled)
        luassert.is_string(files[".tecs-hot-reload.snapshot"])
    end)

    it("clears modules loaded after the tecs2d module baseline", function()
        modtimes["build/.tecs-reload-stamp"] = 1
        package.loaded["run_spec.baseline"] = {keep = true}
        package.loaded["run_spec.reloadable"] = nil

        local tecs2d = require("tecs2d")
        package.loaded["run_spec.reloadable"] = {clear = true}
        local runner = tecs2d.run({
            fps = 60,
            hotReload = {
                enabled = true,
                snapshotPath = ".tecs-hot-reload.snapshot",
                stampPath = "build/.tecs-reload-stamp",
                pollInterval = 0.1,
                debounce = 0.1,
            },
            game = function(_world: tecs.World) end,
            render = {},
        })
        local loop = runner()

        modtimes["build/.tecs-reload-stamp"] = 2
        luassert.equals("restart", loop())

        luassert.is_not_nil(package.loaded["run_spec.baseline"])
        luassert.is_nil(package.loaded["run_spec.reloadable"])
    end)

    it("does not restart when snapshot save fails", function()
        modtimes["build/.tecs-reload-stamp"] = 1
        local fs = love2d_mock.filesystem as {string: any}
        fs.write = function(_path: string, _contents: string): boolean, string
            return false, "disk full"
        end
        local shutdownCalled = false

        local tecs2d = require("tecs2d")
        local runner = tecs2d.run({
            fps = 60,
            hotReload = {
                enabled = true,
                snapshotPath = ".tecs-hot-reload.snapshot",
                stampPath = "build/.tecs-reload-stamp",
                pollInterval = 0.1,
                debounce = 0.1,
            },
            game = function(world: tecs.World)
                world:addSystem({
                    name = "run-spec.shutdown-failure",
                    phase = tecs.phases.Shutdown,
                    run = function() shutdownCalled = true end,
                })
            end,
            render = {},
        })
        local loop = runner()

        modtimes["build/.tecs-reload-stamp"] = 2
        luassert.is_nil(loop())
        luassert.is_nil(loop())
        luassert.is_false(shutdownCalled)
    end)

    it("quits with exit code 0 when quitOnEscape is enabled and escape is pressed", function()
        local queuedEvents: {{any}} = {}
        love2d_mock.event.push = function(name: string, ...: any)
            queuedEvents[#queuedEvents + 1] = {name, ...}
        end
        love2d_mock.event.poll = function(): function(): string, any, any, any, any, any
            return function(): string, any, any, any, any, any
                local event = table.remove(queuedEvents, 1)
                if not event then return nil end
                return event[1] as string, event[2], event[3], event[4], event[5], event[6]
            end
        end
        local inputStub = package.loaded["tecs2d.input"] as {string: any}
        inputStub.setEscapePressed(true)

        local shutdownCalled = false
        local tecs2d = require("tecs2d")
        local runner = tecs2d.run({
            fps = 60,
            quitOnEscape = true,
            game = function(world: tecs.World)
                world:addSystem({
                    name = "run-spec.quit-on-escape-shutdown",
                    phase = tecs.phases.Shutdown,
                    run = function() shutdownCalled = true end,
                })
            end,
            render = {},
        })
        local loop = runner()

        luassert.is_nil(loop())
        inputStub.setEscapePressed(false)
        luassert.equals(0, loop())
        luassert.is_true(shutdownCalled)
    end)
end)
