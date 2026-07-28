--- Tecs, a typed entity component system for Lua, typed with Teal.
--- https://tecs.dev

local types <const> = require("tecs.types")
local ecs <const> = require("tecs.ecs")

--- The public API.
---
--- Support policy: values and types exported from `require("tecs")` are the
--- supported API, as are the `tecs.utils.*` modules (profile, pool, Bitset),
--- which may be required directly. `tecs.internal.*` modules are
--- implementation details unless re-exported here.
-- The engine half, named for its types and loaded on demand.
--
-- `local type` is erased at codegen, so these lines cost nothing at runtime and
-- the module below can still name `tecs.gfx.Camera` as a type. The values
-- arrive through the metatable further down.
--
-- Loading them here instead would end headless use. The engine reaches SDL,
-- Box2D and the worker library through the FFI, and those load when the module
-- that declares them loads, so a plain `require("tecs")` would demand a
-- graphics stack from a test, a server or a tool that only wanted the ECS.
local type Application = require("tecs.Application")
local type Future = require("tecs.Future")
local type Renderer = require("tecs.Renderer")
local type Audio = require("tecs.Audio")
local type Camera = require("tecs.gfx.Camera")
local type animation = require("tecs.gfx.animation")
local type Window = require("tecs.platform.Window")
local type Input = require("tecs.platform.Input")
local type Gamepad = require("tecs.platform.Gamepad")
local type time = require("tecs.platform.time")
local type events = require("tecs.platform.events")
local type net = require("tecs.net")
local type filesystem = require("tecs.platform.filesystem")
local type layers = require("tecs.gfx.layers")
local type sequence = require("tecs.sequence")
local type components = require("tecs.components")
local type text = require("tecs.gfx.text")
local type particles = require("tecs.gfx.particles")
local type materials = require("tecs.gpu.materials")
local type assets = require("tecs.assets")
local type workers = require("tecs.workers")
local type physics = require("tecs.physics")
local type http = require("tecs.http")
local type log = require("tecs.log")
local type mcp = require("tecs.mcp")
local type data = require("tecs.data")
local type system = require("tecs.platform.system")
local type sensors = require("tecs.platform.sensors")
local type platformAudio = require("tecs.platform.audio")
local type loader = require("tecs.ffi.loader")

-- A record below is written for one reason: a public name that no single module
-- answers. A namespace assembled from a class and the records beside it, or
-- from nothing but the modules one level down, has no module whose own record
-- types it, so one is written here.
--
-- A public name that one module answers needs none of this, and has none. It
-- resolves to that module, is typed by the record the module declares, and
-- carries the names one level down as fields of its own: `tecs.filesystem` is
-- `src/tecs/platform/filesystem.tl`, `watch` included. That is the shape to
-- reach for, because a record here restates every signature and every docblock
-- the module already carries and nothing checks the two against each other.
--
-- A class gets a module of its own, lowercase, and the class sits inside it
-- under its own name: `tecs.gfx.Camera`. One name is the namespace and the
-- other is the type, so no name is both at once. The satellite records each
-- class carries are named here too, so a game reaches `tecs.window.Options`
-- without going through `Window` first.
--
-- A module may also sit inside another module, one level and no deeper:
-- `tecs.gfx.layers`, `tecs.filesystem.watch`. `SURFACE` is what declares that,
-- through `within`, and a lowercase field of a record here is one of them only
-- where the parent has no module of its own.

--- The object an entry file returns, and what builds one.
local record application
    Application: Application
    type Config = Application.Config

    --- Builds the application an entry file returns.
    ---
    --- Not a function that runs until done: an entry file ends with
    --- `return tecs.application.create(config)` and the host drives it from
    --- there, because a platform that never hands control back has no loop to
    --- block in.
    ---
    --- @param config Read here, so a field changed on the table afterwards is
    ---     not seen. Nothing is opened yet: the window, the GPU device and the
    ---     audio mixer are the host's to bring up on the first callback, which
    ---     is what lets an entry file be loaded by a tool that never runs one.
    --- @return The application the host drives through its init, event, iterate
    ---     and quit callbacks. Returning it is the whole contract; a game that
    ---     calls into it itself is doing the host's job.
    create: function(config: Application.Config): Application
end

