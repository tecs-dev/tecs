--- An HTTP client driven from a frame, on `Future`.
---
--- `curl_easy_perform` runs a whole transfer before it returns, so a frame that
--- used it would not end until the network answered. This is libcurl's multi
--- interface instead: every request is added to one multi handle, a pump does
--- as much as can be done without waiting, and each request's answer arrives
--- as a settled `Future<Response>`.
---
---     tecs.net.http.newClient({userAgent = "mygame/1.0"})
---         :send({
---             url = "https://example.com/manifest.json",
---             headers = {accept = "application/json"},
---         })
---         :map(function(response: Response): string return response.body:text() end)
---         :onSettle(function(manifest: Future<string>)
---             print(manifest.status, manifest.value)
---         end)
---
--- Nothing there goes in a frame. Building a client puts it on the list
--- `tecs.net.http.pumpClients` turns, and `tecs.Application` turns it once an
--- iteration for the same reason it updates `assets` and `proc`: a transfer
--- that finished has finished, and nothing else in the frame is obliged to
--- ask. `pump` stays on this type because a headless tool has no application
--- to do it, and because the specs drive it directly. A game never calls it.
---
--- This module owns `Client` and exposes `newClient`, rather than being
--- callable itself. A callable namespace would put `Request`, `Response` and
--- `Options` a level below the thing that constructs them, and the public name
--- for each of them would then be one segment deeper than any public name in
--- this tree goes. So the file is `client.tl` rather than `Client.tl`, and it
--- is a module containing a class.
---
--- ## Every call returns a future
---
--- There is no `sendSync` and no `blocking = true`, because blocking is
--- something done *to* a future rather than a mode a request is issued in:
--- `request:wait(2000)`. The number at the call site is the whole guard. A
--- reviewer who sees it asks why a frame is being held for two seconds, which
--- is a question a boolean never prompts.
---
--- The timeout should be mandatory and today it is not: `Future:wait` takes it
--- optionally and falls back to the source's `defaultWaitMs`. This client sets
--- that to its own request timeout, so a `wait()` with no argument is bounded
--- by the same number the transfer is bounded by rather than by an unrelated
--- default. Making it genuinely mandatory is a change to `Future`, not to this
--- module.
---
--- ## A response is not a failure
---
--- A 404 settles `"ready"` with `status` 404. `"failed"` means the transfer
--- did not complete: the name did not resolve, the connection was refused, TLS
--- did not verify, the deadline passed. The reasoning is `proc`'s exit code
--- reasoning: a status code is the answer to the request, and making it a
--- failure would propagate a 404 through `map` as though the transfer broke.
--- `Response:ok()` is the separate question about the answer.
---
--- `"cancelled"` is this process stopping the transfer, through
--- `Future:cancel` or `Client:close`.
---
--- ## A body is a `DataStream`, in both directions
---
--- `body` and `into` are the same type, and a `Response` carries one too, so
--- there is one answer to "where are the bytes" rather than a `body` beside a
--- `path` where exactly one is meaningful. A string is the shorthand each
--- direction wants: as a body it is the bytes, as a destination it is a path.
---
--- A destination is written as the transfer runs. The native buffer holds what
--- has arrived, the pump hands it to the destination and consumes it, and the
--- next pump starts from empty, so a body bound for a file is held for a frame
--- rather than for the length of the transfer. `maxBytes` still counts every
--- byte the body has ever been, drained or not.
---
--- A request body is not streamed, and the asymmetry is the callback rule
--- rather than an oversight. Writing a destination happens *between* calls
--- into libcurl, where Lua may do anything; feeding a body happens *inside*
--- one, through a read callback libcurl calls, and a Lua callback anywhere in
--- a pump makes the loop around it uncompilable -- which is exactly what
--- moving the response callbacks into `native/http.c` removed. So a body given
--- as a file or a handle is read at `send`, and libcurl copies it, and an
--- upload costs twice its size while it runs. The fix is a request buffer in
--- `native/http.c` beside the response one: a C read callback serving bytes
--- Lua tops up each pump, returning `CURL_READFUNC_PAUSE` rather than 0 when
--- it runs dry, since 0 is how a read callback says the body ended. That is a
--- pause protocol across two languages, and it is not worth writing before
--- something needs to upload something large.
---
--- Files go through `tecs.platform.filesystem` and so through the storage
--- seam a port replaces; a handle is the caller's own.
---
--- ## TLS verification is on, and awkward to turn off
---
--- Peer and host verification are set explicitly on every handle rather than
--- left to the library's default, and the protocol set is narrowed to `http`
--- and `https` for the request and for anything it redirects to.
---
--- There is no `insecure = true`. What exists is `insecureHosts`, an explicit
--- list of host names whose certificates are not checked, each of which logs a
--- warning when the client is built. No wildcard is accepted. A self-signed
--- development server is a real need and this serves it; a shipped game that
--- skips verification everywhere is a vulnerability, and a per-host list is
--- something a reviewer can read. Pinning a development CA through
--- `CURLOPT_CAINFO` is better still and is what to reach for when the host is
--- not on a developer's own machine.
---
--- ## DNS does not block
---
--- curl's multi interface is non-blocking for transfer but resolves names
--- synchronously unless the library was built with the threaded resolver or
--- c-ares, and a cold lookup is comfortably a dropped frame. Both builds this
--- tree uses resolve off the calling thread: the packaged libcurl is built with
--- `ENABLE_ARES` off, which is exactly the condition under which curl's own
--- CMake defaults `ENABLE_THREADED_RESOLVER` on, and its generated
--- `curl_config.h` carries `USE_RESOLV_THREADED`. A development preset resolves
--- libcurl from the system, and that library reports `AsynchDNS` too.
---
--- It is worth checking rather than assuming on a new target, and the check is
--- one call: `curl_version_info` sets `CURL_VERSION_ASYNCHDNS` in `features`
--- when the resolver is asynchronous. A build without it would need
--- `ENABLE_THREADED_RESOLVER` turned on, which costs a pthread per name being
--- resolved and nothing else, since curl already links a thread library.
---
--- ## Pumping is not re-entrant
---
--- `Future:wait` advances this client's source, and settling a future runs its
--- listeners. So a listener that calls `wait`, or that calls `pump` again,
--- would re-enter the multi handle from inside a pump of it. libcurl does not
--- define that, so this refuses it: a pump raises while one is already running
--- on the same client, and so does `close`. The refusal covers the settling
--- half of a pump as well as the performing half, because that is where
--- listeners run.
---
--- Sending from a listener is allowed. Nothing is settled while a call into
--- libcurl is in flight -- completions are collected first and the futures are
--- settled afterwards -- so `curl_multi_add_handle` from a listener lands on a
--- multi handle that is between calls rather than inside one.
---
--- ## Three timeouts, because two are not enough
---
--- `connectTimeoutMs` bounds getting a socket, `timeoutMs` bounds the whole
--- transfer, and `stallTimeoutMs` bounds going nowhere. The third is the one
--- that is easy to leave out and awkward to add later: a whole-transfer
--- deadline is the wrong bound for a download, because the number that stops a
--- hung connection is far smaller than the number a large body legitimately
--- needs, and a single option cannot be both. So a long `timeoutMs` beside a
--- short `stallTimeoutMs` is the combination `into` wants, and curl expresses
--- it as one byte per `CURLOPT_LOW_SPEED_TIME` seconds. It is off by default,
--- because a client that abandoned a request while a server was thinking would
--- be doing something nobody asked it to.
---
--- ## Connections are pooled and bounded
---
--- One multi handle is a connection pool: it reuses sockets across requests,
--- and `maxConnections` and `maxConnectionsPerHost` bound how many it opens.
--- Requests past the bound are held by libcurl rather than refused, so a game
--- that queues two hundred sprite fetches opens six sockets to that host and
--- not two hundred. The per-host default is the six HTTP/1.1 clients have
--- settled on.
---
--- That matters more here than it would elsewhere, because the pinned build is
--- HTTP/1.1 only: `USE_NGHTTP2` is off, so there is no multiplexing to make
--- one connection carry many requests. A development preset resolves libcurl
--- from the system and may well get HTTP/2, so this is one of the few places a
--- development and a packaged build differ in behaviour rather than only in
--- what they link. The bounds are what keep the slower of the two honest.
---
--- ## A body is never a live connection
---
--- A `Response` carries a `DataStream`, which is a stream in the sense that
--- matters -- the bytes did not all have to exist at once -- and not in the
--- one that would be a mistake here. It is only ever handed over settled: over
--- a string that is already complete, or over a file that has already been
--- written and closed. There is no shape in which holding a body holds a
--- socket, which is what a frame-driven client cannot afford and what an
--- `InputStream` handed back from a request would be.
---
--- ## What is deliberately not here
---
--- **No adapter seam.** A console's HTTP stack is not libcurl, and it belongs
--- beside audio and input behind `tecs.platform.adapter`. Substituting one
--- takes a `Backend` record with `send`, `pump`, `cancel` and `close` -- which
--- is what `Client` already is, minus its curl fields -- those records moving
--- to a `httpbackend` module so the seam names them, this module becoming the
--- argument checking and the future bookkeeping in front of it, and a guard in
--- `spec/seams_spec.lua` asserting a replacement is reached. `Request`,
--- `Response` and `DataStream` are already backend-neutral. What is not is
--- `insecureHosts`, which is two curl options today and would have to become
--- something the seam states rather than something a backend infers.
---
--- **No protocol version policy**, because there is nothing to choose between
--- while the pinned build is HTTP/1.1 only. Reach for `CURLOPT_HTTP_VERSION`
--- when that changes.

