--[=[
A cooperative HTTP client driven from the SDL loop.

Reqwest and Tokio own the sockets and background threads. `send` copies a
request into Rust and suspends its calling system until the Application drains
the response headers on the Lua thread. A foreign thread never enters LuaJIT.

A response status is still an answer rather than a transfer failure: 404
returns a response whose `Response:ok()` is false. DNS, TLS, connection,
timeout, and body-limit errors raise at the suspended call.

Request readers feed a bounded Rust upload channel from client-owned
cooperative tasks. A composed Reader may therefore suspend on another socket,
process, file, transform, or HTTP body without blocking the SDL pump.
`send` returns as soon as status and headers arrive. The response body is a
one-shot Reader backed by its own bounded native queue. An unread body applies
backpressure only to its transfer, never to response headers or another body.
Close or discard a body that will not be consumed. Neither direction lets a
foreign thread enter LuaJIT or materializes the whole body.
]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")
local runtime <const> = require("tecs.internal.runtime")
local task <const> = require("tecs.internal.taskruntime")
local buffer <const> = require("tecs.io.buffer")
local pump <const> = require("tecs.io.pump")
local stream <const> = require("tecs.io.stream")
local clients <const> = require("tecs.io.http.clients")
local URI <const> = require("tecs.io.URI")
local type iotypes = require("tecs.io.types")

loader.declare("http")

local copy <const> = ffi.copy
local floor <const> = math.floor
local max <const> = math.max

local H <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "http")
-- Externally configured logger name; it remains stable if this module moves.
local LOGGER <const> = log.get("tecs.http")

local SLICE_MS <const> = 50
local DEFAULT_TIMEOUT_MS <const> = 30000
local DEFAULT_CONNECT_TIMEOUT_MS <const> = 10000
local DEFAULT_MAX_REDIRECTS <const> = 5
local DEFAULT_MAX_CONNECTIONS <const> = 16
local DEFAULT_MAX_CONNECTIONS_PER_HOST <const> = 6
local MAX_EXACT_INTEGER <const> = 9007199254740991

local EVENT_HEADERS <const> = 1
local EVENT_CHUNK <const> = 2
local EVENT_COMPLETE <const> = 3
local EVENT_FAILED <const> = 4
local BODY_NONE <const> = 0
local BODY_INLINE <const> = 1
local BODY_UPLOAD <const> = 2
local BODY_FILE <const> = 3
local UPLOAD_CLOSED <const> = -1
local UPLOAD_BACKPRESSURE <const> = 0
local UPLOAD_ACCEPTED <const> = 1
local CHUNK <const> = 512 * 1024
local UPLOAD_STEPS <const> = 16

local function checkWholeNumber(value: number, name: string, minimum: integer)
    if type(value) ~= "number" or value ~= floor(value) or value < minimum or value > MAX_EXACT_INTEGER then
        error(("tecs: HTTP %s must be an integer from %d through %d"):format(name, minimum, MAX_EXACT_INTEGER), 3)
    end
end

