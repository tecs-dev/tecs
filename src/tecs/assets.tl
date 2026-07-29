--- Asynchronous asset loading.
---
--- **The formats an image may be in are PNG and JPEG.** Rust's `image` crate
--- is built with only those two decoders, because every enabled codec becomes
--- code a shipped binary carries. That is a decision the engine makes on a
--- game's behalf, so it is stated here rather than met as a failed load: an
--- atlas in any other format is converted at build time, not enabled at
--- compile time. Sound is the other way round, and
--- `Audio.decoders()` reports what the mixer actually linked.
---
--- Decoding a PNG is milliseconds of pure CPU work with no GPU involvement,
--- so it happens on a worker and the main thread only uploads. A load never
--- blocks a frame; a handle reports that it is still loading and callers draw
--- something else until it is not. Sound takes the same route for the same
--- reason: reading a file is a syscall a frame should not wait on.
---
--- The worker hands back the address of a Rust-owned image rather than copying
--- its pixels through a serialized message only to copy them again into
--- staging. Ownership transfers with it: whoever receives the address destroys
--- the image through the Rust ABI. A loaded sound crosses the same way, as the
--- address of its `MIX_Audio`.
---
--- Nothing here creates a GPU resource. Decoding and residency are separate
--- decisions: the renderer knows what layout its textures need, and an asset
--- that has been decoded is useful before anything has decided where it will
--- live.
---
--- A file whose contents something else knows how to interpret is not loaded
--- here at all. It goes through `filesystem.read`, which is synchronous and is
--- the only sanctioned way to get bytes out of the content root, because
--- content lives inside the package on Android and `io.open` does not reach
--- it. It answers bytes and never text: a Lua string carries a length, so an
--- image, an archive or a binary sidecar comes back whole, and a format that
--- is text is a decoder's opinion rather than that function's.
---
--- Reading a document is therefore two halves with nothing between them:
---
---     local tecs <const> = require("tecs")
---     local bytes <const> = tecs.filesystem.read(tecs.filesystem.assetPath("levels/1.json"))
---     local level <const> = tecs.data.decodeJSON(bytes)
---
--- `filesystem.assetPath` resolves against the content root and `read` answers nil for
--- a path with no file, so a game distinguishes an absent document from a
--- malformed one, which the decoder raises on. A parser for a binary format
--- sits in exactly that second position, over the same bytes.
---
--- What the two loads below do share with it is the record of what this
--- process has opened: each calls `filesystem.note` so the file watcher polls
--- one list rather than two, since the decode being recorded finishes on a
--- worker and a second list would be a second answer to the same question.

local ffi <const> = require("ffi")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")
local time <const> = require("tecs.platform.time")
local filesystem <const> = require("tecs.platform.filesystem")

local MIX <const> = sdl3mixer.C
local RUST <const> = rust.C

--- Runs on the worker. Decodes to a normalized layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local mixer = require("tecs.ffi.sdl3mixer")
local rust = require("tecs.ffi.rust")
local loader = require("tecs.ffi.loader")
local filesystem = require("tecs.platform.filesystem")
local workers = require("tecs.workers")

local MIX = mixer.C
local RUST = rust.C

local self = workers.current()

