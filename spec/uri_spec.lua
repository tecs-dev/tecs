-- General immutable URIs.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local uri = require("tecs.io.uri")

local function parsed(text)
    local value, reason = uri.newURI(text)
    assert.is_not_nil(value, reason)
    return value
end

describe("io.uri", function()
    it("normalizes an absolute URI and exposes every component", function()
        local value = parsed("HTTPS://user:pass@Example.COM:8443/a%20b?q=two#part")

        assert.are.equal("https://user:pass@example.com:8443/a%20b?q=two#part", value:toString())
        assert.are.equal(value:toString(), tostring(value))
        assert.are.equal("https", value:scheme())
        assert.are.equal("user:pass@example.com:8443", value:authority())
        assert.are.equal("user:pass", value:userInfo())
        assert.are.equal("user", value:username())
        assert.are.equal("pass", value:password())
        assert.are.equal("example.com", value:host())
        assert.are.equal(8443, value:port())
        assert.are.equal("/a%20b", value:path())
        assert.are.equal("q=two", value:query())
        assert.are.equal("part", value:fragment())
    end)

    it("accepts non-HTTP schemes", function()
        local file = parsed("file:///tmp/save.bin")
        local mail = parsed("mailto:player@example.com")

        assert.are.equal("file", file:scheme())
        assert.are.equal("/tmp/save.bin", file:path())
        assert.are.equal("mailto", mail:scheme())
        assert.are.equal("player@example.com", mail:path())
    end)

    it("constructs all components without intermediate URI values", function()
        local value = parsed({
            scheme = "https",
            userInfo = "user:pass",
            host = "api.example.com",
            port = 8443,
            path = "/v2/scores",
            query = "limit=20",
            fragment = "top",
        })

        assert.are.equal("https://user:pass@api.example.com:8443/v2/scores?limit=20#top", value:toString())
    end)

    it("reports invalid and relative constructor text", function()
        local invalid, invalidReason = uri.newURI("not a URI")
        local relative, relativeReason = uri.newURI("../save.bin")

        assert.is_nil(invalid)
        assert.is_string(invalidReason)
        assert.is_nil(relative)
        assert.is_string(relativeReason)
        assert.is_false(uri.validate(relative))
        assert.is_true(uri.validate("urn:tecs:asset"))
    end)

    it("returns modified copies without changing the receiver", function()
        local base = parsed("https://user:pass@example.com:8443/v1/items?q=old#old")
        local changed = base
            :withScheme("http")
            :withUserInfo(nil)
            :withHost("api.example.test")
            :withPort(8080)
            :withPath("/v2/scores")
            :withQuery("limit=20")
            :withFragment("top")

        assert.are.equal("https://user:pass@example.com:8443/v1/items?q=old#old", base:toString())
        assert.are.equal("http://api.example.test:8080/v2/scores?limit=20#top", changed:toString())
        assert.are.equal("http://api.example.test/v2/scores?limit=20#top", changed:withPort(nil):toString())
        assert.are.equal("http://api.example.test:8080/v2/scores#top", changed:withQuery(nil):toString())
        assert.are.equal("http://api.example.test:8080/v2/scores?limit=20", changed:withFragment(nil):toString())
    end)

    it("concatenates paths with one boundary separator", function()
        local base = parsed("https://example.com/api/")

        assert.are.equal("https://example.com/api/scores", base:concatPath("/scores"):toString())
        assert.are.equal("https://example.com/api/scores", base:withPath("/api"):concatPath("scores"):toString())
    end)

    it("replaces an endpoint and preserves resource suffixes", function()
        local resource = parsed("smithy:/games/42/scores?limit=10#top")
        local endpoint = parsed("https://user@api.example.com:8443/v2")
        local resolved = resource:withEndpoint(endpoint)

        assert.are.equal("https://user@api.example.com:8443/v2/games/42/scores?limit=10#top", resolved:toString())
    end)

    it("resolves relative references against its base", function()
        local base = parsed("https://example.com/games/current/")
        local result, reason = base:resolve("../42/scores?limit=10")

        assert.is_not_nil(result, reason)
        assert.are.equal("https://example.com/games/42/scores?limit=10", result:toString())
    end)

    it("compares normalized values and rejects invalid modifiers", function()
        local left = parsed("HTTPS://EXAMPLE.COM/a")
        local right = parsed("https://example.com/a")

        assert.is_true(left == right)
        assert.is_true(uri.isURI(left))
        assert.is_false(uri.isURI({}))
        assert.is_true(rawequal(left, left:withScheme("https")))
        assert.is_true(rawequal(left, left:withHost("example.com")))
        assert.is_true(rawequal(left, left:concatPath("")))
        assert.has_error(function() left:withPort(70000) end)
        assert.has_error(function() left:withEndpoint({}) end)
    end)
end)
