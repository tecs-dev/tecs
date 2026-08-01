--[=[
Immutable absolute URIs for protocols, resources, and application links.

[`URI`](tealdoc:tecs.io.URI) is not tied to HTTP. It accepts every
absolute scheme supported by the native URL parser, while an API such as the
HTTP client separately restricts the schemes it can use. Components are
parsed once and copied into Lua, so accessors do not reparse or allocate:

```teal
local endpoint <const> = tecs.io.URI.new("https://api.example.com/v1")
local scores <const> = endpoint:concatPath("scores"):withQuery("limit=20")

print(scores:scheme(), scores:host(), scores:path())
print(scores)
```

URI values are immutable. Every `with` method and `concatPath` returns a new
value and leaves its receiver unchanged. Supplying a component record to
`tecs.io.URI.new` constructs the complete initial value without intermediate
copies. A modifier clones the retained parsed value and validates only the
replacement component; supplying the existing value returns the receiver.
`withEndpoint` replaces the scheme,
user information, host, and port from another URI, prefixes the receiver's
path with the endpoint path, and preserves the receiver's query and fragment.
That makes a configured service endpoint composable with a modeled resource
URI without rebuilding either from strings.

`resolve` applies an RFC-style relative reference to the receiver. The
constructor itself requires an absolute URI, which keeps every stored value
self-contained and leaves relative text at the operation where its base is
known. A URI owns only immutable Lua strings and needs no `close`.
]=]

local ffi <const> = require("ffi")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")

local C <const> = rust.C

