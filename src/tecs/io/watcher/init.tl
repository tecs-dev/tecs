--[=[
Polls loaded content and dispatches changes to reload handlers.

```teal
local watcher <const> = tecs.io.watcher

if watcher.isSupported() then
    watcher.on("document", function(change: watcher.Change)
        print("reload " .. change.path)
    end)
    watcher.install({intervalSeconds = 0.25})
end
```

An [`Application`](tealdoc:tecs.Application) with `watch` in its configuration
installs and advances the watcher. Settled changes enter a bounded queue and
handlers run in the scheduler-owned `Ingress` phase. They never interrupt a
half-completed phase, and a handler may use the same cooperative operations as
an ordinary system. Game systems, plugins, and update functions do not poll.

The watcher scans only paths recorded by `tecs.io.files.read` and the asset
loaders. It waits for a changed file's
size and modification time to settle before dispatching it. Empty, missing,
and directory paths do not dispatch.

Repeated queued changes to one path coalesce. `Config.capacity` bounds distinct
pending paths; an overflow is logged and retried by a later scan instead of
growing memory without limit. A handler error reaches the log and does not
replace the current resource. Release builds report `isSupported() == false`.
]=]

-- Implementation details:
-- SDL exposes path metadata but no portable change notification. Native
-- notification would require an implementation per platform, while polling
-- the loaded set avoids walking the content tree.
--
-- Polling runs synchronously on the main thread. The default backend measured
-- 0.86 microseconds per path on the machine used when this module was written.
-- A hundred files at two polls per second costs about 172 microseconds per
-- second. Moving that work to a worker would add a message boundary before
-- reload work that must return to the main thread.
--
-- Editors commonly truncate and rewrite a file. Stable size and modification
-- time across several polls prevent a half-written file from dispatching.

local adapter <const> = require("tecs.platform.adapter")
local content <const> = require("tecs.platform.content")
local platformOS <const> = require("tecs.platform.os")
local time <const> = require("tecs.platform.time")
local runtime <const> = require("tecs.internal.runtime")
local log <const> = require("tecs.log")

local runtimePoll: function(): integer
local function pollRuntime(): integer
    return runtimePoll()
end

-- The name a developer filters on with `SDL_SetLogPriority`, so it is
-- configuration rather than an identifier and does not follow this module if
-- the module moves.
local LOGGER <const> = log.get("tecs.watch")

--- Seconds between polls. Fast enough that a save is picked up before a hand
--- reaches the window, slow enough that the poll is not on a frame's path.
local DEFAULT_INTERVAL <const> = 0.5
--- Polls a change must repeat before it is dispatched. One means a change is
--- seen twice, which is what makes a rewrite in progress wait.
local DEFAULT_SETTLE <const> = 1

--- What a document's extension makes it. The load path decides every other
--- kind, because something asked for an image as an image, or for a document as
--- a font's metrics; `read` answers bytes and cannot know what wanted them, so
--- this is the one place a suffix decides, and it decides only what nothing
--- named.
local DOCUMENT_KINDS <const>: {string: string} = {
    glsl = "shader",
}

--- One watched path, and how sure we are about its current state.
---
--- A stamp is the modification time in nanoseconds since the epoch, carried as
--- a double. That rounds to the nearest 256 nanoseconds at present-day values,
--- which is a resolution no save comes close to and is worth having in exchange
--- for keeping a plain number per path rather than a boxed 64-bit integer.
local record Entry
    kind: string
    --- The state last accepted, which is what a change is measured against.
    size: integer
    stamp: number
    --- The state the last poll saw, and how many polls have agreed on it.
    pendingSize: integer
    pendingStamp: number
    steady: integer
end

local record watcher
    --- `Config` controls polling frequency, settling and path scope.
    record Config
        --- Caller-writable. Sets the delay between automatic polls in seconds.
        --- It defaults to 0.5. Direct calls to `scan` ignore this delay.
        intervalSeconds: number
        --- Caller-writable. Requires this many additional matching scans after
        --- a change is first observed. It defaults to 1, so one scan observes
        --- the change and the next confirms it. Zero dispatches immediately.
        settle: integer
        --- Caller-writable. Limits watched paths to this root. It defaults to
        --- the content root.
        root: string
        --- Caller-writable. Limits settled changes waiting for the next
        --- logical update. Defaults to 1024. Repeated changes to one path
        --- coalesce while queued.
        capacity: integer
    end

    --- `Change` describes one settled content change.
    record Change
        --- Read-only. The watcher sets `path` to the changed loaded path before
        --- it calls the handler.
        path: string
        --- Read-only. The watcher sets `kind` to the content kind recorded by
        --- the original load. Built-in loaders use `"image"`, `"sound"`,
        --- `"font"`, `"shader"` or `"document"`; a custom loader supplies its
        --- own kind to `tecs.io.files.read`.
        kind: string
    end

    --- `ChangeHandler` receives one settled change.
    type ChangeHandler = function(change: Change)

    --- Looks at every watched path once, whatever the interval says.
    ---
    --- Call this directly when a headless tool or test controls poll timing.
    ---
    --- @return Returns how many handlers ran, or zero when no watcher runs.
    scan: function(): integer