local ffi <const> = require("ffi")
local curl <const> = require("tecs.ffi.curl")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")
local Future <const> = require("tecs.Future")
local DataStream <const> = require("tecs.net.http.DataStream")
local clients <const> = require("tecs.net.http.clients")

loader.declare("http")

local C <const> = curl.C
local K <const> = curl.K
local H <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "http")
-- The name a developer filters on, so it is configuration rather than an
-- identifier and does not follow this module if the module moves.
local LOGGER <const> = log.get("tecs.http")

--- Milliseconds one blocking `wait` slice spends inside `curl_multi_poll`.
---
--- Longer than the asset worker's, because this source has nothing to do
--- between slices: `curl_multi_poll` returns as soon as a socket is readable,
--- so the number is only how long an idle wait sleeps for.
local SLICE_MS <const> = 50

--- Milliseconds a request is given before curl gives up on it.
local DEFAULT_TIMEOUT_MS <const> = 30000

--- Milliseconds the connection alone is given, inside that budget.
local DEFAULT_CONNECT_TIMEOUT_MS <const> = 10000

--- Redirects followed before curl reports too many.
local DEFAULT_MAX_REDIRECTS <const> = 5

--- Sockets one client keeps open across every host it talks to.
local DEFAULT_MAX_CONNECTIONS <const> = 16

--- Sockets one client keeps open to any one host, which is the number
--- HTTP/1.1 clients settled on and the number that matters on a build with no
--- HTTP/2 to multiplex over.
local DEFAULT_MAX_CONNECTIONS_PER_HOST <const> = 6

--- Response-header bytes retained across redirects and interim responses.
---
--- Headers are tiny beside bodies, but still come from an untrusted peer and
--- need a finite allocation bound of their own.
local MAX_HEADER_BYTES <const> = 256 * 1024

--- What a request and a redirect are both allowed to speak.
local PROTOCOLS <const> = "http,https"

