local tests = {}
local unpack = table.unpack or unpack
local context = {
    name = nil,
    after_each = {},
}

local function full_name(name)
    if context.name and context.name ~= "" then
        return context.name .. " " .. name
    end
    return name
end

local function describe(name, fn)
    local parent = context
    context = {
        name = full_name(name),
        after_each = {unpack(parent.after_each)},
    }
    fn()
    context = parent
end

local function after_each(fn)
    context.after_each[#context.after_each + 1] = fn
end

local function it(name, fn)
    tests[#tests + 1] = {
        name = full_name(name),
        fn = fn,
        after_each = {unpack(context.after_each)},
    }
end

local raw_assert = _G.assert
local assertions = {}

setmetatable(assertions, {
    __call = function(_, ...)
        return raw_assert(...)
    end,
})

function assertions.equals(expected, actual)
    if expected ~= actual then
        error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
    end
end

function assertions.matches(pattern, actual)
    if type(actual) ~= "string" or not actual:match(pattern) then
        error(string.format("expected %q to match %q", tostring(actual), pattern), 2)
    end
end

assertions.is_true = function(actual)
    if actual ~= true then
        error(string.format("expected true, got %q", tostring(actual)), 2)
    end
end

assertions.is_false = function(actual)
    if actual ~= false then
        error(string.format("expected false, got %q", tostring(actual)), 2)
    end
end

assertions.is = {
    True = assertions.is_true,
    False = assertions.is_false,
}

local env = {
    describe = describe,
    after_each = after_each,
    it = it,
    assert = assertions,
}
setmetatable(env, {__index = _G})

local chunk = assert(loadfile("spec/cli_spec.lua"))
setfenv(chunk, env)
chunk()

local failures = 0

for _, test in ipairs(tests) do
    local ok, err = xpcall(test.fn, debug.traceback)

    for i = #test.after_each, 1, -1 do
        local cleanup_ok, cleanup_err = xpcall(test.after_each[i], debug.traceback)
        if ok and not cleanup_ok then
            ok = false
            err = cleanup_err
        end
    end

    if ok then
        io.write(".")
    else
        failures = failures + 1
        io.write("F")
        io.stderr:write("\n\n", test.name, "\n", err, "\n")
    end
end

io.write(string.format("\n%d tests, %d failures\n", #tests, failures))

if failures > 0 then
    os.exit(1)
end
