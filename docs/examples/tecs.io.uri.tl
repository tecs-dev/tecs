-- Checked examples attached to the tecs.io.uri reference.

-- #region tecs.io.uri.newURI
local endpoint, reason = tecs.io.uri.newURI("https://user@example.com:8443/assets/list.json?page=2")
if endpoint == nil then
    error(reason)
end

assert(endpoint:scheme() == "https")
assert(endpoint:host() == "example.com")
assert(endpoint:port() == 8443)
assert(endpoint:path() == "/assets/list.json")
assert(endpoint:query() == "page=2")
-- #endregion tecs.io.uri.newURI

-- #region tecs.io.uri.Components
local endpoint, reason = tecs.io.uri.newURI({
    scheme = "https",
    userInfo = "builder:secret",
    host = "api.example.com",
    port = 8443,
    path = "/v2/scores",
    query = "limit=20",
})
if endpoint == nil then
    error(reason)
end

assert(endpoint:toString() == "https://builder:secret@api.example.com:8443/v2/scores?limit=20")
-- #endregion tecs.io.uri.Components

-- #region tecs.io.uri.URI.withQuery
local scores, reason = tecs.io.uri.newURI("https://example.com/scores")
if scores == nil then
    error(reason)
end
local firstPage <const> = scores:withQuery("limit=20&offset=0")

assert(scores:query() == nil)
assert(firstPage:query() == "limit=20&offset=0")
-- #endregion tecs.io.uri.URI.withQuery

-- #region tecs.io.uri.URI.concatPath
local api, reason = tecs.io.uri.newURI("https://example.com/v1/")
if api == nil then
    error(reason)
end
local manifest <const> = api:concatPath("/games/42/manifest.json")

assert(manifest:path() == "/v1/games/42/manifest.json")
-- #endregion tecs.io.uri.URI.concatPath

-- #region tecs.io.uri.URI.withEndpoint
local resource, resourceReason = tecs.io.uri.newURI("smithy:/games/42/scores?limit=10")
if resource == nil then
    error(resourceReason)
end
local endpoint, endpointReason = tecs.io.uri.newURI("https://api.example.com/v2")
if endpoint == nil then
    error(endpointReason)
end
local request <const> = resource:withEndpoint(endpoint)

assert(request:toString() == "https://api.example.com/v2/games/42/scores?limit=10")
-- #endregion tecs.io.uri.URI.withEndpoint

-- #region tecs.io.uri.URI.resolve
local page, reason = tecs.io.uri.newURI("https://example.com/games/current/")
if page == nil then
    error(reason)
end
local scores, resolveReason = page:resolve("../42/scores")
if scores == nil then
    error(resolveReason)
end

assert(scores:toString() == "https://example.com/games/42/scores")
-- #endregion tecs.io.uri.URI.resolve

-- #region tecs.io.uri.validate
local valid <const> = tecs.io.uri.validate("urn:tecs:asset:sprite")
local relative <const>, reason = tecs.io.uri.validate("../sprite.png")

assert(valid)
assert(not relative)
assert(reason ~= nil)
-- #endregion tecs.io.uri.validate