local record client
    --- How a client behaves for every request it sends.
    record Options
        --- Sent as `User-Agent`. Name the game and its version; a server
        --- operator reading a log has nothing else to go on.
        userAgent: string
        --- Sent on every request, and overridden per request by the same name.
        headers: {string: string}
        --- Milliseconds a whole transfer is given. 30000 by default.
        timeoutMs: number
        --- Milliseconds the connection is given, inside that. 10000 by
        --- default.
        connectTimeoutMs: number
        --- Milliseconds a transfer may make no progress before it fails. 0,
        --- the default, never gives up on a quiet connection. curl measures
        --- this in whole seconds, so anything under 1000 rounds up to one.
        stallTimeoutMs: number
        --- Redirects followed. 5 by default; 0 follows none.
        maxRedirects: integer
        --- Sockets kept open across every host. 16 by default.
        maxConnections: integer
        --- Sockets kept open to any one host. 6 by default.
        maxConnectionsPerHost: integer
        --- Bytes a response body may reach before the transfer fails. 0, the
        --- default, is unbounded.
        maxBytes: integer
        --- Whether to offer the content encodings libcurl was built with.
        --- True by default, which is a zlib `Content-Encoding` here.
        compressed: boolean
        --- Host names whose certificates are not verified. Each logs a warning
        --- when the client is built. No wildcard, no port, no scheme.
        insecureHosts: {string}
        --- Proxy every request goes through, as a URL: `http://host:3128`, or
        --- `socks5h://host:1080` for a SOCKS one. Unset follows the
        --- environment's `http_proxy` and `https_proxy`, which is what a
        --- developer behind one expects; `""` ignores the environment and
        --- talks direct.
        proxy: string
        --- Hosts the proxy is not used for, comma separated, as
        --- `CURLOPT_NOPROXY` takes them: `"localhost,127.0.0.1,.internal"`.
        --- A single `*` disables the proxy for everything.
        noProxy: string
        --- Credentials for the proxy, as `user:password`.
        proxyCredentials: string
    end

    --- One request. Only `url` is required.
    record Request
        --- Absolute, with an `http` or `https` scheme.
        url: string
        --- "GET" by default. Any method the server accepts.
        method: string
        --- Merged over the client's, matched case-insensitively.
        headers: {string: string}
        --- What to send. A string is the body itself; a `DataStream` is a body
        --- from anywhere, including a file this reads at `send`.
        body: string | DataStream
        --- Where the body goes. A string is a path; a `DataStream` is any
        --- destination, and both are written as the bytes arrive.
        ---
        --- Left out, the body comes back as a stream over a string, which is
        --- right for a manifest and wrong for a patch.
        into: string | DataStream
        --- Milliseconds this transfer is given, overriding the client's.
        timeoutMs: number
        --- Milliseconds of no progress this transfer tolerates, overriding
        --- the client's. A long download wants a long `timeoutMs` and a short
        --- one of these.
        stallTimeoutMs: number
        --- Bytes this body may reach, overriding the client's.
        maxBytes: integer
    end

    --- What a completed transfer settles to, whatever the status code.
    record Response
        --- The HTTP status code, after any redirects.
        status: integer
        --- Response headers, with lower-cased names. A redirect's headers
        --- replace the ones before it, so this describes the final response.
        headers: {string: string}
        --- The body, wherever it went: a string when nothing asked for it
        --- somewhere else, the destination `into` named when something did.
        ---
        --- One field rather than a `body` and a `path` where exactly one is
        --- meaningful. `body:text()` is the string, `body.length` the bytes,
        --- `body.path` where it was written when that is what happened.
        body: DataStream
        --- The URL that actually answered, after any redirects.
        url: string

        --- Whether the status is a 2xx.
        ---
        --- A method rather than a state, for the same reason
        --- `proc.Result:succeeded` is one: the transfer completing and the
        --- server being happy are two questions, and only the first decides
        --- whether the future is `"ready"`.
        ok: function(self: Response): boolean
    end

    --- One transfer in flight. Internal; a caller holds the future instead.
    record Transfer
        id: integer
        owner: Client
        easy: loader.CPtr
        slist: loader.CPtr
        buffer: loader.CPtr
        future: Future<Response>
        response: Response
        body: string
        --- The in-memory body's length. A destination counts its own.
        bytes: integer
        maxBytes: integer
        --- Where the body is being written, when something asked for one.
        sink: DataStream
        url: string
        bufferError: integer
        --- Whether the destination has been closed, since a released transfer
        --- is settled afterwards and neither step owns the other.
        closed: boolean
        --- Why the transfer was stopped by something other than libcurl.
        failure: string
    end

    --- A pool of transfers over one libcurl multi handle.
    ---
    --- Also the `Future.Source` behind every future it hands out, which is why
    --- `poll`, `advance`, `sliceMs` and `defaultWaitMs` are on it.
    record Client
        --- Milliseconds one blocking `wait` slice spends.
        sliceMs: number
        --- Milliseconds a `wait` with no argument spends, which is this
        --- client's request timeout.
        defaultWaitMs: number

        _multi: loader.CPtr
        _options: Options
        _insecure: {string: boolean}
        _byFuture: {Future<Response>: Transfer}
        _pending: integer
        _pumping: boolean
        _running: loader.CArray
        _numfds: loader.CArray
        _remaining: loader.CArray
        _finished: {Transfer}
        _codes: {integer}
        --- Transfers with a destination, which is what the pump drains.
        _streaming: {Transfer}
        --- Out-parameter the drain reads a buffered length through, held here
        --- rather than allocated once a pump per transfer.
        _bodySize: loader.CArray

        --- Starts a transfer, and answers what it will settle to.
        ---
        --- Raises when the call itself is malformed: no request, no URL, a
        --- destination that is a string in memory rather than somewhere bytes
        --- can go. Everything about the request that only the network can
        --- judge settles the future instead, since a URL out of a manifest is
        --- data rather than a mistake in the program.
        send: function(self: Client, request: Request): Future<Response>

        --- Advances every transfer as far as it can go without waiting.
        ---
        --- **A game does not call this.** An application turns every open
        --- client once an iteration, through `tecs.net.http.pumpClients`. It
        --- is here for a headless tool with no application, and for a test that
        --- drives a transfer a turn at a time.
        ---
        --- Answers how many transfers settled, so a caller that wants to know
        --- whether anything happened does not have to ask each future.
        pump: function(self: Client): integer

        --- Transfers that have not settled.
        pending: function(self: Client): integer

        --- Stops one transfer, whatever state it is in.
        ---
        --- Also the source's cancel hook, which is what `Future:cancel` calls
        --- once the last watcher of a transfer has gone.
        cancel: function(self: Client, future: Future<any>)

        --- Stops every transfer and releases the multi handle.
        ---
        --- Each unsettled future settles `"cancelled"`. A closed client raises
        --- on `send` and answers 0 to `pump`, rather than being silently
        --- useless.
        ---
        --- Also what takes a client off the list a frame turns. Dropping the
        --- last reference to one does not: the list holds it, so a request
        --- nobody kept still lands, and a client nobody closes keeps its
        --- sockets for the life of the process.
        close: function(self: Client)

        --- `Future.Source`: `pump`, under the name a future looks for.
        poll: function(self: Client): integer
        --- `Future.Source`: blocks up to `ms` inside `curl_multi_poll`.
        advance: function(self: Client, ms: number): integer
    end

    --- Builds a client, which is what `tecs.net.http.newClient` answers with.
    ---
    --- @param options Read here rather than kept, so a field changed on the
    ---     table afterwards is not seen. Omitted takes every default, which is
    ---     a usable client with no `User-Agent` of its own; name the game and
    ---     its version, because a server operator reading a log has nothing
    ---     else to go on. Each entry of `insecureHosts` logs a warning here.
    --- @return An open client, already on the list an application turns once
    ---     an iteration, so a request sent through it settles without the
    ---     caller driving anything. It stays on that list until `close`, which
    ---     is what ends a client: dropping the last reference to one does not,
    ---     and its sockets then stay open for the life of the process.
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