--- Sound, at both levels: a mixer with clips, voices, groups and limits, and
--- the physical devices it opens and records from.
local record audio
    Audio: Audio
    --- Play a clip by putting this on an entity.
    Sound: Audio.Sound
    type Config = Audio.Config
    type Clip = Audio.Clip
    type LoadOptions = Audio.LoadOptions
    type PlayOptions = Audio.PlayOptions
    type Limit = Audio.Limit
    type VoiceInfo = Audio.VoiceInfo

    type Device = platformAudio.Device
    type Microphone = platformAudio.Microphone
    type MicrophoneConfig = platformAudio.MicrophoneConfig

    --- Physical playback devices attached now.
    playbackDevices: function(): {platformAudio.Device}, string

    --- Physical recording devices attached now.
    recordingDevices: function(): {platformAudio.Device}, string

    --- Opens a microphone as interleaved native-endian 32-bit float samples.
    ---
    --- No callback is installed. SDL's audio thread fills its own stream and
    --- the game pulls completed bytes from the main thread with `read`.
    openMicrophone: function(config?: platformAudio.MicrophoneConfig): platformAudio.Microphone, string
end

--- The window, its size, its display and its mode.
local record window
    Window: Window
    type Options = Window.Options
    type DisplayMode = Window.DisplayMode
    type Orientation = Window.Orientation
    type Theme = Window.Theme
    type Flash = Window.Flash
    type Progress = Window.Progress
end

--- What a player does, and the devices they do it with: gameplay input in
--- three tiers behind a layer stack, the pads attached to it, and the
--- standalone sensors a device carries.
---
--- One module because they are one question asked of three sources, and
--- because the layer stack answers all three: a pad's buttons are gated by the
--- same stack a keyboard's keys are, so `Input` and `Gamepad` cannot be reached
--- from different places without the gate looking like a property of one of
--- them. Platform events stay separate under `tecs.events`, since that stream
--- also carries lifecycle, window, display and device arrival.
local record input
    Input: Input
    Gamepad: Gamepad

    type Layer = Input.Layer
    type Touch = Input.Touch
    type TextArea = Input.TextArea
    type TextOptions = Input.TextOptions
    type Options = Input.Options
    type TouchpadFinger = Gamepad.TouchpadFinger

    --- An opened standalone sensor, read by polling.
    type Sensor = sensors.Sensor

    --- A standalone sensor the platform reports, before it is opened. Named
    --- for what it is rather than `Device`, which on a module that also holds
    --- gamepads would name two things.
    type SensorDevice = sensors.Device

    --- Builds the input state a game reads.
    ---
    --- @param options Omitted opens against no window, which is what a
    ---     headless tool or a spec wants: keys and pads still fold, and
    ---     anything asking about a window answers as if there is none.
    --- @return The state. One per application; the application builds its own
    ---     and a second is only for a test.
    newInput: function(options?: Input.Options): Input

    --- Standalone sensors attached now, in platform order.
    ---
    --- A snapshot rather than a subscription: a sensor unplugged after this
    --- leaves an id `openSensor` refuses. Gamepad sensors are not here, since
    --- their identity and event routing live on the pad.
    ---
    --- @return The sensors, listed afresh each call and the caller's to keep.
    ---     Empty rather than nil when the subsystem cannot start, and most
    ---     desktop machines genuinely have none.
    --- @return SDL's reason, when something went wrong.
    sensors: function(): {sensors.Device}, string

    --- Opens an attached standalone sensor by instance id.
    ---
    --- @param id An instance id from `sensors`. An id names a device while it
    ---     stays attached rather than a slot, so one kept across an unplug does
    ---     not come back to the same sensor.
    --- @return The open sensor, whose closing is the caller's through
    ---     `destroy`. Nil on failure, and nothing is left open in that case.
    --- @return The reason, when the first return is nil.
    openSensor: function(id: number): sensors.Sensor, string
end

--- A value that settles once.
local record future
    Future: Future
    type Source = Future.Source
end

