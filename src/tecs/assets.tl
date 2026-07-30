--[=[
Reads bytes and decodes images and sounds on a worker.

Each load returns a [`Future`](tealdoc:tecs.Future) immediately:

```teal no-format
return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        tecs.assets.loadImage(
            tecs.io.files.assetPath("sprites/hero.png")
        )
            :map(function(image: tecs.assets.Image): tecs.gfx.Sprite
                return app.renderer:registerImage(image)
            end)
            :onSettle(function(sprite: tecs.Future<tecs.gfx.Sprite>)
                if sprite.status == "ready" then
                    world:spawn(
                        tecs.Transform(100, 100),
                        sprite.value,
                        tecs.gfx.Renderable()
                    )
                end
            end)
    end,
})
```

The loader decodes pixels but creates no GPU resource. The renderer decides
texture residency. Audio follows the same split between decoded clips and
voices.

## Lifetime

[`Application`](tealdoc:tecs.Application) installs, updates, and shuts down the process-wide worker.
Headless code must call `install`, pump with `update` or `waitAll`, then call
`shutdown`. Drain wanted results before shutdown because in-flight futures
otherwise remain pending.

Cancel a pending future to release one caller's interest. Release a ready
payload when its consumer takes ownership. The final release frees the decoded
memory.

Overlapping image loads for one path share a decode. Each caller receives its
own future and a hold on the same image. A later load after settlement decodes
again. Sound loads never share.

`loadBytes` reads a complete file without interpreting it. Image loads accept
PNG and JPEG. `tecs.audio.decoders()` reports the sound formats linked into the
current build. Sound mode `"resident"` decodes the complete clip, `"stream"`
opens a source for each voice, and `"auto"` chooses from the duration threshold.

Use `Future.all` to join independent loads. Release each ready payload after
its consumer takes ownership.
]=]

local ffi <const> = require("ffi")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")
local files <const> = require("tecs.io.files")
local Future <const> = require("tecs.Future")

local MIX <const> = sdl3mixer.C
local RUST <const> = rust.C

--- Runs on the worker. Decodes to a normalized layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local mixer = require("tecs.ffi.sdl3mixer")
local rust = require("tecs.ffi.rust")
local loader = require("tecs.ffi.loader")
local files = require("tecs.io.files")
local workers = require("tecs.workers")

local MIX = mixer.C
local RUST = rust.C

local self = workers.current()

local function decodeImage(task)
    local bytes = files.read(task.path, "image")
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

local function readBytes(task)
    local bytes = files.read(task.path)
    if bytes == nil then
        return {id = task.id, error = "cannot read " .. task.path}
    end
    return {id = task.id, bytes = bytes}
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
    elseif task.kind == "bytes" then
        self:send(readBytes(task))
    else
        self:send(decodeImage(task))
    end
end
]==]

--- Represents decoded pixels and the caller's hold on them.
---
--- What a `loadImage` future settles to. Reference counts govern the pixels rather than
--- owned outright, because two loads of one path that overlap share a decode:
--- each caller holds the same [`Image`](tealdoc:tecs.assets.Image), and the last caller to release it
--- one that frees. Reading `pixels` after that is reading freed memory, which
--- is why a released image reads nil there rather than looking uploadable.
local record Image
    --- Read-only. Contains the requested path unchanged. The loader does not resolve it, so it is
    --- whatever the caller passed.
    path: string

    --- Read-only. Contains decoded RGBA pixels until the last `release`, then
    --- becomes nil.
    pixels: loader.CValue

    --- Read-only. Reports the width in pixels.
    width: integer

    --- Read-only. Reports the height in pixel rows.
    height: integer

    --- Read-only. Reports the row stride in bytes, which a decoder may pad
    --- beyond `width * 4`.
    pitch: integer

    --- Engine-owned. Stores the decoded image allocation until the last
    --- `release`. Ordinary game code should ignore this field.
    _image: loader.CValue

    --- Engine-owned. Counts callers holding these pixels. Ordinary game code
    --- should ignore this field. The count includes one per load of the path whose
    --- future actually settled, so a caller that canceled before settlement is
    --- not counted and one that joined an in-flight decode is.
    _refs: integer

    --- Gives up this caller's hold on the pixels, and frees at the last.
    ---
    --- Called once whatever needed them has taken a copy, which for an image
    --- means after the caller uploads it. Where several loads shared one decode,
    --- this releases one of them.
    ---
    --- Releasing an image already down to nothing does nothing, so a shutdown
    --- path need not know whether something else got there first.
    release: function(self: Image)
end