-------------------------------------------------------------------------------
-- The global side of libcurl
-------------------------------------------------------------------------------

--- Every transfer in flight in this process, by the id its handles carry.
---
--- Global rather than per client because `CURLINFO_PRIVATE` carries only the
--- integer id. It identifies a completion without using a cdata handle as a
--- table key, where two pointer objects for one address would not compare as
--- the same Lua key.
local transfers <const>: {integer: Transfer} = {}
local nextId = 1

local started = false

--- Out-parameter for `CURLINFO_PRIVATE`, reused because it is read once per
--- completed transfer and never held.
local privateOut: loader.CArray = nil

--- The transfer an id belongs to, or nil once it has been released.
local function transferOf(id: integer): Transfer
    return transfers[id]
end

--- Turns a `void *` carrying a small integer back into that integer.
local function idOf(pointer: loader.CValue): integer
    return math.floor(tonumber(ffi.cast("intptr_t", pointer)) or 0) as integer
end

--- Brings libcurl up once.
local function ensure()
    if started then
        return
    end
    local code = C.curl_global_init(K.CURL_GLOBAL_DEFAULT)
    if (tonumber(code) or 0) ~= 0 then
        error(("tecs: curl_global_init failed: %s"):format(curl.errorText(code)), 3)
    end
    privateOut = loader.newArray("char *[1]")
    started = true
end

-------------------------------------------------------------------------------
-- Setting options
-------------------------------------------------------------------------------

-- `curl_easy_setopt` is variadic, so the FFI cannot tell what an option wants
-- and a bare Lua number arrives as eight bytes of floating point where a long
-- was expected. Every option therefore goes through one of these four, which
-- give the value a type before it reaches the call.
--
-- **They are also the only place a variadic call is made, and that is on
-- purpose**, because of what `jit.off` at the bottom of this section is for. A
-- variadic FFI call must not be compiled: see the note there. Keeping every
-- one of them behind a named helper is what makes that enforceable, so add
-- options through these rather than calling `curl_easy_setopt` directly.

local function setLong(easy: loader.CPtr, option: loader.CValue, value: number)
    C.curl_easy_setopt(easy, option, ffi.new("long", math.floor(value) as integer))
end

local function setOffset(easy: loader.CPtr, option: loader.CValue, value: number)
    C.curl_easy_setopt(easy, option, ffi.new("curl_off_t", math.floor(value) as integer))
end

local function setPointer(easy: loader.CPtr, option: loader.CValue, value: any)
    C.curl_easy_setopt(easy, option, value)
end

--- `curl_multi_setopt` is variadic too, and wants the same care.
local function setMultiLong(multi: loader.CPtr, option: loader.CValue, value: number)
    C.curl_multi_setopt(multi, option, ffi.new("long", math.floor(value) as integer))
end

--- Reads one variadic `curl_easy_getinfo`, whatever the out parameter is.
local function getInto(easy: loader.CPtr, info: loader.CValue, out: loader.CArray)
    C.curl_easy_getinfo(easy, info, out)
end

-- These variadic calls must not be JIT-compiled.
--
-- What was measured, on macOS arm64: `CURLOPT_PRIVATE` set to 59 reads back
-- through `CURLINFO_PRIVATE` as 0x1_0000003b. The call reports success and the
-- value is wrong, so the effect was a transfer libcurl had completed whose
-- future was never settled, because the tag identifying it matched nothing.
-- The corruption appears only once the loop containing the call is compiled;
-- `luajit -joff` never reproduces it, and marking these functions
-- uncompilable ends it.
--
-- The likely mechanism is the Darwin arm64 variadic convention, which passes
-- variadic arguments on the stack where ordinary ones go in registers. That is
-- offered as the explanation rather than asserted as one: `tecs.log` makes a
-- variadic call too, `SDL_LogMessage` with a format and one string, and four
-- hundred of those across the same threshold come out intact. So the rule
-- worth following is the measured one -- do not let a variadic FFI call be
-- compiled -- rather than a theory about which arguments survive.
--
-- What makes it worth this much comment is what else goes through the same
-- door. `CURLOPT_SSL_VERIFYPEER` is set here, and a corrupted argument to that
-- is verification silently off.
--
-- It is also invisible until a program has been running for a while: a trace
-- forms after the loop containing the call has gone round fifty-six times, so
-- a test that sends one request passes and a game sending one a second breaks
-- a minute in. `spec/http_spec.lua` sends a hundred and twenty for that
-- reason.
local jit <const> = (_G as {string: any}).jit as {string: function(any)}
local function refuseCompilation(...: any)
    if jit == nil or jit.off == nil then
        return
    end
    local functions <const> = {...}
    for index = 1, select("#", ...) do
        jit.off(functions[index])
    end
end

refuseCompilation(setLong, setOffset, setPointer, setMultiLong, getInto)

