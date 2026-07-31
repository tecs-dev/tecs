local tecs = require("tecs")
local scopeModule = require("tecs.scope")

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

    it("returns each registration and closes in reverse order", function()
        local closed = {}
        local first = resource("first", closed)
        local second = resource("second", closed)

        tecs.scoped(function(scope)
            assert.is_true(rawequal(first, scope:own(first)))
            assert.is_true(rawequal(second, scope:own(second)))
            assert.same({}, closed)
        end)

        assert.same({ "second", "first" }, closed)
    end)

    it("closes a nested scope before its containing scope", function()
        local closed = {}

        tecs.scoped(function(outer)
            outer:own(resource("outer", closed))
            tecs.scoped(function(inner)
                inner:own(resource("inner", closed))
            end)
            assert.same({ "inner" }, closed)
        end)

        assert.same({ "inner", "outer" }, closed)
    end)

    it("closes every registration after the body raises", function()
        local closed = {}
        local ok, reason = pcall(function()
            tecs.scoped(function(scope)
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
            tecs.scoped(function(scope)
                scope:own(resource("first", closed))
                scope:own(resource("second", closed, "second close failed"))
                scope:own(resource("third", closed, "third close failed"))
            end)
        end)
        reason = tostring(reason)

        assert.is_false(ok)
        assert.same({ "third", "second", "first" }, closed)
        assert.is_truthy(reason:find("Scoped cleanup failed", 1, true))
        assert.is_truthy(reason:find("Resource 3 failed to close", 1, true))
        assert.is_truthy(reason:find("third close failed", 1, true))
        assert.is_truthy(reason:find("Resource 2 failed to close", 1, true))
        assert.is_truthy(reason:find("second close failed", 1, true))
    end)

    it("keeps the body failure primary when cleanup also fails", function()
        local closed = {}
        local ok, reason = pcall(function()
            tecs.scoped(function(scope)
                scope:own(resource("resource", closed, "close failed"))
                error("body failed", 0)
            end)
        end)
        reason = tostring(reason)

        assert.is_false(ok)
        assert.same({ "resource" }, closed)
        local body = assert(reason:find("body failed", 1, true))
        local cleanup = assert(reason:find("Scoped cleanup also failed", 1, true))
        assert.is_true(body < cleanup)
        assert.is_truthy(reason:find("close failed", 1, true))
    end)

    it("refuses a captured scope after its body ends", function()
        local captured
        tecs.scoped(function(scope)
            captured = scope
            scope:own(resource("captured", {}))
        end)

        assert.is_nil(next(captured.registrations))

        local ok, reason = pcall(function()
            captured:own(resource("late", {}))
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("Scope is no longer active", 1, true))
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
            tecs.scoped(function(scope)
                captured = scope
                scope:own(value)
            end)
        end)

        assert.is_false(ok)
        assert.same({ "registered" }, closed)
        assert.is_truthy(tostring(reason):find("Scope is no longer active", 1, true))
    end)

    it("treats repeated registration as repeated ownership", function()
        local closed = {}
        local value = resource("same", closed)

        tecs.scoped(function(scope)
            scope:own(value)
            scope:own(value)
        end)

        assert.same({ "same", "same" }, closed)
    end)

    it("owns Lua files", function()
        local file

        tecs.scoped(function(scope)
            file = scope:own(assert(io.tmpfile()))

            assert.are.equal("file", io.type(file))
        end)

        assert.are.equal("closed file", io.type(file))
    end)

    it("validates untyped callers at registration", function()
        local ok, reason = pcall(function()
            tecs.scoped(function(scope)
                scope:own({})
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("Scope needs a value with a close method", 1, true))

        ok, reason = pcall(function()
            tecs.scoped(nil)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("scoped needs a function", 1, true))
    end)
end)