local record URI
    --- Returns the normalized absolute URI.
    ---
    --- `tostring(uri)` returns the same string.
    --- @param self The immutable URI to render.
    --- @return Returns the complete normalized URI.
    toString: function(self: URI): string

    --- Returns the lower-cased scheme without its colon.
    --- @param self The immutable URI to inspect.
    --- @return Returns the required scheme.
    scheme: function(self: URI): string

    --- Returns the encoded authority.
    --- @param self The immutable URI to inspect.
    --- @return Returns user information, host, and port, or nil when this URI
    ---     has no authority.
    authority: function(self: URI): string

    --- Returns the encoded user information.
    --- @param self The immutable URI to inspect.
    --- @return Returns `username`, `username:password`, or nil when neither
    ---     was supplied.
    userInfo: function(self: URI): string

    --- Returns the encoded username.
    --- @param self The immutable URI to inspect.
    --- @return Returns the username, or an empty string when none was supplied.
    username: function(self: URI): string

    --- Returns the encoded password.
    --- @param self The immutable URI to inspect.
    --- @return Returns the password, or nil when none was supplied.
    password: function(self: URI): string

    --- Returns the normalized host.
    --- @param self The immutable URI to inspect.
    --- @return Returns the host, or nil when this scheme has none.
    host: function(self: URI): string

    --- Returns the explicit port.
    --- @param self The immutable URI to inspect.
    --- @return Returns the explicit port, or nil when the URI omits it.
    port: function(self: URI): integer

    --- Returns the encoded path.
    --- @param self The immutable URI to inspect.
    --- @return Returns the path, including its leading slash when present.
    path: function(self: URI): string

    --- Returns the encoded query without its question mark.
    --- @param self The immutable URI to inspect.
    --- @return Returns the query, or nil when the URI omits it.
    query: function(self: URI): string

    --- Returns the encoded fragment without its hash.
    --- @param self The immutable URI to inspect.
    --- @return Returns the fragment, or nil when the URI omits it.
    fragment: function(self: URI): string

    --- Replaces the scheme and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param scheme The caller supplies a scheme without its colon.
    --- @return Returns a new immutable URI.
    withScheme: function(self: URI, scheme: string): URI

    --- Replaces or removes user information and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param userInfo The caller supplies `username`, `username:password`, or
    ---     nil to remove both components.
    --- @return Returns a new immutable URI.
    withUserInfo: function(self: URI, userInfo?: string): URI

    --- Replaces or removes the host and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param host The caller supplies a host, or nil when the scheme permits
    ---     no host.
    --- @return Returns a new immutable URI.
    withHost: function(self: URI, host?: string): URI

    --- Replaces or removes the explicit port and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param port The caller supplies a port from zero through 65535, or nil
    ---     to omit it.
    --- @return Returns a new immutable URI.
    withPort: function(self: URI, port?: integer): URI

    --- Replaces the path and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param path The caller supplies an encoded or unencoded path.
    --- @return Returns a new immutable URI with a normalized path.
    withPath: function(self: URI, path: string): URI

    --- Replaces or removes the query and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param query The caller supplies a query without `?`, or nil to remove it.
    --- @return Returns a new immutable URI.
    withQuery: function(self: URI, query?: string): URI

    --- Replaces or removes the fragment and returns a new URI.
    --- @param self The URI left unchanged.
    --- @param fragment The caller supplies a fragment without `#`, or nil to
    ---     remove it.
    --- @return Returns a new immutable URI.
    withFragment: function(self: URI, fragment?: string): URI

    --- Appends a path while preserving one separator at the boundary.
    --- @param self The URI left unchanged.
    --- @param path The caller supplies the path suffix to append.
    --- @return Returns a new immutable URI.
    concatPath: function(self: URI, path: string): URI

    --- Applies another URI as this resource's endpoint.
    ---
    --- The endpoint supplies scheme, user information, host, and port. Its
    --- path prefixes this URI's path; this URI retains its query and fragment.
    --- @param self The resource URI left unchanged.
    --- @param endpoint The caller supplies the service endpoint.
    --- @return Returns a new immutable URI.
    withEndpoint: function(self: URI, endpoint: URI): URI

    --- Resolves a relative or absolute URI reference.
    --- @param self The absolute base URI left unchanged.
    --- @param reference The caller supplies an RFC-style URI reference.
    --- @return Returns the resolved immutable URI.
    --- @return Returns the parser's reason when the reference is invalid.
    resolve: function(self: URI, reference: string): URI, string

    --- `Components` constructs one URI without intermediate immutable copies.
    record Components
        --- Caller-writable. Supplies the required scheme without its colon.
        scheme: string
        --- Caller-writable. Supplies encoded `username` or
        --- `username:password`, or nil for none.
        userInfo: string
        --- Caller-writable. Supplies the host, or nil for a scheme without an
        --- authority. IPv6 literals may include or omit brackets.
        host: string
        --- Caller-writable. Supplies the explicit port, or nil for none.
        port: integer
        --- Caller-writable. Supplies the path. Nil means an empty path.
        path: string
        --- Caller-writable. Supplies the query without `?`, or nil for none.
        query: string
        --- Caller-writable. Supplies the fragment without `#`, or nil for none.
        fragment: string
    end

    --- Parses and normalizes an absolute URI.
    --- A component record performs one construction; it does not allocate an
    --- intermediate URI for each component.
    --- @param value The caller supplies absolute UTF-8 text or URI components.
    --- @return Returns an immutable URI, or nil when the text is invalid or
    ---     relative.
    --- @return Returns the parser's reason when the first return is nil.
    new: function(value: string | Components): URI, string

    --- Validates an absolute URI without retaining a value.
    --- @param text The caller supplies the UTF-8 text to validate.
    --- @return Returns true when `new` can parse the text.
    --- @return Returns the parser's reason when the first return is false.
    validate: function(text: string): boolean, string

    --- Returns whether a value is a Tecs URI.
    --- @param value The caller supplies any Lua value.
    --- @return Returns true only for values created by this module.
    isURI: function(value: any): boolean
end

local record State
    handle: loader.CPtr
    text: string
    scheme: string
    authority: string
    username: string
    password: string
    host: string
    port: integer
    path: string
    query: string
    fragment: string
end

local states <const>: {URI: State} = setmetatable({}, {__mode = "k"} as metatable<{URI: State}>)
local lengthOut <const> = loader.newArray("size_t[1]")
local portOut <const> = loader.newArray("uint16_t[1]")
local URIMT: metatable<URI>

local function reason(): string
    return loader.toString(C.tecsRustError())
end

local function part(pointer: loader.CValue): string
    if pointer == nil then
        return nil
    end
    return loader.toBytes(pointer, tonumber(lengthOut[0]) as integer)
end

