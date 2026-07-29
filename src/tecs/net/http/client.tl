--- An asynchronous HTTP client driven from the SDL loop.
---
--- Reqwest and Tokio own the sockets and background threads. `send` copies a
--- request into Rust and returns a `Future` immediately. `pump` drains response
--- chunks and completions back on the Lua thread, which means a foreign thread
--- never enters LuaJIT and future listeners always run from the SDL loop.
---
--- A response status is still an answer rather than a transfer failure: 404
--- settles a ready future whose `Response:ok()` is false. DNS, TLS, connection,
--- timeout, and body-limit errors settle a failed future.
---
--- Bodies headed for a file or handle remain streamed. Rust places bounded
--- chunks on the client's event queue, and each pump writes those chunks before
--- asking for more. A request body is copied at `send`, as it was before.

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")
local Future <const> = require("tecs.Future")
local DataStream <const> = require("tecs.net.http.DataStream")
local clients <const> = require("tecs.net.http.clients")

loader.declare("http")

local H <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "http")
-- Externally configured logger name; it remains stable if this module moves.
local LOGGER <const> = log.get("tecs.http")

local SLICE_MS <const> = 50
local DEFAULT_TIMEOUT_MS <const> = 30000
local DEFAULT_CONNECT_TIMEOUT_MS <const> = 10000
local DEFAULT_MAX_REDIRECTS <const> = 5
local DEFAULT_MAX_CONNECTIONS <const> = 16
local DEFAULT_MAX_CONNECTIONS_PER_HOST <const> = 6

local EVENT_CHUNK <const> = 1
local EVENT_COMPLETE <const> = 2
local EVENT_FAILED <const> = 3

local record client
    --- Settings copied when a client is built.
    record Options
        --- Sent as `User-Agent` on every request.
        userAgent: string
        --- Sent on every request and overridden case-insensitively per request.
        headers: {string: string}
        --- Milliseconds allowed for a whole transfer. 30000 by default.
        timeoutMs: number
        --- Milliseconds allowed to establish a connection. 10000 by default.
        connectTimeoutMs: number
        --- Milliseconds a response may make no progress. 0 disables it.
        stallTimeoutMs: number
        --- Redirects followed. 5 by default; 0 follows none.
        maxRedirects: integer
        --- Requests allowed to use sockets at once. 16 by default.
        maxConnections: integer
        --- Requests allowed to use sockets to one host. 6 by default.
        maxConnectionsPerHost: integer
        --- Maximum response-body bytes. 0 is unbounded.
        maxBytes: integer
        --- Whether gzip and deflate response compression is accepted.
        --- True by default.
        compressed: boolean
        --- Host names whose TLS certificates are not verified.
        insecureHosts: {string}
        --- A proxy URL. Unset follows the environment; empty forces direct.
        proxy: string
        --- Hosts excluded from an explicitly configured proxy.
        noProxy: string
        --- Proxy credentials in `user:password` form.
        proxyCredentials: string
    end

    --- One request. Only `url` is required.
    record Request
        --- Absolute, with an `http` or `https` scheme.
        url: string
        --- The method. GET by default.
        method: string
        --- Headers merged over the client's defaults.
        headers: {string: string}
        --- Bytes to send. A stream is read before `send` returns.
        body: string | DataStream
        --- Where response chunks are written. A string is a file path.
        into: string | DataStream
        --- Whole-transfer timeout overriding the client's.
        timeoutMs: number
        --- No-progress timeout overriding the client's.
        stallTimeoutMs: number
        --- Body limit overriding the client's. 0 is unbounded.
        maxBytes: integer
    end

    --- A completed HTTP response.
    record Response
        --- Status after redirects.
        status: integer
        --- Final response headers with lower-cased names.
        headers: {string: string}
        --- Response bytes, in memory or in the requested destination.
        body: DataStream
        --- Effective URL after redirects.
        url: string

        --- Whether the status is in the 2xx range.
        ok: function(self: Response): boolean
    end

    record Transfer
        id: integer
        future: Future<Response>
        response: Response
        sink: DataStream
        chunks: {string}
        chunkCount: integer
        url: string
        closed: boolean
    end

    --- A reqwest connection pool and `Future.Source`.
    record Client
        --- Maximum duration of one blocking future-wait slice.
        sliceMs: number
        --- Default budget for a future wait without an explicit timeout.
        defaultWaitMs: number

        _handle: loader.CPtr
        _options: Options
        _insecure: {string: boolean}
        _byFuture: {Future<Response>: Transfer}
        _byId: {integer: Transfer}
        _pending: integer
        _pumping: boolean
        _eventSize: loader.CArray

        --- Starts a transfer and returns its future immediately.
        send: function(self: Client, request: Request): Future<Response>
        --- Drains every event currently ready without blocking.
        pump: function(self: Client): integer
        --- Returns the number of unsettled transfers.
        pending: function(self: Client): integer
        --- Stops the transfer belonging to a future.
        cancel: function(self: Client, future: Future<any>)
        --- Stops all transfers and releases the connection pool.
        close: function(self: Client)
        --- `Future.Source`: the non-blocking form of `pump`.
        poll: function(self: Client): integer
        --- `Future.Source`: waits at most `ms` for an event, then drains.
        advance: function(self: Client, ms: number): integer
    end

    --- Builds an open client registered with the application pump.
    ---
    --- @param options Copied now; later mutations are not observed.
    --- @return A client that remains registered until `close`.
    newClient: function(options?: Options): Client
