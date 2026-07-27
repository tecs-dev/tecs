--- Asynchronous asset loading.
---
--- Decoding a PNG is milliseconds of pure CPU work with no GPU involvement,
--- so it happens on a worker and the main thread only uploads. A load never
--- blocks a frame; a handle reports that it is still loading and callers draw
--- something else until it is not. Sound takes the same route for the same
--- reason: reading a file is a syscall a frame should not wait on.
---
--- The worker hands back the address of an `SDL_Surface` rather than the
--- pixels themselves. Surfaces live in process memory, so the pointer is
--- valid in either state, and passing it avoids copying a decoded image
--- through a serialized message only to copy it again into staging. Ownership
--- transfers with it: whoever receives the address destroys the surface. A
--- loaded sound crosses the same way, as the address of its `MIX_Audio`.
---
--- Nothing here creates a GPU resource. Decoding and residency are separate
--- decisions: the renderer knows what layout its textures need, and an asset
--- that has been decoded is useful before anything has decided where it will
--- live.
---
--- A file whose contents something else knows how to interpret goes through
--- `read`. That is synchronous and is the only sanctioned way to get bytes out
--- of the content root, because content lives inside the package on Android
--- and `io.open` does not reach it. It answers bytes and never text: a Lua
--- string carries a length, so an image, an archive or a binary sidecar comes
--- back whole, and a format that is text is a decoder's opinion rather than
--- this function's.
---
--- Reading a document is therefore those two halves and nothing between them:
---
---     local tecs <const> = require("tecs")
---     local bytes <const> = tecs.assets.read(tecs.paths.asset("levels/1.json"))
---     local level <const> = tecs.json.decode(bytes)
---
--- `paths.asset` resolves against the content root and `read` answers nil for
--- a path with no file, so a game distinguishes an absent document from a
--- malformed one, which the decoder raises on. A parser for a binary format
--- sits in exactly that second position, over the same bytes.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")

local C <const> = sdl.C
local MIX <const> = sdl3mixer.C

--- Runs on the worker. Decodes to a normalised layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local image = require("tecs.ffi.sdl3image")
local mixer = require("tecs.ffi.sdl3mixer")
local workers = require("tecs.workers")

local C = sdl.C
local IMG = image.C
local MIX = mixer.C

-- SDL_PIXELFORMAT_RGBA32 is a byte-order alias resolved by the preprocessor,
-- so it never reaches the cdef. On a little-endian host it is ABGR8888.
local RGBA32 = C.SDL_PIXELFORMAT_ABGR8888

local self = workers.current()

local function decodeImage(task)
    local surface = IMG.IMG_Load(task.path)
    if surface == nil then
        return { id = task.id, error = "cannot decode " .. task.path }
    end

    -- Normalising here means the upload path handles exactly one layout,
    -- and the conversion cost lands off the main thread with the decode.
    local converted = C.SDL_ConvertSurface(surface, RGBA32)
    C.SDL_DestroySurface(surface)
    if converted == nil then
        return { id = task.id, error = "cannot convert " .. task.path }
    end
    return {
        id = task.id,
        surface = tonumber(ffi.cast("uintptr_t", converted)),
        width = converted.w,
        height = converted.h,
        pitch = converted.pitch,
    }
end

-- Length in milliseconds, or -1 when the container cannot say. A format that
-- only stores a bit rate is estimated from it, and one that streams forever
-- reports infinite; both are "unknown" as far as anything above cares.
local function durationOf(audio)
    local frames = MIX.MIX_GetAudioDuration(audio)
    if frames < 0 then return -1 end
    return tonumber(MIX.MIX_AudioFramesToMS(audio, frames))
end