local function decodeImage(task)
    local bytes = filesystem.read(task.path, "image")
    if bytes == nil then
        return { id = task.id, error = "cannot decode " .. task.path }
    end

    local decoded = RUST.tecsImageDecode(
        ffi.cast("const uint8_t *", bytes),
        #bytes
    )
    if decoded == nil then
        local reason = loader.toString(RUST.tecsRustError())
        return {
            id = task.id,
            error = "cannot decode " .. task.path .. ": " .. reason,
        }
    end
    local width = tonumber(RUST.tecsImageWidth(decoded))
    local height = tonumber(RUST.tecsImageHeight(decoded))
    return {
        id = task.id,
        image = tonumber(ffi.cast("uintptr_t", decoded)),
        width = width,
        height = height,
        pitch = width * 4,
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

--- One asynchronous load, and what it decoded to.
---
--- Returned the moment a load is asked for, before anything has been decoded, so every
--- field but `kind`, `path` and `status` is nil until `status` reads "ready". Nothing here
--- advances on its own: a handle only changes when `assets.update`, `Batch:resolve`,
--- `Batch:wait` or `assets.waitAll` takes the worker's answer.
---
--- What a ready handle points at is owned by the handle and freed by `release`, so a caller
--- keeping the pixels or the clip past that is reading freed memory.
local record Handle
    --- What was asked for: "image" or "sound".
    kind: string
    --- "loading", "ready", "failed", or "released". The last is terminal and
    --- reached only through `release`, so something handed a handle whose
    --- decode it no longer owns is told that rather than finding nil where the
    --- pixels were.
    status: string

    --- The path the load was asked for, unchanged. Not resolved, so it is whatever the
    --- caller passed.
    path: string

    --- Decoded RGBA pixels, valid until `release`. Images only.
    pixels: loader.CValue

    --- Pixels across, not bytes. Images only.
    width: integer

    --- Pixel rows. Images only.
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
    --- A sentence for a log or a message, not something to match on. Nil in every other
    --- status, including "released".
    error: string

    --- Private. The Rust image allocation the pixels belong to, owned here and
    --- destroyed by `release`. Images only.
    _image: loader.CValue
    --- Id the worker answers with, so a release can find this in the queue.
    _id: integer
    --- Callers sharing this decode. One decode serves every load of a path
    --- that was already in flight, and the last release of it frees.
    _shares: integer
end

--- Asynchronous asset loading.
---
--- Images and sounds decode on one worker thread, which `install` starts and `shutdown`
--- ends; nothing loads before the first or after the second. A load returns a `Handle`
--- straight away and never blocks a frame, and a handle only moves off "loading" when
--- something on the main thread takes the worker's answer, which is what `update` is for.
---
--- Nothing here is a cache and nothing here touches the GPU: two loads of a path that do
--- not overlap decode twice, and what comes back is CPU-side pixels or a mixer clip that a
--- caller uploads or plays itself.
local record assets
    --- One asynchronous load.
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
        --- Private. The callback given at construction, called once per load that leaves
        --- "loading", whether it succeeded or failed.
        _finished: function(key: T, handle: Handle)

        --- Private. Loads not yet handed to the callback, compacted in place as they
        --- resolve, so an index is not stable across a `resolve`.
        _handles: {Handle}

        --- Private. The caller's values, held at the same indexes as `_handles`.
        _keys: {T}

        --- Adds a load to wait on, with the caller's value beside it.
        ---
        --- Adding one handle twice waits on it twice and calls back twice. Adding one
        --- already finished is allowed; the next `resolve` hands it over.
        ---
        --- @param handle Held rather than copied, so the batch sees whatever the
        ---     worker settles it to. Nothing is started here: the load was already
        ---     in flight before it arrived.
        --- @param key The caller's own value, handed back beside the handle at
        ---     `resolve` so the callback knows which load it is looking at. Not
        ---     read or compared by the batch, so duplicates are fine.
        add: function(self, handle: Handle, key: T)

        --- Loads still in flight.
        ---
        --- @return How many of the batch's handles read "loading" right now. Counts what is
        ---     still unresolved, so it drops to zero a `resolve` before the batch empties.
        pending: function(self): integer

        --- Hands every finished load to the callback and drops it.
        ---
        --- Takes whatever the worker has answered first, so a subsystem
        --- polling only its own batch still sees its loads finish.
        ---
        --- The callback gets a failed load as well as a ready one; check `handle.status`
        --- rather than assuming pixels. It must not add to this batch, which is being
        --- compacted underneath it.
        --- @return How many were resolved by this call.
        resolve: function(self): integer

        --- Blocks until nothing is in flight, then resolves.
        ---
        --- For startup, shutdown and tests. A frame calls `resolve` instead.
        --- @param timeoutMs Milliseconds to wait. Defaults to 5000.
        --- @return How many were resolved. A timeout is not an error and is not reported:
        ---     the count is simply short and the rest stay in the batch, so check
        ---     `pending` after this rather than trusting the return.
        wait: function(self, timeoutMs?: number): integer
    end

    --- Whether the loading worker is running.
    ---
    --- For a subsystem that loads an asset of its own and has no way of knowing whether the
    --- game has started the worker yet.
    ---
    --- @return Whether the worker exists, which is a fact about the process rather
    ---     than about any world. False means a load raises rather than queueing,
    ---     so this is the guard rather than an optimization.
    installed: function(): boolean
end

local type Batch = assets.Batch

local HandleMT <const>: metatable<Handle> = {__index = Handle}
local BatchMT <const>: metatable<Batch<any>> = {__index = Batch}

local pending: {integer: Handle} = {}
--- Image decodes that have been queued and not yet answered, by path. A second
--- load of a path in this table joins the first rather than queueing a decode
--- of the same file beside it.
local inFlight: {string: Handle} = {}
local nextId = 1
local worker: workers.Worker = nil

--- Starts the loading worker.
---
--- Installing twice is installing once. Spawning unconditionally would leave
--- the first thread running with both its channels and nothing reading them,
--- and every decode already queued would answer into a channel that has been
--- dropped, so a load in flight across the second call would never resolve.
---
--- @param luaPath `package.path` for the worker's own state, which shares no loaded modules
---     with this one. Defaults to this state's, which is what makes the worker resolve the
---     same modules the game does.
function assets.install(luaPath?: string)
    if worker ~= nil then
        return
    end
    worker = workers.spawn({
        source = DECODER,
        luaPath = luaPath or package.path,
    })
end

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
---
--- @param path PNG or JPEG; no other format is compiled in, and one that is not either
---     fails the decode rather than being refused here.
--- @return A handle at "loading", never nil. Raises instead when `install` has not run.
---     Failures reach it through `status`, not through this call: a missing file is a
---     handle that turns "failed" once the worker has looked.
function assets.loadImage(path: string): Handle
    filesystem.note(path, "image")
    local shared = inFlight[path]
    if shared ~= nil then
        shared._shares = shared._shares + 1
        return shared
    end

    local handle = setmetatable({kind = "image", status = "loading", path = path} as Handle, HandleMT)
    local id = queue(handle)
    inFlight[path] = handle
    worker:send({id = id, kind = "image", path = path})
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
--- The library is initialized here rather than on the worker: `MIX_Init` is
--- documented as not thread safe, and doing it before the task is sent puts it
--- in order ahead of every decode without a lock.
---
--- Two overlapping loads of one path do not share, unlike images: each gets its own clip.
---
--- @param mode "resident", "stream" or "auto". Anything else is treated as "stream".
--- @param streamMs The boundary "auto" decides on, in milliseconds. Read only under
---     "auto", and a file whose length the container cannot state streams whatever it says.
--- @return A handle at "loading", or one already at "failed" when the mixer could not be
---     initialized, which is the one failure reported without waiting for the worker.
function assets.loadSound(path: string, mode: string, streamMs: integer): Handle
    filesystem.note(path, "sound")
    if not sdl3mixer.init() then
        local failed = setmetatable({
            kind = "sound",
            status = "failed",
            path = path,
            _shares = 1,
            error = "cannot load " .. path,
        } as Handle, HandleMT)
        return failed
    end
    local handle = setmetatable({kind = "sound", status = "loading", path = path} as Handle, HandleMT)
    local id = queue(handle)
    worker:send({
        id = id,
        kind = "sound",
        path = path,
        mode = mode,
        streamMs = streamMs,
    })
    return handle
end

--- Resolves one decode result into its handle.
local function complete(result: {string: any}): boolean
    local id = result.id as integer
    local handle = pending[id]
    pending[id] = nil
    if handle == nil then
        return false
    end
    if inFlight[handle.path] == handle then
        inFlight[handle.path] = nil
    end

    -- Released while the worker was still decoding. Ownership still arrives
    -- with the address, so what arrived is destroyed here rather than left for
    -- a handle nobody is holding any more.
    if handle.status == "released" then
        if result.image ~= nil then
            RUST.tecsImageDestroy(ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue)
        end
        if result.audio ~= nil then
            MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue)
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
            handle.audio = ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue
        end
        handle.status = "ready"
        return true
    end

    -- Ownership arrived with the address. The image stays alive until the
    -- handle is released, because the pixels are what the caller came for.
    local image = ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue
    handle._image = image
    handle.pixels = RUST.tecsImagePixels(image) as loader.CValue
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
---
--- Calling it on an already released handle does nothing, so a shutdown path need not know
--- whether something else got there first.
function Handle:release()
    if self.status == "released" then
        return
    end
    self._shares = self._shares - 1
    if self._shares > 0 then
        return
    end

    if inFlight[self.path] == self then
        inFlight[self.path] = nil
    end
    self.status = "released"

    if self.audio ~= nil then
        MIX.MIX_DestroyAudio(self.audio)
        self.audio = nil
        self.resident = false
    end
    if self._image == nil then
        return
    end
    RUST.tecsImageDestroy(self._image)
    self._image = nil
    self.pixels = nil