end

local type Options = client.Options
local type Request = client.Request
local type Response = client.Response
local type Transfer = client.Transfer
local type Client = client.Client

local ResponseMT <const>: metatable<Response> = {__index = Response}
local ClientMT <const>: metatable<Client> = {__index = Client}

function Response:ok(): boolean
    return self.status >= 200 and self.status < 300
end

local nextId = 1

local function schemeOf(url: string): string
    local scheme = url:match("^(%a[%w+.%-]*)://")
    return scheme ~= nil and scheme:lower() or nil
end

local function hostOf(url: string): string
    local authority = url:match("^%a[%w+.%-]*://([^/?#]*)")
    if authority == nil or authority == "" then
        return nil
    end
    local at = authority:find("@", 1, true)
    if at ~= nil then
        authority = authority:sub(at + 1)
    end
    if authority:sub(1, 1) == "[" then
        local literal = authority:match("^%[([^%]]*)%]")
        return literal ~= nil and literal:lower() or nil
    end
    local host = authority:match("^([^:]*)")
    return host ~= nil and host ~= "" and host:lower() or nil
end

local function streamOf(given: string | DataStream, sending: boolean, what: string): DataStream
    if given == nil then
        return nil
    end
    if given is string then
        return sending and DataStream.ofString(given) or DataStream.ofFile(given)
    end
    if not DataStream.is(given) then
        error(("tecs: %s is not a string or a DataStream"):format(what), 3)
    end
    return given
end

local function nativeError(): string
    return loader.toString(H.tecsHttpError())
end

local function setSlice(slice: loader.CStruct, value?: string)
    if value == nil or value == "" then
        slice.data = nil
        slice.length = 0
        return
    end
    slice.data = ffi.cast("const uint8_t *", value)
    slice.length = #value
end

local function eventBytes(self: Client, event: loader.CPtr, accessor: loader.CValue): string
    local data <const> = accessor(event, self._eventSize)
    local length <const> = math.floor(tonumber(self._eventSize[0]) or 0) as integer
    return loader.toBytes(data, length)
end

local function parseHeaders(raw: string): {string: string}
    local headers: {string: string} = {}
    for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name ~= nil then
            headers[name:lower()] = value
        end
    end
    return headers
end

local function release(self: Client, transfer: Transfer)
    if self._byId[transfer.id] == nil then
        return
    end
    self._byId[transfer.id] = nil
    self._byFuture[transfer.future] = nil
    self._pending = self._pending - 1
end

local function finishSink(transfer: Transfer): boolean, string
    if transfer.sink == nil or transfer.closed then
        return true
    end
    transfer.closed = true
    return transfer.sink:_finish()
end

local function failTransfer(self: Client, transfer: Transfer, reason: string)
    H.tecsHttpClientCancel(self._handle, transfer.id)
    release(self, transfer)
    local ok <const>, closeFailure = finishSink(transfer)
    if not ok and (reason == nil or reason == "") then
        reason = closeFailure
    end
    transfer.future:fail(reason or ("tecs: %s: transfer failed"):format(transfer.url))
