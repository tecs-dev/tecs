--- Test suite for tecs.json module
require("busted")
local luassert <const> = require("luassert")
local json = require("tecs.utils.json")

describe("tecs.json", function()

    describe("basic parsing", function()
        it("should parse null", function()
            local result = json.parse("null")
            luassert.equals(json.NULL, result)
        end)

        it("should parse true", function()
            local result = json.parse("true")
            luassert.is_true(result)
        end)

        it("should parse false", function()
            local result = json.parse("false")
            luassert.is_false(result)
        end)

        it("should parse positive integer", function()
            local result = json.parse("42")
            luassert.is_equal(42, result)
        end)

        it("should parse negative integer", function()
            local result = json.parse("-123")
            luassert.is_equal(-123, result)
        end)

        it("should parse decimal number", function()
            local result = json.parse("3.14159")
            luassert.is_equal(3.14159, result)
        end)

        it("should parse scientific notation", function()
            local result = json.parse("1.23e-4")
            luassert.is_equal(1.23e-4, result)
        end)

        it("should parse simple string", function()
            local result = json.parse('"hello"')
            luassert.is_equal("hello", result)
        end)

        it("should parse string with escapes", function()
            local result = json.parse('"hello\\nworld\\t!"')
            luassert.is_equal("hello\nworld\t!", result)
        end)

        it("should parse empty array", function()
            local result = json.parse("[]") as {any}
            luassert.is_table(result)
            luassert.is_equal(0, #result)
        end)

        it("should parse simple array", function()
            local result = json.parse('[1, 2, 3]') as {any}
            luassert.is_table(result)
            luassert.is_equal(3, #result)
            luassert.is_equal(1, result[1])
            luassert.is_equal(2, result[2])
            luassert.is_equal(3, result[3])
        end)

        it("should parse empty object", function()
            local result = json.parse("{}") as {any:any}
            luassert.is_table(result)
            local count = 0
            for _ in pairs(result) do
                count = count + 1
            end
            luassert.is_equal(0, count)
        end)

        it("should parse simple object", function()
            local result = json.parse('{"name": "John", "age": 30}') as {string:any}
            luassert.is_table(result)
            luassert.is_equal("John", result.name)
            luassert.is_equal(30, result.age)
        end)
    end)

    describe("complex structures", function()
        it("should parse nested object", function()
            local jsonStr = '{"person": {"name": "Alice", "details": {"age": 25, "city": "NYC"}}}'
            local result = json.parse(jsonStr) as {string:any}

            luassert.is_equal("Alice", (result.person as {string:any}).name)
            luassert.is_equal(25, ((result.person as {string:any}).details as {string:any}).age)
            luassert.is_equal("NYC", ((result.person as {string:any}).details as {string:any}).city)
        end)

        it("should parse nested array", function()
            local jsonStr = '[[1, 2], [3, 4], [5, 6]]'
            local result = json.parse(jsonStr) as {any}

            luassert.is_equal(1, (result[1] as {any})[1])
            luassert.is_equal(2, (result[1] as {any})[2])
            luassert.is_equal(3, (result[2] as {any})[1])
            luassert.is_equal(4, (result[2] as {any})[2])
        end)

        it("should parse mixed array", function()
            local jsonStr = '[null, true, 42, "hello", {"key": "value"}]'
            local result = json.parse(jsonStr) as {any}

            luassert.is_equal(json.NULL, result[1])
            luassert.is_true(result[2])
            luassert.is_equal(42, result[3])
            luassert.is_equal("hello", result[4])
            luassert.is_equal("value", (result[5] as {string:any}).key)
        end)
    end)

    describe("error handling", function()
        it("should error on empty input", function()
            luassert.has_error(function()
                json.parse("")
            end, nil, nil)
        end)

        it("should error on nil input", function()
            luassert.has_error(function()
                json.parse(nil as string)
            end, nil, nil)
        end)

        it("should error on invalid JSON", function()
            luassert.has_error(function()
                json.parse("{invalid}")
            end, nil, nil)
        end)

        it("should error on unclosed string", function()
            luassert.has_error(function()
                json.parse('"unclosed string')
            end, nil, nil)
        end)

        it("should error on trailing comma in object", function()
            luassert.has_error(function()
                json.parse('{"key": "value",}')
            end, nil, nil)
        end)

        it("should error on trailing comma in array", function()
            luassert.has_error(function()
                json.parse('[1, 2, 3,]')
            end, nil, nil)
        end)

        it("should error on exceeding maximum nesting depth", function()
            local nested = ""
            for i = 1, 101 do
                nested = nested .. "["
            end
            for i = 1, 101 do
                nested = nested .. "]"
            end
            luassert.has_error(function()
                json.parse(nested)
            end, "Maximum nesting depth exceeded", nil)
        end)
    end)


    describe("performance features", function()
        it("should handle large objects efficiently", function()
            local parts = {}
            for i = 1, 100 do
                table.insert(parts, '"key' .. i .. '": ' .. i)
            end
            local largeObject = "{" .. table.concat(parts, ", ") .. "}"

            local result = json.parse(largeObject) as {string:any}
            luassert.is_table(result)
            luassert.is_equal(1, result.key1)
            luassert.is_equal(100, result.key100)
        end)

        it("should handle large arrays efficiently", function()
            local parts = {}
            for i = 1, 100 do
                table.insert(parts, tostring(i))
            end
            local largeArray = "[" .. table.concat(parts, ", ") .. "]"

            local result = json.parse(largeArray) as {any}
            luassert.is_table(result)
            luassert.is_equal(100, #result)
            luassert.is_equal(1, result[1])
            luassert.is_equal(100, result[100])
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