local record client
    --- Settings copied when a client is built.
    record Options
        --- Caller-writable. Sets `User-Agent` on every request.
        userAgent: string
        --- Caller-writable. Sets headers sent on every request. Per-request
        --- headers override these without regard to case.
        headers: {string: string}
        --- Caller-writable. Sets positive milliseconds allowed for a whole
        --- transfer. Defaults to 30000.
        timeoutMs: number
        --- Caller-writable. Sets positive milliseconds allowed to establish
        --- a connection. Defaults to 10000.
        connectTimeoutMs: number
        --- Caller-writable. Sets milliseconds a response may make no progress.
        --- Zero disables this timeout.
        stallTimeoutMs: number
        --- Caller-writable. Sets redirects followed. Defaults to five; zero
        --- follows none.
        maxRedirects: integer
        --- Caller-writable. Sets requests allowed to use sockets at once.
        --- Defaults to 16.
        maxConnections: integer
        --- Caller-writable. Sets requests allowed to use sockets to one host.
        --- Defaults to six.
        maxConnectionsPerHost: integer
        --- Caller-writable. Sets maximum response-body bytes. Zero is
        --- unbounded.
        maxBytes: integer
        --- Caller-writable. Accepts gzip and deflate response compression when
        --- true. Defaults to true.
        compressed: boolean
        --- Caller-writable. Lists host names whose TLS certificates are not
        --- verified.
        insecureHosts: {string}
        --- Caller-writable. Sets the textual spelling of an absolute proxy
        --- [`URI`](tealdoc:tecs.io.URI). Nil follows the environment; an empty
        --- string forces a direct connection. This option accepts a string,
        --- not a `URI` object.
        proxy: string
        --- Caller-writable. Lists hosts excluded from an explicitly configured
        --- proxy.
        noProxy: string
        --- Caller-writable. Sets proxy credentials in `user:password` form.
        proxyCredentials: string
    end

    --- One request. Only `url` is required.
    record Request
        --- Caller-writable. Sets an absolute URL with an `http` or `https`
        --- scheme.
        url: URI
        --- Caller-writable. Sets the method. Defaults to GET.
        method: string
        --- Caller-writable. Sets headers merged over the client's defaults.
        --- A `Content-Length` must contain decimal digits and must match a
        --- body whose length is known.
        headers: {string: string}
        --- Caller-writable. Sets bytes to send. A general stream opens one
        --- reader and feeds a bounded upload queue. On the SDL storage backend,
        --- a file stream is opened and read directly by the native HTTP lane.
        --- The client owns cooperative work that waits on a composed reader.
        body: string | iotypes.ReadableStream
        --- Caller-writable. Overrides the client's positive whole-transfer
        --- timeout.
        timeoutMs: number
        --- Caller-writable. Overrides the client's no-progress timeout.
        stallTimeoutMs: number
        --- Caller-writable. Overrides the client's body limit. Zero is
        --- unbounded.
        maxBytes: integer
    end

    --- A completed HTTP response.
    record Response
        --- Read-only. Reports the status after redirects.
        status: integer
        --- Read-only. Reports final response headers with lower-cased names.
        headers: {string: string}
        --- Read-only. Provides a one-shot progressive response body. Reading
        --- may suspend a system or block a direct caller until bytes arrive.
        --- The caller must consume, discard, or close this owned stream.
        body: iotypes.Stream
        --- Read-only. Reports the effective URL after redirects.
        url: URI

        --- Whether the status is in the 2xx range.
        ok: function(self: Response): boolean
    end

    record Transfer
        id: integer
        listener: function(string, Response, string)
        response: Response
        sourceReader: iotypes.Reader
        sourceScratch: iotypes.Buffer
        sourcePending: integer
        transferred: integer
        url: string
        client: Client
        headersReady: boolean
        bodyEvent: loader.CPtr
        bodyReader: any
        bodyOffset: integer
        bodyDone: boolean
        bodyError: string
        bodyWaiter: function()
        uploadTask: task.Task<any>
    end

    --- A reqwest connection pool.
    record Client
        _handle: loader.CPtr
        _options: Options
        _insecure: {string: boolean}
        _byId: {integer: Transfer}
        _uploadScheduler: task.Scheduler
        _uploadSettled: integer
        _pending: integer
        _pumping: boolean
        _eventSize: loader.CArray

        -- Internal completion view used by the coroutine adapter.
        _subscribe: function(self: Client, request: Request, listener: function(string, Response, string)): function()

        --- Sends a request and returns its completed response.
        send: function(self: Client, request: Request): Response
        --- Returns the number of unsettled transfers.
        pending: function(self: Client): integer
        --- Stops all transfers and releases the connection pool.
        close: function(self: Client)
    end

    --- Builds an open client registered with the application pump.
    ---
    --- @param options Copied now; later mutations are not observed.
    --- @return A client that remains registered until `close`.
    newClient: function(options?: Options): Client
end

local type Options = client.Options
local type Stream = iotypes.Stream
local type ReadableStream = iotypes.ReadableStream
local type Request = client.Request
local type Response = client.Response
local type Transfer = client.Transfer
local type Client = client.Client

local record BodyReader is iotypes.Reader
    _transfer: Transfer
    _closed: boolean
    _release: loader.CPtr
end

local record ClientPump
    client: Client
    close: function(self: ClientPump)
end

local ResponseMT <const>: metatable<Response> = {__index = Response}
local ClientMT <const>: metatable<Client> = {__index = Client}
local BodyReaderMT <const>: metatable<BodyReader> = {__index = BodyReader}
local ClientPumpMT <const>: metatable<ClientPump> = {__index = ClientPump}
local clientPumps <const>: {Client: ClientPump} = {}

function Response:ok(): boolean
    return self.status >= 200 and self.status < 300
end

local cancelTransfer: function(self: Client, transfer: Transfer, reason: string, notify: boolean)
local drive: function(self: Client, waitMs: number, level: integer, bodyTarget?: Transfer): integer
local pollBody: function(self: Client, transfer: Transfer): boolean

local function wakeBody(transfer: Transfer)
    local waiter <const> = transfer.bodyWaiter
    transfer.bodyWaiter = nil
    if waiter ~= nil then
        waiter()
    end
end

local function releaseBodyEvent(event: loader.CPtr)
    H.tecsHttpEventDestroy(event)
end

local function currentBodyEvent(transfer: Transfer): loader.CPtr
    return transfer.bodyEvent
end

