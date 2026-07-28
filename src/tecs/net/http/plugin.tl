--- A request as an entity, for a world that would rather spawn one.
---
--- `Client:send` answers a future, which is the right shape for a loading
--- screen and the wrong one for a game that wants the request to be a thing in
--- the world: something the debug server can list, something a system can
--- react to, something that dies when the entity that asked for it does.
---
---     world:addPlugin(tecs.net.http.plugin.install)
---
---     world:spawn(http.plugin.Request, {url = "https://example.com/scores"})
---
--- Some frames later the entity carries a `Response` instead, and a system
--- with `include = {http.Response}` sees it. Nothing polls a future, and the
--- request is inspectable the whole way through because it is a component.
---
--- ## What it does not do
---
--- It does not pump. The application already turns every open client once an
--- iteration, this plugin's included, so a system that pumped would be a
--- second turn of the same handle for nothing. What its system does is send
--- what has been spawned and settle what has answered.
---
--- ## Where the client comes from
---
--- One per world, built with the options given to `plugin.install` or with
--- defaults, and kept in the world's resources so a game can reach it:
--- `plugin.clientOf(world)`. A game that wants two clients, one for a chatty
--- API and one for downloads, builds the second itself; nothing about this
--- plugin is in the way of `tecs.net.http.newClient` beside it.
---
--- Despawning the world does not close the client. `plugin.close(world)` does,
--- and a program that ends is a process that ends, which is the same answer
--- every other pooled resource here gives.

local ecs <const> = require("tecs.ecs")
local Future <const> = require("tecs.Future")
local client <const> = require("tecs.net.http.client")
local DataStream <const> = require("tecs.net.http.DataStream")

local type World = ecs.World
local type Component = ecs.Component
local type Options = client.Options
local type Client = client.Client

local record plugin
    --- What a game spawns to make a request. The fields of a `Request`,
    --- because there is no second vocabulary for the same thing.
    record Request is Component
        --- Absolute, with an `http` or `https` scheme.
        url: string
        --- "GET" by default.
        method: string
        --- Merged over the client's, matched without case.
        headers: {string: string}
        --- What to send.
        body: string | DataStream
        --- Where the body goes. Left out, it comes back as a string.
        into: string | DataStream
        --- Milliseconds this transfer is given, overriding the client's.
        timeoutMs: number
        --- Milliseconds of no progress it tolerates, overriding the client's.
        stallTimeoutMs: number
        --- Bytes its body may reach, overriding the client's.
        maxBytes: integer
    end

    --- What replaces a `Request` once the transfer settles.
    ---
    --- Present whatever happened, because "the request finished" is the event
    --- a system waits for and a failure is one of the ways it can finish.
    --- `error` is what says which.
    record Response is Component
        --- The HTTP status code, or 0 when the transfer never got one.
        status: integer
        --- Response headers, with lower-cased names.
        headers: {string: string}
        --- The body, wherever it went.
        body: DataStream
        --- The URL that actually answered.
        url: string
        --- Why the transfer did not complete, or nil when it did. A 404 is not
        --- one of these: it is a `status` of 404 and no error.
        error: string
    end

    --- On an entity whose request is in flight. Internal, and the reason a
    --- request is sent once rather than every frame.
    record Pending is Component
        future: Future<client.Response>
    end

    --- Installs the plugin: `world:addPlugin(tecs.net.http.plugin.install)`.
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
local type Pending = plugin.Pending

-- The three names below, the resource key under them and the system names
-- further down are all spelled `tecs.http.*` and stay that way now that the
-- module is `tecs.net.http`. A snapshot names a component by string and an
-- agent selects a system by one, so they are a save format and a tooling
-- surface rather than module paths. See `AGENTS.md` on externally typed
-- strings.
ecs.newComponent({
    name = "tecs.http.Request",
    container = plugin.Request,
})

ecs.newComponent({
    name = "tecs.http.Response",
    container = plugin.Response,
})

ecs.newComponent({
    name = "tecs.http.Pending",
    container = plugin.Pending,
})

local CLIENT <const> = ecs.newKey("tecs.http.client", nil as Client)

local installed <const>: {World: boolean} = setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

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
local function start(world: World, owned: Client, waiting: ecs.Query)
    for archetype, length, entities in waiting:iter() do
        local requests <const> = archetype:get(plugin.Request) as {Request}
        for row = 1, length do
            local request <const> = requests[row]
            local entity <const> = entities[row]
            -- A malformed request raises rather than settling, and raising out
            -- of a system would take the frame with it. So it becomes the
            -- response it would have become anyway.
            local ok <const>, result = pcall(owned.send, owned, request as client.Request) as (boolean, any)
            if ok then
                world:set(entity, plugin.Pending({future = result as Future<client.Response>}))
            else
                world:set(
                    entity, plugin.Response({status = 0, headers = {}, url = request.url, error = tostring(result)})
                )
                world:remove(entity, plugin.Request)
            end
        end
    end
end

--- Turns every settled future into a `Response`.
local function finish(world: World, inFlight: ecs.Query)
    for archetype, length, entities in inFlight:iter() do
        local pendings <const> = archetype:get(plugin.Pending) as {Pending}
        for row = 1, length do
            local future <const> = pendings[row].future
            if future.status ~= "pending" then
                local entity <const> = entities[row]
                local answer <const> = future.value
                local settled <const>: Response = answer ~= nil
                    and plugin.Response({
                        status = answer.status,
                        headers = answer.headers,
                        body = answer.body,
                        url = answer.url,
                    }) or plugin.Response({status = 0, headers = {}, error = future.error})
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

    local waiting <const> = world:query({
        name = "tecs.http.Unsent",
        include = {plugin.Request},
        exclude = {plugin.Pending, plugin.Response},
    })
    local inFlight <const> = world:query({
        name = "tecs.http.InFlight",
        include = {plugin.Pending},
    })

    -- `First`, so a request spawned last frame is in flight before anything
    -- this frame looks at it, and a response that settled between the two is
    -- already a component when the systems that read one run. The transfers
    -- themselves are turned by the application, outside any phase: a system
    -- that pumped would be a second turn of the same multi handle.
    world:addSystem({
        name = "tecs.http.Drive",
        phase = ecs.phases.First,
        run = function() start(world, owned, waiting); finish(world, inFlight) end,
    })

    -- An entity that asked for something and then died wanted the answer, and
    -- nothing is left to give it to. Canceling is reference counted, so this
    -- stops the transfer only if nothing else is waiting on the same future.
    world:observe(
        0,
        ecs.OnDespawn,
        function(event: ecs.OnDespawn)
            local waitingOn <const> = world:get(event.entity, plugin.Pending) as Pending
            if waitingOn ~= nil then
                waitingOn.future:cancel()
            end
        end
    )
end

return plugin
