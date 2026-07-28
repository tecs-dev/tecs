--- Noticing that a content file changed, so a reload can be driven by the edit
--- rather than by an agent that remembers to ask.
---
--- **SDL has no change notification.** Not in 3.4, and not behind a hint or a
--- property: `SDL_AddEventWatch` watches the event queue and nothing in
--- `SDL_filesystem.h` or `SDL_storage.h` reports a change. What is there is
--- `SDL_GetPathInfo`, which answers a type, a size and three timestamps, and
--- `SDL_EnumerateDirectory` and `SDL_GlobDirectory` to find paths to ask it
--- about. So a portable watcher is a poll, and going native for one would mean
--- three implementations (inotify, FSEvents, ReadDirectoryChangesW) plus a
--- fourth for every platform whose SDK is licensed, to save work measured
--- below in microseconds.
---
--- **It polls what was loaded, not the content tree.** `assets` records every
--- path this process has read or decoded, which is a far smaller set than the
--- tree and is exactly the set where a change has something to act on: a file
--- nothing opened has no reloader to route to. That also makes enumeration
--- unnecessary, so `SDL_EnumerateDirectory` is not called at all.
---
--- **It runs between frames, on the main thread, synchronously.** Not on a
--- worker and not through async IO, and the second is not a choice: SDL's
--- asynchronous IO opens, reads, writes and closes files, and there is no
--- asynchronous form of `SDL_GetPathInfo`, so asking what a file's size and
--- modification time are is a blocking `stat` however it is reached.
---
--- What makes that fine is the cost. One `SDL_GetPathInfo` per watched path per
--- interval, measured at 0.86 microseconds a path on this machine: a hundred
--- files at two polls a second is 172 microseconds a second, under a fiftieth
--- of one percent of one core, and it lands between frames rather than inside
--- one. Frames the interval has not elapsed on cost a clock read and a compare.
--- A worker would have to be told the watched set every time something loaded,
--- and every reload it could trigger has to happen on the main thread anyway,
--- so it would move the one part that is already free and put a message
--- boundary in front of the part that is not.
---
--- **A half-written file is the case that bites.** An editor saving commonly
--- truncates and rewrites, so a poll can land on a file of zero length or of
--- half its eventual size. Two rules cover it. A file must report the same size
--- and modification time on `settle` consecutive polls before it is dispatched,
--- so a rewrite in progress is seen changing and is not acted on until it stops
--- changing; and a file of zero length is never dispatched at all, since that
--- is a truncation whatever else it is. Underneath both, a handler runs guarded
--- and a raise is logged rather than propagated, and the reloads themselves
--- already refuse safely: a truncated PNG does not decode and a broken shader
--- does not compile, and neither replaces what the process is drawing.
---
--- **Development only.** A release polls nothing. The gate is the one
--- `reload_shaders` already uses, because it is the same distinction: a release
--- links no shader compiler, and `install` refuses on a build that has none
--- rather than starting a poll no reload could complete.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local filesystem <const> = require("tecs.platform.filesystem")
local paths <const> = require("tecs.platform.paths")
local capabilities <const> = require("tecs.platform.capabilities")
local log <const> = require("tecs.log")

local C <const> = sdl.C
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

local record watch
    record Config
        --- Seconds between polls. Defaults to 0.5.
        interval: number
        --- Polls a change must repeat before it is dispatched. Defaults to 1,
        --- so a change is seen twice. Zero dispatches the first time a file
        --- reads differently, which is what a test that writes whole files
        --- wants and what an editor that truncates will trip over.
        settle: integer
        --- Only paths under this prefix are watched. Defaults to the content
        --- root, so a file the engine read from somewhere else is not content
        --- and is left alone.
        root: string
    end

    --- What a handler is told about.
    record Change
        path: string
        --- "image", "sound", "font", "shader" or "document".
        ---
        --- A font is its metrics and not the atlas beside them. The atlas is an
        --- image, was loaded as one, and reloads as one: its texels are
        --- replaced under the rect they already occupy and no glyph has to be
        --- told. The metrics are the half that decides what a glyph is, so they
        --- are the half with a font's rules over them.
        kind: string
    end

    type Handler = function(change: Change)

    --- Looks at every watched path once, whatever the interval says.
    ---
    --- What `poll` calls when the interval has elapsed, and what a test drives
    --- directly: settling is counted in polls, so stepping it by hand is how a
    --- half-written file is asserted on without sleeping.
    ---
    --- @return How many changes were dispatched, which is handlers run rather
    ---     than paths looked at. Zero while nothing is being watched.
    scan: function(): integer
end

local handlers <const>: {string: watch.Handler} = {}
local entries: {string: Entry} = {}
local running = false
local intervalMs = DEFAULT_INTERVAL * 1000
local settleCount = DEFAULT_SETTLE
local root = ""
local lastPoll = 0.0
local dispatched = 0

--- One SDL_PathInfo, reused. A poll asks about every watched path in turn and
--- reads the answer before the next question, so one is all it ever needs.
local INFO <const> = loader.newStruct("SDL_PathInfo")
local FIELDS <const> = INFO as {string: any}
local PATHTYPE_FILE <const> = tonumber(C.SDL_PATHTYPE_FILE)