local function waitForBody(self: BodyReader): boolean, string
    local transfer <const> = self._transfer
    if currentBodyEvent(transfer) ~= nil or transfer.bodyDone then
        return true
    end
    -- The consumer is already on the Lua thread. Probe its native queue here
    -- so a buffered run of chunks drains in one resumption instead of paying
    -- one host frame per 64 KiB chunk.
    pollBody(transfer.client, transfer)
    if currentBodyEvent(transfer) ~= nil or transfer.bodyDone then
        return true
    end
    local mode <const> = task.checkWait("HTTP response body")
    if mode == "blocking" then
        while currentBodyEvent(transfer) == nil and not transfer.bodyDone do
            drive(transfer.client, SLICE_MS, 3, transfer)
        end
        return true
    end
    task.awaitCallback(function(resume: function(boolean)): function()
        if currentBodyEvent(transfer) ~= nil or transfer.bodyDone then
            resume(true)
            return function() end
        end
        if transfer.bodyWaiter ~= nil then
            error("tecs: an HTTP response body permits one pending reader", 2)
        end
        local active = true
        transfer.bodyWaiter = function()
            if active then
                active = false
                resume(true)
            end
        end
        return function()
            if active then
                active = false
                transfer.bodyWaiter = nil
                cancelTransfer(transfer.client, transfer, "response body read was canceled", false)
            end
        end
    end)
    return true
end

local function readBodyPointer(self: BodyReader, count: integer): loader.BytePointer, integer, string
    if self._closed then
        return nil, nil, "the reader is closed"
    end
    local transfer <const> = self._transfer
    if self._release ~= nil then
        releaseBodyEvent(self._release)
        self._release = nil
    end
    waitForBody(self)
    local event <const> = currentBodyEvent(transfer)
    if event == nil then
        if transfer.bodyError ~= nil then
            return nil, nil, transfer.bodyError
        end
        return nil, 0
    end
    local pointer <const> = H.tecsHttpEventData(event, transfer.client._eventSize)
    local length <const> = floor(tonumber(transfer.client._eventSize[0]) or 0) as integer
    local taking <const> = math.min(math.max(1, count), length - transfer.bodyOffset)
    local result <const> = (pointer as loader.BytePointer) + transfer.bodyOffset
    transfer.bodyOffset = transfer.bodyOffset + taking
    if transfer.bodyOffset == length then
        transfer.bodyEvent = nil
        transfer.bodyOffset = 0
        self._release = event
    end
    return result, taking
end

function BodyReader:read(count: integer): string, string
    if type(count) ~= "number" or count ~= floor(count) or count < 0 then
        error("tecs: HTTP body read count must be a non-negative integer", 2)
    end
    local pointer <const>, length, reason = readBodyPointer(self, count)
    if pointer == nil then
        return length == 0 and "" or nil, reason
    end
    return loader.toBytes(pointer as loader.CValue, length)
end

function BodyReader:readInto(destination: iotypes.Buffer, offset?: integer, count?: integer): integer, string
    offset = offset or 0
    count = count or CHUNK
    if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 then
        error("tecs: HTTP body read offset must be a non-negative integer", 2)
    end
    if type(count) ~= "number" or count ~= floor(count) or count < 0 then
        error("tecs: HTTP body read count must be a non-negative integer", 2)
    end
    if count == 0 then
        return 0
    end
    local pointer <const>, length, reason = readBodyPointer(self, count)
    if pointer == nil then
        return length, reason
    end
    local output <const>, previous = buffer.prepareWrite(destination, offset, length)
    copy(output as ffi.CData, pointer as ffi.CData, length)
    buffer.commitWrite(destination, offset, length, previous)
    return length
end

function BodyReader:close(): boolean, string
    if self._closed then
        return true
    end
    self._closed = true
    local transfer <const> = self._transfer
    self._transfer = nil
    if self._release ~= nil then
        releaseBodyEvent(self._release)
        self._release = nil
    end
    if transfer.bodyEvent ~= nil then
        releaseBodyEvent(transfer.bodyEvent)
        transfer.bodyEvent = nil
    end
    if transfer.client._byId[transfer.id] == transfer then
        cancelTransfer(transfer.client, transfer, "response body was closed", false)
    end
    return true
end

local nextId = 1

local function sourceOf(given: string | ReadableStream): ReadableStream
    if given == nil then
        return nil
    end
    if given is string then
        return nil
    end
    local checked <const> = stream._check(given as Stream, "an HTTP request body", 3)
    if not checked:isReadable() then
        error("tecs: an HTTP request body needs a ReadableStream", 3)
    end
    return checked as ReadableStream
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

local function setPointerSlice(slice: loader.CStruct, pointer: any, length: integer)
    slice.data = pointer
    slice.length = length
end

local function eventBytes(self: Client, event: loader.CPtr, accessor: loader.CValue): string
    local data <const> = accessor(event, self._eventSize)
    local length <const> = floor(tonumber(self._eventSize[0]) or 0) as integer
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
    self._pending = self._pending - 1