--- Drawing: what a frame is drawn from, what draws it, and the vocabularies a
--- scene is described in.
---
--- The facilities every scene reaches for sit here directly. The four
--- vocabularies are each their own module a level down rather than a section of
--- this one, because they share a subject and nothing else: a game that
--- positions bands never reads a glyph, and loading one has no reason to load
--- the rest.
local record gfx
    --- The view a frame is drawn from.
    Camera: Camera
    type CameraOptions = Camera.Options

    --- A world to a frame, through an extractor and a backend.
    Renderer: Renderer
    type RendererOptions = Renderer.Options
    type InstanceProducer = Renderer.InstanceProducer
    type ClipRegion = Renderer.ClipRegion
    type ComputeStage = Renderer.ComputeStage

    --- Builds a view onto the world.
    ---
    --- @param options Omit for an unrotated, unzoomed view at the world origin,
    ---     which a renderer recentres on its first drawn frame if the game
    ---     never moves it. No field is validated.
    --- @return A camera whose fields are plain and meant to be assigned to
    ---     frame by frame. It is not attached to anything: a renderer draws
    ---     from the one on `renderer.camera`, so a second is for a calculation
    ---     rather than a second view.
    newCamera: function(options?: Camera.Options): Camera

    --- Builds a renderer against an open GPU device.
    ---
    --- @param device The `SDL_GPUDevice` to draw through, which stays the
    ---     caller's to destroy and must outlive the renderer.
    --- @param swapchainFormat The `SDL_GPUTextureFormat` present copies into.
    --- @param options Every field has a default, and nil is accepted even
    ---     though the signature does not mark it optional. `capacity` is a
    ---     ceiling rather than a hint: rows past it are dropped rather than
    ---     growing a buffer mid-frame.
    --- @return The renderer, which owns the packet, the extractor and the
    ---     backend, and releases all three from `destroy`.
    newRenderer: function(device: loader.CPtr, swapchainFormat: integer, options: Renderer.Options): Renderer

    -- The components a game spawns to put something on screen. All but
    -- `Renderable` are FFI components, so their columns are contiguous C
    -- memory the sync walks row by row into mapped GPU staging: writing one
    -- through `world:get` needs an explicit `world:markComponentDirty`, since
    -- only `getMut` marks the column on its own.
    --
    -- `Transform` is not among them. It positions everything a world holds
    -- rather than only what draws, so it is the ECS builtin and is reached as
    -- `tecs.ecs.builtins.Transform`.

    --- The transform as it stood before the current fixed step. Presence is
    --- the opt-in to interpolation: an entity carrying it is drawn between
    --- this and its current transform, so physics does not step visibly.
    --- Carries `x`, `y` and `rotation` (radians) only, because scale and
    --- layer change by assignment rather than by integration.
    PreviousTransform: components.PreviousTransform

    --- Base colour and coverage, each channel 0 to 1, defaulting to opaque
    --- white. The alpha decides which pass draws the entity: exactly 1 goes
    --- through the G-buffer and is lit once for the whole scene, anything
    --- below 1 goes through the forward pass instead, writes no depth, and
    --- is dropped when the forward list is full. Say 1 exactly for anything
    --- meant to be solid.
    Tint: components.Tint

    --- Samples a texture instead of drawing flat colour. `image` is an
    --- `imageId` index, and 0 means no image; `u0, v0, u1, v1` select the
    --- region, defaulting to the whole of it, so an atlas entry and a whole
    --- image are the same thing. `slot` is the texture-array layer the
    --- renderer resolved `image` to, and a negative value means unresolved:
    --- pointing a live Sprite at another image means writing a negative slot
    --- along with the new `image`, or the row keeps drawing the old layer.
    --- Only the image name survives a snapshot.
    Sprite: components.Sprite

    --- Selects one of the materials found under `materials/`. Absent means
    --- the default, which samples the image array over the whole quad, so an
    --- entity with neither this nor a Sprite still draws. Take `id` from
    --- `materials.id(name)` rather than writing a number: ids are positions
    --- in sorted order and move when a material file is added. `param` is 0
    --- to 1 and means whatever the material says it does.
    Material: components.Material

    --- A light the deferred lighting pass resolves, positioned by the
    --- entity's Transform and in the same world units. `height` is above the
    --- surface plane and at 0 the light contributes nothing at all;
    --- `radius` is its reach in world units; `r`, `g`, `b` and `intensity`
    --- default to white at 1.
    PointLight: components.PointLight

    --- Keeps a renderable's fragments inside one rectangle. `index` names a
    --- region set with `Renderer:setClipRegion`, and 0, the default, means
    --- no clipping. A region is a single rectangle, so nesting is the
    --- caller's job: intersect the two and set that.
    Clip: components.Clip

    --- Blocks every light with the shape the entity draws. `height` is 0 to
    --- 1 of the world height `Deferred.shadowHeight` sets, so 1 is a full
    --- wall and 0 is something lying flat that blocks nothing. Needs
    --- `shadows` on the renderer; without it the entity draws and casts
    --- nothing.
    Occluder: components.Occluder

    --- Darkens the ground away from each of the nearest lights, ambient
    --- included, and blocks no light. `height` is 0 to 1 and decides how far
    --- the copy is thrown, under the same reading as `Occluder.height`. An
    --- entity carrying both is an occluder.
    DropShadow: components.DropShadow

    --- Marks an entity as contributing geometry. A tag, so it costs a
    --- column of nothing; without it a Transform is only a position, which
    --- is what most entities in a world are.
    Renderable: components.Renderable

    --- Index of an image name, assigning one the first time it is seen.
    ---
    --- The name is normalised lexically first, so `"a/b.png"` and
    --- `"a/./b.png"` are one image. Case, `..` and the asset root are
    --- deliberately left alone, and nothing here touches the filesystem.
    ---
    --- @param name Must be non-empty; an empty or nil name errors rather
    ---     than interning.
    --- @return An index from 1 upwards, stable for the life of the process
    ---     and meaningless outside it. 0 is never returned and is what a
    ---     Sprite carries until something names an image.
    imageId: function(name: string): integer

    --- Name an image index stands for.
    ---
    --- @param id An index previously handed out by `imageId`.
    --- @return The normalised name, or nil when the index names nothing.
    imageName: function(id: integer): string

    animation: animation
    layers: layers
    materials: materials
    particles: particles