end

local function completeTransfer(
    self: Client, transfer: Transfer, status: integer, rawHeaders: string, effectiveUrl: string
)
    release(self, transfer)
    local ok <const>, failure = finishSink(transfer)
    if not ok then
        transfer.future:fail(("tecs: %s: %s"):format(transfer.url, failure or "response destination failed"))
        return
    end

    local response <const> = transfer.response
    response.status = status
    response.headers = parseHeaders(rawHeaders)
    response.url = effectiveUrl ~= "" and effectiveUrl or transfer.url
    if transfer.sink ~= nil then
        transfer.sink.contentType = response.headers["content-type"]
        response.body = transfer.sink
    else
        response.body = DataStream.ofString(table.concat(transfer.chunks), response.headers["content-type"])
    end
    transfer.future:complete(response)
end

local function copyEvent(self: Client, pointer: loader.CPtr): integer, integer, string, string, string, integer
    local kind <const> = math.floor(tonumber(H.tecsHttpEventKind(pointer)) or 0) as integer
    local id <const> = math.floor(tonumber(H.tecsHttpEventId(pointer)) or 0) as integer
    local data = ""
    local headers = ""
    local url = ""
    local status = 0
    if kind == EVENT_CHUNK then
        data = eventBytes(self, pointer, H.tecsHttpEventData)
    elseif kind == EVENT_COMPLETE then
        status = math.floor(tonumber(H.tecsHttpEventStatus(pointer)) or 0) as integer
        headers = eventBytes(self, pointer, H.tecsHttpEventHeaders)
        url = eventBytes(self, pointer, H.tecsHttpEventUrl)
    elseif kind == EVENT_FAILED then
        data = eventBytes(self, pointer, H.tecsHttpEventError)
    end
    H.tecsHttpEventDestroy(pointer)
    return kind, id, data, headers, url, status
end

local function handleEvent(self: Client, pointer: loader.CPtr): boolean
    local kind <const>, id <const>, data <const>, headers <const>, url <const>, status <const> = copyEvent(
        self, pointer
    )
    local transfer <const> = self._byId[id]
    if transfer == nil then
        return false
    end
    if kind == EVENT_CHUNK then
        if transfer.sink ~= nil then
            local ok <const>, failure = transfer.sink:_write(data)
            if not ok then
                failTransfer(self, transfer, ("tecs: %s: %s"):format(transfer.url, failure or "cannot write response"))
                return true
            end
        else
            transfer.chunkCount = transfer.chunkCount + 1
            transfer.chunks[transfer.chunkCount] = data
        end
        return false
    end
    if kind == EVENT_COMPLETE then
        completeTransfer(self, transfer, status, headers, url)
        return true
    end
    if kind == EVENT_FAILED then
        failTransfer(self, transfer, data)
        return true
    end
    failTransfer(self, transfer, ("tecs: %s: unknown HTTP event"):format(transfer.url))
    return true
end

local function turn(self: Client, waitMs: number): integer
    local settled = 0
    local event = H.tecsHttpClientNext(self._handle, math.max(0, math.floor(waitMs))) as loader.CPtr
    while event ~= nil do
        if handleEvent(self, event) then
            settled = settled + 1
        end
        event = H.tecsHttpClientNext(self._handle, 0) as loader.CPtr
    end
    return settled
end

local function drive(self: Client, waitMs: number, level: integer): integer
    if self._pumping then
        error(
            "tecs: this http client is already pumping; a listener cannot wait on or pump the client calling it", level
        )
    end
    if self._handle == nil then
        return 0
    end
    self._pumping = true
    local ok, result = pcall(turn, self, waitMs) as (boolean, any)
    self._pumping = false
    if not ok then
        error(result, 0)
    end
    return result as integer
end

function Client:pump(): integer
    return drive(self, 0, 3)
end

function Client:poll(): integer
    return drive(self, 0, 3)
end

function Client:advance(ms: number): integer
    return drive(self, ms, 3)
end

function Client:pending(): integer
    return self._pending
end