-------------------------------------------------------------------------------
-- Reading a URL
-------------------------------------------------------------------------------

--- The lower-cased scheme of an absolute URL, or nil when it has none.
local function schemeOf(url: string): string
    local scheme = url:match("^(%a[%w+.%-]*)://")
    if scheme == nil then
        return nil
    end
    return scheme:lower()
end

--- The lower-cased host of an absolute URL, without userinfo or port.
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
    if host == nil or host == "" then
        return nil
    end
    return host:lower()
end

-------------------------------------------------------------------------------
-- Finishing a transfer
-------------------------------------------------------------------------------

--- Reads what only the easy handle knows, before the handle is released.
local function readResult(transfer: Transfer)
    local status = loader.newArray("long[1]")
    getInto(transfer.easy, C.CURLINFO_RESPONSE_CODE, status)
    transfer.response.status = math.floor(tonumber(status[0]) or 0) as integer

    local effective = loader.newArray("char *[1]")
    getInto(transfer.easy, C.CURLINFO_EFFECTIVE_URL, effective)
    if effective[0] ~= nil then
        transfer.response.url = loader.toString(effective[0] as loader.CValue)
    else
        transfer.response.url = transfer.url
    end

    local size = loader.newArray("uint64_t[1]")
    if transfer.sink == nil then
        local body = H.tecsHttpResponseBody(transfer.buffer, size)
        transfer.bytes = math.floor(tonumber(size[0]) or 0) as integer
        transfer.body = loader.toBytes(body, transfer.bytes)
    end

    local raw = H.tecsHttpResponseHeaders(transfer.buffer, size)
    local headerBytes <const> = math.floor(tonumber(size[0]) or 0) as integer
    local rawHeaders <const> = loader.toBytes(raw, headerBytes)
    local headers: {string: string} = {}
    -- The native callback retains exactly what curl provides. Parse it only
    -- after completion, resetting at every status line so redirects and
    -- interim responses cannot leak headers into the final response.
    for line in (rawHeaders .. "\n"):gmatch("(.-)\r?\n") do
        if line:sub(1, 5) == "HTTP/" then
            headers = {}
        else
            local name, value = line:match("^([^:]+):%s*(.-)%s*$")
            if name ~= nil then
                headers[name:lower()] = value
            end
        end
    end
    transfer.response.headers = headers
    transfer.bufferError = math.floor(tonumber(H.tecsHttpResponseBufferError(transfer.buffer)) or 0) as integer
end

--- Writes whatever has arrived to a transfer's destination, and drops it.
---
--- The counterpart of buffering the body in C. The native callback appends and
--- knows nothing about where the bytes are going; this runs from the pump,
--- between calls into libcurl, and hands one pump's worth of arrival to the
--- destination. So a body bound for a file is held for a frame rather than for
--- the length of the transfer, and there is still no Lua callback anywhere
--- libcurl can call: `turn` stays compilable.
---
--- What the consume answers is discarded because it is always zero: this takes
--- everything it was shown.
local function drain(transfer: Transfer): boolean
    local sink <const> = transfer.sink
    if sink == nil or transfer.buffer == nil or transfer.failure ~= nil then
        return true
    end

    local size <const> = transfer.owner._bodySize
    local body <const> = H.tecsHttpResponseBody(transfer.buffer, size)
    local length <const> = math.floor(tonumber(size[0]) or 0) as integer
    if length == 0 then
        return true
    end

    local ok <const>, failure = sink:_write(loader.toBytes(body, length))
    H.tecsHttpResponseBodyConsume(transfer.buffer, length)
    if not ok then
        transfer.failure = failure or "the body could not be written"
        return false
    end
    return true
end

--- Closes a transfer's destination, whatever the outcome.
---
--- A failed transfer has the same handle open as a successful one, and a
--- cancelled one too, so this runs on every path out. What closing said
--- becomes the transfer's failure when nothing else already is one: that call
--- is where a full disk is reported.
local function closeSink(transfer: Transfer)
    if transfer.closed then
        return
    end
    transfer.closed = true

    local sink <const> = transfer.sink
    if sink == nil then
        return
    end
    -- The last bytes, which arrived after the pump that drove the final
    -- perform had already drained.
    drain(transfer)
    local ok <const>, failure = sink:_finish()
    if not ok and transfer.failure == nil then
        transfer.failure = failure or "the body could not be written"
    end
end

--- Takes a transfer off its client and frees everything libcurl gave it.
---
--- Separate from settling, and always before it: a listener may send another
--- request, and it should land on a multi handle this transfer has already
--- left.
local function release(transfer: Transfer)
    if transfer.easy == nil then
        return
    end
    local owner = transfer.owner
    transfers[transfer.id] = nil
    if owner._byFuture[transfer.future] ~= nil then
        owner._byFuture[transfer.future] = nil
        owner._pending = owner._pending - 1
    end
    if owner._multi ~= nil then
        C.curl_multi_remove_handle(owner._multi, transfer.easy)
    end
    C.curl_easy_cleanup(transfer.easy)
    transfer.easy = nil
    if transfer.slist ~= nil then
        C.curl_slist_free_all(transfer.slist)
        transfer.slist = nil
    end
    if transfer.sink ~= nil then
        local streaming <const> = owner._streaming
        for index = 1, #streaming do
            if streaming[index] == transfer then
                table.remove(streaming, index)
                break
            end
        end
    end
    -- After the handle and before the buffer: the last bytes are still in
    -- there, and until `curl_easy_cleanup` returned libcurl was entitled to
    -- append more.
    closeSink(transfer)
    if transfer.buffer ~= nil then
        H.tecsHttpResponseBufferDestroy(transfer.buffer)
        transfer.buffer = nil
    end
end