-- Sound is read by the mixer's own decoders, which is what makes anything but
-- WAV loadable. No mixer is passed: a clip is independent of the output, so
-- loading works before one is open and on a machine that has none, and the
-- mixer converts what it reads either way.
--
-- `mode` decides whether the clip ends up resident:
--   "resident"  decoded once, up front, and held as PCM
--   "stream"    nothing held; each voice opens the file for itself
--   "auto"      resident under `streamMs`, streamed at or over it
--
-- The auto case reads the file twice when it turns out to be short: once
-- without decoding, to ask how long it is, and once to decode it. That is a
-- second read of a small file, off the main thread, against holding a decoded
-- copy of a piece of music.
local function decodeSound(task)
    local predecode = task.mode == "resident"
    local audio = MIX.MIX_LoadAudio(nil, task.path, predecode)
    if audio == nil then
        return { id = task.id, error = "cannot load " .. task.path }
    end

    local ms = durationOf(audio)
    if task.mode == "resident" then
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    if task.mode == "auto" and ms >= 0 and ms < task.streamMs then
        MIX.MIX_DestroyAudio(audio)
        audio = MIX.MIX_LoadAudio(nil, task.path, true)
        if audio == nil then
            return { id = task.id, error = "cannot decode " .. task.path }
        end
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    MIX.MIX_DestroyAudio(audio)
    return { id = task.id, resident = false, durationMs = ms }
end

while true do
    local task = self:receive()
    if task == nil then break end
    if task.kind == "sound" then
        self:send(decodeSound(task))
    else
        self:send(decodeImage(task))
    end
end
]==]

local record Handle
    --- What was asked for: "image" or "sound".
    kind: string
    --- "loading", "ready", "failed", or "released". The last is terminal and
    --- reached only through `release`, so something handed a handle whose
    --- decode it no longer owns is told that rather than finding nil where the
    --- pixels were.
    status: string
    path: string
    --- Decoded RGBA pixels, valid until `release`. Images only.
    pixels: loader.CValue
    width: integer
    height: integer
    --- Row stride in bytes, which a decoder may pad beyond width * 4.
    pitch: integer
    --- The loaded clip, valid until `release`. Sounds only, and nil for one
    --- that streams, which holds nothing.
    audio: loader.CValue
    --- Whether the clip is held in memory. Sounds only.
    resident: boolean
    --- Length in milliseconds, or -1 when the file cannot say. Sounds only.
    durationMs: integer
    --- Set if loading failed.
    error: string
    _surface: loader.CValue
    --- Id the worker answers with, so a release can find this in the queue.
    _id: integer
    --- Callers sharing this decode. One decode serves every load of a path
    --- that was already in flight, and the last release of it frees.
    _shares: integer
end

local record assets
    Handle: Handle

    --- A set of loads to wait on, with something of the caller's beside each.
    ---
    --- Waiting on several handles at once is not one subsystem's problem. Sound
    --- holds a clip per handle, text holds an atlas per handle, and a sidecar
    --- holds whatever it was read for; each of them wants the same three things,
    --- which are how many are still in flight, a callback per one that
    --- finished, and a blocking form for startup and tests. That is the whole
    --- shape, so it is here once rather than written again beside every list of
    --- handles.
    ---
    --- `T` is the caller's and nothing here reads it. Resolving compacts in
    --- place, so a frame with loads in flight allocates nothing; the price of
    --- that is that a callback must not add to the batch it is being called
    --- from.
    record Batch<T>
        _finished: function(key: T, handle: Handle)
        _handles: {Handle}
        _keys: {T}

        --- Adds a load to wait on, with the caller's value beside it.
        add: function(self, handle: Handle, key: T)

        --- Loads still in flight.
        pending: function(self): integer

        --- Hands every finished load to the callback and drops it.
        ---
        --- Takes whatever the worker has answered first, so a subsystem
        --- polling only its own batch still sees its loads finish.
        --- @return How many were resolved by this call.
        resolve: function(self): integer

        --- Blocks until nothing is in flight, then resolves.
        ---
        --- For startup, shutdown and tests. A frame calls `resolve` instead.
        --- @param timeoutMs Milliseconds to wait. Defaults to 5000.
        --- @return How many were resolved.
        wait: function(self, timeoutMs?: number): integer
    end

    --- Whether the loading worker is running.
    installed: function(): boolean