local function mergedHeaders(self: Client, request: Request, source: DataStream): {string: string}
    local merged: {string: string} = {}
    for name, value in pairs(self._options.headers or {}) do
        merged[name:lower()] = value
    end
    for name, value in pairs(request.headers or {}) do
        merged[name:lower()] = value
    end
    if self._options.userAgent ~= nil and merged["user-agent"] == nil then
        merged["user-agent"] = self._options.userAgent
    end
    if source ~= nil and source.contentType ~= nil and merged["content-type"] == nil then
        merged["content-type"] = source.contentType
    end
    return merged
end

function Client:send(request: Request): Future<Response>
    if self._handle == nil then
        error("tecs: this http client is closed", 2)
    end
    if request == nil or type(request.url) ~= "string" or request.url == "" then
        error("tecs: http send needs a request with a url", 2)
    end

    local source <const> = streamOf(request.body, true, "a request body")
    local sink <const> = streamOf(request.into, false, "into")
    if sink ~= nil and not sink:writable() then
        error(("tecs: a %s stream is not somewhere a body can be written"):format(sink.kind), 2)
    end

    local url <const> = request.url
    local scheme <const> = schemeOf(url)
    if scheme ~= "http" and scheme ~= "https" then
        return Future.failed(("tecs: %s is not an http or https url"):format(url)) as Future<Response>
    end

    local body = ""
    if source ~= nil then
        local failure: string
        body, failure = source:text()
        if body == nil then
            return Future.failed(failure or "tecs: the request body could not be read") as Future<Response>
        end
    end

    if sink ~= nil then
        local ok <const>, failure = sink:_beginWrite()
        if not ok then
            return Future.failed(failure) as Future<Response>
        end
    end

    local id <const> = nextId
    nextId = nextId + 1
    local future <const> = Future.pending(self as Future.Source) as Future<Response>
    local transfer <const>: Transfer = {
        id = id,
        future = future,
        response = setmetatable({status = 0, headers = {}, url = url} as Response, ResponseMT),
        sink = sink,
        chunks = {},
        chunkCount = 0,
        url = url,
        closed = false,
    }

    local merged <const> = mergedHeaders(self, request, source)
    local headerCount = 0
    for _ in pairs(merged) do
        headerCount = headerCount + 1
    end
    local nativeHeaders: loader.CArray = nil
    if headerCount > 0 then
        nativeHeaders = loader.newArray("TecsHttpHeader[?]", headerCount)
        local at = 0
        for name, value in pairs(merged) do
            local header <const> = nativeHeaders[at] as loader.CStruct
            setSlice(header.name as loader.CStruct, name)
            setSlice(header.value as loader.CStruct, value)
            at = at + 1
        end
    end

    local method <const> = (request.method or "GET"):upper()
    local carries <const> = method == "POST" or method == "PUT" or method == "PATCH"
    local nativeArray <const> = loader.newArray("TecsHttpRequest[1]")
    local native <const> = nativeArray[0] as loader.CStruct
    native.id = id
    setSlice(native.url as loader.CStruct, url)
    setSlice(native.method as loader.CStruct, method)
    native.headers = nativeHeaders
    native.headerCount = headerCount
    setSlice(native.body as loader.CStruct, body)
    native.hasBody = (source ~= nil or carries) and 1 or 0
    native.timeoutMs = request.timeoutMs or self._options.timeoutMs
    native.stallTimeoutMs = request.stallTimeoutMs or self._options.stallTimeoutMs
    native.maxBytes = request.maxBytes ~= nil and request.maxBytes or self._options.maxBytes
    local host <const> = hostOf(url)
    native.insecure = host ~= nil and self._insecure[host] and 1 or 0

    if (tonumber(H.tecsHttpClientSend(self._handle, nativeArray)) or 0) == 0 then
        finishSink(transfer)
        return Future.failed(("tecs: cannot start %s: %s"):format(url, nativeError())) as Future<Response>
    end

    self._byFuture[future] = transfer
    self._byId[id] = transfer
    self._pending = self._pending + 1
    return future
end

function Client:cancel(future: Future<any>)
    local transfer <const> = self._byFuture[future as Future<Response>]
    if transfer == nil then
        return
    end
    H.tecsHttpClientCancel(self._handle, transfer.id)
    release(self, transfer)
    finishSink(transfer)
    transfer.future:abandon("canceled")
end

