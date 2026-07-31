--[=[
An asynchronous HTTP client driven from the SDL loop.

Reqwest and Tokio own the sockets and background threads. `send` copies a
request into Rust and returns a `Future` immediately. `pump` drains response
chunks and completions back on the Lua thread, which means a foreign thread
never enters LuaJIT and future listeners always run from the SDL loop.

A response status is still an answer rather than a transfer failure: 404
settles a ready future whose `Response:ok()` is false. DNS, TLS, connection,
timeout, and body-limit errors settle a failed future.

Request readers feed a bounded Rust upload channel from the SDL thread.
Response chunks append to one owned buffer or pass through one reusable
scratch buffer to the caller's writer. Neither direction lets a foreign thread
enter LuaJIT, and neither file direction materializes the whole body.
]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")
local Future <const> = require("tecs.Future")
local buffer <const> = require("tecs.io.buffer")
local pump <const> = require("tecs.io.pump")
local stream <const> = require("tecs.io.stream")
local clients <const> = require("tecs.io.http.clients")
local uri <const> = require("tecs.io.http.uri")
local type iotypes = require("tecs.io.types")
local type coretypes = require("tecs.types")
local type Closeable = coretypes.Closeable
local type URI = uri.URI

loader.declare("http")

local copy <const> = ffi.copy
local floor <const> = math.floor
local max <const> = math.max
local protect <const> = pcall
local removeAt <const> = table.remove

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

local EVENT_CHUNK <const> = 1
local EVENT_COMPLETE <const> = 2
local EVENT_FAILED <const> = 3
local BODY_NONE <const> = 0
local BODY_INLINE <const> = 1
local BODY_UPLOAD <const> = 2
local UPLOAD_CLOSED <const> = -1
local UPLOAD_BACKPRESSURE <const> = 0
local UPLOAD_ACCEPTED <const> = 1
local CHUNK <const> = 64 * 1024
local UPLOAD_STEPS <const> = 16

local record client
    --- Settings copied when a client is built.
    record Options
        --- Caller-writable. Sets `User-Agent` on every request.
        userAgent: string
        --- Caller-writable. Sets headers sent on every request. Per-request
        --- headers override these without regard to case.
        headers: {string: string}
        --- Caller-writable. Sets milliseconds allowed for a whole transfer.
        --- Defaults to 30000.
        timeoutMs: number
        --- Caller-writable. Sets milliseconds allowed to establish a
        --- connection. Defaults to 10000.
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
        --- Caller-writable. Sets a proxy URL. Unset follows the environment;
        --- empty forces a direct connection.
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
        --- Caller-writable. Sets bytes to send. A stream opens one reader when
        --- this request begins and feeds it through a bounded upload queue.
        body: string | iotypes.ReadableStream
        --- Caller-writable. Sets where response chunks are written. A string
        --- is a file path.
        into: string | iotypes.WritableStream
        --- Caller-writable. Overrides the client's whole-transfer timeout.
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
        --- Read-only. Provides response bytes in memory or in the requested
        --- destination.
        body: iotypes.Stream
        --- Read-only. Reports the effective URL after redirects.
        url: URI

        --- Whether the status is in the 2xx range.
        ok: function(self: Response): boolean
    end

    record Transfer
        id: integer
        future: Future<Response>
        response: Response
        sink: iotypes.WritableStream
        writer: iotypes.Writer
        responseBuffer: iotypes.Buffer
        responseScratch: iotypes.Buffer
        sourceReader: iotypes.Reader
        sourceScratch: iotypes.Buffer
        sourcePending: integer
        transferred: integer
        url: string
    end

    --- A reqwest connection pool and `Future.Source`.
    record Client is Closeable
        --- Maximum duration of one blocking future-wait slice.
        sliceMs: number
        --- Default budget for a future wait without an explicit timeout.
        defaultWaitMs: number

        _handle: loader.CPtr
        _options: Options
        _insecure: {string: boolean}
        _byFuture: {Future<Response>: Transfer}
        _byId: {integer: Transfer}
        _uploadOrder: {Transfer}
        _uploadCursor: integer
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
local type Stream = iotypes.Stream
local type ReadableStream = iotypes.ReadableStream
local type WritableStream = iotypes.WritableStream
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
    if not checked:isAvailable() then
        error("tecs: the HTTP request body is unavailable", 3)
    end
    return checked as ReadableStream
end

local function sinkOf(given: string | WritableStream): WritableStream
    if given == nil then
        return nil
    end
    if given is string then
        return stream.newFileStream(given)
    end
    local checked <const> = stream._check(given as Stream, "an HTTP response destination", 3)
    if not checked:isWritable() then
        error("tecs: an HTTP response destination needs a WritableStream", 3)
    end
    if not checked:isAvailable() then
        error("tecs: the HTTP response destination is unavailable", 3)
    end
    return checked as WritableStream
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

local function removeUpload(self: Client, transfer: Transfer)
    for index = 1, #self._uploadOrder do
        if self._uploadOrder[index] == transfer then
            removeAt(self._uploadOrder, index)
            if index < self._uploadCursor then
                self._uploadCursor = self._uploadCursor - 1
            end
            if self._uploadCursor > #self._uploadOrder then
                self._uploadCursor = 1
            end
            return
        end
    end
end

local function release(self: Client, transfer: Transfer)
    if self._byId[transfer.id] == nil then
        return
    end
    removeUpload(self, transfer)
    self._byId[transfer.id] = nil
    self._byFuture[transfer.future] = nil
    self._pending = self._pending - 1
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

local function finishWriter(transfer: Transfer, openEmpty: boolean): boolean, string
    if transfer.sink == nil then
        return true
    end
    if transfer.writer == nil and openEmpty then
        local opened <const>, writer, reason = pcall(
            transfer.sink.newWriter, transfer.sink
        ) as (boolean, iotypes.Writer, string)
        if not opened then
            return false, tostring(writer)
        end
        if writer == nil then
            return false, reason or "cannot open response destination"
        end
        transfer.writer = writer
    end
    if transfer.writer == nil then
        return true
    end
    local writer <const> = transfer.writer
    transfer.writer = nil
    local closed <const>, ok, reason = pcall(writer.close, writer) as (boolean, boolean, string)
    if not closed then
        return false, tostring(ok)
    end
    if not ok then
        return false, reason or "cannot close response destination"
    end
    return true
end

local function releaseResponseBuffers(transfer: Transfer)
    if transfer.responseBuffer ~= nil then
        transfer.responseBuffer:close()
        transfer.responseBuffer = nil
    end
    if transfer.responseScratch ~= nil then
        transfer.responseScratch:close()
        transfer.responseScratch = nil
    end
end

local function failTransfer(self: Client, transfer: Transfer, reason: string)
    H.tecsHttpClientCancel(self._handle, transfer.id)
    release(self, transfer)
    closeSource(transfer)
    local ok <const>, closeFailure = finishWriter(transfer, false)
    releaseResponseBuffers(transfer)
    if not ok and (reason == nil or reason == "") then
        reason = closeFailure
    end
    transfer.future:fail(reason or ("tecs: %s: transfer failed"):format(transfer.url))
end

local function completeTransfer(
    self: Client, transfer: Transfer, status: integer, rawHeaders: string, effectiveUrl: string
)
    release(self, transfer)
    closeSource(transfer)
    local ok <const>, failure = finishWriter(transfer, true)
    if not ok then
        releaseResponseBuffers(transfer)
        transfer.future:fail(("tecs: %s: %s"):format(transfer.url, failure or "response destination failed"))
        return
    end

    local response <const> = transfer.response
    response.status = status
    response.headers = parseHeaders(rawHeaders)
    local responseURI <const>, uriFailure = uri.new(effectiveUrl ~= "" and effectiveUrl or transfer.url)
    if responseURI == nil then
        releaseResponseBuffers(transfer)
        transfer.future:fail(("tecs: %s: invalid effective URI: %s"):format(transfer.url, uriFailure))
        return
    end
    response.url = responseURI
    local prepared <const>, body = protect(function(): Stream
        if transfer.sink ~= nil then
            return stream.newStreamWithMetadata(
                transfer.sink, response.headers["content-type"], transfer.transferred
            ) as Stream
        end
        if transfer.responseBuffer == nil then
            transfer.responseBuffer = stream.newBuffer()
        end
        local responseBuffer <const> = transfer.responseBuffer
        local view <const> = responseBuffer:view()
        local buffered <const> = view:newStream(response.headers["content-type"]) as Stream

        view:close()
        responseBuffer:close()
        transfer.responseBuffer = nil
        return buffered
    end) as (boolean, any)
    if not prepared then
        releaseResponseBuffers(transfer)
        transfer.future:fail(
            ("tecs: %s: response body could not be finalized: %s"):format(transfer.url, tostring(body))
        )
        return
    end
    response.body = body as Stream
    if transfer.responseScratch ~= nil then
        transfer.responseScratch:close()
        transfer.responseScratch = nil
    end
    transfer.future:complete(response)
end

local function writeChunk(self: Client, transfer: Transfer, pointer: loader.CPtr): string
    local data <const> = H.tecsHttpEventData(pointer, self._eventSize)
    local length <const> = floor(tonumber(self._eventSize[0]) or 0) as integer
    if length == 0 then
        return nil
    end
    if transfer.sink == nil then
        if transfer.responseBuffer == nil then
            transfer.responseBuffer = stream.newBuffer()
        end
        local offset <const> = transfer.responseBuffer:length()
        local output <const>, previousLength = buffer.prepareWrite(transfer.responseBuffer, offset, length)
        copy(output as ffi.CData, data as ffi.CData, length)
        buffer.commitWrite(transfer.responseBuffer, offset, length, previousLength)
    else
        if transfer.writer == nil then
            local reason: string
            transfer.writer, reason = transfer.sink:newWriter()
            if transfer.writer == nil then
                return reason or "cannot open response destination"
            end
        end
        if transfer.responseScratch == nil then
            transfer.responseScratch = stream.newBuffer()
        end
        transfer.responseScratch:clear()
        local output <const>, previousLength = buffer.prepareWrite(transfer.responseScratch, 0, length)
        copy(output as ffi.CData, data as ffi.CData, length)
        buffer.commitWrite(transfer.responseScratch, 0, length, previousLength)
        local offset = 0
        while offset < length do
            local remaining <const> = length - offset
            local wrote <const>, reason = pump.writeFrom(
                transfer.writer, transfer.responseScratch, offset, length - offset
            )
            if wrote == nil then
                return reason or "cannot write response"
            end
            if type(wrote) ~= "number" or wrote ~= floor(wrote) or wrote < 1 or wrote > remaining then
                return ("response writer returned %s for a %d-byte write"):format(tostring(wrote), remaining)
            end
            offset = offset + wrote
        end
    end
    transfer.transferred = transfer.transferred + length
    return nil
end

local function handleEvent(self: Client, pointer: loader.CPtr): boolean
    local kind <const> = floor(tonumber(H.tecsHttpEventKind(pointer)) or 0) as integer
    local id <const> = floor(tonumber(H.tecsHttpEventId(pointer)) or 0) as integer
    local transfer <const> = self._byId[id]
    if transfer == nil then
        H.tecsHttpEventDestroy(pointer)
        return false
    end
    if kind == EVENT_CHUNK then
        local ok <const>, failure = pcall(writeChunk, self, transfer, pointer) as (boolean, string)
        H.tecsHttpEventDestroy(pointer)
        if not ok then
            failTransfer(self, transfer, ("tecs: %s: %s"):format(transfer.url, tostring(failure)))
            return true
        end
        if failure ~= nil then
            failTransfer(self, transfer, ("tecs: %s: %s"):format(transfer.url, failure))
            return true
        end
        return false
    end
    if kind == EVENT_COMPLETE then
        local status <const> = floor(tonumber(H.tecsHttpEventStatus(pointer)) or 0) as integer
        local headers <const> = eventBytes(self, pointer, H.tecsHttpEventHeaders)
        local url <const> = eventBytes(self, pointer, H.tecsHttpEventUrl)
        H.tecsHttpEventDestroy(pointer)
        completeTransfer(self, transfer, status, headers, url)
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
            pump.readInto, reader, transfer.sourceScratch, CHUNK, 0
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

local function serviceUploads(self: Client): integer
    local settled = 0
    local steps = 0
    while #self._uploadOrder > 0 and steps < UPLOAD_STEPS do
        if self._uploadCursor > #self._uploadOrder then
            self._uploadCursor = 1
        end
        local transfer <const> = self._uploadOrder[self._uploadCursor]
        local didSettle <const> = serviceUpload(self, transfer)
        settled = settled + (didSettle and 1 or 0)
        steps = steps + 1
        if self._byId[transfer.id] == transfer and transfer.sourceReader ~= nil then
            self._uploadCursor = self._uploadCursor + 1
        elseif self._byId[transfer.id] == transfer then
            removeUpload(self, transfer)
        end
    end
    return settled
end

local function turn(self: Client, waitMs: number): integer
    local settled = serviceUploads(self)
    local event = H.tecsHttpClientNext(self._handle, max(0, floor(waitMs))) as loader.CPtr
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

function Client:send(request: Request): Future<Response>
    if self._handle == nil then
        error("tecs: this http client is closed", 2)
    end
    if request == nil or not uri.isURI(request.url) then
        error("tecs: http send needs a request with a URI from tecs.io.http.newURI", 2)
    end

    local requestURI <const> = request.url
    local url <const> = requestURI.text
    local scheme <const> = requestURI.scheme
    if scheme ~= "http" and scheme ~= "https" then
        return Future.failed(("tecs: %s is not an http or https url"):format(url)) as Future<Response>
    end

    local givenBody <const> = request.body
    local source <const> = sourceOf(givenBody)
    local sink <const> = sinkOf(request.into)
    local bodyText: string = nil
    if givenBody is string then
        bodyText = givenBody
    end
    local borrowed = source ~= nil and stream._borrowBytes(source) or nil

    local id <const> = nextId
    nextId = nextId + 1
    local future <const> = Future.pending(self as Future.Source) as Future<Response>
    local transfer <const>: Transfer = {
        id = id,
        future = future,
        response = setmetatable({status = 0, headers = {}, url = requestURI} as Response, ResponseMT),
        sink = sink,
        sourcePending = 0,
        transferred = 0,
        url = url,
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
    elseif source ~= nil then
        bodyKind = BODY_UPLOAD
        local bodyLengthFailure: string
        bodyLength, bodyLengthFailure = streamContentLength(source)
        if bodyLengthFailure ~= nil then
            future:fail(bodyLengthFailure)
            return future
        end
    elseif carries then
        bodyKind = BODY_INLINE
        bodyLength = 0
        bodyText = ""
    end

    local merged <const> = mergedHeaders(self, request, source)
    local contentLength <const>, contentLengthFailure <const> = declaredContentLength(merged)
    if contentLengthFailure ~= nil then
        future:fail(contentLengthFailure)
        return future
    end
    if contentLength ~= nil then
        if bodyLength >= 0 and bodyLength ~= contentLength then
            future:fail(
                ("tecs: Content-Length is %d, but the request body contains %d bytes"):format(contentLength, bodyLength)
            )
            return future
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
    else
        setSlice(native.body as loader.CStruct, nil)
    end
    native.bodyKind = bodyKind
    native.bodyLength = bodyLength
    native.timeoutMs = request.timeoutMs or self._options.timeoutMs
    native.stallTimeoutMs = request.stallTimeoutMs or self._options.stallTimeoutMs
    native.maxBytes = request.maxBytes ~= nil and request.maxBytes or self._options.maxBytes
    local host <const> = requestURI.host
    native.insecure = host ~= nil and self._insecure[host] and 1 or 0

    if (tonumber(H.tecsHttpClientSend(self._handle, nativeArray)) or 0) == 0 then
        future:fail(("tecs: cannot start %s: %s"):format(url, nativeError()))
        return future
    end

    if bodyKind == BODY_UPLOAD then
        local opened <const>, reader, reason = pcall(source.newReader, source) as (boolean, iotypes.Reader, string)
        if not opened or reader == nil then
            H.tecsHttpClientCancel(self._handle, id)
            future:fail(
                opened and (reason or "tecs: the request body could not be opened")
                    or ("tecs: the request body could not be opened: %s"):format(tostring(reader))
            )
            return future
        end
        transfer.sourceReader = reader
        local allocated <const>, scratch = pcall(stream.newBuffer) as (boolean, iotypes.Buffer)
        if not allocated then
            H.tecsHttpClientCancel(self._handle, id)
            closeSource(transfer)
            future:fail(("tecs: the request body buffer could not be allocated: %s"):format(tostring(scratch)))
            return future
        end
        transfer.sourceScratch = scratch
        self._uploadOrder[#self._uploadOrder + 1] = transfer
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
    closeSource(transfer)
    finishWriter(transfer, false)
    releaseResponseBuffers(transfer)
    transfer.future:abandon("canceled")
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
    clients.remove(self as clients.Pumpable)

    local live: {Transfer} = {}
    for _, transfer in pairs(self._byId) do
        live[#live + 1] = transfer
    end
    for index = 1, #live do
        local transfer <const> = live[index]
        H.tecsHttpClientCancel(handle, transfer.id)
        release(self, transfer)
        closeSource(transfer)
        finishWriter(transfer, false)
        releaseResponseBuffers(transfer)
        transfer.future:abandon("the http client was closed")
    end

    H.tecsHttpClientDestroy(handle)
    self._uploadOrder = {}
    self._uploadCursor = 1
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
    self._uploadOrder = {}
    self._uploadCursor = 1
    self._pending = 0
    self._pumping = false
    self._eventSize = loader.newArray("size_t[1]")
    clients.add(self as clients.Pumpable)
    return self
end

return client