end

local record tecs
    type World = types.World
    type System = types.System
    type Plugin = types.Plugin
    type Pipeline = types.Pipeline
    type FixedOverload = types.FixedOverload
    type Component = types.components.Component
    type ScalarComponent<T> = types.components.ScalarComponent<T>
    type ComponentOptions<C> = types.components.ComponentOptions<C>
    type FFIComponentOptions<C> = types.components.FFIComponentOptions<C>
    type ScalarComponentOptions<T> = types.components.ScalarComponentOptions<T>
    type TagComponentOptions = types.components.TagComponentOptions
    type RelationshipOptions<R is Relationship> = types.components.RelationshipOptions<R>
    type FFIRelationshipOptions<R is Relationship> = types.components.FFIRelationshipOptions<R>
    type Relationship = types.components.Relationship
    type Query = types.Query
    type QueryDescriptor = types.Query.Descriptor
    type QueryCursor = types.Query.Cursor
    type Archetype = types.Archetype
    type ArchetypeEntityObserver = types.ArchetypeEntityObserver
    type Event = types.events.Event
    type EventListener = types.events.EventListener
    type EventInit = types.events.EventInit
    type MessageBus = types.events.MessageBus
    type Context = types.Context
    type Key<T> = types.Context.Key<T>
    type StatePolicy = types.StatePolicy
    type Stats = types.World.Stats
    type Phase = types.Phase
    type SystemConfig = types.SystemConfig
    type DoubleArray = types.DoubleArray
    type Bundle = types.Bundle
    type BundleDef = types.Bundle.Definition
    type Snapshot = types.World.Snapshot
    type SnapshotPrelude = types.World.SnapshotPrelude
    type SnapshotComponentTableEntry = types.World.SnapshotComponentTableEntry
    type SnapshotOptions = types.World.SnapshotOptions
    type SnapshotOutput = types.World.SnapshotOutput
    type SnapshotHandler = types.World.SnapshotHandler

    --- Worlds, components, queries, systems, events and resources. The one
    --- half that reaches nothing below Lua, so it is here rather than
    --- resolved on demand.
    ecs: ecs

    application: application
    assets: assets
    audio: audio
    data: data
    events: events
    filesystem: filesystem
    future: future
    gfx: gfx
    http: http
    input: input
    log: log
    mcp: mcp
    net: net
    physics: physics
    sequence: sequence
    system: system
    text: text
    time: time
    window: window
    workers: workers

    --- Version of this build.
    version: string
end

tecs.ecs = ecs

--- How one public name resolves, at whatever depth it is written.
---
--- A descriptor with one principal `module` answers with that module's own
--- table, so `tecs.filesystem` and `require("tecs.platform.filesystem")` are
--- one value rather than a copy of one. Names one level down are hung off it
--- lazily, so a `within` costs nothing until one of them is read.
---
--- A descriptor with no principal module, or with several modules at one
--- level, answers with a table built here instead, which fills a member at a
--- time. That table cannot be typed by any one module, so `init.tl` declares a
--- record for it, and that record is a second copy of every signature and every
--- docblock the module already carries. Prefer the merge: two files that are
--- one public name should be one file.
local record Namespace
    --- The module a member comes off when nothing above it answered.
    module: string
    --- The member name that answers with `module` itself, which is how a class
    --- sits inside a namespace named for it.
    class: string
    --- Further modules read at this level, searched before `module`.
    beside: {string}
    --- The names one level down, each described the same way and each resolved
    --- on the first read of its own name.
    within: {string: Namespace}
