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
-- the module below can still name `tecs.camera.Camera` as a type. The values
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
-- under its own name: `tecs.camera.Camera`. One name is the namespace and the
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

--- A world to a frame, through an extractor and a backend.
local record renderer
    Renderer: Renderer
    type InstanceProducer = Renderer.InstanceProducer
    type ClipRegion = Renderer.ClipRegion
    type ComputeStage = Renderer.ComputeStage
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

--- The view a frame is drawn from.
local record camera
    Camera: Camera
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

--- Drawing, and the vocabularies a scene is described in.
---
--- Each of those is its own module a level down rather than a section of this
--- one, because they share a subject and nothing else: a game that positions
--- bands never reads a glyph, and loading one has no reason to load the rest.
local record gfx
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
    camera: camera
    components: components
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
    renderer: renderer
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
--- `audio` and `input` are the two namespaces reading more than one module at
--- one level, and both are a class with satellites rather than a merge. Every
--- other name here answers with one module, which is what lets the module's own
--- record type it.
local SURFACE <const>: {string: Namespace} = {
    application = {module = "tecs.Application", class = "Application"},
    assets = {module = "tecs.assets"},
    audio = {module = "tecs.Audio", class = "Audio", beside = {"tecs.platform.audio"}},
    camera = {module = "tecs.gfx.Camera", class = "Camera"},
    components = {module = "tecs.components"},
    data = {module = "tecs.data"},
    events = {module = "tecs.platform.events"},
    filesystem = {
        module = "tecs.platform.filesystem",
        within = {watch = {module = "tecs.platform.watch"}},
    },
    future = {module = "tecs.Future", class = "Future"},
    gfx = {
        within = {
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
    renderer = {module = "tecs.Renderer", class = "Renderer"},
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
--- `tecs.camera` off the global loads the engine module on demand exactly as
--- reading it off the required value does. `require` caches, so this runs
--- once; a game that assigns `tecs` itself afterwards owns the name and the
--- declaration no longer describes it.
local globals <const> = _G as {string: any}
globals.tecs = tecs

return tecs
