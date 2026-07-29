--- Asynchronous asset loading.
---
--- A load answers with a `Future` straight away, and the future settles only
--- when something on the main thread takes the worker's answer. What it settles
--- to is a value: an `Image` carrying pixels or a `Sound` carrying a clip. So a
--- load is transformed, joined and waited on with the combinators every other
--- asynchronous thing in this tree uses:
---
--- ```teal
--- tecs.assets.loadImage("sprites/hero.png")
---     :map(function(image: tecs.assets.Image): tecs.Sprite
---         -- registerImage releases the pixels; the array holds them now.
---         return (renderer:registerImage(image))
---     end)
---     :onSettle(function(sprite: tecs.Future<tecs.Sprite>)
---         if sprite.status == "ready" then
---             world:spawn(tecs.Transform(100, 100), sprite.value)
---         end
---     end)
--- ```
---
--- Waiting on several is `Future.all`, which settles once every one of them
--- has, and a set of them is joined without anything here knowing about sets.
---
--- The split between the two halves of a load is the status line, and it is one
--- sentence: **before it lands you cancel the future, after it lands you release
--- the payload.** A cancel gives up this caller's interest in a decode; a
--- release gives up this caller's hold on the pixels or the clip, and the last
--- release is the one that frees. Reading either after that is freed memory.
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
--- blocks a frame; the future stays pending and callers draw
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
--- ```teal
--- local bytes <const> = tecs.filesystem.read(tecs.filesystem.assetPath("levels/1.json"))
--- local level <const> = tecs.data.decodeJSON(bytes)
--- ```
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
local filesystem <const> = require("tecs.platform.filesystem")
local Future <const> = require("tecs.Future")

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

--- Decoded pixels, and the hold a caller has on them.
---
--- What a `loadImage` future settles to. The pixels are refcounted rather than
--- owned outright, because two loads of one path that overlap share a decode:
--- each caller holds the same `Image` and the last of them to release is the
--- one that frees. Reading `pixels` after that is reading freed memory, which
--- is why a released image reads nil there rather than looking uploadable.
local record Image
    --- The path the load was asked for, unchanged. Not resolved, so it is
    --- whatever the caller passed.
    path: string

    --- Decoded RGBA pixels, valid until the last `release`. Nil afterwards.
    pixels: loader.CValue

    --- Pixels across, not bytes.
    width: integer

    --- Pixel rows.
    height: integer

    --- Row stride in bytes, which a decoder may pad beyond width * 4.
    pitch: integer

    --- Private. The Rust image allocation the pixels belong to, owned here and
    --- destroyed by the last `release`.
    _image: loader.CValue

    --- Private. Callers holding these pixels. One per load of the path whose
    --- future actually settled, so a caller that canceled before settlement is
    --- not counted and one that joined an in-flight decode is.
    _refs: integer

    --- Gives up this caller's hold on the pixels, and frees at the last.
    ---
    --- Called once whatever needed them has taken a copy, which for an image
    --- means after it has been uploaded. Where several loads shared one decode
    --- this releases one of them.
    ---
    --- Releasing an image already down to nothing does nothing, so a shutdown
    --- path need not know whether something else got there first.
    release: function(self: Image)
end

--- A loaded clip, and the hold a caller has on it.
---
--- What a `loadSound` future settles to. Two overlapping loads of one path do
--- not share, unlike images, so a `Sound` normally has one holder; the count is
--- here so that releasing twice frees once rather than twice.
local record Sound
    --- The path the load was asked for, unchanged.
    path: string

    --- The loaded clip, valid until the last `release`. Nil for one that
    --- streams, which holds nothing, and nil once released.
    audio: loader.CValue

    --- Whether the decoded audio is held in memory. False for a clip each voice
    --- reads from the file for itself.
    resident: boolean

    --- Length in milliseconds, or -1 when the container cannot say.
    durationMs: integer

    --- Private. Callers holding this clip.
    _refs: integer

    --- Gives up this caller's hold on the clip, and frees at the last.
    ---
    --- A voice reads a clip where it lies, so a clip is released when nothing
    --- will play it again. A track holds its own reference, so releasing one
    --- that is still sounding is safe: the mixer drops it when the last track
    --- using it does.
    ---
    --- Releasing a clip already down to nothing does nothing.
    release: function(self: Sound)
end

