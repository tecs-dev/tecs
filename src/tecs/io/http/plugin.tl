--[=[
A request as an entity, for a world that would rather spawn one.

`Client:send` suspends the calling system, which is the right shape for one
ordered request and the wrong one for a game that wants the request itself to
be a thing in the world: something the debug server can list, something a
system can react to, something that dies when the entity that asked for it
does.

    world:addPlugin(tecs.io.http.plugin.install)

    world:spawn(http.plugin.Request, {
        url = tecs.io.URI.new("https://example.com/scores"),
    })

Some frames later the entity carries a `Response` instead, and a system
with `include = {http.Response}` sees it. The request is inspectable the whole
way through because it is a component.

## Boundaries

It does not pump. The application already turns every open client once an
iteration, this plugin's included, so a system that pumped would be a
second turn of the same handle for nothing. What its system does is send
what has been spawned and settle what has answered.

## Per-world client

One per world, built with the options given to `plugin.install` or with
defaults, and kept in the world's resources so a game can reach it:
`plugin.clientOf(world)`. A game that wants two clients, one for a chatty
API and one for downloads, builds the second itself; nothing about this
plugin is in the way of `tecs.io.http.newClient` beside it.

Despawning the world does not close the client. `plugin.close(world)` does,
and a program that ends is a process that ends, which is the same answer
every other pooled resource here gives.

## Snapshots

A save carries the `Request` and not the `Pending` marker, so a request that
had not answered yet is sent again on load rather than restored as a wait on
a transfer that ended with the world that started it. The `Response` a game
eventually reads is the reissued request's.

The exception is a `Request` whose `body` is a
`tecs.io.newHandleStream`. The caller owns that live handle, and neither
snapshot format can reconstruct its ownership or position, so saving the world
raises. Use `tecs.io.newFileStream` when a request must survive a snapshot.

A successful `Response` owns a live one-shot body. Consume it and replace it
with replayable storage before taking a snapshot that includes the response.
An in-flight native stream and its transport backpressure are runtime state,
not save data. Despawning the response entity closes an unread body.

Loading stops the transfers that were open before it. A load replaces the
world in place and despawns nothing, so the entities that asked are gone
without anything hearing about it, and a transfer nobody is left to receive
is work for no one.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local storekeys <const> = require("tecs.internal.storekeys")
local client <const> = require("tecs.io.http.client")
local URI <const> = require("tecs.io.URI")
local stream <const> = require("tecs.io.stream")
local type iotypes = require("tecs.io.types")

local type World = types.World
local type Component = ecs.Component
local type Options = client.Options
local type Client = client.Client
local type Stream = iotypes.Stream
local type ReadableStream = iotypes.ReadableStream

local record plugin
    --- What a game spawns to make a request. The fields of a `Request`,
    --- because there is no second vocabulary for the same thing.
    record Request is Component
        --- Caller-writable. Sets an absolute HTTP or HTTPS
        --- [`URI`](tealdoc:tecs.io.URI).
        url: URI
        --- Caller-writable. Sets the method. Defaults to `"GET"`.
        method: string
        --- Caller-writable. Sets headers merged over the client's defaults
        --- without regard to case. A `Content-Length` must contain decimal
        --- digits and must match a body whose length is known.
        headers: {string: string}
        --- Caller-writable. Sets what to send. A snapshot rejects a
        --- `tecs.io.newHandleStream` here because its live handle cannot
        --- be reconstructed.
        body: string | ReadableStream
        --- Caller-writable. Sets milliseconds for this transfer, overriding
        --- the client's value.
        timeoutMs: number
        --- Caller-writable. Sets tolerated milliseconds without progress,
        --- overriding the client's value.
        stallTimeoutMs: number
        --- Caller-writable. Sets the body byte limit, overriding the client's
        --- value.
        maxBytes: integer
    end

    --- What replaces a `Request` once the transfer settles.
    ---
    --- Present whatever happened, because "the request finished" is the event
    --- a system waits for and a failure is one of the ways it can finish.
    --- `error` is what says which.
    record Response is Component
        --- Engine-owned. Reports the HTTP status code, or zero when the
        --- transfer never received one.
        status: integer
        --- Engine-owned. Reports response headers with lower-cased names, in
        --- the joined form `Response.headers` uses. A component is one value
        --- per name, so a repeated `set-cookie` keeps only its first value
        --- here; a system that needs every cookie sends its request through a
        --- client and reads `Response:getAll`.
        headers: {string: string}
        --- Engine-owned. Provides a one-shot progressive response body.
        --- Despawning this entity closes a body that remains unread.
        body: Stream
        --- Engine-owned. Reports the URI that actually answered, or nil when
        --- the request failed before it supplied a valid URI.
        url: URI
        --- Engine-owned. Reports why the transfer did not complete, or nil
        --- when it did. A 404 is not one of these: it is a `status` of 404 and
        --- no error.
        error: string
    end

    --- On an entity whose request is in flight. Internal, and the reason a
    --- request is sent once rather than every frame.
    ---
    --- A marker, while the callback and transfer state remain in the plugin.
    --- It is transient because runtime transport state cannot be saved. A save
    --- taken mid-request keeps the `Request`, drops this marker, and sends the
    --- request again after loading.
    record Pending is Component
    end

    --- Installs the plugin: `world:addPlugin(tecs.io.http.plugin.install)`.
    ---
    --- Takes options because the plugin builds the world's client, and a game
    --- that wants a `userAgent` on it has nowhere else to say so:
    --- `world:addPlugin(function(w) http.plugin.install(w, {...}) end)`.
    install: function(world: World, options?: Options)
    --- The world's client, or nil when the plugin is not installed.
    clientOf: function(world: World): Client
    --- Closes the world's client and forgets it.
    close: function(world: World)
end

local type Request = plugin.Request
local type Response = plugin.Response

local function copyHeaders(headers: {string: string}): {string: string}
    if headers == nil then
        return nil
    end
    local copied: {string: string} = {}
    for name, value in pairs(headers) do
        copied[name] = value
    end
    return copied
end

local function serializeRequest(request: Request): {string: any}
    local data: {string: any} = {}
    for key, value in pairs(request as {string: any}) do
        if type(key) == "string" and not key:match("^component") and key ~= "storage" then
            local valueType <const> = type(value)
            if key == "headers" and valueType == "table" then
                data.headers = copyHeaders(value as {string: string})
            elseif key == "url" and URI.isURI(value) then
                data.url = (value as URI):toString()
            elseif key == "body" and valueType == "table" then
                data[key] = stream._snapshot(value as Stream, ("tecs.http.Request %s"):format(key))
            elseif valueType == "number" or valueType == "string" or valueType == "boolean" then
                data[key] = value
            end
        end
    end
    return data
end

local function deserializeRequest(_world: World, data: {string: any}): Request
    local restored: {string: any} = {}
    for key, value in pairs(data) do
        if key == "headers" and type(value) == "table" then
            restored.headers = copyHeaders(value as {string: string})
        elseif key == "url" and type(value) == "string" then
            local parsed <const>, reason = URI.new(value as string)
            if parsed == nil then
                error(("tecs: cannot restore tecs.http.Request URL: %s"):format(reason), 0)
            end
            restored.url = parsed
        elseif key == "body" and type(value) == "table" then
            restored[key] = stream._restore(value as {string: any}, ("tecs.http.Request %s"):format(key))
        else
            restored[key] = value
        end
    end
    return plugin.Request(restored)
end

local function serializeResponse(response: Response): {string: any}
    local data: {string: any} = {
        status = response.status,
        headers = copyHeaders(response.headers),
        url = response.url ~= nil and response.url:toString() or nil,
        error = response.error,
    }
    if response.body ~= nil then
        data.body = stream._snapshot(response.body, "tecs.http.Response body")
    end
    return data
end

local function deserializeResponse(_world: World, data: {string: any}): Response
    local restored: {string: any} = {}
    for key, value in pairs(data) do
        if key == "headers" and type(value) == "table" then
            restored.headers = copyHeaders(value as {string: string})
        elseif key == "url" and type(value) == "string" then
            local parsed <const>, reason = URI.new(value as string)
            if parsed == nil then
                error(("tecs: cannot restore tecs.http.Response URL: %s"):format(reason), 0)
            end
            restored.url = parsed
        elseif key == "body" and type(value) == "table" then
            restored.body = stream._restore(value as {string: any}, "tecs.http.Response body")
        else
            restored[key] = value
        end
    end
    if restored.body == nil then
        restored.body = stream.newEmptyStream()
    end
    return plugin.Response(restored)
end

-- The three names below, the resource key under them and the system names
-- further down are all spelled `tecs.http.*` and stay that way now that the
-- module is `tecs.io.http`. A snapshot names a component by string and an
-- agent selects a system by one, so they are a save format and a tooling
-- surface rather than module paths. See `AGENTS.md` on externally typed
-- strings.
ecs.newComponent({
    name = "tecs.http.Request",
    container = plugin.Request,
    serialize = serializeRequest,
    deserialize = deserializeRequest,
})

ecs.newComponent({
    name = "tecs.http.Response",
    container = plugin.Response,
    serialize = serializeResponse,
    deserialize = deserializeResponse,
})

ecs.newComponent({
    name = "tecs.http.Pending",
    container = plugin.Pending,
    transient = true,
})

local CLIENT <const> = storekeys.newKey("tecs.http.client", nil as Client)

local installed <const>: {World: boolean} = setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

--- The callback result each in-flight request waits on, keyed by entity.
---
--- Here rather than on `Pending`, because a transfer callback is runtime state
--- rather than component data.
--- One of these is built per install and captured by the plugin's system and
--- observers, so it lives exactly as long as the world does.
local record Wait
    status: string
    response: client.Response
    reason: string
    cancel: function()
end

local record ClientOperations
    _subscribe: function(
        self: ClientOperations, request: client.Request, listener: function(string, client.Response, string)
    ): function()
end

local type Waiting = {integer: Wait}

function plugin.clientOf(world: World): Client
    return world.resources[CLIENT]
end

function plugin.close(world: World)
    local owned <const> = world.resources[CLIENT]
    if owned == nil then
        return
    end
    world.resources[CLIENT] = nil
    owned:close()
end

--- Starts every request that has been spawned and not yet sent.
local function start(world: World, owned: Client, unsent: types.Query, waiting: Waiting)
    for archetype, length, entities in unsent:iter() do
        local requests <const> = archetype:get(plugin.Request) as {Request}
        for row = 1, length do
            local request <const> = requests[row]
            local entity <const> = entities[row] as integer
            -- A malformed request raises rather than settling, and raising out
            -- of a system would take the frame with it. So it becomes the
            -- response it would have become anyway.
            local wait: Wait = {status = "pending", response = nil, reason = nil, cancel = nil}
            local ok <const>, result = pcall(function(): function()
                return (owned as ClientOperations):_subscribe(
                    request as client.Request,
                    function(status: string, response: client.Response, reason: string)
                        wait.status = status
                        wait.response = response
                        wait.reason = reason
                    end
                )
            end) as (boolean, any)
            if not ok then
                world:set(
                    entity,
                    plugin.Response({
                        status = 0,
                        headers = {},
                        body = stream.newEmptyStream(),
                        url = URI.isURI(request.url) and request.url or nil,
                        error = tostring(result),
                    })
                )
                world:remove(entity, plugin.Request)
            else
                wait.cancel = result as function()
                waiting[entity] = wait
                world:set(entity, plugin.Pending)
            end
        end
    end
end

--- Turns every completed transfer into a `Response`.
local function finish(world: World, inFlight: types.Query, waiting: Waiting)
    for _, length, entities in inFlight:iter() do
        for row = 1, length do
            local entity <const> = entities[row] as integer
            local wait <const> = waiting[entity]
            if wait == nil then
                -- A marker with no transfer behind it, which is what a hand-set
                -- `Pending` is. Dropping it puts the `Request` back in front of
                -- `start` rather than leaving the entity waiting on nothing.
                world:remove(entity, plugin.Pending)
            elseif wait.status ~= "pending" then
                local settled: Response
                if wait.status == "ready" then
                    local answer <const> = wait.response
                    settled = plugin.Response({
                        status = answer.status,
                        headers = answer.headers,
                        body = answer.body,
                        url = answer.url,
                    })
                else
                    local request <const> = world:get(entity, plugin.Request)
                    settled = plugin.Response({
                        status = 0,
                        headers = {},
                        body = stream.newEmptyStream(),
                        url = request ~= nil and request.url or nil,
                        error = wait.reason,
                    })
                end
                waiting[entity] = nil
                world:set(entity, settled)
                world:remove(entity, plugin.Pending)
                world:remove(entity, plugin.Request)
            end
        end
    end
end

function plugin.install(world: World, options?: Options)
    if installed[world] then
        return
    end
    installed[world] = true

    local owned <const> = client.newClient(options)
    world.resources[CLIENT] = owned

    local waiting <const>: Waiting = {}

    local unsent <const> = world:newQuery({
        name = "tecs.http.Unsent",
        include = {plugin.Request},
        exclude = {plugin.Pending, plugin.Response},
    })
    local inFlight <const> = world:newQuery({
        name = "tecs.http.InFlight",
        include = {plugin.Pending},
    })

    -- `First`, so a request spawned last frame is in flight before anything
    -- this frame looks at it, and a response that settled between the two is
    -- already a component when the systems that read one run. The transfers
    -- themselves are turned by the application, outside any phase: a system
    -- that pumped would recursively drain the client while listeners settle.
    world:addSystem({
        name = "tecs.http.Drive",
        phase = ecs.phases.First,
        run = function() start(world, owned, unsent, waiting); finish(world, inFlight, waiting) end,
    })

    -- An entity that asked for something and then died wanted the answer, and
    -- nothing is left to give it to. Canceling is reference counted, so this
    -- stops the transfer represented by this entity.
    world:observe(
        0,
        ecs.OnDespawn,
        function(event: ecs.OnDespawn)
            local response <const> = world:get(event.entity, plugin.Response)
            if response ~= nil and response.body ~= nil then
                response.body:close()
            end
            local wait <const> = waiting[event.entity]
            if wait ~= nil then
                waiting[event.entity] = nil
                wait.cancel()
            end
        end
    )

    -- A load replaces the world in place rather than despawning what was in it,
    -- so the observer above never hears about the requesters it removed. The
    -- entities that were going to read those responses are gone, and `Pending`
    -- is transient so nothing is left to drive the transfers to a `Response`
    -- either: the transfers stop here or they run for nobody.
    world:observe(
        0,
        ecs.FinishSnapshotLoad,
        function(_event: ecs.FinishSnapshotLoad)
            for entity, wait in pairs(waiting) do
                waiting[entity] = nil
                wait.cancel()
            end
        end
    )
end

return plugin
