--[=[
A request as an entity, for a world that would rather spawn one.

`Client:send` answers a future, which is the right shape for a loading
screen and the wrong one for a game that wants the request to be a thing in
the world: something the debug server can list, something a system can
react to, something that dies when the entity that asked for it does.

    world:addPlugin(tecs.io.http.plugin.install)

    world:spawn(http.plugin.Request, {url = "https://example.com/scores"})

Some frames later the entity carries a `Response` instead, and a system
with `include = {http.Response}` sees it. Nothing polls a future, and the
request is inspectable the whole way through because it is a component.

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

The exception is a `Request` whose `body` or `into` is a
`tecs.io.newHandleStream`. The caller owns that live handle, and neither
snapshot format can reconstruct its ownership or position, so saving the world
raises.
Use `tecs.io.newFileStream` when a request must survive a snapshot.

Loading stops the transfers that were open before it. A load replaces the
world in place and despawns nothing, so the entities that asked are gone
without anything hearing about it, and a transfer nobody is left to receive
is work for no one.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local storekeys <const> = require("tecs.internal.storekeys")
local Future <const> = require("tecs.Future")
local client <const> = require("tecs.io.http.client")
local stream <const> = require("tecs.io.stream")
local type iotypes = require("tecs.io.types")

local type World = types.World
local type Component = ecs.Component
local type Options = client.Options
local type Client = client.Client
local type Stream = iotypes.Stream
local type ReadableStream = iotypes.ReadableStream
local type WritableStream = iotypes.WritableStream

local record plugin
    --- What a game spawns to make a request. The fields of a `Request`,
    --- because there is no second vocabulary for the same thing.
    record Request is Component
        --- Caller-writable. Sets an absolute URL with an `http` or `https`
        --- scheme.
        url: string
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
        --- Caller-writable. Sets where the body goes. Left out, the response
        --- carries a replayable in-memory [`Stream`](tealdoc:tecs.io.Stream).
        --- A snapshot rejects a
        --- `tecs.io.newHandleStream` here because its live handle cannot
        --- be reconstructed.
        into: string | WritableStream
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
        --- Engine-owned. Reports response headers with lower-cased names.
        headers: {string: string}
        --- Engine-owned. Provides the body wherever it went.
        body: Stream
        --- Engine-owned. Reports the URL that actually answered.
        url: string
        --- Engine-owned. Reports why the transfer did not complete, or nil
        --- when it did. A 404 is not one of these: it is a `status` of 404 and
        --- no error.
        error: string
    end

    --- On an entity whose request is in flight. Internal, and the reason a
    --- request is sent once rather than every frame.
    ---
    --- A marker, and the future it stands for is not a field on it: a future
    --- holds listeners and the source that settles them, so nothing a save
    --- writes can carry one. Transient for the same reason, which is what makes
    --- a save taken mid-request coherent: the `Request` survives, this does not,
    --- and the load sends it again.
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
            elseif (key == "body" or key == "into") and valueType == "table" then
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
        elseif (key == "body" or key == "into") and type(value) == "table" then
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
        url = response.url,
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

--- The future each in-flight request waits on, keyed by entity.
---
--- Here rather than on `Pending`, because a future is not data: it holds
--- listeners and the source that settles them, and a snapshot writer that
--- reached one walks a cyclic graph of runtime state rather than refusing it.
--- One of these is built per install and captured by the plugin's system and
--- observers, so it lives exactly as long as the world does.
local type Waiting = {integer: Future<client.Response>}

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
local function start(world: World, owned: Client, unsent: types.Query, futures: Waiting)
    for archetype, length, entities in unsent:iter() do
        local requests <const> = archetype:get(plugin.Request) as {Request}
        for row = 1, length do
            local request <const> = requests[row]
            local entity <const> = entities[row] as integer
            -- A malformed request raises rather than settling, and raising out
            -- of a system would take the frame with it. So it becomes the
            -- response it would have become anyway.
            local ok <const>, result = pcall(owned.send, owned, request as client.Request) as (boolean, any)
            if ok then
                futures[entity] = result as Future<client.Response>
                world:set(entity, plugin.Pending)
            else
                world:set(
                    entity,
                    plugin.Response({
                        status = 0,
                        headers = {},
                        body = stream.newEmptyStream(),
                        url = request.url,
                        error = tostring(result),
                    })
                )
                world:remove(entity, plugin.Request)
            end
        end
    end
end

--- Turns every settled future into a `Response`.
local function finish(world: World, inFlight: types.Query, futures: Waiting)
    for _, length, entities in inFlight:iter() do
        for row = 1, length do
            local entity <const> = entities[row] as integer
            local future <const> = futures[entity]
            if future == nil then
                -- A marker with no transfer behind it, which is what a hand-set
                -- `Pending` is. Dropping it puts the `Request` back in front of
                -- `start` rather than leaving the entity waiting on nothing.
                world:remove(entity, plugin.Pending)
            elseif future.status ~= "pending" then
                local settled: Response
                if future.status == "ready" then
                    local answer <const> = future.value
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
                        url = request ~= nil and request.url or "",
                        error = future.error,
                    })
                end
                futures[entity] = nil
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

    local futures <const>: Waiting = {}

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
        run = function() start(world, owned, unsent, futures); finish(world, inFlight, futures) end,
    })

    -- An entity that asked for something and then died wanted the answer, and
    -- nothing is left to give it to. Canceling is reference counted, so this
    -- stops the transfer only if nothing else is waiting on the same future.
    world:observe(
        0,
        ecs.OnDespawn,
        function(event: ecs.OnDespawn)
            local future <const> = futures[event.entity]
            if future ~= nil then
                futures[event.entity] = nil
                future:cancel()
            end
        end
    )

    -- A load replaces the world in place rather than despawning what was in it,
    -- so the observer above never hears about the requesters it removed. The
    -- entities that were going to read those responses are gone, and `Pending`
    -- is transient so nothing is left to drive the futures to a `Response`
    -- either: the transfers stop here or they run for nobody.
    world:observe(
        0,
        ecs.FinishSnapshotLoad,
        function(_event: ecs.FinishSnapshotLoad)
            for entity, future in pairs(futures) do
                futures[entity] = nil
                future:cancel()
            end
        end
    )
end

return plugin