function Client:close()
    if self._handle == nil then
        return
    end
    if self._pumping then
        error("tecs: cannot close an http client from inside its own pump", 2)
    end
    clients.remove(self as clients.Pumpable)

    local live: {Transfer} = {}
    for _, transfer in pairs(self._byId) do
        live[#live + 1] = transfer
    end
    for index = 1, #live do
        local transfer <const> = live[index]
        H.tecsHttpClientCancel(self._handle, transfer.id)
        release(self, transfer)
        finishSink(transfer)
        transfer.future:abandon("the http client was closed")
    end

    H.tecsHttpClientDestroy(self._handle)
    self._handle = nil
    self._pending = 0
end

local function insecureSet(hosts: {string}): {string: boolean}
    local set: {string: boolean} = {}
    if hosts == nil then
        return set
    end
    for index = 1, #hosts do
        local host <const> = hosts[index]
        if type(host) ~= "string" or host == "" or host:find("[^%w%.%-_]") ~= nil then
            error(("tecs: insecureHosts[%d] is not a plain host name"):format(index), 3)
        end
        local lowered <const> = host:lower()
        set[lowered] = true
        LOGGER:warn("TLS verification is disabled for %s; this must not reach a shipped build", lowered)
    end
    return set
end

function client.newClient(options?: Options): Client
    local given <const> = options or {} as Options
    local timeoutMs <const> = given.timeoutMs or DEFAULT_TIMEOUT_MS
    local maxConnections <const> = given.maxConnections or DEFAULT_MAX_CONNECTIONS
    local maxConnectionsPerHost <const> = given.maxConnectionsPerHost or DEFAULT_MAX_CONNECTIONS_PER_HOST
    if maxConnections < 1 or maxConnectionsPerHost < 1 then
        error("tecs: HTTP connection limits must be greater than zero", 3)
    end
    local defaultHeaders: {string: string} = nil
    if given.headers ~= nil then
        defaultHeaders = {}
        for name, value in pairs(given.headers) do
            defaultHeaders[name] = value
        end
    end
    local insecure <const> = insecureSet(given.insecureHosts)
    local settings <const>: Options = {
        userAgent = given.userAgent,
        headers = defaultHeaders,
        timeoutMs = timeoutMs,
        connectTimeoutMs = given.connectTimeoutMs or DEFAULT_CONNECT_TIMEOUT_MS,
        stallTimeoutMs = given.stallTimeoutMs or 0,
        maxRedirects = given.maxRedirects or DEFAULT_MAX_REDIRECTS,
        maxConnections = maxConnections,
        maxConnectionsPerHost = maxConnectionsPerHost,
        maxBytes = given.maxBytes or 0,
        compressed = given.compressed ~= false,
        insecureHosts = given.insecureHosts,
        proxy = given.proxy,
        noProxy = given.noProxy,
        proxyCredentials = given.proxyCredentials,
    }

    local nativeArray <const> = loader.newArray("TecsHttpClientOptions[1]")
    local native <const> = nativeArray[0] as loader.CStruct
    native.connectTimeoutMs = settings.connectTimeoutMs
    native.maxRedirects = settings.maxRedirects
    native.maxConnections = settings.maxConnections
    native.maxConnectionsPerHost = settings.maxConnectionsPerHost
    native.compressed = settings.compressed and 1 or 0
    if settings.proxy == nil then
        native.proxyMode = 0
    elseif settings.proxy == "" then
        native.proxyMode = 1
    else
        native.proxyMode = 2
    end
    setSlice(native.proxy as loader.CStruct, settings.proxy)
    native.noProxySet = settings.noProxy ~= nil and 1 or 0
    setSlice(native.noProxy as loader.CStruct, settings.noProxy)
    setSlice(native.proxyCredentials as loader.CStruct, settings.proxyCredentials)

    local handle <const> = H.tecsHttpClientCreate(nativeArray) as loader.CPtr
    if handle == nil then
        error(("tecs: cannot create http client: %s"):format(nativeError()), 3)
    end

    local self <const> = setmetatable({} as Client, ClientMT)
    self.sliceMs = SLICE_MS
    self.defaultWaitMs = timeoutMs
    self._handle = handle
    self._options = settings
    self._insecure = insecure
    self._byFuture = {}
    self._byId = {}
    self._pending = 0
    self._pumping = false
    self._eventSize = loader.newArray("size_t[1]")
    clients.add(self as clients.Pumpable)
    return self
end

return client