end

local type Batch = assets.Batch

local HandleMT <const>: metatable<Handle> = { __index = Handle }
local BatchMT <const>: metatable<Batch<any>> = { __index = Batch }

local pending: {integer: Handle} = {}
--- Image decodes that have been queued and not yet answered, by path. A second
--- load of a path in this table joins the first rather than queueing a decode
--- of the same file beside it.
local inFlight: {string: Handle} = {}
local nextId = 1
local worker: workers.Worker = nil

--- Every path this process has read or decoded, and what it was read as.
---
--- Every file the engine opens comes through one of the three functions below,
--- so this is the whole of what a run has touched. It is what a watcher polls,
--- because polling what was loaded is a fraction of the work of walking a
--- content tree and is the only set where a change has anything to act on.
local seen <const>: {string: string} = {}

--- Records a path under the kind it was first read as.
---
--- A named kind supersedes "document". `read` answers bytes and cannot know
--- what asked for them, so whatever did is the only thing that can say what the
--- file is, and it says so by naming a kind. The two can arrive in either
--- order, since a game is free to read a font's metrics as a document before
--- anything loads them as a font.
local function note(path: string, kind: string)
    local held = seen[path]
    if held == nil or (held == "document" and kind ~= "document") then
        seen[path] = kind
    end
end

--- Reads a whole file and returns its bytes, or nil when there is none there.
---
--- Through SDL rather than stdio, because on Android content lives inside the
--- package and only SDL's IO reaches it. Binary: the result carries its own
--- length, so a NUL in the middle of it is a byte like any other.
---
--- Synchronous, which is what makes it usable while a world is being built.
--- This is for the documents a game or the engine reads once; a decode a frame
--- should not wait on goes through `loadImage` or `loadSound` instead.
--- @param path An absolute path, or one `paths.asset` has resolved.
--- @param kind What the bytes were read as, for anything watching what this
---     process has opened. Bytes are bytes, so nothing here can tell a font's
---     metrics from a level; whatever asked can, and this is where it says so.
---     Omitted, the path is recorded as a document.
function assets.read(path: string, kind?: string): string
    local size = loader.newArray("size_t[1]")
    local data = C.SDL_LoadFile(path, size)
    if data == nil then return nil end
    note(path, kind or "document")
    local bytes = loader.toBytes(data, tonumber(size[0]) as integer)
    C.SDL_free(data)
    return bytes
end

--- Every path this process has read or decoded, by the kind it was read as:
--- "image", "sound", "font", or "document" for bytes nothing named.
---
--- A path that failed to load is here too. Whatever asked for it named it, and
--- a file that would not decode is exactly the one worth noticing a change to.
--- @return The live table, so something consulting it periodically does not
---     copy it. Shared, so a caller that means to keep it does not also mean to
---     edit it.
function assets.loaded(): {string: string}
    return seen
end

--- Starts the loading worker.
function assets.install(luaPath?: string)
    worker = workers.spawn({
        source = DECODER,
        luaPath = luaPath or package.path,
    })
end

--- Whether the loading worker is running.
---
--- For a subsystem that loads an asset of its own and has no way of knowing
--- whether the game has started the worker yet.
function assets.installed(): boolean
    return worker ~= nil
end

--- Registers a handle and returns the id the worker will answer with.
local function queue(handle: Handle): integer
    if worker == nil then
        error("tecs: assets.install must run before loading", 3)
    end
    local id = nextId
    nextId = nextId + 1
    handle._id = id
    handle._shares = 1
    pending[id] = handle
    return id
end

