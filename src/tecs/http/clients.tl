--- Every open HTTP client in this process, and the one call that turns them.
---
--- A transfer only moves when something drives libcurl, and deciding what that
--- something is was the whole question. `assets` and `proc` are module
--- singletons, so the loop names them and calls them. A client is not: a game
--- constructs it, may construct several, and may keep none of them anywhere
--- the loop could reach. So the clients come to the loop instead. Building one
--- registers it here, closing one takes it off, and `tecs.Application` turns
--- whatever is on the list once a frame. A game calls nothing.
---
--- ## Why this is a module of its own
---
--- The loop has to reach the list without loading libcurl. `tecs.http.client`
--- resolves the library when it is required, so an `Application` that required
--- it would make every game depend on libcurl being present at startup,
--- including the ones that never make a request. This module names no library
--- and costs a table.
---
--- It is also why the list is of a small record rather than of `Client`:
--- naming that type here would be a require in the wrong direction, and Teal
--- rejects the cycle even through a type-only one.
---
--- ## A client that is dropped is still pumped
---
--- The list holds its clients, so a game that sends a request and keeps only
--- the future still gets an answer. The cost is that a client nobody closes is
--- never collected and its sockets stay open: `close` is what ends a client,
--- not losing the last reference to it. That is the same bargain `proc` makes
--- with a child nobody waits for, and the alternative -- a weak list -- is a
--- fire-and-forget request that stops moving whenever a collection happens to
--- run, which is a bug nobody could reproduce.

local record clients
    --- What the loop turns. `Client` is one.
    record Pumpable
        --- Advances every transfer as far as it can go without waiting, and
        --- answers how many settled.
        pump: function(self: Pumpable): integer
    end
end

local type Pumpable = clients.Pumpable

--- The live clients, in the order they were built.
local live <const>: {Pumpable} = {}
--- Where each one is in that list, so removing is not a scan.
local at <const>: {Pumpable: integer} = {}
local count = 0

--- The list as it stood when a pump began. Reused rather than allocated: a
--- listener may close a client or build another while the walk is in progress,
--- and a walk over the live list would then skip one or turn one twice.
local turning <const>: {Pumpable} = {}

--- Adds a client to the list the loop turns. Adding one twice does nothing.
function clients.add(client: Pumpable)
    if client == nil or at[client] ~= nil then
        return
    end
    count = count + 1
    live[count] = client
    at[client] = count
end

--- Takes a client off it. What `Client:close` calls, and the only thing that
--- ends a client's place in a frame.
function clients.remove(client: Pumpable)
    local index <const> = client ~= nil and at[client] or nil
    if index == nil then
        return
    end
    -- The last one moves into the gap, which keeps the list dense and costs
    -- the order of two clients nobody can observe an order between.
    local last <const> = live[count]
    live[index] = last
    at[last] = index
    live[count] = nil
    at[client] = nil
    count = count - 1
end

--- How many clients are open.
function clients.count(): integer
    return count
end

--- Turns every open client once, and answers how many transfers settled.
---
--- What `tecs.Application` calls each frame. A headless tool driving several
--- clients calls this rather than each of them.
function clients.pump(): integer
    if count == 0 then
        return 0
    end

    local turns <const> = count
    for index = 1, turns do
        turning[index] = live[index]
    end

    local settled = 0
    for index = 1, turns do
        local client <const> = turning[index]
        turning[index] = nil
        -- Still open: a listener the previous client's pump ran may have
        -- closed this one.
        if at[client] ~= nil then
            settled = settled + client:pump()
        end
    end
    return settled
end

return clients
