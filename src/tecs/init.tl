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
local type datajson = require("tecs.data")
local type system = require("tecs.platform.system")
local type sensors = require("tecs.platform.sensors")
local type platformAudio = require("tecs.platform.audio")

-- A class gets a module of its own, lowercase, and the class sits inside it
-- under its own name: `tecs.camera.Camera`. One name is the namespace and the
-- other is the type, so no name is both at once. The satellite records each
-- class carries are named here too, so a game reaches `tecs.window.Options`
-- without going through `Window` first.
--
-- A module may also sit inside another module, one level and no deeper:
-- `tecs.gfx.layers`. A record here is what declares that, and its lowercase
-- fields are the modules under it while its capitalised ones are the types the
-- parent owns.

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

--- Turning bytes into other bytes: JSON in both directions, DEFLATE in both
--- directions, and a hash over either.
---
--- One module because each of these is a few functions over a byte string with
--- no state to carry, and a game reaching for one is nearly always about to
--- reach for another: a save is encoded, compressed and stamped, and a cache
--- entry is checked the other way round. Three modules of three functions each
--- would put that one job in three places.
---
--- The transformations name their format, because a merged module makes a bare
--- verb ambiguous and because a value produced here outlives the process. There
--- is no `encode`, and `fnv1a64` says which hash it is so that changing what it
--- computes is a rename every caller is rechecked against.
local record data
    --- An independent JSON table with its own settings, as `newJSON` answers
    --- with.
    type JSON = datajson

    --- What `null` and `empty_array` are: a value standing for something a Lua
    --- table cannot express, opaque and compared by identity.
    type Sentinel = datajson.Sentinel

    --- Encodes a Lua value as JSON text.
    ---
    --- @param value Any value JSON has a form for. A function, a coroutine, a
    ---     cdata or a non-finite number raises rather than going missing.
    --- @return The document, compact unless `encode_indent` says otherwise.
    encodeJSON: function(value: any): string

    --- Decodes JSON text into a Lua value.
    ---
    --- @param text A whole document. A JSON null answers as `null`, which is
    ---     not `nil`, so an absent key and a null one stay apart.
    --- @return The value. Malformed input raises rather than returning nil.
    decodeJSON: function(text: string): any

    --- JSON `null`, which is not `nil`. lua-cjson's own value, so it compares
    --- equal to the one `require("cjson")` answers with.
    null: datajson.Sentinel

    --- A value that encodes as `[]`, which an empty Lua table cannot.
    empty_array: datajson.Sentinel

    --- Metatable marking a table as an array whatever it holds.
    array_mt: metatable<{any}>

    --- Metatable turning an otherwise empty table into `[]`.
    empty_array_mt: metatable<{any}>

    --- Whether `{}` encodes as an object rather than as `[]`. On by default.
    ---
    --- Every setting reads the same way: called with no argument it answers the
    --- current value, called with one it sets it and answers the new one. They
    --- are process-wide, which is what `newJSON` exists to escape.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_empty_table_as_object: function(setting?: boolean | string): boolean

    --- Whether a decoded array carries `array_mt`. Off by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_array_with_array_mt: function(setting?: boolean | string): boolean

    --- Whether `/* ... */` and `// ...` are tolerated in input. Off by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_allow_comment: function(setting?: boolean | string): boolean

    --- Whether a sparse array is converted to an object rather than raising,
    --- and when an array counts as sparse.
    ---
    --- @param convert Omitted only reads, and reads all three.
    --- @param ratio The multiple of the entry count the largest index may reach
    ---     before the array is called sparse. 2 by default.
    --- @param safe A largest index below which an array never counts as sparse.
    ---     10 by default.
    --- @return Whether conversion is on, off by default.
    --- @return The ratio after the call.
    --- @return The safe bound after the call.
    encode_sparse_array: function(
        convert?: boolean | string, ratio?: integer, safe?: integer
    ): boolean, integer, integer

    --- Nesting the encoder accepts before raising. 1000 by default.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    encode_max_depth: function(depth?: integer): integer

    --- Nesting the decoder accepts before raising. 1000 by default, and what
    --- keeps a hostile document from exhausting the C stack.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    decode_max_depth: function(depth?: integer): integer

    --- Significant digits written for a number. 14 by default, which is what
    --- keeps an entity id exact rather than writing it back as `1.0`.
    ---
    --- @param precision Omitted only reads. 1 to 14.
    --- @return The precision after the call.
    encode_number_precision: function(precision?: integer): integer

    --- Whether the encode buffer is kept between calls rather than freed. On by
    --- default.
    ---
    --- @param keep Omitted only reads.
    --- @return The setting after the call.
    encode_keep_buffer: function(keep?: boolean | string): boolean

    --- What NaN and infinity encode as. Off by default, which raises.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call, which is `"null"` rather than a
    ---     boolean when that is what is in force.
    encode_invalid_numbers: function(setting?: boolean | string): boolean | string

    --- Whether `nan` and `inf` are accepted in input. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_invalid_numbers: function(setting?: boolean | string): boolean

    --- Whether `/` is written as `\/`. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_escape_forward_slash: function(setting?: boolean | string): boolean

    --- Whether a value JSON has no form for is skipped rather than raising. Off
    --- by default, and worth leaving off.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_skip_unsupported_value_types: function(setting?: boolean | string): boolean

    --- Indent string for pretty output. Unset, and by default, the encoder
    --- writes compact JSON.
    ---
    --- @param indent Omitted only reads. Whitespace, one level's worth.
    --- @return The indent after the call.
    encode_indent: function(indent?: string): string

    --- An independent JSON table with its own settings.
    ---
    --- @return A table carrying the JSON names here and none of the compression
    ---     or hashing ones, since those have nothing to configure. The
    ---     sentinels are shared with every copy.
    newJSON: function(): JSON

    --- lua-cjson's own name for itself, `"cjson"`, and its version.
    _NAME: string
    _VERSION: string

    --- Compresses bytes as an RFC 1950 zlib stream, header and Adler-32
    --- trailer included.
    ---
    --- @param bytes The whole input, which may be empty.
    --- @param level Minus one or omitted uses zlib's default. Zero stores
    ---     without compression; one through nine trade time for size.
    --- @return The stream. Never nil: a failure raises.
    deflate: function(bytes: string, level?: integer): string

    --- Compresses bytes as a raw RFC 1951 DEFLATE stream, with no header and no
    --- checksum.
    ---
    --- @param bytes The whole input, which may be empty.
    --- @param level As `deflate` takes it.
    --- @return The stream. Never nil: a failure raises.
    deflateRaw: function(bytes: string, level?: integer): string

    --- Decompresses a zlib stream, the form RFC 1950 defines.
    ---
    --- @param bytes The whole stream, trailer included. An empty string raises,
    ---     since it is not one.
    --- @param sizeHint The decompressed size, when the caller's format records
    ---     it. Only an allocation hint: a wrong one costs a copy, never an
    ---     error.
    --- @return The decompressed bytes, which may be empty. A bad header, a
    ---     corrupt block, a truncated stream and a trailer that disagrees all
    ---     raise.
    inflate: function(bytes: string, sizeHint?: integer): string

    --- Decompresses a raw DEFLATE stream, the form RFC 1951 defines.
    ---
    --- @param bytes The whole stream. An empty string raises.
    --- @param sizeHint As `inflate` takes it.
    --- @return The decompressed bytes. There is no checksum in this form, so a
    ---     container carrying one of its own should check it.
    inflateRaw: function(bytes: string, sizeHint?: integer): string

    --- FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex
    --- digits.
    ---
    --- Not an integrity primitive: sixty-four bits puts a deliberate collision
    --- within reach of anyone who wants one.
    ---
    --- @param text Any string. NUL and bytes above 127 hash like any other.
    --- @return Sixteen hex digits, high half first, so two hashes compare as
    ---     strings the way their values compare.
    fnv1a64: function(text: string): string

    --- CRC-32 over the bytes of `text`, as a number in [0, 2^32).
    ---
    --- @param text Any string.
    --- @return The checksum PNG, gzip and ZIP put beside compressed bytes. An
    ---     error-detecting checksum and not a digest.
    crc32: function(text: string): integer

    --- Adler-32 over the bytes of `text`, as a number in [0, 2^32).
    ---
    --- @param text Any string.
    --- @return The checksum RFC 1950 puts in a zlib stream's trailer, seeded
    ---     with 1 as that document specifies. A poor content hash; use
    ---     `fnv1a64` for identity.
    adler32: function(text: string): integer