local function make(handle: loader.CPtr): URI
    handle = ffi.gc(handle as ffi.CData, C.tecsUriDestroy as function(ffi.CData)) as loader.CPtr
    local value <const> = setmetatable({} as URI, URIMT)
    local state <const>: State = {
        handle = handle,
        text = part(C.tecsUriText(handle, lengthOut)),
        scheme = part(C.tecsUriScheme(handle, lengthOut)),
        authority = part(C.tecsUriAuthority(handle, lengthOut)),
        username = part(C.tecsUriUsername(handle, lengthOut)),
        password = part(C.tecsUriPassword(handle, lengthOut)),
        host = part(C.tecsUriHost(handle, lengthOut)),
        path = part(C.tecsUriPath(handle, lengthOut)),
        query = part(C.tecsUriQuery(handle, lengthOut)),
        fragment = part(C.tecsUriFragment(handle, lengthOut)),
    }
    if tonumber(C.tecsUriPort(handle, portOut)) == 1 then
        state.port = tonumber(portOut[0]) as integer
    end
    states[value] = state
    return value
end

local function changed(handle: loader.CPtr, level: integer): URI
    if handle == nil then
        error("tecs: cannot modify URI: " .. reason(), level)
    end
    return make(handle)
end

local function required(value: any, what: string, level: integer): string
    if type(value) ~= "string" then
        error("tecs: " .. what .. " needs a string", level)
    end
    return value as string
end