--- Settles a released transfer's future.
local function settle(transfer: Transfer, code: integer)
    local future = transfer.future
    if code ~= 0 then
        local bodyLimit <const> = tonumber(H.TECS_HTTP_BUFFER_BODY_LIMIT) or 1
        local headerLimit <const> = tonumber(H.TECS_HTTP_BUFFER_HEADER_LIMIT) or 2
        local outOfMemory <const> = tonumber(H.TECS_HTTP_BUFFER_OOM) or 3
        local fileTooLarge <const> = tonumber(C.CURLE_FILESIZE_EXCEEDED) or -1
        if transfer.bufferError == bodyLimit or code == fileTooLarge then
            future:fail(("tecs: %s exceeded %d bytes"):format(transfer.url, transfer.maxBytes))
        elseif transfer.bufferError == headerLimit then
            future:fail(("tecs: %s response headers exceeded %d bytes"):format(transfer.url, MAX_HEADER_BYTES))
        elseif transfer.bufferError == outOfMemory then
            future:fail(("tecs: %s: response buffering ran out of memory"):format(transfer.url))
        elseif transfer.failure ~= nil then
            future:fail(("tecs: %s: %s"):format(transfer.url, transfer.failure))
        else
            local reason <const> = curl.errorText(ffi.cast("CURLcode", code) as loader.CValue)
            future:fail(("tecs: %s: %s"):format(transfer.url, reason))
        end
        return
    end

    -- Closing the destination is where a full disk is reported, so a transfer
    -- libcurl was happy with can still have failed to land.
    if transfer.failure ~= nil then
        future:fail(("tecs: %s: %s"):format(transfer.url, transfer.failure))
        return
    end

    local response = transfer.response
    if transfer.sink ~= nil then
        response.body = transfer.sink
    else
        response.body = DataStream.ofString(transfer.body, response.headers["content-type"])
    end
    future:complete(response)
end

-------------------------------------------------------------------------------
-- Pumping
-------------------------------------------------------------------------------

--- Takes every completed transfer off the multi handle and settles it.
---
--- Two loops rather than one. libcurl is called in the first and futures are
--- settled in the second, so nothing a listener does reaches a multi handle
--- that is part way through a call.
local function collect(self: Client): integer
    local finished = self._finished
    local codes = self._codes
    local count = 0

    while true do
        local message = C.curl_multi_info_read(self._multi, self._remaining)
        if message == nil then
            break
        end
        -- Read out of the message before anything else: releasing a handle
        -- invalidates it.
        if (tonumber(message.msg) or 0) == (tonumber(C.CURLMSG_DONE) or 0) then
            local easy = message.easy_handle as loader.CPtr
            local code = math.floor(tonumber(message.data.result) or 0) as integer
            getInto(easy, C.CURLINFO_PRIVATE, privateOut)
            local transfer = transferOf(idOf(privateOut[0] as loader.CValue))
            if transfer ~= nil then
                readResult(transfer)
                release(transfer)
                count = count + 1
                finished[count] = transfer
                codes[count] = code
            end
        end
    end

    for index = 1, count do
        settle(finished[index], codes[index])
        finished[index] = nil
    end
    return count
end

--- One turn of the multi handle, optionally waiting for something to happen.
local function turn(self: Client, waitMs: number): integer
    if waitMs > 0 then
        C.curl_multi_poll(self._multi, nil, 0, math.floor(waitMs), self._numfds)
    end
    local code = C.curl_multi_perform(self._multi, self._running)
    if (tonumber(code) or 0) ~= 0 then
        LOGGER:error("curl_multi_perform failed: %s", curl.multiErrorText(code))
    end
    -- Between the perform and the drain of completions, which is the one point
    -- in a pump where libcurl is not inside a call and a transfer that has
    -- finished has not been released yet. Empty for a client nothing is
    -- streaming, which is almost every client.
    local streaming <const> = self._streaming
    for index = 1, #streaming do
        drain(streaming[index])
    end
    return collect(self)
end

--- `turn`, with the re-entrancy refusal around it.
local function drive(self: Client, waitMs: number, level: integer): integer
    if self._pumping then
        error(
            "tecs: this http client is already pumping; a listener cannot wait on or pump the client calling it", level
        )
    end
    if self._multi == nil then
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

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------

--- Builds the header list for one request, or nil when there is nothing to
--- send. Request headers win over the client's, matched without case.
local function buildHeaders(self: Client, request: Request, source: DataStream): loader.CPtr
    local merged: {string: string} = nil

    local defaults = self._options.headers
    if defaults ~= nil then
        merged = {}
        for name, value in pairs(defaults) do
            merged[name:lower()] = value
        end
    end

    local own = request.headers
    if own ~= nil then
        merged = merged or {}
        for name, value in pairs(own) do
            merged[name:lower()] = value
        end
    end

    -- What the body says it is, and only when nothing said otherwise: a stream
    -- built from a file knows less about the request than the caller does.
    if source ~= nil and source.contentType ~= nil then
        merged = merged or {}
        if merged["content-type"] == nil then
            merged["content-type"] = source.contentType
        end
    end

    if merged == nil then
        return nil
    end

    local slist: loader.CPtr = nil
    for name, value in pairs(merged) do
        slist = C.curl_slist_append(slist, ("%s: %s"):format(name, value)) as loader.CPtr
    end
    return slist
end

--- The stream a `body` or an `into` means, whichever spelling was used.
---
--- A string is the body itself in one direction and a path in the other, which
--- is the only place the two differ: a request says what to send, and a
--- destination says where to put what comes back.
local function streamOf(given: string | DataStream, sending: boolean, what: string): DataStream
    if given == nil then
        return nil
    end
    if given is string then
        if sending then
            return DataStream.ofString(given)
        end
        return DataStream.ofFile(given)
    end
    if not DataStream.is(given) then
        error(("tecs: %s is not a string or a DataStream"):format(what), 3)
    end
    return given
end