--- Queues an image for loading and returns its handle immediately.
---
--- Two loads of one path that overlap share a decode and get the same handle,
--- because decoding the same PNG twice at once is work with no result the
--- first decode does not already have. They share the surface with it, so the
--- last of them to release is the one that frees. A load that starts after the
--- first has resolved decodes again: nothing here is a cache, and a handle
--- that has been released is not something to hand out a second time.
function assets.loadImage(path: string): Handle
    note(path, "image")
    local shared = inFlight[path]
    if shared ~= nil then
        shared._shares = shared._shares + 1
        return shared
    end

    local handle = setmetatable(
        { kind = "image", status = "loading", path = path } as Handle, HandleMT)
    local id = queue(handle)
    inFlight[path] = handle
    worker:send({ id = id, kind = "image", path = path })
    return handle
end

--- Queues a sound for loading and returns its handle immediately.
---
--- Whatever the mixer's decoders can read loads, so the format is the file's
--- business rather than the caller's.
---
--- `mode` is "resident", "stream", or "auto", and auto keeps anything shorter
--- than `streamMs` resident.
---
--- The library is initialised here rather than on the worker: `MIX_Init` is
--- documented as not thread safe, and doing it before the task is sent puts it
--- in order ahead of every decode without a lock.
function assets.loadSound(path: string, mode: string,
                          streamMs: integer): Handle
    note(path, "sound")
    if not sdl3mixer.init() then
        local failed = setmetatable({
            kind = "sound", status = "failed", path = path, _shares = 1,
            error = "cannot load " .. path,
        } as Handle, HandleMT)
        return failed
    end
    local handle = setmetatable(
        { kind = "sound", status = "loading", path = path } as Handle, HandleMT)
    local id = queue(handle)
    worker:send({
        id = id, kind = "sound", path = path,
        mode = mode, streamMs = streamMs,
    })
    return handle
end

--- Resolves one decode result into its handle.
local function complete(result: {string: any}): boolean
    local id = result.id as integer
    local handle = pending[id]
    pending[id] = nil
    if handle == nil then return false end
    if inFlight[handle.path] == handle then inFlight[handle.path] = nil end

    -- Released while the worker was still decoding. Ownership still arrives
    -- with the address, so what arrived is destroyed here rather than left for
    -- a handle nobody is holding any more.
    if handle.status == "released" then
        if result.surface ~= nil then
            C.SDL_DestroySurface(ffi.cast("SDL_Surface *",
                ffi.cast("uintptr_t", result.surface)) as loader.CValue)
        end
        if result.audio ~= nil then
            MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *",
                ffi.cast("uintptr_t", result.audio)) as loader.CValue)
        end
        return true
    end

    if result.error ~= nil then
        handle.status = "failed"
        handle.error = result.error as string
        return true
    end

    if handle.kind == "sound" then
        handle.resident = result.resident as boolean
        handle.durationMs = result.durationMs as integer
        if handle.resident then
            -- Ownership arrived with the address, exactly as it does for a
            -- surface. The mixer allocated this, so the mixer frees it.
            handle.audio = ffi.cast("MIX_Audio *",
                ffi.cast("uintptr_t", result.audio)) as loader.CValue
        end
        handle.status = "ready"
        return true
    end

    -- Ownership arrived with the address. The surface stays alive until the
    -- handle is released, because the pixels are what the caller came for.
    local surface = ffi.cast("SDL_Surface *",
        ffi.cast("uintptr_t", result.surface)) as loader.CValue
    handle._surface = surface
    handle.pixels = surface.pixels as loader.CValue
    handle.width = result.width as integer
    handle.height = result.height as integer
    handle.pitch = result.pitch as integer
    handle.status = "ready"
    return true
end