--- Asynchronous asset loading.
---
--- Images and sounds decode on one worker thread, which `install` starts and `shutdown`
--- ends; nothing loads before the first or after the second. A load returns a `Future`
--- straight away and never blocks a frame, and that future settles only when something on
--- the main thread takes the worker's answer, which is what `update` is for.
---
--- Nothing here is a cache and nothing here touches the GPU: two loads of a path that do
--- not overlap decode twice, and what comes back is CPU-side pixels or a mixer clip that a
--- caller uploads or plays itself.
local record assets
    --- Decoded pixels, and the hold a caller has on them.
    Image: Image

    --- A loaded clip, and the hold a caller has on it.
    Sound: Sound

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

local ImageMT <const>: metatable<Image> = {__index = Image}
local SoundMT <const>: metatable<Sound> = {__index = Sound}

--- One decode the worker has been given and has not answered for.
---
--- The root future is here rather than handed out. Callers get futures derived
--- from it, which is what lets several of them share one decode without sharing
--- one object: see `loadImage`.
local record Entry
    id: integer
    --- "image" or "sound", which decides what the answer is built into.
    kind: string
    path: string
    root: Future<any>
end

local pending: {integer: Entry} = {}
--- The same entries by root future, so the source's cancel hook can start from
--- the future whose last watcher has gone.
local byFuture: {Future<any>: Entry} = {}
--- Counted rather than walked, because `waitAll` reads it in a loop.
local pendingCount = 0
--- Image decodes that have been queued and not yet answered, by path. A second
--- load of a path in this table joins the first rather than queueing a decode
--- of the same file beside it.
local inFlight: {string: Future<any>} = {}
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

-------------------------------------------------------------------------------
-- Settling
-------------------------------------------------------------------------------

--- Settles when nothing is in flight, so `waitAll` is one `Future:wait` rather
--- than a wall-clock loop written again here.
---
--- Created on demand and dropped once it settles, because a wait that ran out
--- of time leaves it pending and the next one joins the same drain.
local idle: Future<integer> = nil

--- Forgets a decode the worker has answered for.
local function retire(entry: Entry)
    pending[entry.id] = nil
    byFuture[entry.root] = nil
    pendingCount = pendingCount - 1

    -- Dropped at settlement rather than left for the next load of the path.
    -- `listen` stores a link's closure on the upstream and that closure holds
    -- the derived future, so a root still reachable through this table would
    -- keep every future ever derived from it alive for the life of the process.
    -- Nothing shows that until it is measured, which is why it is said here.
    if inFlight[entry.path] == entry.root then
        inFlight[entry.path] = nil
    end
end

--- Destroys what the worker sent for a decode nobody is waiting on any more.
---
--- Ownership transfers with the address whether or not anyone still wants it,
--- so what arrived is freed here rather than leaked to a future that has
--- already settled "canceled".
local function discard(result: {string: any})
    if result.image ~= nil then
        RUST.tecsImageDestroy(ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue)
    end
    if result.audio ~= nil then
        MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue)
    end
end

--- Settles one decode result into the future it was queued for.
local function settleResult(result: {string: any}): boolean
    local entry = pending[result.id as integer]
    if entry == nil then
        return false
    end
    retire(entry)
    local root = entry.root

    -- Canceled while the worker was still decoding: every caller gave up before
    -- this arrived.
    if root.status ~= "pending" then
        discard(result)
        return true
    end

    if result.error ~= nil then
        root:fail(result.error as string)
        return true
    end

    if entry.kind == "sound" then
        local sound = setmetatable({
            path = entry.path,
            resident = result.resident as boolean,
            durationMs = result.durationMs as integer,
            -- One holder, because sound does not dedupe: this future has one
            -- caller and no link of the caller's can add another.
            _refs = 1,
        } as Sound, SoundMT)
        if sound.resident then
            -- Ownership arrived with the address, exactly as it does for a
            -- surface. The mixer allocated this, so the mixer frees it.
            sound.audio = ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue
        end
        root:complete(sound)
        return true
    end

    -- Ownership arrived with the address. The image stays alive until the last
    -- caller releases it, because the pixels are what they came for.
    local allocation = ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue
    local image = setmetatable({
        path = entry.path,
        _image = allocation,
        pixels = RUST.tecsImagePixels(allocation) as loader.CValue,
        width = result.width as integer,
        height = result.height as integer,
        pitch = result.pitch as integer,
        -- Zero, and counted up by each surviving caller's own link below. A
        -- caller that canceled first never runs one, which is what makes this
        -- exact rather than optimistic.
        _refs = 0,
    } as Image, ImageMT)
    root:complete(image)
    return true
end