function Client:send(request: Request): Future<Response>
    if self._multi == nil then
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

    local easy = C.curl_easy_init() as loader.CPtr
    if easy == nil then
        return Future.failed("tecs: curl_easy_init failed") as Future<Response>
    end

    local options <const> = self._options
    local maxBytes <const> = request.maxBytes or options.maxBytes
    local buffer = H.tecsHttpResponseBufferCreate(maxBytes, MAX_HEADER_BYTES) as loader.CPtr
    if buffer == nil then
        C.curl_easy_cleanup(easy)
        return Future.failed("tecs: cannot allocate an http response buffer") as Future<Response>
    end
    local id <const> = nextId
    nextId = nextId + 1

    local future <const> = Future.pending(self as Future.Source) as Future<Response>
    local transfer <const>: Transfer = {
        id = id,
        owner = self,
        easy = easy,
        slist = nil,
        buffer = buffer,
        future = future,
        response = setmetatable({status = 0, headers = {}} as Response, ResponseMT),
        body = nil,
        bytes = 0,
        maxBytes = maxBytes,
        sink = sink,
        url = url,
        bufferError = 0,
        closed = false,
    }

    -- Opened before the handle is armed, so a destination that cannot be
    -- written is a failed future rather than a transfer that starts and dies
    -- at the first byte.
    if sink ~= nil then
        local ok <const>, failure = sink:_beginWrite()
        if not ok then
            H.tecsHttpResponseBufferDestroy(buffer)
            C.curl_easy_cleanup(easy)
            return Future.failed(failure) as Future<Response>
        end
    end

    setPointer(easy, C.CURLOPT_URL, url)
    -- The id, not the transfer: a Lua table cannot be a `void *`, and two
    -- cdata pointers to one address are two different Lua table keys, so
    -- keying anything by the handle itself would silently never match.
    local tag <const> = ffi.cast("void *", id)
    setPointer(easy, C.CURLOPT_PRIVATE, tag)
    setPointer(easy, C.CURLOPT_WRITEFUNCTION, H.tecsHttpWriteCallback)
    setPointer(easy, C.CURLOPT_WRITEDATA, buffer)
    setPointer(easy, C.CURLOPT_HEADERFUNCTION, H.tecsHttpHeaderCallback)
    setPointer(easy, C.CURLOPT_HEADERDATA, buffer)

    -- Signals are how the synchronous resolver implements its timeout, and
    -- they are not usable from a library inside a game. curl documents this as
    -- required for the multi interface on a threaded program.
    setLong(easy, C.CURLOPT_NOSIGNAL, 1)
    setPointer(easy, C.CURLOPT_PROTOCOLS_STR, PROTOCOLS)
    setPointer(easy, C.CURLOPT_REDIR_PROTOCOLS_STR, PROTOCOLS)
    setLong(easy, C.CURLOPT_TIMEOUT_MS, request.timeoutMs or options.timeoutMs)
    setLong(easy, C.CURLOPT_CONNECTTIMEOUT_MS, options.connectTimeoutMs)
    local stallMs <const> = request.stallTimeoutMs or options.stallTimeoutMs
    if stallMs > 0 then
        -- One byte a second is "any progress at all", and the window is whole
        -- seconds, so anything under a second rounds up rather than to zero,
        -- which would read as off.
        setLong(easy, C.CURLOPT_LOW_SPEED_LIMIT, 1)
        setLong(easy, C.CURLOPT_LOW_SPEED_TIME, math.max(1, math.floor(stallMs / 1000)))
    end
    if options.maxRedirects > 0 then
        setLong(easy, C.CURLOPT_FOLLOWLOCATION, 1)
        setLong(easy, C.CURLOPT_MAXREDIRS, options.maxRedirects)
    end
    if transfer.maxBytes > 0 then
        -- The declared length, refused before a byte of it arrives. The write
        -- buffer is the other half, for a server that declares nothing.
        setOffset(easy, C.CURLOPT_MAXFILESIZE_LARGE, transfer.maxBytes)
    end
    if options.userAgent ~= nil then
        setPointer(easy, C.CURLOPT_USERAGENT, options.userAgent)
    end
    if options.compressed then
        setPointer(easy, C.CURLOPT_ACCEPT_ENCODING, "")
    end

    -- Unset is not the same as empty. Nothing here means libcurl reads
    -- `http_proxy` and `https_proxy` as it always has, and `""` is a stated
    -- decision to ignore them, which is the only way a game can talk direct on
    -- a machine that has them set.
    if options.proxy ~= nil then
        setPointer(easy, C.CURLOPT_PROXY, options.proxy)
    end
    if options.noProxy ~= nil then
        setPointer(easy, C.CURLOPT_NOPROXY, options.noProxy)
    end
    if options.proxyCredentials ~= nil then
        setPointer(easy, C.CURLOPT_PROXYUSERPWD, options.proxyCredentials)
    end

    -- Set every time rather than left to the library's default, so this does
    -- not depend on how the libcurl that answered the load was built.
    setLong(easy, C.CURLOPT_SSL_VERIFYPEER, 1)
    setLong(easy, C.CURLOPT_SSL_VERIFYHOST, 2)
    local host <const> = hostOf(url)
    if host ~= nil and self._insecure[host] then
        setLong(easy, C.CURLOPT_SSL_VERIFYPEER, 0)
        setLong(easy, C.CURLOPT_SSL_VERIFYHOST, 0)
    end

    local slist <const> = buildHeaders(self, request, source)
    if slist ~= nil then
        transfer.slist = slist
        setPointer(easy, C.CURLOPT_HTTPHEADER, slist)
    end

    local method <const> = (request.method or "GET"):upper()
    local carries <const> = method == "POST" or method == "PUT" or method == "PATCH"

    -- A method that carries a body always gets one, even an empty one: with
    -- `CURLOPT_POST` set and no fields, libcurl reads the body from a read
    -- callback, and the default read callback is standard input.
    if source ~= nil or carries then
        local payload: any = ""
        local length = 0
        if source ~= nil then
            -- Read here rather than as libcurl asks for it. Asking would mean
            -- a read callback, and the only kind this module can install from
            -- Lua is one libcurl calls from inside `curl_multi_perform`, which
            -- is exactly what moving the response callbacks into C got rid of:
            -- a Lua callback anywhere in a pump makes the loop around it
            -- uncompilable. The bound is the body, and libcurl copies it
            -- again, so an upload costs twice its size until it completes.
            -- Streaming one belongs in `native/http.c` beside the buffering,
            -- and is written up in this module's notes.
            local bytes <const>, failure = source:text()
            if bytes == nil then
                H.tecsHttpResponseBufferDestroy(buffer)
                C.curl_easy_cleanup(easy)
                if sink ~= nil then
                    sink:_finish()
                end
                return Future.failed(failure or "tecs: the request body could not be read") as Future<Response>
            end
            payload = bytes
            length = #bytes
        end
        -- Size before fields. `CURLOPT_COPYPOSTFIELDS` copies what the size
        -- already set says, and with no size it measures a binary body as a C
        -- string.
        setOffset(easy, C.CURLOPT_POSTFIELDSIZE_LARGE, length)
        setPointer(easy, C.CURLOPT_COPYPOSTFIELDS, payload)
    end
    if method == "HEAD" then
        setLong(easy, C.CURLOPT_NOBODY, 1)
    elseif method ~= "GET" or source ~= nil then
        -- The verb, stated rather than inferred from which body option was
        -- set. A body alone would make this a POST whatever it says.
        setPointer(easy, C.CURLOPT_CUSTOMREQUEST, method)
    end

    transfers[id] = transfer
    self._byFuture[future] = transfer
    self._pending = self._pending + 1
    -- Last, after every path that gives up before the transfer exists: a pump
    -- walks this list and everything on it has a buffer to drain.
    if sink ~= nil then
        local streaming <const> = self._streaming
        streaming[#streaming + 1] = transfer
    end

    local code = C.curl_multi_add_handle(self._multi, easy)
    if (tonumber(code) or 0) ~= 0 then
        local message = curl.multiErrorText(code)
        release(transfer)
        future:fail(("tecs: cannot start %s: %s"):format(url, message))
    end
    return future
end

-------------------------------------------------------------------------------
-- Stopping
-------------------------------------------------------------------------------

function Client:cancel(future: Future<any>)
    local transfer = self._byFuture[future as Future<Response>]
    if transfer == nil then
        return
    end
    release(transfer)
    -- A no-op when this is the source hook, since `Future:cancel` has already
    -- written the state; the settlement is for a caller who called this
    -- directly with a future still pending.
    transfer.future:abandon("cancelled")
end

function Client:close()
    if self._multi == nil then
        return
    end
    if self._pumping then
        error("tecs: cannot close an http client from inside its own pump", 2)
    end
    -- Off the frame's list first: nothing below can settle a future whose
    -- listener would find this client still there.
    clients.remove(self as clients.Pumpable)

    -- Collected first: releasing a transfer removes it from the table being
    -- walked, and settling one runs listeners that may hold others.
    local live: {Transfer} = {}
    local count = 0
    for _, transfer in pairs(self._byFuture) do
        count = count + 1
        live[count] = transfer
    end
    for index = 1, count do
        local transfer = live[index]
        release(transfer)
        transfer.future:abandon("the http client was closed")
    end

    C.curl_multi_cleanup(self._multi)
    self._multi = nil
    self._pending = 0
end

-------------------------------------------------------------------------------
-- Building one
-------------------------------------------------------------------------------

--- Reads `insecureHosts` into a set, refusing anything that is not one host.
local function insecureSet(hosts: {string}): {string: boolean}
    local set: {string: boolean} = {}
    if hosts == nil then
        return set
    end
    for index = 1, #hosts do
        local host = hosts[index]
        if type(host) ~= "string" or host == "" or host:find("[^%w%.%-_]") ~= nil then
            error(("tecs: insecureHosts[%d] is not a plain host name"):format(index), 3)
        end
        local lowered = host:lower()
        set[lowered] = true
        LOGGER:warn("TLS verification is disabled for %s; this must not reach a shipped build", lowered)
    end
    return set
end

function client.newClient(options?: Options): Client
    ensure()

    local given <const> = options or {} as Options
    local multi <const> = C.curl_multi_init() as loader.CPtr
    if multi == nil then
        error("tecs: curl_multi_init failed", 3)
    end

    local timeoutMs <const> = given.timeoutMs or DEFAULT_TIMEOUT_MS
    local settings <const>: Options = {
        userAgent = given.userAgent,
        headers = given.headers,
        timeoutMs = timeoutMs,
        connectTimeoutMs = given.connectTimeoutMs or DEFAULT_CONNECT_TIMEOUT_MS,
        stallTimeoutMs = given.stallTimeoutMs or 0,
        maxRedirects = given.maxRedirects or DEFAULT_MAX_REDIRECTS,
        maxConnections = given.maxConnections or DEFAULT_MAX_CONNECTIONS,
        maxConnectionsPerHost = given.maxConnectionsPerHost or DEFAULT_MAX_CONNECTIONS_PER_HOST,
        maxBytes = given.maxBytes or 0,
        compressed = given.compressed ~= false,
        insecureHosts = given.insecureHosts,
    }

    -- The multi handle is the pool, so the bounds go on it rather than on each
    -- transfer. Over the bound libcurl holds a request back instead of failing
    -- it, which is what makes queueing many of them safe.
    setMultiLong(multi, C.CURLMOPT_MAX_TOTAL_CONNECTIONS, settings.maxConnections)
    setMultiLong(multi, C.CURLMOPT_MAX_HOST_CONNECTIONS, settings.maxConnectionsPerHost)
    -- How many idle sockets are kept for reuse. Matched to the total, so a
    -- connection this pool is allowed to open is one it is allowed to keep.
    setMultiLong(multi, C.CURLMOPT_MAXCONNECTS, settings.maxConnections)

    local self <const> = setmetatable({} as Client, ClientMT)
    self.sliceMs = SLICE_MS
    -- A `wait` with no argument is bounded by what the transfer is bounded by,
    -- rather than by a number picked somewhere else.
    self.defaultWaitMs = timeoutMs
    self._multi = multi
    self._options = settings
    self._insecure = insecureSet(given.insecureHosts)
    self._byFuture = {}
    self._pending = 0
    self._pumping = false
    self._running = loader.newArray("int[1]")
    self._numfds = loader.newArray("int[1]")
    self._remaining = loader.newArray("int[1]")
    self._finished = {}
    self._codes = {}
    self._streaming = {}
    self._bodySize = loader.newArray("uint64_t[1]")
    -- On the list the frame turns, from here until `close`. A game that builds
    -- a client and sends a request calls nothing else.
    clients.add(self as clients.Pumpable)
    return self
end

return client
