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
local type clock = require("tecs.platform.clock")
local type events = require("tecs.platform.events")
local type clipboard = require("tecs.platform.clipboard")
local type proc = require("tecs.platform.proc")
local type net = require("tecs.net")
local type capabilities = require("tecs.platform.capabilities")
local type paths = require("tecs.platform.paths")
local type filesystem = require("tecs.platform.filesystem")
local type watch = require("tecs.platform.watch")
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
local type json = require("tecs.json")
local type hash = require("tecs.hash")
local type compress = require("tecs.compress")
local type system = require("tecs.platform.system")
local type sensors = require("tecs.platform.sensors")
local type platformAudio = require("tecs.platform.audio")

-- A class gets a module of its own, lowercase, and the class sits inside it
-- under its own name: `tecs.camera.Camera`. One name is the namespace and the
-- other is the type, so no name is both at once. The satellite records each
-- class carries are named here too, so a game reaches `tecs.window.Options`
-- without going through `Window` first.

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

--- Gameplay input in three tiers, behind a layer stack.
local record input
    Input: Input
    Layer: Input.Layer
    Touch: Input.Touch
    TextArea: Input.TextArea
    TextOptions: Input.TextOptions
    Options: Input.Options
end

--- A pad's identity, lifetime, metadata and outputs.
local record gamepad
    Gamepad: Gamepad
    TouchpadFinger: Gamepad.TouchpadFinger
end

--- A value that settles once.
local record future
    Future: Future
    type Source = Future.Source
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

    animation: animation
    application: application
    assets: assets
    audio: audio
    camera: camera
    capabilities: capabilities
    clipboard: clipboard
    clock: clock
    components: components
    compress: compress
    events: events
    filesystem: filesystem
    future: future
    gamepad: gamepad
    hash: hash
    http: http
    input: input
    json: json
    layers: layers
    log: log
    materials: materials
    mcp: mcp
    net: net
    particles: particles
    paths: paths
    physics: physics
    proc: proc
    renderer: renderer
    sensors: sensors
    sequence: sequence
    system: system
    text: text
    watch: watch
    window: window
    workers: workers

    --- Version of this build.
    version: string
end

tecs.ecs = ecs

--- Module paths resolved on first use: everything that reaches native code,
--- which is the engine and JSON, whose parser is C, plus the byte facilities,
--- which cost nothing to skip and which most programs never ask for.
---
--- Listed rather than discovered, so `tecs.anmation` is an error where it is
--- written instead of a nil where it is called.
local ENGINE <const>: {string: string} = {
    animation = "tecs.gfx.animation",
    clock = "tecs.platform.clock",
    events = "tecs.platform.events",
    clipboard = "tecs.platform.clipboard",
    proc = "tecs.platform.proc",
    net = "tecs.net",
    capabilities = "tecs.platform.capabilities",
    paths = "tecs.platform.paths",
    filesystem = "tecs.platform.filesystem",
    watch = "tecs.platform.watch",
    layers = "tecs.gfx.layers",
    sequence = "tecs.sequence",
    components = "tecs.components",
    text = "tecs.gfx.text",
    particles = "tecs.gfx.particles",
    materials = "tecs.gpu.materials",
    assets = "tecs.assets",
    workers = "tecs.workers",
    physics = "tecs.physics",
    http = "tecs.http",
    log = "tecs.log",
    mcp = "tecs.mcp",
    json = "tecs.json",
    hash = "tecs.hash",
    compress = "tecs.compress",
    system = "tecs.platform.system",
    sensors = "tecs.platform.sensors",
}

--- What one of those namespaces is made of.
local record Namespace
    --- The module the class comes from.
    module: string
    --- The member name that answers with the module itself.
    class: string
    --- Further modules named at this level, searched before the class's own.
    beside: {string}
end

--- Namespaces whose members come off one module: the class itself under its
--- own name, and everything else read off the module table beside it.
---
--- Resolved on first use like the modules above, and for the same reason: each
--- of these reaches SDL through the FFI, so a tool that never names one never
--- loads a graphics stack.
---
--- `audio` is the one with a second module under it. The mixer and the device
--- it opens are one subject at two levels, and a game asking about sound
--- should find one module rather than pick between two.
local CLASSES <const>: {string: Namespace} = {
    application = {module = "tecs.Application", class = "Application"},
    renderer = {module = "tecs.Renderer", class = "Renderer"},
    audio = {module = "tecs.Audio", class = "Audio", beside = {"tecs.platform.audio"}},
    camera = {module = "tecs.gfx.Camera", class = "Camera"},
    window = {module = "tecs.platform.Window", class = "Window"},
    input = {module = "tecs.platform.Input", class = "Input"},
    gamepad = {module = "tecs.platform.Gamepad", class = "Gamepad"},
    future = {module = "tecs.Future", class = "Future"},
}

--- Builds one of those namespaces. The module loads on the first member read
--- rather than when the namespace itself is, so naming `tecs.window` costs
--- nothing until something is taken out of it.
---
--- A `beside` module is searched first, because it is the cheaper one to load
--- and no name is in both: listing a sound device does not open a mixer.
local function namespace(spec: Namespace): {string: any}
    local members: {string: any} = {}
    return setmetatable(
        members,
        {
            __index = function(self: {string: any}, name: string): any
                local member: any = nil
                if spec.beside ~= nil then
                    for _, path in ipairs(spec.beside) do
                        member = (require(path) as {string: any})[name]
                        if member ~= nil then
                            break
                        end
                    end
                end
                if member == nil then
                    local module = require(spec.module) as {string: any}
                    member = name == spec.class and module or module[name]
                end
                if member == nil then
                    return nil
                end
                rawset(self, name, member)
                return member
            end,
        }
    )
end

setmetatable(
    tecs as {string: any},
    {
        __index = function(self: {string: any}, name: string): any
            local module = ENGINE[name]
            if module ~= nil then
                local resolved = require(module)
                rawset(self, name, resolved)
                return resolved
            end
            local class = CLASSES[name]
            if class == nil then
                return nil
            end
            local built = namespace(class)
            rawset(self, name, built)
            return built
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
