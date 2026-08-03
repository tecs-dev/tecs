-- Main-thread readiness bridge for cooperative network operations.
--
-- Native mio watches are one-shot. A public socket operation attempts its
-- syscall first, arrives here only after would-block, and retries after this
-- module completes its private Gate from the process-wide runtime pump.

local ffi <const> = require("ffi")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local runtime <const> = require("tecs.internal.runtime")
local time <const> = require("tecs.platform.time")
local type tasks = require("tecs.internal.taskruntime")
local task <const> = require("tecs.internal.taskruntime")

local C <const> = rust.C
local RUNTIME_NAME <const> = "network-readiness"
local RUNTIME_ORDER <const> = 45
local MAX_TOKEN <const> = 4294967295

local record Wait
    owner: any
    handle: loader.CPtr
    kind: integer
    token: integer
    gate: tasks.Gate
    deadline: number
end

local reactor: loader.CPtr = nil
local nextToken = 1
local active = 0
local registered = false
local deadlines = 0
local byToken <const>: {integer: Wait} = {}
local byOwner <const>: {any: Wait} = {}
local tokenOut <const> = ffi.new("uint32_t[1]") as loader.CArray
local readinessOut <const> = ffi.new("uint32_t[1]") as loader.CArray

local record netreactor
    stream: integer
    server: integer
    datagram: integer
    readable: integer
    writable: integer
    wait: function(
        owner: any, handle: loader.CPtr, kind: integer, interest: integer, timeoutMs?: integer
    ): integer, string
    cancel: function(owner: any, reason?: string): boolean, string
    poll: function(): integer
    pending: function(): integer
    shutdown: function(): boolean, string
    _shutdownRuntime: function()
end

netreactor.stream = 1
netreactor.server = 2
netreactor.datagram = 3
netreactor.readable = 1
netreactor.writable = 2

local function nativeReason(): string
    return loader.toString(C.tecsRustError())
end

local function ensure(): boolean, string
    if reactor ~= nil then
        return true
    end
    reactor = C.tecsNetReactorCreate()
    if reactor == nil then
        return false, nativeReason()
    end
    return true
end

local function unregister()
    if registered and active == 0 then
        runtime.unregister(RUNTIME_NAME)
        registered = false
    end
end

local function remove(wait: Wait)
    if byToken[wait.token] ~= wait then
        return
    end
    byToken[wait.token] = nil
    byOwner[wait.owner] = nil
    active = active - 1
    if wait.deadline ~= nil then
        deadlines = deadlines - 1
    end
    unregister()
end

local function allocateToken(): integer
    while true do
        local token <const> = nextToken
        nextToken = token == MAX_TOKEN and 1 or token + 1
        if byToken[token] == nil then
            return token
        end
    end
end

local function watch(kind: integer, handle: loader.CPtr, token: integer, interest: integer): integer
    if kind == netreactor.stream then
        return tonumber(C.tecsNetReactorWatch(reactor, handle, token, interest)) as integer
    elseif kind == netreactor.server then
        return tonumber(C.tecsNetReactorWatchServer(reactor, handle, token, interest)) as integer
    end
    return tonumber(C.tecsNetReactorWatchDatagram(reactor, handle, token, interest)) as integer
end

local function unwatch(wait: Wait): integer
    if wait.kind == netreactor.stream then
        return tonumber(C.tecsNetReactorUnwatch(reactor, wait.handle, wait.token)) as integer
    elseif wait.kind == netreactor.server then
        return tonumber(C.tecsNetReactorUnwatchServer(reactor, wait.handle, wait.token)) as integer
    end
    return tonumber(C.tecsNetReactorUnwatchDatagram(reactor, wait.handle, wait.token)) as integer
end