end

--- Takes finished decodes and uploads them. Call once per frame.
---
--- Polls, never blocks, and drains everything the worker has answered rather than one
--- result. Handles do not change state without this, so a game that stops calling it has
--- loads that stay "loading" forever.
---
--- @return How many handles moved off "loading" this call, which is zero when nothing has
---     finished and also zero when no worker is installed.
function assets.update(): integer
    if worker == nil then
        return 0
    end
    local completed = 0
    while true do
        local result = worker:receive(0)
        if result == nil then
            break
        end
        if complete(result as {string: any}) then
            completed = completed + 1
        end
    end
    return completed
end

--- Handles still waiting on the worker.
---
--- @return Every load in flight in this process, not one caller's. Counted by walking the
---     set, so it is fine per frame and not per entity.
function assets.pending(): integer
    local count = 0
    for _ in pairs(pending) do
        count = count + 1
    end
    return count
end

--- Waits up to `ms` for one decode and takes it. Shared by everything here
--- that blocks, so there is one description of how a wait is spent.
local function pump(ms: number)
    if worker == nil then
        return
    end
    local result = worker:receive(ms)
    if result ~= nil then
        complete(result as {string: any})
    end
end

--- Milliseconds one blocking pump spends when nothing has arrived yet.
local PUMP_MS <const> = 16