--- Frees what was decoded.
---
--- Called once whatever needed it has taken a copy, which for an image means
--- after it has been uploaded. A voice reads a clip where it lies, so a clip is
--- released when nothing will play it again. A track holds its own reference,
--- so releasing one that is still sounding is safe: the mixer drops it when
--- the last track using it does.
---
--- The handle ends at "released" whatever it held, so a caller handed one
--- after its decode has gone reads a status that says so rather than finding
--- the pixels nil and no reason for it. Releasing a load still in flight is
--- allowed: what the worker returns is destroyed on arrival.
---
--- Where several loads shared one decode, this releases one of them, and the
--- last one frees.
function Handle:release()
    if self.status == "released" then return end
    self._shares = self._shares - 1
    if self._shares > 0 then return end

    if inFlight[self.path] == self then inFlight[self.path] = nil end
    self.status = "released"

    if self.audio ~= nil then
        MIX.MIX_DestroyAudio(self.audio)
        self.audio = nil
        self.resident = false
    end
    if self._surface == nil then return end
    C.SDL_DestroySurface(self._surface)
    self._surface = nil
    self.pixels = nil
end

--- Takes finished decodes and uploads them. Call once per frame.
function assets.update(): integer
    if worker == nil then return 0 end
    local completed = 0
    while true do
        local result = worker:receive(0)
        if result == nil then break end
        if complete(result as {string: any}) then completed = completed + 1 end
    end
    return completed
end

--- Handles still waiting on the worker.
function assets.pending(): integer
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
end

--- Waits up to `ms` for one decode and takes it. Shared by everything here
--- that blocks, so there is one description of how a wait is spent.
local function pump(ms: number)
    if worker == nil then return end
    local result = worker:receive(ms)
    if result ~= nil then complete(result as {string: any}) end
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should poll `update` instead.
function assets.waitAll(timeoutMs?: number)
    local remaining = timeoutMs or 5000
    while assets.pending() > 0 and remaining > 0 do
        pump(16)
        remaining = remaining - 16
    end
end

-------------------------------------------------------------------------------
-- Awaiting a set
-------------------------------------------------------------------------------

--- A batch that hands each finished load to `finished`.
---
--- The callback is given once rather than at every drain, because what a batch
--- does with a load is a property of who made it and not of the moment it is
--- looked at.
function assets.batch<T>(
    finished: function(key: T, handle: Handle)
): Batch<T>
    if finished == nil then
        error("tecs: a batch needs something to hand finished loads to", 2)
    end
    return setmetatable({
        _finished = finished, _handles = {}, _keys = {},
    } as Batch<T>, BatchMT as metatable<Batch<T>>)
end

function Batch:add(handle: Handle, key: T)
    local at = #self._handles + 1
    self._handles[at] = handle
    self._keys[at] = key
end

function Batch:pending(): integer
    local waiting = 0
    local handles = self._handles
    for index = 1, #handles do
        if handles[index].status == "loading" then waiting = waiting + 1 end
    end
    return waiting
end

function Batch:resolve(): integer
    local waiting = #self._handles
    if waiting == 0 then return 0 end
    assets.update()

    -- Compacted in place: what is still in flight slides down over what has
    -- finished, and the tail is cleared once. Rebuilding the list instead
    -- would allocate a table on every frame with a load outstanding.
    local handles, keys = self._handles, self._keys
    local kept = 0
    local resolved = 0
    for index = 1, waiting do
        local handle = handles[index]
        local key = keys[index]
        if handle.status == "loading" then
            kept = kept + 1
            handles[kept] = handle
            keys[kept] = key
        else
            resolved = resolved + 1
            self._finished(key, handle)
        end
    end
    for index = kept + 1, waiting do
        handles[index] = nil
        keys[index] = nil
    end
    return resolved
end

function Batch:wait(timeoutMs?: number): integer
    local remaining = timeoutMs or 5000
    while self:pending() > 0 and remaining > 0 do
        pump(16)
        remaining = remaining - 16
    end
    return self:resolve()
end

--- Stops the loading worker.
function assets.shutdown()
    if worker == nil then return end
    worker:stop()
    worker = nil
    pending = {}
    inFlight = {}
end

return assets