end

local function cancelUpload(transfer: Transfer, reason: string)
    local upload = transfer.uploadTask
    transfer.uploadTask = nil
    if upload ~= nil and upload.status == "pending" and task.current() ~= upload then
        upload:cancel(reason)
    end
end

local function settleTransfer(transfer: Transfer, status: string, response?: Response, reason?: string)
    local listener = transfer.listener
    transfer.listener = nil
    if listener ~= nil then
        listener(status, response, reason)
    end
end

local function closeSource(transfer: Transfer)
    if transfer.sourceReader ~= nil then
        pcall(transfer.sourceReader.close, transfer.sourceReader)
        transfer.sourceReader = nil
    end
    if transfer.sourceScratch ~= nil then
        transfer.sourceScratch:close()
        transfer.sourceScratch = nil
    end
    transfer.sourcePending = 0
end

local function discardBodyEvents(transfer: Transfer)
    if transfer.bodyEvent ~= nil then
        releaseBodyEvent(transfer.bodyEvent)
        transfer.bodyEvent = nil
    end
    local reader <const> = transfer.bodyReader as BodyReader
    if reader ~= nil and reader._release ~= nil then
        releaseBodyEvent(reader._release)
        reader._release = nil
    end
    transfer.bodyOffset = 0
end

local function failTransfer(self: Client, transfer: Transfer, reason: string)
    cancelUpload(transfer, reason or "HTTP upload failed")
    H.tecsHttpClientCancel(self._handle, transfer.id)
    release(self, transfer)
    closeSource(transfer)
    discardBodyEvents(transfer)
    reason = reason or ("tecs: %s: transfer failed"):format(transfer.url)
    if transfer.headersReady then
        transfer.bodyError = reason
        transfer.bodyDone = true
        wakeBody(transfer)
        return
    end
    settleTransfer(transfer, "failed", nil, reason)
end

local function beginResponse(
    self: Client, transfer: Transfer, status: integer, rawHeaders: string, effectiveUrl: string
)
    local response <const> = transfer.response
    response.status = status
    response.headers = parseHeaders(rawHeaders)
    local responseURI <const>, uriFailure = URI.new(effectiveUrl ~= "" and effectiveUrl or transfer.url)
    if responseURI == nil then
        settleTransfer(
            transfer, "failed", nil, ("tecs: %s: invalid effective URI: %s"):format(transfer.url, uriFailure)
        )
        H.tecsHttpClientCancel(self._handle, transfer.id)
        release(self, transfer)
        return
    end
    response.url = responseURI
    local contentLength: integer = nil
    local declared <const> = response.headers["content-length"]
    if declared ~= nil and declared:match("^%d+$") ~= nil then
        local parsed <const> = tonumber(declared)
        if parsed ~= nil and parsed <= MAX_EXACT_INTEGER then
            contentLength = floor(parsed) as integer
        end
    end
    local reader <const> = setmetatable(
        {_transfer = transfer, _closed = false, _release = nil} as BodyReader, BodyReaderMT
    ) as iotypes.Reader
    transfer.bodyReader = reader
    response.body = stream._newReaderStream(reader, response.headers["content-type"], contentLength) as Stream
    transfer.headersReady = true
    settleTransfer(transfer, "ready", response)
end

local function queueChunk(self: Client, transfer: Transfer, pointer: loader.CPtr)
    H.tecsHttpEventData(pointer, self._eventSize)
    local length <const> = floor(tonumber(self._eventSize[0]) or 0) as integer
    if transfer.bodyEvent ~= nil then
        H.tecsHttpEventDestroy(pointer)
        failTransfer(self, transfer, ("tecs: %s: response body queue overflowed"):format(transfer.url))
        return
    end
    transfer.bodyEvent = pointer
    transfer.transferred = transfer.transferred + length
    wakeBody(transfer)
end

local function completeTransfer(self: Client, transfer: Transfer)
    cancelUpload(transfer, "HTTP transfer completed")
    release(self, transfer)
    closeSource(transfer)
    discardBodyEvents(transfer)
    transfer.bodyDone = true
    wakeBody(transfer)
end