--- Represents a loaded clip and the caller's hold on it.
---
--- What a `loadSound` future settles to. Two overlapping loads of one path do
--- not share, unlike images, so a [`Sound`](tealdoc:tecs.assets.Sound)
--- normally has one holder; the count is
--- here so that releasing twice frees once rather than twice.
local record Sound
    --- Read-only. Contains the requested path unchanged.
    path: string

    --- Read-only. Contains the loaded clip until the last `release`. It is nil for one that
    --- streams, which holds nothing, and nil once released.
    audio: loader.CValue

    --- Read-only. Reports whether memory holds the decoded audio. It is false for a clip each voice
    --- reads from the file for itself.
    resident: boolean

    --- Read-only. Reports the length in milliseconds, or -1 when the container
    --- cannot say.
    durationMs: integer

    --- Engine-owned. Counts callers holding this clip. Ordinary game code
    --- should ignore this field.
    _refs: integer

    --- Gives up this caller's hold on the clip, and frees at the last.
    ---
    --- A voice reads a clip where it lies, so release a clip when nothing
    --- will play it again. A track holds its own reference, so releasing one
    --- that is still sounding is safe: the mixer drops it when the last track
    --- using it does.
    ---
    --- Releasing a clip already down to nothing does nothing.
    release: function(self: Sound)
end

local record assets
    --- Read-only. Exposes the decoded image type.
    Image: Image

    --- Read-only. Exposes the loaded sound type.
    Sound: Sound

    --- Reports whether the loading worker is running.
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

--- One load the worker has been given and has not answered for.
---
--- The root future is here rather than handed out. Callers get futures derived
--- from it, which is what lets several of them share one decode without sharing
--- one object: see `loadImage`.
local record Entry
    id: integer
    --- "bytes", "image" or "sound", which decides what the answer is built into.
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
--- Tracks queued image decodes that have not answered yet, by path. A second
--- load of a path in this table joins the first rather than queueing a decode
--- of the same file beside it.
local imagesInFlight: {string: Future<any>} = {}
--- Tracks queued byte reads on the same terms. Separate from image decodes
--- because the same path may be requested in both representations at once.
local bytesInFlight: {string: Future<any>} = {}
local nextId = 1
local worker: workers.Worker = nil

--- Starts the loading worker.
---
--- Installing twice is installing once. Spawning unconditionally would leave
--- the first thread running with both its channels and nothing reading them,
--- and every queued decode would answer into an abandoned channel, so a load
--- in flight across the second call would never resolve.
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

--- Forgets a load the worker has answered for.
local function retire(entry: Entry)
    pending[entry.id] = nil
    byFuture[entry.root] = nil
    pendingCount = pendingCount - 1

    -- Dropped at settlement rather than left for the next load of the path.
    -- `listen` stores a link's closure on the upstream and that closure holds
    -- the derived future, so a root still reachable through this table would
    -- keep every future ever derived from it alive for the life of the process.
    -- Nothing shows that until it is measured, which is why it is said here.
    local shared = entry.kind == "image" and imagesInFlight or entry.kind == "bytes" and bytesInFlight or nil
    if shared ~= nil and shared[entry.path] == entry.root then
        shared[entry.path] = nil
    end
end

--- Destroys what the worker sent for a decode nobody is waiting on any more.
---
--- Ownership transfers with the address whether or not anyone still wants it,
--- so this function frees the result instead of leaking it to a future that has
--- already settled "canceled".
local function discard(result: {string: any})
    if result.image ~= nil then
        RUST.tecsImageDestroy(ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue)
    end
    if result.audio ~= nil then
        MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue)
    end
end

--- Settles one load result into its associated future.
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

    if entry.kind == "bytes" then
        root:complete(result.bytes as string)
        return true
    end

    if entry.kind == "sound" then
        local sound = setmetatable(
            {
                path = entry.path,
                resident = result.resident as boolean,
                durationMs = result.durationMs as integer,
                -- One holder, because sound does not dedupe: this future has one
                -- caller and no link of the caller's can add another.
                _refs = 1,
            } as Sound,
            SoundMT
        )
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
    local image = setmetatable(
        {
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
        } as Image,
        ImageMT
    )
    root:complete(image)
    return true
end

--- Settles one load result, and ends a process-wide drain that this emptied.
---
--- The function settles the drain after the result rather than inside it, because a
--- listener the settlement runs is free to start another load and a `waitAll`
--- that returned before it did would have left one outstanding.
---
--- @return Whether the function matched the result to a queued decode. False for a result
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

--- Gives up a load whose last caller has gone.
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
    local shared = entry.kind == "image" and imagesInFlight or entry.kind == "bytes" and bytesInFlight or nil
    if shared ~= nil and shared[entry.path] == future then
        shared[entry.path] = nil
    end
end

local pump <const> = setmetatable(
    {
        -- Both live here rather than in `Future`, which is what lets a decode keep
        -- a shorter default than a child process without a second convention.
        sliceMs = SLICE_MS,
        defaultWaitMs = DEFAULT_WAIT_MS,
    } as Loader,
    LoaderMT
)

local source <const> = pump as Future.Source

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

