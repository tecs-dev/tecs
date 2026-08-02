local tecs = require("tecs")
local scopeModule = require("tecs.scope")
local task = require("tecs.internal.taskruntime")
local zones = require("tecs.internal.zones")
local zone = require("jit.zone")

local function resource(name, closed, failure)
    local value = { name = name }
    function value:close()
        closed[#closed + 1] = self.name
        if failure then
            error(failure, 0)
        end
    end
    return value
end

describe("resource scopes", function()
    it("is the root function declared by its module", function()
        assert.are.equal(scopeModule.scoped, tecs.scoped)
    end)

    it("requires and exposes a diagnostic name", function()
        local seen
        tecs.scoped("named scope", function(scope)
            seen = scope.name
        end)
        assert.are.equal("named scope", seen)

        assert.has_error(function()
            tecs.scoped(nil, function() end)
        end, "tecs: scoped needs a non-empty name")
        assert.has_error(function()
            tecs.scoped("", function() end)
        end, "tecs: scoped needs a non-empty name")
    end)

    it("does not touch the JIT zone stack while profiling is inactive", function()
        assert.is_false(zones.active)
        local version = zones.version
        local depth = #zone

        tecs.scoped("inactive zone", function() end)

        assert.are.equal(version, zones.version)
        assert.are.equal(depth, #zone)
    end)

    it("uses its name as a nested JIT zone through cleanup", function()
        local seenBody
        local seenCleanup
        local restoredOuter
        zones.acquire()
        local ok, reason = pcall(function()
            zone("outer zone")
            tecs.scoped("profiled scope", function(scope)
                seenBody = zone[#zone]
                scope:own({
                    close = function()
                        seenCleanup = zone[#zone]
                    end,
                })
            end)
            restoredOuter = zone[#zone]
            zone()
        end)
        zones.release()

        assert.is_true(ok, reason)
        assert.are.equal("profiled scope", seenBody)
        assert.are.equal("profiled scope", seenCleanup)
        assert.are.equal("outer zone", restoredOuter)
        assert.is_nil(zone[#zone])
    end)

    it("parks its JIT zone with a suspended coroutine", function()
        local seenCleanup
        local scheduler = task.newScheduler()
        local gate = task.newGate()

        zones.acquire()
        local ok, reason = pcall(function()
            zone("host zone")
            local rootTask = scheduler:spawnImmediate(function()
                tecs.scoped("suspended scope", function(scope)
                    scope:own({
                        close = function()
                            seenCleanup = zone[#zone]
                        end,
                    })
                    gate:wait()
                end)
            end)

            assert.are.equal("pending", rootTask.status)
            assert.are.equal("host zone", zone[#zone])
            gate:complete(true)
            scheduler:step()
            assert.are.equal("ready", rootTask.status)
            assert.are.equal("suspended scope", seenCleanup)
            assert.are.equal("host zone", zone[#zone])
            zone()
        end)
        zones.release()

        assert.is_true(ok, reason)
        assert.is_nil(zone[#zone])
    end)

    it("does not restore parked zones into a newer profiling session", function()
        local seenCleanup
        local scheduler = task.newScheduler()
        local gate = task.newGate()

        zones.acquire()
        zone("old host")
        local rootTask = scheduler:spawnImmediate(function()
            tecs.scoped("old suspended scope", function(scope)
                scope:own({
                    close = function()
                        seenCleanup = zone[#zone]
                    end,
                })
                gate:wait()
            end)
        end)
        assert.are.equal("old host", zone[#zone])
        zone()
        zones.release()

        zones.acquire()
        local ok, reason = pcall(function()
            zone("new host")
            gate:complete(true)
            scheduler:step()
            assert.are.equal("ready", rootTask.status)
            assert.are.equal("new host", seenCleanup)
            assert.are.equal("new host", zone[#zone])
            zone()
        end)
        zones.release()

        assert.is_true(ok, reason)
        assert.is_nil(zone[#zone])
    end)

    it("returns each registration and closes in reverse order", function()
        local closed = {}
        local first = resource("first", closed)
        local second = resource("second", closed)

        tecs.scoped("reverse cleanup", function(scope)
            assert.is_true(rawequal(first, scope:own(first)))
            assert.is_true(rawequal(second, scope:own(second)))
            assert.same({}, closed)
        end)

        assert.same({ "second", "first" }, closed)
    end)

    it("closes a nested scope before its containing scope", function()
        local closed = {}

        tecs.scoped("outer", function(outer)
            outer:own(resource("outer", closed))
            tecs.scoped("inner", function(inner)
                inner:own(resource("inner", closed))
            end)
            assert.same({ "inner" }, closed)
        end)

        assert.same({ "inner", "outer" }, closed)
    end)

    it("closes every registration after the body raises", function()
        local closed = {}
        local ok, reason = pcall(function()
            tecs.scoped("body failure", function(scope)
                scope:own(resource("first", closed))
                scope:own(resource("second", closed))
                error("body failed", 0)
            end)
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("body failed", 1, true))
        assert.same({ "second", "first" }, closed)
    end)

    it("attempts every close and reports cleanup failures", function()
        local closed = {}
        local ok, reason = pcall(function()
            tecs.scoped("cleanup failures", function(scope)
                scope:own(resource("first", closed))
                scope:own(resource("second", closed, "second close failed"))
                scope:own(resource("third", closed, "third close failed"))
            end)
        end)
        reason = tostring(reason)

        assert.is_false(ok)
        assert.same({ "third", "second", "first" }, closed)
        assert.is_truthy(reason:find('Scope "cleanup failures" cleanup failed', 1, true))
        assert.is_truthy(reason:find("Resource 3 failed to close", 1, true))
        assert.is_truthy(reason:find("third close failed", 1, true))
        assert.is_truthy(reason:find("Resource 2 failed to close", 1, true))
        assert.is_truthy(reason:find("second close failed", 1, true))
    end)

    it("reports false close results and continues cleanup", function()
        local closed = {}
        local failed = resource("failed", closed)
        function failed:close()
            closed[#closed + 1] = self.name
            return false, "flush failed"
        end

        local ok, reason = pcall(function()
            tecs.scoped("false close", function(scope)
                scope:own(resource("first", closed))
                scope:own(failed)
                scope:own(resource("last", closed))
            end)
        end)

        assert.is_false(ok)
        assert.same({ "last", "failed", "first" }, closed)
        assert.is_truthy(tostring(reason):find("Resource 2 failed to close", 1, true))
        assert.is_truthy(tostring(reason):find("flush failed", 1, true))
    end)

    it("keeps the body failure primary when cleanup also fails", function()
        local closed = {}
        local ok, reason = pcall(function()
            tecs.scoped("primary failure", function(scope)
                scope:own(resource("resource", closed, "close failed"))
                error("body failed", 0)
            end)
        end)
        reason = tostring(reason)

        assert.is_false(ok)
        assert.same({ "resource" }, closed)
        local body = assert(reason:find("body failed", 1, true))
        local cleanup = assert(reason:find('Scope "primary failure" cleanup also failed', 1, true))
        assert.is_true(body < cleanup)
        assert.is_truthy(reason:find("close failed", 1, true))
    end)

    it("refuses a captured scope after its body ends", function()
        local captured
        tecs.scoped("captured scope", function(scope)
            captured = scope
            scope:own(resource("captured", {}))
        end)

        assert.is_nil(next(captured.registrations))

        local ok, reason = pcall(function()
            captured:own(resource("late", {}))
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find('Scope "captured scope" is no longer active', 1, true))
    end)

    it("makes the scope inactive before closing resources", function()
        local closed = {}
        local captured
        local value = resource("registered", closed)
        function value:close()
            closed[#closed + 1] = self.name
            captured:own(resource("late", closed))
        end

        local ok, reason = pcall(function()
            tecs.scoped("active cleanup", function(scope)
                captured = scope
                scope:own(value)
            end)
        end)

        assert.is_false(ok)
        assert.same({ "registered" }, closed)
        assert.is_truthy(tostring(reason):find('Scope "active cleanup" is no longer active', 1, true))
    end)

    it("treats repeated registration as repeated ownership", function()
        local closed = {}
        local value = resource("same", closed)

        tecs.scoped("duplicate registration", function(scope)
            scope:own(value)
            scope:own(value)
        end)

        assert.same({ "same", "same" }, closed)
    end)

    it("owns Lua files", function()
        local file

        tecs.scoped("Lua file", function(scope)
            file = assert(io.tmpfile())
            scope:own(file)

            assert.are.equal("file", io.type(file))
        end)

        assert.are.equal("closed file", io.type(file))
    end)

    it("validates untyped callers at registration", function()
        local ok, reason = pcall(function()
            tecs.scoped("nil registration", function(scope)
                scope:own(nil)
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("Scope:own needs a non-nil value", 1, true))

        ok, reason = pcall(function()
            tecs.scoped("invalid registration", function(scope)
                scope:own({})
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("Scope needs a value with a close method", 1, true))

        ok, reason = pcall(function()
            tecs.scoped("invalid body", nil)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("scoped needs a function", 1, true))
    end)

    it("raises a constructor failure supplied beside a nil value", function()
        local ok, reason = pcall(function()
            tecs.scoped("constructor failure", function(scope)
                scope:own(nil, "resource could not be opened")
            end)
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("resource could not be opened", 1, true))
    end)
end)