--- Settles one decode result, and ends a process-wide drain that this emptied.
---
--- The drain is answered after the settlement rather than inside it, because a
--- listener the settlement runs is free to start another load and a `waitAll`
--- that returned before it did would have left one outstanding.
---
--- @return Whether a queued decode was answered, which is false for a result
---     arriving after `shutdown` dropped what it belonged to.
local function complete(result: {string: any}): boolean
    local answered = settleResult(result)
    if pendingCount == 0 and idle ~= nil then
        -- Cleared before it settles, so a load started from a listener on it
        -- opens a fresh drain rather than joining one that has already answered.
        local settling = idle
        idle = nil
        settling:complete(0)
    end
    return answered
end

function Image:release()
    -- Guarded rather than allowed to go negative: a shutdown path that releases
    -- what something else already released must free once, not twice.
    if self._refs <= 0 then
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    if self._image == nil then
        return
    end
    RUST.tecsImageDestroy(self._image)
    self._image = nil
    self.pixels = nil
end

function Sound:release()
    if self._refs <= 0 then
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    if self.audio ~= nil then
        MIX.MIX_DestroyAudio(self.audio)
        self.audio = nil
        self.resident = false
    end
end

-------------------------------------------------------------------------------
-- The source
-------------------------------------------------------------------------------

--- Milliseconds one blocking slice of a wait spends.
local SLICE_MS <const> = 16

--- Milliseconds a wait spends when the caller names nothing.
local DEFAULT_WAIT_MS <const> = 5000

--- What drives every future this module hands out.
---
--- `poll` and `advance` are the same receive with a different budget, which is
--- the whole of what a future needs from a worker channel.
local record Loader
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Loader): integer
    advance: function(self: Loader, ms: number): integer
    cancel: function(self: Loader, future: Future<any>)
end

local LoaderMT <const>: metatable<Loader> = {__index = Loader}

function Loader:poll(): integer
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

function Loader:advance(ms: number): integer
    if worker == nil then
        return 0
    end
    local result = worker:receive(ms)
    if result == nil then
        return 0
    end
    return complete(result as {string: any}) and 1 or 0
end

--- Gives up a decode whose last caller has gone.
---
--- The worker takes its tasks off a channel and cannot be told to drop one, so
--- the decode runs to the end whatever happens here. What this does is release
--- the path, so a later load of it starts a fresh decode rather than joining
--- one nobody wants; the entry stays queued, and `complete` destroys the
--- address when it arrives because ownership transfers with it either way.
function Loader:cancel(future: Future<any>)
    local entry = byFuture[future]
    if entry == nil then
        return
    end
    if inFlight[entry.path] == future then
        inFlight[entry.path] = nil
    end
end

local pump <const> = setmetatable({
    -- Both live here rather than in `Future`, which is what lets a decode keep
    -- a shorter default than a child process without a second convention.
    sliceMs = SLICE_MS,
    defaultWaitMs = DEFAULT_WAIT_MS,
} as Loader, LoaderMT)

local source <const> = pump as Future.Source

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

--- A root future the loader owns and never hands out.
---
--- `Future.pending` counts whoever created a future as one of its watchers,
--- which is right for a caller holding what it created and wrong here. The
--- loader is the producer: the root lives in `inFlight` and every consumer of
--- it is some caller's own derived future, so a hold of the loader's own would
--- be a watcher nothing ever gives up and the decode could never reach zero and
--- be abandoned.
local function newRoot(): Future<any>
    local root = Future.pending(source) as Future<any>
    root._watchers = 0
    return root
end

--- Registers a decode, and answers the future it will settle and the id the
--- worker will answer with.
local function queue(kind: string, path: string): Future<any>, integer
    if worker == nil then
        error("tecs: assets.install must run before loading", 3)
    end
    local id = nextId
    nextId = nextId + 1
    local root = newRoot()
    local entry: Entry = {id = id, kind = kind, path = path, root = root}
    pending[id] = entry
    byFuture[root] = entry
    pendingCount = pendingCount + 1
    return root, id
end

--- Counts one more holder of the decoded pixels, and answers them.
---
--- One per surviving caller of a shared decode: it is the transform of that
--- caller's own link, so it runs exactly when that caller's future settles
--- "ready" and never when the caller canceled first.
local function claim(image: Image): Image
    image._refs = image._refs + 1
    return image
end