local function handleEvent(self: Client, pointer: loader.CPtr): boolean
    local kind <const> = floor(tonumber(H.tecsHttpEventKind(pointer)) or 0) as integer
    local id <const> = floor(tonumber(H.tecsHttpEventId(pointer)) or 0) as integer
    local transfer <const> = self._byId[id]
    if transfer == nil then
        H.tecsHttpEventDestroy(pointer)
        return false
    end
    if kind == EVENT_HEADERS then
        local status <const> = floor(tonumber(H.tecsHttpEventStatus(pointer)) or 0) as integer
        local headers <const> = eventBytes(self, pointer, H.tecsHttpEventHeaders)
        local url <const> = eventBytes(self, pointer, H.tecsHttpEventUrl)
        H.tecsHttpEventDestroy(pointer)
        beginResponse(self, transfer, status, headers, url)
        return true
    end
    if kind == EVENT_CHUNK then
        queueChunk(self, transfer, pointer)
        return false
    end
    if kind == EVENT_COMPLETE then
        H.tecsHttpEventDestroy(pointer)
        completeTransfer(self, transfer)
        return true
    end
    if kind == EVENT_FAILED then
        local reason <const> = eventBytes(self, pointer, H.tecsHttpEventError)
        H.tecsHttpEventDestroy(pointer)
        failTransfer(self, transfer, reason)
        return true
    end
    H.tecsHttpEventDestroy(pointer)
    failTransfer(self, transfer, ("tecs: %s: unknown HTTP event"):format(transfer.url))
    return true
end

local function serviceUpload(self: Client, transfer: Transfer): boolean, boolean
    local reader <const> = transfer.sourceReader
    if reader == nil then
        return false, false
    end
    if transfer.sourcePending == 0 then
        transfer.sourceScratch:clear()
        local ok <const>, count, reason = pcall(
            pump.readInto, reader, transfer.sourceScratch, 0, CHUNK
        ) as (boolean, integer, string)
        if not ok then
            failTransfer(self, transfer, ("tecs: %s: %s"):format(transfer.url, tostring(count)))
            return true, true
        end
        if count == nil then
            failTransfer(self, transfer, ("tecs: %s: %s"):format(transfer.url, reason or "cannot read request body"))
            return true, true
        end
        if type(count) ~= "number" or count ~= floor(count) or count < 0 or count > CHUNK then
            failTransfer(
                self,
                transfer,
                ("tecs: %s: request reader returned invalid byte count %s"):format(transfer.url, tostring(count))
            )
            return true, true
        end
        if count > transfer.sourceScratch:length() then
            failTransfer(
                self,
                transfer,
                ("tecs: %s: request reader returned %d bytes but initialized only %d"):format(
                    transfer.url, count, transfer.sourceScratch:length()
                )
            )
            return true, true
        end
        if count == 0 then
            local uploaded <const> = floor(
                tonumber(H.tecsHttpClientUpload(self._handle, transfer.id, nil, 0, 1)) or UPLOAD_CLOSED
            ) as integer
            if uploaded ~= UPLOAD_BACKPRESSURE then
                closeSource(transfer)
            end
            return false, true
        end
        transfer.sourcePending = count
    end

    local uploaded <const> = floor(
        tonumber(
            H.tecsHttpClientUpload(
                self._handle, transfer.id, transfer.sourceScratch:getFFIPointer(), transfer.sourcePending, 0
            )
        ) or UPLOAD_CLOSED
    ) as integer
    if uploaded == UPLOAD_ACCEPTED then
        transfer.sourcePending = 0
        return false, true
    end
    if uploaded == UPLOAD_CLOSED then
        closeSource(transfer)
    end
    return false, false
end

local function runUpload(self: Client, transfer: Transfer)
    while self._byId[transfer.id] == transfer and transfer.sourceReader ~= nil do
        local steps = 0
        repeat
            local didSettle <const>, progressed <const> = serviceUpload(self, transfer)
            if didSettle then
                self._uploadSettled = self._uploadSettled + 1
                return
            end
            if self._byId[transfer.id] ~= transfer or transfer.sourceReader == nil then
                return
            end
            if not progressed then
                break
            end
            steps = steps + 1
        until steps >= UPLOAD_STEPS
        task.yield()
    end
end

pollBody = function(self: Client, transfer: Transfer): boolean
    if transfer.bodyEvent ~= nil or transfer.bodyDone or self._byId[transfer.id] ~= transfer then
        return false
    end
    local event <const> = H.tecsHttpClientBodyNext(self._handle, transfer.id, 0) as loader.CPtr
    if event == nil then
        return false
    end
    return handleEvent(self, event)
end

local function turn(self: Client, waitMs: number, bodyTarget?: Transfer): integer
    self._uploadSettled = 0
    self._uploadScheduler:step()
    local settled = self._uploadSettled
    local event = H.tecsHttpClientNext(self._handle, max(0, floor(waitMs))) as loader.CPtr
    while event ~= nil do
        if handleEvent(self, event) then
            settled = settled + 1
        end
        event = H.tecsHttpClientNext(self._handle, 0) as loader.CPtr
    end
    if bodyTarget ~= nil and pollBody(self, bodyTarget) then
        settled = settled + 1
    end
    for _, transfer in pairs(self._byId) do
        if transfer ~= bodyTarget and transfer.bodyWaiter ~= nil and pollBody(self, transfer) then
            settled = settled + 1
        end
    end
    return settled