--- A root future the loader owns and never hands out.
---
--- `Future.pending` counts whoever created a future as one of its watchers,
--- which is right for a caller holding what it created and wrong here. The
--- loader is the producer: the root lives in one of the shared-work tables and
--- every consumer of it is some caller's own derived future. A hold of the
--- loader's own would create a watcher nothing ever gives up, so the count
--- could never reach zero and let the source abandon the decode.
local function newRoot(): Future<any>
    local root = Future.pending(source) as Future<any>
    root._watchers = 0
    return root
end

--- Registers a load, and answers the future it will settle and the id the
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
--- PNG twice at once duplicates work without producing another result.
--- They share the [`Image`](tealdoc:tecs.assets.Image), so the last caller to release it
--- one that frees, and each of them holds a future of its own, so one canceling
--- is invisible to the others. A load that starts after the first has settled
--- decodes again: nothing here is a cache.
---
--- @param path PNG or JPEG. The build contains no other decoder, and another
---     format fails during decoding.
--- @return A pending future, never nil. Raises instead when `install` has not run.
---     Failures reach it as a failed settlement, not through this call: a missing file
---     is a future that fails once the worker has looked. Canceling it gives up this
---     caller's interest in the decode, and the last caller to do so abandons it.
function assets.loadImage(path: string): Future<Image>
    files.note(path, "image")
    local shared = imagesInFlight[path]
    if shared == nil then
        local root, id = queue("image", path)
        imagesInFlight[path] = root
        worker:send({id = id, kind = "image", path = path})
        shared = root
    end
    -- Derived rather than the root itself. Two callers holding one object would
    -- make "the future the caller holds" ambiguous as a map key, which three
    -- subsystems in this tree already use it as, and would leave this module
    -- with no way to count how many of them survived to settlement.
    return shared:map(claim) as Future<Image>
end

--- Queues a complete file read and answers a future for its bytes immediately.
---
--- The returned string preserves embedded NUL bytes. Overlapping reads of one
--- path share the worker task while each caller receives its own future, so one
--- caller may cancel without affecting another. A later read after settlement
--- reads the file again.
---
--- @param path The caller supplies an absolute path or one from
---     [`assetPath`](/modules/io/files/#tecs.io.files.assetPath).
--- @param kind The caller supplies the content kind used by file watching, or
---     omits it to record a document.
--- @return Returns a pending [`Future`](tealdoc:tecs.Future). A missing or
---     unreadable file settles it as failed.
function assets.loadBytes(path: string, kind?: string): Future<string>
    files.note(path, kind or "document")
    local shared = bytesInFlight[path]
    if shared == nil then
        local root, id = queue("bytes", path)
        bytesInFlight[path] = root
        worker:send({id = id, kind = "bytes", path = path})
        shared = root
    end
    return shared:map(function(bytes: string): string return bytes end) as Future<string>
end

--- Queues a sound for loading and answers a future for it immediately.
---
--- Whatever the mixer's decoders can read loads, so the format is the file's
--- business rather than the caller's.
---
--- `mode` is "resident", "stream", or "auto", and auto keeps anything shorter
--- than `streamMs` resident.
---
--- This call initializes the library instead of the worker because `MIX_Init`
--- does not support concurrent calls. Initialization before sending the task puts it
--- in order ahead of every decode without a lock.
---
--- Two overlapping loads of one path do not share, unlike images: each gets its
--- own clip, because that is what `MIX_LoadAudio` produces. So this answers the
--- root future rather than a link over one, and the
--- [`Sound`](tealdoc:tecs.assets.Sound) it settles to has
--- exactly one holder.
---
--- @param mode "resident", "stream" or "auto". Any other value selects "stream".
--- @param streamMs The boundary "auto" decides on, in milliseconds. Read only under
---     "auto", and a file whose length the container cannot state streams whatever it says.
--- @return A pending future, or a failed future when mixer initialization
---     fails. This is the only failure reported without waiting for the worker.
function assets.loadSound(path: string, mode: string, streamMs: integer): Future<Sound>
    files.note(path, "sound")
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

--- Takes finished loads and settles their futures. Call once per frame.
---
--- Polls, never blocks, and drains everything the worker has answered rather than one
--- result. Nothing settles without this, so a game that stops calling it has loads that
--- stay pending forever.
---
--- @return How many loads settled this call, which is zero when nothing has
---     finished and also zero when no worker exists.
function assets.update(): integer
    return pump:poll()
end

--- Returns the number of loads still waiting on the worker.
---
--- @return Every load in flight in this process, not one caller's. A load every
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
--- Blocks until the thread exits. This call drops loads still in flight and leaves their
--- futures pending forever, so drain with `waitAll` first when their results matter.
--- Releasing an [`Image`](tealdoc:tecs.assets.Image) or a
--- [`Sound`](tealdoc:tecs.assets.Sound) that already settled still works afterwards; this
--- frees nothing.
function assets.shutdown()
    if worker == nil then
        return
    end
    worker:stop()
    worker = nil
    pending = {}
    byFuture = {}
    imagesInFlight = {}
    bytesInFlight = {}
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
