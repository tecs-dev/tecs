--[=[
Parses absolute URIs with the same URL implementation used by Reqwest.

The native parser normalizes the input once and this module copies the
canonical text and its parts into an ordinary Lua value. A URI therefore needs
no explicit lifetime, can live in ECS components and snapshots, and can be
inspected without reparsing or allocating.
]=]

local loader <const> = require("tecs.ffi.loader")

loader.declare("http")

local H <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "http")

--- One parsed absolute URI.
local record URI
    --- Read-only. Contains the normalized absolute URI.
    text: string
    --- Read-only. Contains the lower-cased scheme without `:`.
    scheme: string
    --- Read-only. Contains the authority, including user information and port,
    --- or nil when the URI has no authority.
    authority: string
    --- Read-only. Contains the percent-encoded username, or an empty string
    --- when none was supplied.
    username: string
    --- Read-only. Contains the percent-encoded password, or nil when none was
    --- supplied.
    password: string
    --- Read-only. Contains the normalized host, or nil when the URI has none.
    host: string
    --- Read-only. Contains the explicit port, or nil when the URI omits it.
    port: integer
    --- Read-only. Contains the path, beginning with `/` for HTTP URIs.
    path: string
    --- Read-only. Contains the query without `?`, or nil when none was
    --- supplied.
    query: string
    --- Read-only. Contains the fragment without `#`, or nil when none was
    --- supplied.
    fragment: string
end

local URI_MT <const>: metatable<URI> = {
    __index = URI,
    __tostring = function(self: URI): string return self.text end,
}

local lengthOut <const> = loader.newArray("size_t[1]")
local portOut <const> = loader.newArray("uint16_t[1]")

local function part(pointer: loader.CValue): string
    if pointer == nil then
        return nil
    end
    return loader.toBytes(pointer, tonumber(lengthOut[0]) as integer)
end

local record uri
    type URI = URI
    new: function(text: string): URI, string
    isURI: function(value: any): boolean
end

--- Parses and normalizes an absolute URI.
---
--- Relative references fail because an HTTP request needs a scheme and
--- authority. Parsing uses Rust's `url::Url`, which is also the URL type
--- Reqwest accepts.
---
--- @param text The caller supplies an absolute UTF-8 URI.
--- @return Returns a parsed URI, or nil when the text is invalid or relative.
--- @return Returns the parser's reason when the first return is nil.
function uri.new(text: string): URI, string
    if type(text) ~= "string" or text == "" then
        return nil, "tecs: http.newURI needs an absolute URI"
    end
    local handle <const> = H.tecsHttpUriParse(text, #text) as loader.CPtr
    if handle == nil then
        return nil, loader.toString(H.tecsHttpError())
    end

    local parsed <const> = setmetatable({} as URI, URI_MT)
    parsed.text = part(H.tecsHttpUriText(handle, lengthOut))
    parsed.scheme = part(H.tecsHttpUriScheme(handle, lengthOut))
    parsed.authority = part(H.tecsHttpUriAuthority(handle, lengthOut))
    parsed.username = part(H.tecsHttpUriUsername(handle, lengthOut))
    parsed.password = part(H.tecsHttpUriPassword(handle, lengthOut))
    parsed.host = part(H.tecsHttpUriHost(handle, lengthOut))
    if tonumber(H.tecsHttpUriPort(handle, portOut)) == 1 then
        parsed.port = tonumber(portOut[0]) as integer
    end
    parsed.path = part(H.tecsHttpUriPath(handle, lengthOut))
    parsed.query = part(H.tecsHttpUriQuery(handle, lengthOut))
    parsed.fragment = part(H.tecsHttpUriFragment(handle, lengthOut))
    H.tecsHttpUriDestroy(handle)
    return parsed
end

function uri.isURI(value: any): boolean
    return type(value) == "table" and rawequal(getmetatable(value), URI_MT)
end

return uri