end

--- Drawing, and the vocabularies a scene is described in.
---
--- Each of those is its own module a level down rather than a section of this
--- one, because they share a subject and nothing else: a game that positions
--- bands never reads a glyph, and loading one has no reason to load the rest.
local record gfx
    layers: layers
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
    components: components
    data: data
    events: events
    filesystem: filesystem
    future: future
    gfx: gfx
    http: http
    input: input
    log: log
    materials: materials
    mcp: mcp
    net: net
    particles: particles
    paths: paths
    physics: physics
    proc: proc
    renderer: renderer
    sequence: sequence
    system: system
    text: text
    time: time
    watch: watch
    window: window
    workers: workers

    --- Version of this build.
    version: string
end

tecs.ecs = ecs

--- How one public name resolves, at whatever depth it is written.
---
--- A descriptor naming only `module` answers with that module's own table, so
--- `tecs.gfx.layers` and `require("tecs.gfx.layers")` are one value rather than
--- a copy of one. A descriptor naming anything else answers with a table built
--- here, which fills a member at a time.
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
--- `audio` is the one namespace reading two modules at one level. The mixer and
--- the device it opens are one subject at two levels, and a game asking about
--- sound should find one module rather than pick between two.
local SURFACE <const>: {string: Namespace} = {
    animation = {module = "tecs.gfx.animation"},
    application = {module = "tecs.Application", class = "Application"},
    assets = {module = "tecs.assets"},
    audio = {module = "tecs.Audio", class = "Audio", beside = {"tecs.platform.audio"}},
    camera = {module = "tecs.gfx.Camera", class = "Camera"},
    capabilities = {module = "tecs.platform.capabilities"},
    clipboard = {module = "tecs.platform.clipboard"},
    components = {module = "tecs.components"},
    data = {module = "tecs.data", beside = {"tecs.compress", "tecs.hash"}},
    events = {module = "tecs.platform.events"},
    filesystem = {module = "tecs.platform.filesystem"},
    future = {module = "tecs.Future", class = "Future"},
    gfx = {within = {layers = {module = "tecs.gfx.layers"}}},
    http = {module = "tecs.http"},
    input = {
        module = "tecs.platform.Input",
        class = "Input",
        beside = {"tecs.platform.sensors"},
        within = {Gamepad = {module = "tecs.platform.Gamepad"}},
    },
    log = {module = "tecs.log"},
    materials = {module = "tecs.gpu.materials"},
    mcp = {module = "tecs.mcp"},
    net = {module = "tecs.net"},
    particles = {module = "tecs.gfx.particles"},
    paths = {module = "tecs.platform.paths"},
    physics = {module = "tecs.physics"},
    proc = {module = "tecs.platform.proc"},
    renderer = {module = "tecs.Renderer", class = "Renderer"},
    sequence = {module = "tecs.sequence"},
    system = {module = "tecs.platform.system"},
    text = {module = "tecs.gfx.text"},
    time = {module = "tecs.platform.time"},
    watch = {module = "tecs.platform.watch"},
    window = {module = "tecs.platform.Window", class = "Window"},
    workers = {module = "tecs.workers"},
}

--- Answers what one descriptor describes, at the root and one level down
--- alike. Declared ahead of `namespace` because the two call each other: a
--- namespace resolves the descriptors under it, and each of those is a
--- descriptor like any other.
---
--- @param spec What the name resolves through. A descriptor naming only a
---     module answers with that module and loads it now; anything else answers
---     with a table that loads nothing until a member is read.
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
local function namespace(spec: Namespace): {string: any}
    local members: {string: any} = {}
    return setmetatable(
        members,
        {
            __index = function(self: {string: any}, name: string): any
                local member: any = nil
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
                rawset(self, name, member)
                return member
            end,
        }
    )
end

resolve = function(spec: Namespace): any
    local plain = spec.class == nil and spec.beside == nil and spec.within == nil
    if plain then
        return require(spec.module)
    end
    return namespace(spec)
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