--- Milliseconds a wait spends when the caller names nothing.
local DEFAULT_WAIT_MS <const> = 5000

--- Spends up to `ms` of wall clock pumping while `waiting` answers true.
---
--- Wall clock rather than a count of pumps. `pump` returns as soon as one
--- message arrives, so subtracting its nominal size whatever it cost turns
--- "wait 5000 ms" into "wait for at most 312 messages", and against a worker
--- with a queue of answers ready that is a wait that gives up almost at once.
local function spend(ms: number, waiting: function(): boolean)
    local deadline = time.now() * 1000.0 + ms
    while waiting() do
        local remaining = deadline - time.now() * 1000.0
        if remaining <= 0 then
            break
        end
        pump(remaining < PUMP_MS and remaining or PUMP_MS)
    end
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should poll `update` instead.
---
--- @param timeoutMs Wall-clock milliseconds, defaulting to 5000. Running out is not an
---     error and is not reported, so read `assets.pending` afterwards to tell the two
---     endings apart.
function assets.waitAll(timeoutMs?: number)
    spend(timeoutMs or DEFAULT_WAIT_MS, function(): boolean return assets.pending() > 0 end)
end

-------------------------------------------------------------------------------
-- Awaiting a set
-------------------------------------------------------------------------------

--- A batch that hands each finished load to `finished`.
---
--- The callback is given once rather than at every drain, because what a batch
--- does with a load is a property of who made it and not of the moment it is
--- looked at.
---
--- @param finished Called once per load that leaves "loading", ready or failed alike, on
---     the thread that drains the batch. Required; nil raises.
--- @return An empty batch. Nothing registers it, so a batch nobody resolves simply holds
---     its handles.
function assets.newBatch<T>(finished: function(key: T, handle: Handle)): Batch<T>
    if finished == nil then
        error("tecs: a batch needs something to hand finished loads to", 2)
    end
    return setmetatable({
        _finished = finished,
        _handles = {},
        _keys = {},
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
        if handles[index].status == "loading" then
            waiting = waiting + 1
        end
    end
    return waiting
end

function Batch:resolve(): integer
    local waiting = #self._handles
    if waiting == 0 then
        return 0
    end
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
    spend(timeoutMs or DEFAULT_WAIT_MS, function(): boolean return self:pending() > 0 end)
    return self:resolve()
end

--- Stops the loading worker.
---
--- Blocks until the thread has exited. Loads still in flight are dropped and their handles
--- stay at "loading" forever, so drain with `waitAll` first if their results are wanted.
--- Releasing a handle that is already ready still works afterwards; this frees nothing.
function assets.shutdown()
    if worker == nil then
        return
    end
    worker:stop()
    worker = nil
    pending = {}
    inFlight = {}
end

return assets