end

--- What every public name resolves to, described once and used at both levels.
---
--- Everything here is resolved on first use: the engine, which reaches SDL,
--- Box2D and the worker library through the FFI, JSON, whose parser is C, and
--- the byte facilities, which cost nothing to skip and which most programs
--- never ask for. A tool that names none of them loads none of them, and that
--- holds a level down too: reading `tecs.gfx.layers` loads layers and nothing
--- else under `gfx`.
---
--- Listed rather than discovered, so `tecs.anmation` is an error where it is
--- written instead of a nil where it is called.
---
--- `audio`, `input` and `gfx` are the namespaces reading more than one module
--- at one level. The first two are a class with satellites; `gfx` is the one
--- name several substantial modules answer, and no candidate could be its
--- principal without being loaded the moment the name is read, which every one
--- of them reaches SDL to do. Every other name here answers with one module,
--- which is what lets the module's own record type it.
local SURFACE <const>: {string: Namespace} = {
    application = {module = "tecs.Application", class = "Application"},
    assets = {module = "tecs.assets"},
    audio = {module = "tecs.Audio", class = "Audio", beside = {"tecs.platform.audio"}},
    data = {module = "tecs.data"},
    events = {module = "tecs.platform.events"},
    filesystem = {
        module = "tecs.platform.filesystem",
        within = {watch = {module = "tecs.platform.watch"}},
    },
    future = {module = "tecs.Future", class = "Future"},
    gfx = {
        beside = {"tecs.components", "tecs.gfx.Camera", "tecs.Renderer"},
        within = {
            Camera = {module = "tecs.gfx.Camera"},
            Renderer = {module = "tecs.Renderer"},
            animation = {module = "tecs.gfx.animation"},
            layers = {module = "tecs.gfx.layers"},
            materials = {module = "tecs.gpu.materials"},
            particles = {module = "tecs.gfx.particles"},
        },
    },
    http = {module = "tecs.http"},
    input = {
        module = "tecs.platform.Input",
        class = "Input",
        beside = {"tecs.platform.sensors"},
        within = {Gamepad = {module = "tecs.platform.Gamepad"}},
    },
    log = {module = "tecs.log"},
    mcp = {module = "tecs.mcp"},
    net = {module = "tecs.net"},
    physics = {module = "tecs.physics"},
    sequence = {module = "tecs.sequence"},
    system = {module = "tecs.platform.system"},
    text = {module = "tecs.gfx.text"},
    time = {module = "tecs.platform.time"},
    window = {module = "tecs.platform.Window", class = "Window"},
    workers = {module = "tecs.workers"},
}

--- Answers what one descriptor describes, at the root and one level down
--- alike. Declared ahead of `namespace` because the two call each other: a
--- namespace resolves the descriptors under it, and each of those is a
--- descriptor like any other.
---
--- @param spec What the name resolves through. A descriptor with one principal
---     module answers with that module and loads it now, with the names below
---     it hung off it unloaded; anything else answers with a table that loads
---     nothing until a member is read.
--- @return The module or the namespace, which is what the name is from here on:
---     the caller memoizes it, so this runs once per name.
local resolve: function(spec: Namespace): any

