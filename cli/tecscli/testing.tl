--- The spec runner `tecs test` runs, and the API a spec is written against.
---
--- **A spec requires this rather than being handed globals.** Globals would
--- read better and would not type-check: `tl` learns about a global from a
--- declaration file named by `--global-env-def`, one per invocation, and that
--- one is already spent on `tecs.global`, which is what puts the engine in
--- scope without a game requiring anything. A required module needs no slot.
---
---     local testing <const> = require("tecscli.testing")
---     local describe <const>, it <const> = testing.describe, testing.it
---
--- **Busted is not what runs here, and could not be.** It reaches for
--- LuaFileSystem, `luasystem` and `lua-term`, which are three C modules, and a
--- single executable has nowhere to load one from. What a game's specs
--- actually use is two blocks and a handful of assertions, so that is what this
--- is: about a hundred lines, no dependency, and it runs inside the same
--- process that has the engine already loaded, so a spec can build a world.
---
--- What it deliberately does not have: tags, filters, randomised order,
--- parallelism, coverage, output formats. Each of those is worth adding the
--- day something needs it and none is worth guessing at now.

--- The assertions. Declared before the module that carries them, because a
--- record field's type has to exist by the time the field is named.
local record check
end

local record testing
    --- One failure, with where it came from.
    record Failure
        name: string
        message: string
    end

    --- What a run reports.
    record Summary
        passed: integer
        failed: integer
        failures: {Failure}
    end

    --- The assertions a spec makes.
    check: check
end

--- Names of the blocks currently open, outermost first.
local stack: {string} = {}
local summary: testing.Summary = {passed = 0, failed = 0, failures = {}}

--- The full name of the test being run, for a failure message.
local function qualified(name: string): string
    local parts: {string} = {}
    for _, part in ipairs(stack) do
        parts[#parts + 1] = part
    end
    parts[#parts + 1] = name
    return table.concat(parts, " ")
end

--- Groups the tests inside it under one name.
function testing.describe(name: string, body: function())
    stack[#stack + 1] = name
    local ok, failure = pcall(body as function(): any)
    stack[#stack] = nil
    if not ok then
        summary.failed = summary.failed + 1
        summary.failures[#summary.failures + 1] = {name = qualified(name), message = tostring(failure)}
    end
end

--- One test.
---
--- A test that raises has failed, and everything after it in the same block
--- still runs: a suite that stops at the first failure tells you about one
--- defect per run.
function testing.it(name: string, body: function())
    local ok, failure = pcall(body as function(): any)
    if ok then
        summary.passed = summary.passed + 1
        io.write(("  ok   %s\n"):format(qualified(name)))
        return
    end
    summary.failed = summary.failed + 1
    summary.failures[#summary.failures + 1] = {name = qualified(name), message = tostring(failure)}
    io.write(("  FAIL %s\n"):format(qualified(name)))
end

--- Deep equality, for the assertions below.
local function same(left: any, right: any): boolean
    if left == right then
        return true
    end
    if not (left is table) or not (right is table) then
        return false
    end
    for key, value in pairs(left as {any: any}) do
        if not same(value, (right as {any: any})[key]) then
            return false
        end
    end
    for key in pairs(right as {any: any}) do
        if (left as {any: any})[key] == nil then
            return false
        end
    end
    return true
end

--- How a value reads in a failure message.
local function show(value: any): string
    if value is string then
        return ("%q"):format(value)
    end
    return tostring(value)
end

--- Fails unless the two values are equal.
function check.equal(expected: any, actual: any, why?: string)
    if expected ~= actual then
        error(("expected %s, got %s%s"):format(show(expected), show(actual), why and (" (" .. why .. ")") or ""), 2)
    end
end

--- Fails unless the two values are equal all the way down.
function check.same(expected: any, actual: any, why?: string)
    if not same(expected, actual) then
        error(("expected %s, got %s%s"):format(show(expected), show(actual), why and (" (" .. why .. ")") or ""), 2)
    end
end

--- Fails unless the value is neither nil nor false.
function check.truthy(value: any, why?: string)
    if not value then
        error(("expected a value, got %s%s"):format(show(value), why and (" (" .. why .. ")") or ""), 2)
    end
end

--- Fails unless the value is nil or false.
function check.falsy(value: any, why?: string)
    if value then
        error(("expected nothing, got %s%s"):format(show(value), why and (" (" .. why .. ")") or ""), 2)
    end
end

--- Fails unless calling `body` raises, and answers what it raised.
function check.raises(body: function()): string
    local ok, failure = pcall(body as function(): any)
    if ok then
        error("expected an error, and none was raised", 2)
    end
    return tostring(failure)
end

testing.check = check

--- Everything a run has recorded so far.
function testing.summary(): testing.Summary
    return summary
end

--- Forgets it, so one process can run several spec files as one suite.
function testing.reset()
    stack = {}
    summary = {passed = 0, failed = 0, failures = {}}
end

return testing
