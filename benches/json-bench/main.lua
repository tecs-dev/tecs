#!/usr/bin/env luajit
-- JSON Parsing Benchmark
-- Usage: `make json-bench` or `luajit main.lua`

local WARMUP_ITERATIONS = 5000
local BENCHMARK_ITERATIONS = 5000

-- Set package paths
local home = os.getenv("HOME") or ""
package.path = package.path
        .. ";../../out/macos-arm64-dev/lua/?.lua;../../out/macos-arm64-dev/lua/?/init.lua;"
        .. "../?.lua;../?/init.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"

assert(jit, "LuaJIT is required to run this benchmark")
print("LuaJIT version:", jit.version)

local bench = require("lib.bench")
local tecsJson = require("tecs.utils.json")

local function tryRequire(name)
    local ok, result = pcall(require, name)
    if ok then return result end
    return nil
end

local cjson = tryRequire("cjson")
if cjson then
    cjson.decode_invalid_numbers(false)
    print("✓ lua-cjson loaded")
else
    print("⚠ lua-cjson not available (luarocks --lua-version=5.1 install lua-cjson)")
end

local dkjson = tryRequire("dkjson")
if dkjson then print("✓ dkjson loaded") else print("⚠ dkjson not available") end

local jsonLua = tryRequire("json")
if jsonLua and not jsonLua.encode then jsonLua = nil end
if jsonLua then print("✓ json.lua loaded") else print("⚠ json.lua not available") end

-- Lua table serializer for the loadstring "parser"
local function serializeTable(t)
    if type(t) ~= "table" then
        if type(t) == "string" then return string.format("%q", t) end
        if type(t) == "nil" then return "nil" end
        return tostring(t)
    end
    local isArray, maxIndex = true, 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k <= 0 then
            isArray = false; break
        end
        if k > maxIndex then maxIndex = k end
    end
    if isArray then
        local parts = {}
        for i = 1, maxIndex do parts[#parts + 1] = serializeTable(t[i]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local parts = {}
    for k, v in pairs(t) do
        if type(k) == "string" and k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
            parts[#parts + 1] = k .. "=" .. serializeTable(v)
        else
            parts[#parts + 1] = "[" .. serializeTable(k) .. "]=" .. serializeTable(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Test cases -- each generates JSON and Lua-table strings ahead of time so the bench
-- only measures parsing/serialization, not data construction.
local function makeCase(name, dataOrSetup)
    local data = type(dataOrSetup) == "function" and dataOrSetup() or dataOrSetup
    return {
        name = name,
        data = {
            value = data,
            json = tecsJson.serialize(data),
            luaStr = serializeTable(data),
        },
    }
end

local cases = {
    makeCase("Small Object", {name = "John", age = 30, city = "New York"}),
    makeCase("Small Array", {"apples"}),
    makeCase("Number Array", {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20}),
    makeCase("Integer Heavy", function()
        local nums = {}
        for i = 1, 500 do nums[i] = math.random(1, 999999999) end
        return nums
    end),
    makeCase("Float Heavy", function()
        local nums = {}
        for i = 1, 500 do nums[i] = math.random() * 1000 + math.random() end
        return nums
    end),
    makeCase("Exponent Heavy", function()
        local nums = {}
        for i = 1, 500 do nums[i] = (math.random() * 100) * (10 ^ math.random(-10, 10)) end
        return nums
    end),
    makeCase("Nested Object", {user = {name = "Alice", profile = {age = 25, settings = {theme = "dark", notifications = true}}}}),
    makeCase("Large Array", function()
        local items = {}
        for i = 1, 100 do items[i] = {id = i, name = "Item " .. i, value = math.random(-1000, 1000)} end
        return items
    end),
    makeCase("String Heavy", {
        title = "The quick brown fox",
        content = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua",
        author = "John Smith Anderson",
        a = "Hello1", b = "Hello2", c = "Hello3",
    }),
    makeCase("Escape Heavy", {
        text = "This is a \"quoted\" string with \n newlines \t tabs and A unicode",
        description = "Another string with more \"content\" and escapes",
    }),
    makeCase("Mixed Types", {
        string = "hello", number = 42, float = 3.14159, boolean = true,
        array = {1, "two", true}, object = {nested = "value"},
    }),
    makeCase("Long String", {data = string.rep("abcdefghijklmnopqrstuvwxyz0123456789", 100)}),
    makeCase("Wide Object", function()
        local obj = {}
        for i = 1, 200 do obj["key" .. i] = i end
        return obj
    end),
    makeCase("Literal Heavy", {true,false,true,false,true,false,true,false,true,false,true,false,true,false,true,false,true,false,true,false}),
    makeCase("Number Variety", {0,42,-123,3.14159,-2.718,1.23e10,4.56e-7,-9.87E-3,0.000001,1.7976931348623157e+308}),
}

-- Parse benchmark: each variant parses the same JSON string (or Lua string for loadstring).
local parseVariants = {
    {
        name = "tecs.json",
        run = function(_, case) tecsJson.parse(case.data.json) end,
    },
}
if cjson then
    table.insert(parseVariants, {name = "lua-cjson", run = function(_, case) cjson.decode(case.data.json) end})
end
if jsonLua then
    table.insert(parseVariants, {name = "json.lua", run = function(_, case) jsonLua.decode(case.data.json) end})
end
if dkjson then
    table.insert(parseVariants, {name = "dkjson", run = function(_, case) dkjson.decode(case.data.json) end})
end
table.insert(parseVariants, {
    name = "loadstring",
    run = function(_, case) loadstring("return " .. case.data.luaStr)() end,
})

bench.suite({
    name = "JSON Parse",
    warmupIterations = WARMUP_ITERATIONS,
    iterations = BENCHMARK_ITERATIONS,
    baseline = "tecs.json",
    variants = parseVariants,
    cases = cases,
})

-- Serialize benchmark: each variant serializes the same Lua value to JSON.
local serializeVariants = {
    {
        name = "tecs.json",
        run = function(_, case) tecsJson.serialize(case.data.value) end,
    },
}
if cjson then
    table.insert(serializeVariants, {name = "lua-cjson", run = function(_, case) cjson.encode(case.data.value) end})
end
if jsonLua then
    table.insert(serializeVariants, {name = "json.lua", run = function(_, case) jsonLua.encode(case.data.value) end})
end
if dkjson then
    table.insert(serializeVariants, {name = "dkjson", run = function(_, case) dkjson.encode(case.data.value) end})
end

bench.suite({
    name = "JSON Serialize",
    warmupIterations = WARMUP_ITERATIONS,
    iterations = BENCHMARK_ITERATIONS,
    baseline = "tecs.json",
    variants = serializeVariants,
    cases = cases,
})
