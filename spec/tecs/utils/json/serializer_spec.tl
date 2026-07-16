--- Test suite for tecs.json serializer module
require("busted")
local luassert <const> = require("luassert")
local json = require("tecs.utils.json")

describe("tecs.json serializer", function()

    describe("basic serialization", function()
        it("should serialize null", function()
            local result = json.serialize(nil, false)
            luassert.is_equal("null", result)
        end)

        it("should serialize true", function()
            local result = json.serialize(true, false)
            luassert.is_equal("true", result)
        end)

        it("should serialize false", function()
            local result = json.serialize(false, false)
            luassert.is_equal("false", result)
        end)

        it("should serialize positive integer", function()
            local result = json.serialize(42, false)
            luassert.is_equal("42", result)
        end)

        it("should serialize negative integer", function()
            local result = json.serialize(-123, false)
            luassert.is_equal("-123", result)
        end)

        it("should serialize decimal number", function()
            local result = json.serialize(3.14159, false)
            luassert.is_equal("3.14159", result)
        end)

        it("should serialize simple string", function()
            local result = json.serialize("hello", false)
            luassert.is_equal('"hello"', result)
        end)

        it("should serialize string with escapes", function()
            local result = json.serialize("hello\nworld\t!", false)
            luassert.is_equal('"hello\\nworld\\t!"', result)
        end)

        it("should serialize empty array", function()
            local result = json.serialize({}, false)
            luassert.is_equal("[]", result)
        end)

        it("should serialize simple array", function()
            local result = json.serialize({1, 2, 3}, false)
            luassert.is_equal("[1,2,3]", result)
        end)

        it("should serialize empty array", function()
            local emptyArr: {any} = {}
            local result = json.serialize(emptyArr, false)
            -- Empty tables are serialized as arrays by default
            luassert.is_equal("[]", result)
        end)

        it("should serialize simple object", function()
            local result = json.serialize({name = "John", age = 30}, true)
            luassert.is_equal('{"age":30,"name":"John"}', result)
        end)
    end)

    describe("string escaping", function()
        it("should escape quotes", function()
            local result = json.serialize('He said "hello"', false)
            luassert.is_equal('"He said \\"hello\\""', result)
        end)

        it("should escape backslash", function()
            local result = json.serialize("C:\\path\\to\\file", false)
            luassert.is_equal('"C:\\\\path\\\\to\\\\file"', result)
        end)

        it("should escape control characters", function()
            local result = json.serialize("\b\f\n\r\t", false)
            luassert.is_equal('"\\b\\f\\n\\r\\t"', result)
        end)

        it("should escape other control characters with \\uXXXX", function()
            local result = json.serialize("\x00\x01\x1f", false)
            luassert.is_equal('"\\u0000\\u0001\\u001f"', result)
        end)
    end)

    describe("complex structures", function()
        it("should serialize nested object", function()
            local data = {
                person = {
                    name = "Alice",
                    details = {
                        age = 25,
                        city = "NYC"
                    }
                }
            }
            local result = json.serialize(data, true)
            luassert.is_equal('{"person":{"details":{"age":25,"city":"NYC"},"name":"Alice"}}', result)
        end)

        it("should serialize nested array", function()
            local data = {{1, 2}, {3, 4}, {5, 6}}
            local result = json.serialize(data, true)
            luassert.is_equal("[[1,2],[3,4],[5,6]]", result)
        end)

        it("should serialize mixed array", function()
            local data = {json.NULL, true, 42, "hello", {key = "value"}}
            local result = json.serialize(data, true)
            luassert.is_equal('[null,true,42,"hello",{"key":"value"}]', result)
        end)

        it("should serialize object with array values", function()
            local data = {
                numbers = {1, 2, 3},
                strings = {"a", "b", "c"}
            }
            local result = json.serialize(data, true)
            luassert.is_equal('{"numbers":[1,2,3],"strings":["a","b","c"]}', result)
        end)
    end)

    describe("round-trip serialization", function()
        it("round-trips empty objects as {} (never [])", function()
            -- Strict JSON-schema consumers (MCP clients validating tools/list)
            -- reject "properties": []; a parse -> serialize round trip must
            -- keep empty-object identity.
            local src = "{\"a\":{},\"b\":[],\"c\":{\"properties\":{},\"items\":[]}}"
            local out = json.serialize(json.parse(src), true)
            luassert.is_truthy(out:find("\"a\":{}", 1, true), out)
            luassert.is_truthy(out:find("\"b\":[]", 1, true), out)
            luassert.is_truthy(out:find("\"properties\":{}", 1, true), out)
            luassert.is_truthy(out:find("\"items\":[]", 1, true), out)

            -- Pretty output keeps the distinction too.
            local pretty = json.serializePretty(json.parse(src))
            luassert.is_nil(pretty:find("\"a\": []", 1, true))

            -- A parsed empty object that later gains keys serializes normally.
            local mutated = json.parse("{\"m\":{}}") as {string: any}
            local m = mutated.m as {string: any}
            m.added = 1
            luassert.is_truthy(json.serialize(mutated, true):find("\"added\":1", 1, true))
        end)

        it("should round-trip simple values", function()
            local original = {
                nil_val = nil,
                bool_true = true,
                bool_false = false,
                number = 42,
                string = "hello"
            }
            local jsonStr = json.serialize(original, true)
            local parsed = json.parse(jsonStr) as {string:any}
            luassert.is_nil(parsed.nil_val)
            luassert.is_true(parsed.bool_true)
            luassert.is_false(parsed.bool_false)
            luassert.is_equal(42, parsed.number)
            luassert.is_equal("hello", parsed.string)
        end)

        it("should round-trip complex object", function()
            local original = {
                person = {
                    name = "Alice",
                    age = 25,
                    hobbies = {"reading", "coding"}
                }
            }
            local jsonStr = json.serialize(original, true)
            local parsed = json.parse(jsonStr) as {string:any}
            luassert.is_equal("Alice", (parsed.person as {string:any}).name)
            luassert.is_equal(25, (parsed.person as {string:any}).age)
            luassert.is_equal("reading", ((parsed.person as {string:any}).hobbies as {any})[1])
        end)

        it("should round-trip array", function()
            local original = {1, 2, 3, 4, 5}
            local jsonStr = json.serialize(original, true)
            local parsed = json.parse(jsonStr) as {any}
            luassert.is_equal(5, #parsed)
            for i = 1, 5 do
                luassert.is_equal(i, parsed[i])
            end
        end)
    end)

    describe("pretty printing", function()
        it("should pretty print simple object", function()
            local data = {name = "John", age = 30}
            local result = json.serializePretty(data, nil, nil)
            luassert.is_equal('{\n  "age": 30,\n  "name": "John"\n}', result)
        end)

        it("should pretty print array", function()
            local data = {1, 2, 3}
            local result = json.serializePretty(data, nil, nil)
            luassert.is_equal('[\n  1,\n  2,\n  3\n]', result)
        end)

        it("should pretty print nested structure", function()
            local data = {
                person = {
                    name = "Alice",
                    age = 25
                }
            }
            local result = json.serializePretty(data, true, nil)
            luassert.is_equal('{\n  "person": {\n    "age": 25,\n    "name": "Alice"\n  }\n}', result)
        end)

        it("should pretty print with custom indent (4 spaces)", function()
            local data = {name = "John", age = 30}
            local result = json.serializePretty(data, true, "    ")
            luassert.is_equal('{\n    "age": 30,\n    "name": "John"\n}', result)
        end)

        it("should pretty print with tabs", function()
            local data = {name = "John", age = 30}
            local result = json.serializePretty(data, true, "\t")
            luassert.is_equal('{\n\t"age": 30,\n\t"name": "John"\n}', result)
        end)

        it("should pretty print nested structure with tabs", function()
            local data = {
                person = {
                    name = "Alice",
                    age = 25
                }
            }
            local result = json.serializePretty(data, true, "\t")
            luassert.is_equal('{\n\t"person": {\n\t\t"age": 25,\n\t\t"name": "Alice"\n\t}\n}', result)
        end)
    end)

    describe("error handling", function()
        it("should error on circular reference", function()
            local tbl: {any:any} = {}
            tbl.self = tbl
            luassert.has_error(function()
                json.serialize(tbl, false)
            end, "Circular reference detected", nil)
        end)

        it("should error on NaN", function()
            luassert.has_error(function()
                json.serialize(0/0, false)
            end, nil, nil)
        end)

        it("should error on Inf", function()
            luassert.has_error(function()
                json.serialize(math.huge, false)
            end, nil, nil)
        end)

        it("should error on -Inf", function()
            luassert.has_error(function()
                json.serialize(-math.huge, false)
            end, nil, nil)
        end)

        it("should error on unsupported type", function()
            luassert.has_error(function()
                json.serialize(function() end, false)
            end, nil, nil)
        end)
    end)

    describe("performance features", function()
        it("should handle large objects efficiently", function()
            local data: {string:any} = {}
            for i = 1, 100 do
                data["key" .. i] = i
            end

            local result = json.serialize(data, false)
            local parsed = json.parse(result) as {string:any}
            luassert.is_equal(1, parsed.key1)
            luassert.is_equal(100, parsed.key100)
        end)

        it("should handle large arrays efficiently", function()
            local data: {any} = {}
            for i = 1, 100 do
                data[i] = i
            end

            local result = json.serialize(data, false)
            local parsed = json.parse(result) as {any}
            luassert.is_equal(100, #parsed)
            luassert.is_equal(1, parsed[1])
            luassert.is_equal(100, parsed[100])
        end)
    end)

    describe("key ordering", function()
        it("should sort keys when sortKeys=true", function()
            local data = {zebra = 1, apple = 2, banana = 3}
            local result = json.serialize(data, true)
            luassert.is_equal('{"apple":2,"banana":3,"zebra":1}', result)
        end)

        it("should not sort keys when sortKeys=false", function()
            local data = {zebra = 1, apple = 2, banana = 3}
            local result = json.serialize(data, false)
            -- Key order is non-deterministic, just check it contains all keys
            luassert.is_true(result:find('"zebra":1') ~= nil)
            luassert.is_true(result:find('"apple":2') ~= nil)
            luassert.is_true(result:find('"banana":3') ~= nil)
        end)
    end)

    describe("custom indent per call", function()
        it("should use default indent when not specified", function()
            local data = {name = "John"}
            local result = json.serializePretty(data, true, nil)
            luassert.is_equal('{\n  "name": "John"\n}', result)
        end)

        it("should use custom indent when specified", function()
            local data = {name = "John"}
            local result = json.serializePretty(data, true, "\t")
            luassert.is_equal('{\n\t"name": "John"\n}', result)
        end)

        it("should support different indent strings per call", function()
            local data1 = {a = 1}
            local data2 = {b = 2}
            local result1 = json.serializePretty(data1, true, "    ")
            local result2 = json.serializePretty(data2, true, "\t")
            luassert.is_equal('{\n    "a": 1\n}', result1)
            luassert.is_equal('{\n\t"b": 2\n}', result2)
        end)
    end)

    describe("EMPTY_OBJECT sentinel", function()
        it("should serialize EMPTY_OBJECT as {}", function()
            local result = json.serialize(json.EMPTY_OBJECT, false)
            luassert.is_equal("{}", result)
        end)

        it("should serialize empty table as []", function()
            local result = json.serialize({}, false)
            luassert.is_equal("[]", result)
        end)

        it("should serialize EMPTY_OBJECT nested in object", function()
            local data = {props = json.EMPTY_OBJECT}
            local result = json.serialize(data, true)
            luassert.is_equal('{"props":{}}', result)
        end)

        it("should serialize EMPTY_OBJECT nested in array", function()
            local data = {json.EMPTY_OBJECT, json.EMPTY_OBJECT}
            local result = json.serialize(data, false)
            luassert.is_equal("[{},{}]", result)
        end)

        it("should pretty print EMPTY_OBJECT", function()
            local data = {config = json.EMPTY_OBJECT}
            local result = json.serializePretty(data, true, nil)
            luassert.is_equal('{\n  "config": {}\n}', result)
        end)

        it("should distinguish EMPTY_OBJECT from empty array in complex structure", function()
            local data = {
                emptyArray = {},
                emptyObject = json.EMPTY_OBJECT
            }
            local result = json.serialize(data, true)
            luassert.is_equal('{"emptyArray":[],"emptyObject":{}}', result)
        end)
    end)

end)