end

drive = function(self: Client, waitMs: number, level: integer, bodyTarget?: Transfer): integer
    if self._pumping then
        error(
            "tecs: this http client is already pumping; a listener cannot wait on or pump the client calling it", level
        )
    end
    if self._handle == nil then
        return 0
    end
    self._pumping = true
    local ok, result = pcall(turn, self, waitMs, bodyTarget) as (boolean, any)
    self._pumping = false
    if not ok then
        error(result, 0)
    end
    return result as integer
end

function ClientPump:pump(): integer
    return drive(self.client, 0, 3)
end

function ClientPump:close()
    self.client:close()
end

function Client:pending(): integer
    return self._pending
end

local function mergedHeaders(self: Client, request: Request, source: ReadableStream): {string: string}
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
    if source ~= nil and merged["content-type"] == nil then
        local contentType <const> = source:contentType()
        if contentType ~= nil then
            merged["content-type"] = contentType
        end
    end
    return merged
end

local function declaredContentLength(headers: {string: string}): integer, string
    local value <const> = headers["content-length"]
    if value == nil then
        return nil
    end
    if type(value) ~= "string" or value:match("^%d+$") == nil then
        return nil, "tecs: Content-Length must contain only decimal digits"
    end
    local length <const> = tonumber(value)
    if length == nil or length > MAX_EXACT_INTEGER then
        return nil, "tecs: Content-Length exceeds the largest exact byte count"
    end
    return floor(length) as integer
end

local function streamContentLength(source: ReadableStream): integer, string
    local read <const>, value = pcall(source.contentLength, source) as (boolean, any)
    if not read then
        return nil, ("tecs: the request body Content-Length could not be read: %s"):format(tostring(value))
    end
    if value == nil then
        return -1
    end
    if type(value) ~= "number" then
        return nil, "tecs: the request body Content-Length must be a non-negative exact integer or nil"
    end
    local length <const> = value as number
    if length < 0 or length > MAX_EXACT_INTEGER or length ~= floor(length) then
        return nil, "tecs: the request body Content-Length must be a non-negative exact integer or nil"
    end
    return length as integer
end