end

local handlers <const>: {string: watcher.ChangeHandler} = {}
local entries: {string: Entry} = {}
local running = false
local interval = DEFAULT_INTERVAL
local settleCount = DEFAULT_SETTLE
local root = ""
local lastPoll = 0.0
local dispatched = 0
local capacity = 1024
local pending: {watcher.Change} = {}
local pendingPaths: {string: boolean} = {}
local active: {watcher.Change} = nil

--- The size and modification time of a file, or -1 for both when there is no
--- file there right now.
---
--- A path that is missing, or that has become a directory, reads as absent
--- rather than as an error: some editors save by writing a temporary file and
--- renaming it over the target, so a poll landing in the gap sees nothing and
--- has to treat that as "not settled" rather than as a change.
local function look(path: string): integer, number
    local info <const> = adapter.storage().info(path)
    if info == nil or info.kind ~= "file" then
        return -1, -1
    end
    return info.size, info.modifiedAt
end

--- What a path is reloaded as, from the kind it was loaded under.
local function kindOf(path: string, loadedAs: string): string
    if loadedAs ~= "document" then
        return loadedAs
    end
    local suffix = path:match("%.([%a%d]+)$")
    if suffix == nil then
        return "document"
    end
    return DOCUMENT_KINDS[suffix:lower()] or "document"
end

--- Returns whether this build supports hot reload.
---
--- @return Returns true when this build can install the watcher.
function watcher.isSupported(): boolean
    return platformOS.capabilities().hotReload
end

--- Starts watching loaded content.
---
--- The watcher records the current state of loaded paths and dispatches only
--- later changes. It raises when the build lacks hot-reload support.
---
--- @param config The caller supplies polling options or omits them for the
---     documented defaults.
function watcher.install(config?: watcher.Config)
    if not watcher.isSupported() then
        error("this build has no hot-reload support, so it has no business polling the filesystem", 0)
    end

    local given = config or {} as watcher.Config
    interval = given.intervalSeconds or DEFAULT_INTERVAL
    settleCount = given.settle or DEFAULT_SETTLE
    if settleCount < 0 then
        error("tecs: settle counts polls, so it cannot be negative", 2)
    end
    root = given.root or content.assetRoot()
    capacity = given.capacity or 1024
    if type(capacity) ~= "number" or capacity ~= math.floor(capacity) or capacity < 1 then
        error("tecs: watcher capacity must be a positive integer", 2)
    end
    entries = {}
    pending = {}
    pendingPaths = {}
    active = nil
    running = true
    runtime.unregister("watcher")
    runtime.register("watcher", 60, pollRuntime, nil)
    dispatched = 0
    lastPoll = time.now()
    watcher.scan()
end

--- Returns whether the watcher is running.
---
--- @return Returns true after `install` and before `uninstall`.
function watcher.isInstalled(): boolean
    return running
end

--- Stops watching and forgets every path's state.
---
--- Registered handlers remain available for a later installation.
function watcher.uninstall()
    running = false
    runtime.unregister("watcher")
    entries = {}
    pending = {}
    pendingPaths = {}
    active = nil
end

--- Registers the handler for a content kind.
---
--- Re-registering a kind replaces its handler. Nil removes it.
---
--- @param kind The caller supplies the content kind to register.
--- @param handler The caller supplies the replacement handler or nil to remove
---     the current one.
function watcher.on(kind: string, handler: watcher.ChangeHandler)
    if kind == nil or kind == "" then
        error("tecs: a handler needs a kind to be registered under", 2)
    end
    handlers[kind] = handler
end