--- Builds the table a namespace answers with. Nothing under it loads until a
--- member is read, so naming `tecs.window` or `tecs.gfx` costs nothing until
--- something is taken out of it.
---
--- `within` is searched first and `beside` second, both ahead of `module`,
--- because they are the cheaper ones to load and no name is in more than one: a
--- module below is its own file, and listing a sound device does not open a
--- mixer.
---
--- What is resolved is remembered in a table beside the one answered with
--- rather than on it. The table a caller holds stays empty, so both metamethods
--- keep being consulted: memoizing onto it would stop `__index` firing after
--- the first read, and `__newindex` fires only for a name the table does not
--- already carry, so the first write after a read would land here instead of on
--- the module that owns the name.
local function namespace(spec: Namespace): {string: any}
    local resolved: {string: any} = {}
    return setmetatable({} as {string: any}, {
        __index = function(_self: {string: any}, name: string): any
            local member: any = resolved[name]
            if member ~= nil then
                return member
            end
            if spec.within ~= nil and spec.within[name] ~= nil then
                member = resolve(spec.within[name])
            end
            if member == nil and spec.beside ~= nil then
                for _, path in ipairs(spec.beside) do
                    member = (require(path) as {string: any})[name]
                    if member ~= nil then
                        break
                    end
                end
            end
            if member == nil and spec.module ~= nil then
                local module = require(spec.module) as {string: any}
                member = name == spec.class and module or module[name]
            end
            if member == nil then
                return nil
            end
            resolved[name] = member
            return member
        end,

        --- Sends a write to whichever module answers the name.
        ---
        --- A namespace stands in front of several modules, and a module
        --- value can be assigned rather than called: a write parked on
        --- this table would then be a write the module that reads the
        --- name back never sees, with nothing to raise. Ownership is
        --- decided the way a read decides it, and a name no module below
        --- answers is the namespace's own.
        ---
        --- Only a namespace needs this. A name backed by one module
        --- answers with the module, so a write to it is a write on the
        --- table that owns the name and there is nothing to route.
        ---
        --- What was resolved earlier is dropped rather than replaced, so
        --- the next read asks the owner again instead of trusting a copy
        --- taken before the write.
        __newindex = function(_self: {string: any}, name: string, value: any)
            local owner: {string: any} = nil
            if spec.beside ~= nil then
                for _, path in ipairs(spec.beside) do
                    local module = require(path) as {string: any}
                    if module[name] ~= nil then
                        owner = module
                        break
                    end
                end
            end
            if owner == nil and spec.module ~= nil then
                local module = require(spec.module) as {string: any}
                if module[name] ~= nil then
                    owner = module
                end
            end
            if owner == nil then
                resolved[name] = value
                return
            end
            owner[name] = value
            resolved[name] = nil
        end,
    })
end

--- Hangs the names one level down off the module that carries them.
---
--- The module table is what the public name answers with, so a subordinate
--- module has to be reachable through it without being loaded with it. A
--- metatable does both: the name misses, this resolves it once, and it is
--- written on so every later read is an ordinary field.
---
--- Writing it on is safe here in a way it is not on a namespace built by
--- `namespace`. The module owns every name it answers, so there is no other
--- table a write could belong on and nothing to route.
---
--- @param module The table `require` answered with, which is edited in place:
---     `require("tecs.platform.filesystem").watch` is the same name reached the
---     other way, and one table means one answer.
--- @param within The names below it, each a descriptor like any other.
local function hang(module: {string: any}, within: {string: Namespace})
    setmetatable(
        module,
        {
            __index = function(self: {string: any}, name: string): any
                local spec = within[name]
                if spec == nil then
                    return nil
                end
                local member = resolve(spec)
                rawset(self, name, member)
                return member
            end,
        }
    )
end

resolve = function(spec: Namespace): any
    if spec.class ~= nil or spec.beside ~= nil or spec.module == nil then
        return namespace(spec)
    end
    local module = require(spec.module) as {string: any}
    if spec.within ~= nil then
        hang(module, spec.within)
    end
    return module
end

setmetatable(
    tecs as {string: any},
    {
        __index = function(self: {string: any}, name: string): any
            local spec = SURFACE[name]
            if spec == nil then
                return nil
            end
            local resolved = resolve(spec)
            rawset(self, name, resolved)
            return resolved
        end,
    }
)

tecs.version = "0.1.0"

--- `tecs` is also a global, so a game writes `tecs.ecs.newWorld()` in any file
--- without a require line, and `tecs/global.d.tl` types it.
---
--- Set here, where the module is defined, rather than by the host. A host that
--- set it would leave the global present for a game and absent under a plain
--- interpreter, so headless tools, the spec suite and the benchmarks would each
--- see a different API and the same line would work in one and fail in
--- another with nothing to warn on. Setting it here makes requiring tecs
--- anywhere, including transitively, enough: require stays the mechanism and
--- the global is a consequence of it.
---
--- It is the same table `require` returns, metatable included, so reading
--- `tecs.gfx` off the global loads the engine module on demand exactly as
--- reading it off the required value does. `require` caches, so this runs
--- once; a game that assigns `tecs` itself afterwards owns the name and the
--- declaration no longer describes it.
local globals <const> = _G as {string: any}
globals.tecs = tecs

return tecs