local function startTransfer(self: Client, request: Request, listener: function(string, Response, string)): Transfer
    if self._handle == nil then
        error("tecs: this http client is closed", 2)
    end
    if request == nil or not URI.isURI(request.url) then
        error("tecs: http send needs a request with a URI from tecs.io.URI.new", 2)
    end
    if request.timeoutMs ~= nil then
        checkWholeNumber(request.timeoutMs, "request timeoutMs", 1)
    end
    if request.stallTimeoutMs ~= nil then
        checkWholeNumber(request.stallTimeoutMs, "request stallTimeoutMs", 0)
    end
    if request.maxBytes ~= nil then
        checkWholeNumber(request.maxBytes, "request maxBytes", 0)
    end

    local requestURI <const> = request.url
    local url <const> = requestURI:toString()
    local scheme <const> = requestURI:scheme()
    if scheme ~= "http" and scheme ~= "https" then
        listener("failed", nil, ("tecs: %s is not an http or https url"):format(url))
        return nil
    end

    local givenBody <const> = request.body
    local source <const> = sourceOf(givenBody)
    local bodyText: string = nil
    if givenBody is string then
        bodyText = givenBody
    end
    local borrowed = source ~= nil and stream._borrowBytes(source) or nil
    local filePath = source ~= nil and stream._nativeFilePath(source) or nil

    local id <const> = nextId
    nextId = nextId + 1
    local transfer <const>: Transfer = {
        id = id,
        listener = listener,
        response = setmetatable({status = 0, headers = {}, url = requestURI} as Response, ResponseMT),
        sourcePending = 0,
        transferred = 0,
        url = url,
        client = self,
        headersReady = false,
        bodyEvent = nil,
        bodyReader = nil,
        bodyOffset = 0,
        bodyDone = false,
    }

    local method <const> = (request.method or "GET"):upper()
    local carries <const> = method == "POST" or method == "PUT" or method == "PATCH"
    local bodyKind = BODY_NONE
    local bodyLength = 0
    if bodyText ~= nil then
        bodyKind = BODY_INLINE
        bodyLength = #bodyText
    elseif borrowed ~= nil then
        bodyKind = BODY_INLINE
        bodyLength = borrowed.length
    elseif filePath ~= nil then
        bodyKind = BODY_FILE
        local bodyLengthFailure: string
        bodyLength, bodyLengthFailure = streamContentLength(source)
        if bodyLengthFailure ~= nil or bodyLength < 0 then
            settleTransfer(
                transfer, "failed", nil, bodyLengthFailure or "tecs: the request body file length could not be read"
            )
            return nil
        end
    elseif source ~= nil then
        bodyKind = BODY_UPLOAD
        local bodyLengthFailure: string
        bodyLength, bodyLengthFailure = streamContentLength(source)
        if bodyLengthFailure ~= nil then
            settleTransfer(transfer, "failed", nil, bodyLengthFailure)
            return nil
        end
    elseif carries then
        bodyKind = BODY_INLINE
        bodyLength = 0
        bodyText = ""
    end

    local merged <const> = mergedHeaders(self, request, source)
    local contentLength <const>, contentLengthFailure <const> = declaredContentLength(merged)
    if contentLengthFailure ~= nil then
        settleTransfer(transfer, "failed", nil, contentLengthFailure)
        return nil
    end
    if contentLength ~= nil then
        if bodyLength >= 0 and bodyLength ~= contentLength then
            settleTransfer(
                transfer,
                "failed",
                nil,
                ("tecs: Content-Length is %d, but the request body contains %d bytes"):format(contentLength, bodyLength)
            )
            return nil
        end
        if bodyKind == BODY_UPLOAD then
            bodyLength = contentLength
        end
    end
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

    local nativeArray <const> = loader.newArray("TecsHttpRequest[1]")
    local native <const> = nativeArray[0] as loader.CStruct
    native.id = id
    setSlice(native.url as loader.CStruct, url)
    setSlice(native.method as loader.CStruct, method)
    native.headers = nativeHeaders
    native.headerCount = headerCount
    if bodyText ~= nil then
        setSlice(native.body as loader.CStruct, bodyText)
    elseif borrowed ~= nil then
        setPointerSlice(native.body as loader.CStruct, borrowed.pointer, borrowed.length)
    elseif filePath ~= nil then
        setSlice(native.body as loader.CStruct, filePath)
    else
        setSlice(native.body as loader.CStruct, nil)
    end
    native.bodyKind = bodyKind
    native.bodyLength = bodyLength
    native.timeoutMs = request.timeoutMs or self._options.timeoutMs
    native.stallTimeoutMs = request.stallTimeoutMs or self._options.stallTimeoutMs
    native.maxBytes = request.maxBytes ~= nil and request.maxBytes or self._options.maxBytes
    local host <const> = requestURI:host()
    native.insecure = host ~= nil and self._insecure[host] and 1 or 0

    if (tonumber(H.tecsHttpClientSend(self._handle, nativeArray)) or 0) == 0 then
        settleTransfer(transfer, "failed", nil, ("tecs: cannot start %s: %s"):format(url, nativeError()))
        return nil
    end

    if bodyKind == BODY_UPLOAD then
        local opened <const>, reader, reason = pcall(source.newReader, source) as (boolean, iotypes.Reader, string)
        if not opened or reader == nil then
            H.tecsHttpClientCancel(self._handle, id)
            settleTransfer(
                transfer,
                "failed",
                nil,
                opened and (reason or "tecs: the request body could not be opened")
                    or ("tecs: the request body could not be opened: %s"):format(tostring(reader))
            )
            return nil
        end
        transfer.sourceReader = reader
        local allocated <const>, scratch = pcall(stream.newBuffer) as (boolean, iotypes.Buffer)
        if not allocated then
            H.tecsHttpClientCancel(self._handle, id)
            closeSource(transfer)
            settleTransfer(
                transfer,
                "failed",
                nil,
                ("tecs: the request body buffer could not be allocated: %s"):format(tostring(scratch))
            )
            return nil
        end
        transfer.sourceScratch = scratch
    end

    self._byId[id] = transfer
    self._pending = self._pending + 1
    if bodyKind == BODY_UPLOAD then
        local upload <const> = self._uploadScheduler:spawn(function(): boolean
            runUpload(self, transfer)
            return true
        end)
        transfer.uploadTask = upload as task.Task<any>
        task.onSettle(
            upload,
            function(settled: task.Task<boolean>)
                if transfer.uploadTask == settled as task.Task<any> then
                    transfer.uploadTask = nil
                end
                if settled.status == "failed" and self._byId[transfer.id] == transfer then
                    self._uploadSettled = self._uploadSettled + 1
                    failTransfer(self, transfer, settled.error or "tecs: HTTP upload task failed")
                end
            end
        )
    end
    return transfer
end

cancelTransfer = function(self: Client, transfer: Transfer, reason: string, notify: boolean)
    if self._byId[transfer.id] ~= transfer then
        return
    end
    H.tecsHttpClientCancel(self._handle, transfer.id)
    cancelUpload(transfer, reason)
    release(self, transfer)
    closeSource(transfer)
    discardBodyEvents(transfer)
    if transfer.headersReady then
        transfer.bodyError = reason
        transfer.bodyDone = true
        wakeBody(transfer)
    elseif notify then
        settleTransfer(transfer, "canceled", nil, reason)
    else
        transfer.listener = nil
    end
end