--- The size and modification time of a file, or -1 for both when there is no
--- file there right now.
---
--- A path that is missing, or that has become a directory, reads as absent
--- rather than as an error: some editors save by writing a temporary file and
--- renaming it over the target, so a poll landing in the gap sees nothing and
--- has to treat that as "not settled" rather than as a change.
local function look(path: string): integer, number
    if not C.SDL_GetPathInfo(path, INFO) then
        return -1, -1
    end
    if tonumber(FIELDS.type) ~= PATHTYPE_FILE then
        return -1, -1
    end
    return tonumber(FIELDS.size) as integer, tonumber(FIELDS.modify_time)
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

--- Whether the watcher can run on this build.
---
--- A release links no shader compiler, which is what tells it apart from a
--- development build, and it is the same bit `reload_shaders` refuses on.
function watch.available(): boolean
    return capabilities.get().runtimeShaders
end

--- Starts watching, and refuses on a build that should not.
---
--- Every path already loaded is taken as it reads now, so nothing is dispatched
--- for a file that has not changed since the process opened it.
function watch.install(config?: watch.Config)
    if not watch.available() then
        error(
            "this build links no shader compiler, so it is a release and " .. "has no business polling the filesystem",
            0
        )
    end

    local given = config or {} as watch.Config
    intervalMs = (given.interval or DEFAULT_INTERVAL) * 1000
    settleCount = given.settle or DEFAULT_SETTLE
    if settleCount < 0 then
        error("tecs: settle counts polls, so it cannot be negative", 2)
    end
    root = given.root or paths.assets()
    entries = {}
    running = true
    dispatched = 0
    lastPoll = tonumber(C.SDL_GetTicks()) as number
    watch.scan()
end

--- Whether the watcher is running.
function watch.installed(): boolean
    return running
end

--- Stops watching and forgets every path's state.
---
--- The handlers stay registered. What a kind reloads is a property of the
--- build rather than of whether anything is watching right now, and a game
--- that turns the watcher off and on again means the second thing.
function watch.uninstall()
    running = false
    entries = {}
end

--- Registers what reloads a kind. Re-registering a kind replaces it, and nil
--- removes it.
---
--- Mechanism and policy are split here on purpose. Nothing in this module knows
--- what an image or a clip is; the application registers the reloader that owns
--- each kind, the way it already hands the shader tool its pipeline rebuild.
function watch.on(kind: string, handler: watch.Handler)
    if kind == nil or kind == "" then
        error("tecs: a handler needs a kind to be registered under", 2)
    end
    handlers[kind] = handler
end

--- Kinds something is registered to reload, sorted.
function watch.kinds(): {string}
    local names: {string} = {}
    for kind, handler in pairs(handlers) do
        if handler ~= nil then
            names[#names + 1] = kind
        end
    end
    table.sort(names)
    return names
end

--- Every path being watched, sorted.
function watch.watching(): {string}
    local list: {string} = {}
    for path in pairs(entries) do
        list[#list + 1] = path
    end
    table.sort(list)
    return list
end

--- Paths that have changed and have not settled yet, sorted.
---
--- What a file mid-save looks like from here, and what a test asserts on to
--- show that a truncated write was seen and not acted on.
function watch.unsettled(): {string}
    local list: {string} = {}
    for path, entry in pairs(entries) do
        if entry.pendingSize >= 0 then
            list[#list + 1] = path
        end
    end
    table.sort(list)
    return list
end

--- Changes dispatched since `install`.
function watch.dispatched(): integer
    return dispatched
end

--- Takes up whatever has been loaded since the last look.
---
--- A path is accepted as it reads the first time it is seen, so a run that
--- loads an image on frame ten does not reload it on frame eleven.
local function adopt()
    local loaded = filesystem.loaded()
    for path, loadedAs in pairs(loaded) do
        if entries[path] == nil and path:sub(1, #root) == root then
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
local function dispatch(path: string, entry: Entry): boolean
    local handler = handlers[entry.kind]
    if handler == nil then
        return false
    end
    local ok, failure = pcall(handler, {path = path, kind = entry.kind}) as (boolean, any)
    if not ok then
        LOGGER:error("reloading '%s' failed: %s", path, tostring(failure))
        return false
    end
    LOGGER:info("reloaded '%s' as %s", path, entry.kind)
    return true
end

function watch.scan(): integer
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
                entry.size = size
                entry.stamp = stamp
                entry.pendingSize = -1
                entry.pendingStamp = -1
                entry.steady = 0
                if dispatch(path, entry) then
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

    dispatched = dispatched + fired
    return fired
end

--- Scans if the interval has elapsed. Call once per iteration.
---
--- A frame that is not due costs one clock read and a compare, which is why
--- this can sit in the loop unconditionally.
--- @return How many changes were dispatched.
function watch.poll(): integer
    if not running then
        return 0
    end
    local now = tonumber(C.SDL_GetTicks()) as number
    if now - lastPoll < intervalMs then
        return 0
    end
    lastPoll = now
    return watch.scan()
end

return watch