--- Queues an image for loading and answers a future for it immediately.
---
--- Two loads of one path that overlap share a decode, because decoding the same
--- PNG twice at once is work with no result the first decode does not already
--- have. They share the `Image` with it, so the last of them to release is the
--- one that frees, and each of them holds a future of its own, so one canceling
--- is invisible to the others. A load that starts after the first has settled
--- decodes again: nothing here is a cache.
---
--- @param path PNG or JPEG; no other format is compiled in, and one that is not either
---     fails the decode rather than being refused here.
--- @return A pending future, never nil. Raises instead when `install` has not run.
---     Failures reach it as a failed settlement, not through this call: a missing file
---     is a future that fails once the worker has looked. Canceling it gives up this
---     caller's interest in the decode, and the last caller to do so abandons it.
function assets.loadImage(path: string): Future<Image>
    filesystem.note(path, "image")
    local shared = inFlight[path]
    if shared == nil then
        local root, id = queue("image", path)
        inFlight[path] = root
        worker:send({id = id, kind = "image", path = path})
        shared = root
    end
    -- Derived rather than the root itself. Two callers holding one object would
    -- make "the future the caller holds" ambiguous as a map key, which three
    -- subsystems in this tree already use it as, and would leave this module
    -- with no way to count how many of them survived to settlement.
    return shared:map(claim) as Future<Image>
end

--- Queues a sound for loading and answers a future for it immediately.
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
--- Two overlapping loads of one path do not share, unlike images: each gets its
--- own clip, because that is what `MIX_LoadAudio` produces. So this answers the
--- root future rather than a link over one, and the `Sound` it settles to has
--- exactly one holder.
---
--- @param mode "resident", "stream" or "auto". Anything else is treated as "stream".
--- @param streamMs The boundary "auto" decides on, in milliseconds. Read only under
---     "auto", and a file whose length the container cannot state streams whatever it says.
--- @return A pending future, or one already failed when the mixer could not be
---     initialized, which is the one failure reported without waiting for the worker.
function assets.loadSound(path: string, mode: string, streamMs: integer): Future<Sound>
    filesystem.note(path, "sound")
    if not sdl3mixer.init() then
        return Future.failed("cannot load " .. path)
    end
    local root, id = queue("sound", path)
    -- The one caller is the watcher `Future.pending` counts, so this root is
    -- handed out as it is: canceling it takes the count to zero and abandons
    -- the decode, which is what the only caller giving up should do.
    root._watchers = 1
    worker:send({
        id = id,
        kind = "sound",
        path = path,
        mode = mode,
        streamMs = streamMs,
    })
    return root as Future<Sound>
end

-------------------------------------------------------------------------------
-- Draining
-------------------------------------------------------------------------------

--- Takes finished decodes and settles their futures. Call once per frame.
---
--- Polls, never blocks, and drains everything the worker has answered rather than one
--- result. Nothing settles without this, so a game that stops calling it has loads that
--- stay pending forever.
---
--- @return How many decodes settled this call, which is zero when nothing has
---     finished and also zero when no worker is installed.
function assets.update(): integer
    return pump:poll()
end

--- Loads still waiting on the worker.
---
--- @return Every load in flight in this process, not one caller's. A decode every
---     caller has canceled is still counted until the worker answers for it, because
---     the address it sends still has to be taken and destroyed.
function assets.pending(): integer
    return pendingCount
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should poll `update` instead.
---
--- Not a join over futures a caller holds, and no join expresses it: this waits
--- on every load in this process, including ones a subsystem the caller has
--- never heard of started, which is what a reload or a startup path wants.
---
--- @param timeoutMs Wall-clock milliseconds, defaulting to 5000. Running out is not an
---     error and is not reported, so read `assets.pending` afterwards to tell the two
---     endings apart.
function assets.waitAll(timeoutMs?: number)
    if pendingCount == 0 then
        return
    end
    if idle == nil then
        idle = Future.pending(source) as Future<integer>
    end
    idle:wait(timeoutMs)
end

--- Stops the loading worker.
---
--- Blocks until the thread has exited. Loads still in flight are dropped and their futures
--- stay pending forever, so drain with `waitAll` first if their results are wanted.
--- Releasing an `Image` or a `Sound` that already settled still works afterwards; this
--- frees nothing.
function assets.shutdown()
    if worker == nil then
        return
    end
    worker:stop()
    worker = nil
    pending = {}
    byFuture = {}
    inFlight = {}
    pendingCount = 0
    if idle ~= nil then
        -- The drain it was waiting for will not finish, and saying so is more
        -- truthful than settling it as though it had.
        local abandoned = idle
        idle = nil
        abandoned:abandon("the loading worker was shut down")
    end
end

return assets