function Client:send(request: Request): Response
    local mode <const> = task.checkWait("HTTP request")
    if mode == "blocking" then
        local outcome: {string: any} = nil
        self:_subscribe(
            request,
            function(status: string, response: Response, reason: string)
                outcome = {status = status, response = response, reason = reason}
            end
        )
        while outcome == nil do
            drive(self, SLICE_MS, 3)
            runtime.poll()
        end
        if outcome.status == "ready" then
            return outcome.response as Response
        end
        if outcome.status == "failed" then
            error(outcome.reason as string or "HTTP request failed", 2)
        end
        error("tecs: HTTP request was canceled: " .. (outcome.reason as string or "canceled"), 2)
    end
    local outcome <const> = task.awaitCallback(function(resume: function({string: any})): function()
        return self:_subscribe(
            request,
            function(status: string, response: Response, reason: string)
                resume({status = status, response = response, reason = reason})
            end
        )
    end)
    if outcome.status == "ready" then
        return outcome.response as Response
    end
    if outcome.status == "failed" then
        error(outcome.reason as string or "HTTP request failed", 2)
    end
    error("tecs: HTTP request was canceled: " .. (outcome.reason as string or "canceled"), 2)
end

function Client:_subscribe(request: Request, listener: function(string, Response, string)): function()
    if type(listener) ~= "function" then
        error("tecs: HTTP completion subscription needs a listener", 2)
    end
    local transfer <const> = startTransfer(self, request, listener)
    if transfer == nil then
        return function() end
    end
    local active = true
    return function()
        if not active then
            return
        end
        active = false
        -- Cancellation releases this sole consumer before stopping native
        -- work, so a canceled operation cannot be retained or resumed by it.
        transfer.listener = nil
        cancelTransfer(self, transfer, "canceled", false)
    end
end

function Client:close()
    if self._handle == nil then
        return
    end
    if self._pumping then
        error("tecs: cannot close an http client from inside its own pump", 2)
    end
    local handle <const> = self._handle
    self._handle = nil
    local clientPump <const> = clientPumps[self]
    clientPumps[self] = nil
    clients.remove(clientPump as clients.Pumpable)

    local live: {Transfer} = {}
    for _, transfer in pairs(self._byId) do
        live[#live + 1] = transfer
    end
    for index = 1, #live do
        local transfer <const> = live[index]
        H.tecsHttpClientCancel(handle, transfer.id)
        cancelUpload(transfer, "the http client was closed")
        release(self, transfer)
        closeSource(transfer)
        discardBodyEvents(transfer)
        if transfer.headersReady then
            transfer.bodyError = "the http client was closed"
            transfer.bodyDone = true
            wakeBody(transfer)
        else
            settleTransfer(transfer, "canceled", nil, "the http client was closed")
        end
    end

    self._uploadScheduler:step()

    H.tecsHttpClientDestroy(handle)
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
    local connectTimeoutMs <const> = given.connectTimeoutMs or DEFAULT_CONNECT_TIMEOUT_MS
    local stallTimeoutMs <const> = given.stallTimeoutMs or 0
    local maxRedirects <const> = given.maxRedirects or DEFAULT_MAX_REDIRECTS
    local maxConnections <const> = given.maxConnections or DEFAULT_MAX_CONNECTIONS
    local maxConnectionsPerHost <const> = given.maxConnectionsPerHost or DEFAULT_MAX_CONNECTIONS_PER_HOST
    local maxBytes <const> = given.maxBytes or 0
    checkWholeNumber(timeoutMs, "timeoutMs", 1)
    checkWholeNumber(connectTimeoutMs, "connectTimeoutMs", 1)
    checkWholeNumber(stallTimeoutMs, "stallTimeoutMs", 0)
    checkWholeNumber(maxRedirects, "maxRedirects", 0)
    checkWholeNumber(maxConnections, "maxConnections", 1)
    checkWholeNumber(maxConnectionsPerHost, "maxConnectionsPerHost", 1)
    checkWholeNumber(maxBytes, "maxBytes", 0)
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
        connectTimeoutMs = connectTimeoutMs,
        stallTimeoutMs = stallTimeoutMs,
        maxRedirects = maxRedirects,
        maxConnections = maxConnections,
        maxConnectionsPerHost = maxConnectionsPerHost,
        maxBytes = maxBytes,
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
    self._handle = handle
    self._options = settings
    self._insecure = insecure
    self._byId = {}
    self._uploadScheduler = task.newScheduler()
    self._uploadSettled = 0
    self._pending = 0
    self._pumping = false
    self._eventSize = loader.newArray("size_t[1]")
    local clientPump <const> = setmetatable({client = self} as ClientPump, ClientPumpMT)
    clientPumps[self] = clientPump
    clients.add(clientPump as clients.Pumpable)
    return self
end

return client