local function withText(self: URI, kind: integer, value: string, present: boolean): URI
    local component <const> = value or ""
    return changed(C.tecsUriWithText(states[self].handle, kind, component, #component, present and 1 or 0), 3)
end

URIMT = {
    __index = URI,
    __tostring = function(value: URI): string return states[value].text end,
    __eq = function(left: URI, right: URI): boolean return states[left].text == states[right].text end,
}

function URI:toString(): string
    return states[self].text
end
function URI:scheme(): string
    return states[self].scheme
end
function URI:authority(): string
    return states[self].authority
end
function URI:username(): string
    return states[self].username
end
function URI:password(): string
    return states[self].password
end
function URI:host(): string
    return states[self].host
end
function URI:port(): integer
    return states[self].port
end
function URI:path(): string
    return states[self].path
end
function URI:query(): string
    return states[self].query
end
function URI:fragment(): string
    return states[self].fragment
end

function URI:userInfo(): string
    local state <const> = states[self]
    if state.username == "" and state.password == nil then
        return nil
    end
    if state.password ~= nil then
        return state.username .. ":" .. state.password
    end
    return state.username
end

function URI:withScheme(scheme: string): URI
    scheme = required(scheme, "URI scheme", 2)
    if scheme == states[self].scheme then
        return self
    end
    return withText(self, 0, scheme, true)
end

function URI:withUserInfo(userInfo: string): URI
    if userInfo ~= nil then
        required(userInfo, "URI user information", 2)
    end
    if userInfo == self:userInfo() then
        return self
    end
    return withText(self, 1, userInfo, userInfo ~= nil)
end

function URI:withHost(host: string): URI
    if host ~= nil then
        required(host, "URI host", 2)
    end
    if host == states[self].host then
        return self
    end
    return withText(self, 2, host, host ~= nil)
end

function URI:withPort(port: integer): URI
    if port ~= nil and (type(port) ~= "number" or port < 0 or port > 65535 or port % 1 ~= 0) then
        error("tecs: URI port must be an integer from 0 through 65535 or nil", 2)
    end
    if port == states[self].port then
        return self
    end
    return changed(C.tecsUriWithPort(states[self].handle, port or -1), 2)
end

function URI:withPath(path: string): URI
    path = required(path, "URI path", 2)
    if path == states[self].path then
        return self
    end
    return withText(self, 3, path, true)
end

function URI:withQuery(query: string): URI
    if query ~= nil then
        required(query, "URI query", 2)
    end
    if query == states[self].query then
        return self
    end
    return withText(self, 4, query, query ~= nil)
end

function URI:withFragment(fragment: string): URI
    if fragment ~= nil then
        required(fragment, "URI fragment", 2)
    end
    if fragment == states[self].fragment then
        return self
    end
    return withText(self, 5, fragment, fragment ~= nil)
end

function URI:concatPath(path: string): URI
    path = required(path, "URI path", 2)
    if path == "" then
        return self
    end
    return changed(C.tecsUriConcatPath(states[self].handle, path, #path), 2)
end

function URI:withEndpoint(endpoint: URI): URI
    local endpointState <const> = states[endpoint]
    if endpointState == nil then
        error("tecs: URI endpoint must be an io.URI", 2)
    end
    return changed(C.tecsUriWithEndpoint(states[self].handle, endpointState.handle), 2)
end

function URI:resolve(reference: string): URI, string
    if type(reference) ~= "string" then
        return nil, "tecs: URI reference needs a string"
    end
    local handle <const> = C.tecsUriResolve(states[self].handle, reference, #reference) as loader.CPtr
    if handle == nil then
        return nil, reason()
    end
    return make(handle)
end

local function componentText(components: URI.Components): string, string
    if type(components) ~= "table" then
        return nil, "tecs: URI.new needs absolute text or URI components"
    end
    local scheme <const> = components.scheme
    if type(scheme) ~= "string" or scheme == "" then
        return nil, "tecs: URI components need a non-empty scheme"
    end
    local host <const> = components.host
    local userInfo <const> = components.userInfo
    local port <const> = components.port
    local path <const> = components.path or ""
    local query <const> = components.query
    local fragment <const> = components.fragment
    if host ~= nil and type(host) ~= "string" then
        return nil, "tecs: URI host must be a string or nil"
    end
    if userInfo ~= nil and type(userInfo) ~= "string" then
        return nil, "tecs: URI user information must be a string or nil"
    end
    if userInfo ~= nil and host == nil then
        return nil, "tecs: URI user information needs a host"
    end
    if port ~= nil and (type(port) ~= "number" or port < 0 or port > 65535 or port % 1 ~= 0) then
        return nil, "tecs: URI port must be an integer from 0 through 65535 or nil"
    end
    if port ~= nil and host == nil then
        return nil, "tecs: URI port needs a host"
    end
    if type(path) ~= "string" then
        return nil, "tecs: URI path must be a string or nil"
    end
    if query ~= nil and type(query) ~= "string" then
        return nil, "tecs: URI query must be a string or nil"
    end
    if fragment ~= nil and type(fragment) ~= "string" then
        return nil, "tecs: URI fragment must be a string or nil"
    end

    local parts <const>: {string} = {scheme, ":"}
    if host ~= nil then
        parts[#parts + 1] = "//"
        if userInfo ~= nil then
            parts[#parts + 1] = userInfo
            parts[#parts + 1] = "@"
        end
        if host:find(":", 1, true) ~= nil and not host:match("^%[.*%]$") then
            parts[#parts + 1] = "[" .. host .. "]"
        else
            parts[#parts + 1] = host
        end
        if port ~= nil then
            parts[#parts + 1] = ":" .. tostring(port)
        end
        if path ~= "" and path:sub(1, 1) ~= "/" then
            parts[#parts + 1] = "/"
        end
    end
    parts[#parts + 1] = path
    if query ~= nil then
        parts[#parts + 1] = "?" .. query
    end
    if fragment ~= nil then
        parts[#parts + 1] = "#" .. fragment
    end
    return table.concat(parts)
end

function URI.new(value: string | URI.Components): URI, string
    local text: string
    if type(value) == "table" then
        local failure: string
        text, failure = componentText(value as URI.Components)
        if text == nil then
            return nil, failure
        end
    elseif type(value) == "string" then
        text = value as string
    else
        return nil, "tecs: URI.new needs absolute text or URI components"
    end
    if text == "" then
        return nil, "tecs: URI.new needs a non-empty absolute URI"
    end
    local handle <const> = C.tecsUriParse(text, #text) as loader.CPtr
    if handle == nil then
        return nil, reason()
    end
    return make(handle)
end

function URI.validate(text: string): boolean, string
    if type(text) ~= "string" or text == "" then
        return false, "tecs: URI text must be a non-empty string"
    end
    local handle <const> = C.tecsUriParse(text, #text) as loader.CPtr
    if handle == nil then
        return false, reason()
    end
    C.tecsUriDestroy(handle)
    return true
end

function URI.isURI(value: any): boolean
    return type(value) == "table" and states[value as URI] ~= nil
end

return URI