--- Returns registered content kinds in sorted order.
---
--- @return Returns a fresh caller-owned list.
function watcher.kinds(): {string}
    local names: {string} = {}
    for kind, handler in pairs(handlers) do
        if handler ~= nil then
            names[#names + 1] = kind
        end
    end
    table.sort(names)
    return names
end

--- Returns watched paths in sorted order.
---
--- @return Returns a fresh caller-owned list.
function watcher.watching(): {string}
    local list: {string} = {}
    for path in pairs(entries) do
        list[#list + 1] = path
    end
    table.sort(list)
    return list
end

--- Returns unsettled changed paths in sorted order.
---
--- @return Returns a fresh caller-owned list.
function watcher.unsettled(): {string}
    local list: {string} = {}
    for path, entry in pairs(entries) do
        if entry.pendingSize >= 0 then
            list[#list + 1] = path
        end
    end
    table.sort(list)
    return list
end

--- Returns the changes dispatched since `install`.
---
--- @return Returns the cumulative handler count.
function watcher.dispatched(): integer
    return dispatched
end

--- Whether `path` is the root itself or below it.
---
--- Paths stay lexical because the installed storage may not be an operating
--- system filesystem. The separator check is the boundary a plain prefix
--- lacks: `/content-old/file` is not under `/content`.
local function underRoot(path: string): boolean
    if path:sub(1, #root) ~= root then
        return false
    end
    if #path == #root or root == "" then
        return true
    end
    local last <const> = root:sub(-1)
    if last == "/" or last == "\\" then
        return true
    end
    local boundary <const> = path:sub(#root + 1, #root + 1)
    return boundary == "/" or boundary == "\\"
end

--- Takes up whatever has been loaded since the last look.
---
--- A path is accepted as it reads the first time it is seen, so a run that
--- loads an image on frame ten does not reload it on frame eleven.
local function adopt()
    local loaded = content.loaded()
    for path, loadedAs in pairs(loaded) do
        if entries[path] == nil and underRoot(path) then
            local size, stamp = look(path)
            entries[path] = {
                kind = kindOf(path, loadedAs),
                size = size,
                stamp = stamp,
                pendingSize = -1,
                pendingStamp = -1,
                steady = 0,
            }
        end
    end
end

--- Hands one change to whatever reloads its kind.
---
--- Guarded, because a reload is the one operation most likely to be handed a
--- file that is not finished being written. A handler that raises has said the
--- file is not usable, which is the same answer as waiting for the next save.
local function enqueue(path: string, entry: Entry): boolean
    if pendingPaths[path] then
        return true
    end
    if #pending >= capacity then
        LOGGER:error("the watcher ingress queue is full; retaining '%s' for a later scan", path)
        return false
    end
    pending[#pending + 1] = {path = path, kind = entry.kind}
    pendingPaths[path] = true
    return true
end

function watcher.scan(): integer
    if not running then
        return 0
    end
    adopt()

    local fired = 0
    for path, entry in pairs(entries) do
        local size, stamp = look(path)

        -- A file that is missing, that has become a directory, or that is
        -- empty is a save in progress rather than a state to reload from.
        -- Nothing is accepted and nothing is dispatched, and the next poll
        -- looks again.
        if size <= 0 then
            entry.pendingSize = -1
            entry.pendingStamp = -1
            entry.steady = 0
        elseif size ~= entry.size or stamp ~= entry.stamp then
            if size == entry.pendingSize and stamp == entry.pendingStamp then
                entry.steady = entry.steady + 1
            else
                entry.pendingSize = size
                entry.pendingStamp = stamp
                entry.steady = 0
            end

            if entry.steady >= settleCount then
                if enqueue(path, entry) then
                    entry.size = size
                    entry.stamp = stamp
                    entry.pendingSize = -1
                    entry.pendingStamp = -1
                    entry.steady = 0
                    fired = fired + 1
                end
            end
        elseif entry.pendingSize >= 0 then
            -- Changed and then changed back inside the settle window, which
            -- is a save that produced the bytes that were already there.
            entry.pendingSize = -1
            entry.pendingStamp = -1
            entry.steady = 0
        end
    end

    return fired
end

--- Advances the Application-owned watcher without waiting.
local function pollWatcher(): integer
    if not running then
        return 0
    end
    local now = time.now()
    if now - lastPoll < interval then
        return 0
    end
    lastPoll = now
    return watcher.scan()
end

runtimePoll = pollWatcher

--- Seals queued changes for one logical update.
function watcher._sealIngress()
    if active ~= nil then
        return
    end
    active = pending
    pending = {}
    pendingPaths = {}
end

--- Dispatches the sealed changes from the scheduler-owned Ingress phase.
function watcher._dispatchIngress(): integer
    local batch <const> = active
    if batch == nil then
        return 0
    end
    local fired = 0
    for index = 1, #batch do
        local change <const> = batch[index]
        local handler <const> = handlers[change.kind]
        if handler ~= nil then
            local ok, failure = pcall(handler, change) as (boolean, any)
            if ok then
                LOGGER:info("reloaded '%s' as %s", change.path, change.kind)
                fired = fired + 1
            else
                LOGGER:error("reloading '%s' failed: %s", change.path, tostring(failure))
            end
        end
    end
    dispatched = dispatched + fired
    return fired
end

--- Releases the sealed change batch after its logical update completes.
function watcher._finishIngress()
    active = nil
end

return watcher
