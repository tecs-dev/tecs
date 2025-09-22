--- Test suite for tecs.json using JSONTestSuite external tests
require("busted")
local luassert <const> = require("luassert")
local json  <const> = require("tecs.utils.json")

-- Test classification based on filename prefix:
-- y_ = should pass (valid JSON)
-- n_ = should fail (invalid JSON)
-- i_ = implementation-defined (may pass or fail)

describe("tecs.json JSONTestSuite compliance", function()

    local function readTestFile(filename: string): string
        local file = io.open("spec/tecs/utils/json/external_tests/test_parsing/" .. filename, "rb")
        if not file then
            error("Could not open test file: " .. filename)
        end
        local content = file:read("*all")
        file:close()
        return content
    end

    local function shouldPass(filename: string): boolean
        return filename:sub(1, 2) == "y_"
    end

    local function shouldFail(filename: string): boolean
        return filename:sub(1, 2) == "n_"
    end

    local function isImplementationDefined(filename: string): boolean
        return filename:sub(1, 2) == "i_"
    end

    -- Get all test files
    local testFiles = {}
    local file = io.popen('ls spec/tecs/utils/json/external_tests/test_parsing/*.json')
    if file then
        for filename in file:lines() do
            -- Extract just the filename from the full path
            local justName = filename:match("([^/]+)%.json$")
            if justName then
                table.insert(testFiles, justName .. ".json")
            end
        end
        file:close()
    end

    -- Sort test files for consistent test order
    table.sort(testFiles)

    describe("valid JSON tests (y_*)", function()
        for _, filename in ipairs(testFiles) do
            if shouldPass(filename) then
                it("should parse " .. filename, function()
                    local content = readTestFile(filename)

                    local success, result = pcall(function(): any
                        return json.parse(content)
                    end)

                    if not success then
                        local preview = #content > 100 and (content:sub(1, 100) .. "...") or content
                        error(string.format(
                            "Expected to parse valid JSON but got error.\nFile: %s\nContent: %s\nError: %s",
                            filename, preview, tostring(result)
                        ))
                    end
                end)
            end
        end
    end)

    describe("invalid JSON tests (n_*)", function()
        for _, filename in ipairs(testFiles) do
            if shouldFail(filename) then
                it("should reject " .. filename, function()
                    local content = readTestFile(filename)

                    local success, result = pcall(function(): any
                        return json.parse(content)
                    end)

                    if success then
                        local preview = #content > 100 and (content:sub(1, 100) .. "...") or content
                        error(string.format(
                            "Expected to reject invalid JSON but parsing succeeded.\nFile: %s\nContent: %s\nResult: %s",
                            filename, preview, tostring(result)
                        ))
                    end

                    luassert.is_string(result)
                end)
            end
        end
    end)

    describe("implementation-defined tests (i_*)", function()
        for _, filename in ipairs(testFiles) do
            if isImplementationDefined(filename) then
                it("may handle " .. filename, function()
                    local content = readTestFile(filename)

                    local success, result = pcall(function(): any
                        return json.parse(content)
                    end)

                    if success then
                        luassert.is_not_nil(result)
                    else
                        luassert.is_string(result)
                    end
                end)
            end
        end
    end)

    describe("specific edge cases", function()
        it("should handle deeply nested structures", function()
            local nested = '{"a":{"b":{"c":{"d":{"e":"deep"}}}}}'
            local result = json.parse(nested) as {string:any}
            luassert.is_equal("deep", ((((result.a as {string:any}).b as {string:any}).c as {string:any}).d as {string:any}).e)
        end)

        it("should handle large arrays efficiently", function()
            local largeArray = "[" .. table.concat((function(): {string}
                local parts = {}
                for i = 1, 100 do
                    table.insert(parts, tostring(i))
                end
                return parts
            end)(), ",") .. "]"

            local result = json.parse(largeArray) as {any}
            luassert.is_equal(100, #result)
            luassert.is_equal(1, result[1])
            luassert.is_equal(100, result[100])
        end)

        it("should handle objects with many keys", function()
            local parts = {}
            for i = 1, 50 do
                table.insert(parts, '"key' .. i .. '":' .. i)
            end
            local largeObject = "{" .. table.concat(parts, ",") .. "}"

            local result = json.parse(largeObject) as {string:any}
            local count = 0
            for _ in pairs(result) do
                count = count + 1
            end
            luassert.is_equal(50, count)
            luassert.is_equal(1, result.key1)
            luassert.is_equal(50, result.key50)
        end)

        it("should handle strings with unicode", function()
            local unicode = '{"emoji": "🎉", "chinese": "你好", "accents": "café"}'
            local result = json.parse(unicode) as {string:any}
            luassert.is_equal("🎉", result.emoji)
            luassert.is_equal("你好", result.chinese)
            luassert.is_equal("café", result.accents)
        end)

        it("should handle mixed whitespace", function()
            local whitespace = '  {\n  "key1"  :  "value1"  ,\r\n  "key2"\t:\t"value2"\n  }  '
            local result = json.parse(whitespace) as {string:any}
            luassert.is_equal("value1", result.key1)
            luassert.is_equal("value2", result.key2)
        end)
    end)

end)