function netreactor.poll(): integer
    if reactor == nil or active == 0 then
        return 0
    end
    local count <const> = tonumber(C.tecsNetReactorPoll(reactor, 0)) as integer
    if count < 0 then
        error("tecs: network readiness poll failed: " .. nativeReason(), 2)
    end

    local delivered = 0
    while true do
        local status <const> = tonumber(C.tecsNetReactorNext(reactor, tokenOut, readinessOut)) as integer
        if status < 0 then
            error("tecs: network readiness drain failed: " .. nativeReason(), 2)
        end
        if status == 0 then
            break
        end
        local token <const> = tonumber(tokenOut[0]) as integer
        local wait <const> = byToken[token]
        if wait == nil then
            error("tecs: network reactor delivered an unknown token", 2)
        end
        remove(wait)
        wait.gate:complete(tonumber(readinessOut[0]) as integer)
        delivered = delivered + 1
    end
    if delivered ~= count then
        error("tecs: network readiness count did not match its queue", 2)
    end

    if deadlines ~= 0 then
        local now <const> = time.now()
        for _, wait in pairs(byToken) do
            if wait.deadline ~= nil and wait.deadline <= now then
                if unwatch(wait) == 0 then
                    error("tecs: expiring network readiness failed: " .. nativeReason(), 2)
                end
                remove(wait)
                wait.gate:complete(0)
                delivered = delivered + 1
            end
        end
    end
    return delivered
end

function netreactor.wait(
    owner: any, handle: loader.CPtr, kind: integer, interest: integer, timeoutMs?: integer
): integer, string
    task.checkSuspension("network I/O")
    if owner == nil or handle == nil then
        error("tecs: network readiness needs an owner and endpoint", 2)
    end
    if kind ~= netreactor.stream and kind ~= netreactor.server and kind ~= netreactor.datagram then
        error("tecs: network readiness endpoint kind is invalid", 2)
    end
    if interest ~= netreactor.readable and interest ~= netreactor.writable then
        error("tecs: network readiness interest is invalid", 2)
    end
    if byOwner[owner] ~= nil then
        return nil, "socket already has a readiness wait"
    end
    local ok, reason <const> = ensure()
    if not ok then
        return nil, reason
    end

    local token <const> = allocateToken()
    local wait: Wait
    local gate <const> = task.newGate(function()
        if wait == nil or byToken[token] ~= wait then
            return
        end
        if unwatch(wait) == 0 then
            local failure <const> = nativeReason()
            remove(wait)
            error("tecs: canceling network readiness failed: " .. failure, 0)
        end
        remove(wait)
    end)
    wait = {
        owner = owner,
        handle = handle,
        kind = kind,
        token = token,
        gate = gate,
        deadline = timeoutMs ~= nil and time.now() + timeoutMs / 1000 or nil,
    }

    if watch(kind, handle, token, interest) == 0 then
        return nil, nativeReason()
    end
    byToken[token] = wait
    byOwner[owner] = wait
    active = active + 1
    if wait.deadline ~= nil then
        deadlines = deadlines + 1
    end
    if not registered then
        runtime.register(RUNTIME_NAME, RUNTIME_ORDER, netreactor.poll, netreactor._shutdownRuntime)
        registered = true
    end
    local readiness, waitReason <const> = gate:wait()
    return readiness as integer, waitReason
end

function netreactor.cancel(owner: any, reason?: string): boolean, string
    local wait <const> = byOwner[owner]
    if wait == nil then
        return true
    end
    local failure: string
    if unwatch(wait) == 0 then
        failure = "canceling network readiness failed: " .. nativeReason()
    end
    remove(wait)
    wait.gate:fail(reason or "socket closed")
    if failure ~= nil then
        return false, failure
    end
    return true
end

function netreactor.pending(): integer
    return active
end

function netreactor.shutdown(): boolean, string
    if active ~= 0 then
        return false, ("%d network readiness wait(s) remain active"):format(active)
    end
    unregister()
    if reactor ~= nil then
        C.tecsNetReactorDestroy(reactor)
        reactor = nil
    end
    return true
end

function netreactor._shutdownRuntime()
    local waits: {Wait} = {}
    for _, wait in pairs(byToken) do
        waits[#waits + 1] = wait
    end
    for index = 1, #waits do
        local wait <const> = waits[index]
        if byToken[wait.token] == wait then
            unwatch(wait)
            remove(wait)
            wait.gate:fail("application shutdown")
        end
    end
    unregister()
    if reactor ~= nil then
        C.tecsNetReactorDestroy(reactor)
        reactor = nil
    end
end

return netreactor
