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
local type filesystemModule = require("tecs.platform.filesystem")
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

--- Files: where they are, what is in them, and when one changed.
---
--- Where and what were two modules and are one, because they were never two
--- questions. Every path a game touches is resolved and then acted on in the
--- same breath, and a caller holding one half had to name the other module to
--- do anything with it. There is still deliberately no second way to resolve a
--- path: every operation takes the string the platform takes, so a path from
--- here, a path a user typed and an absolute path from somewhere else all work
--- and none is rewritten on the way through.
---
--- Watching is the one thing below rather than beside, under
--- `tecs.filesystem.watch`. It is a running poller with a lifecycle of its own
--- rather than a call that answers, and its vocabulary, an interval, a settle
--- count and a set of kinds, means nothing to the rest of this.
local record filesystem
    --- Polling for changed files, and dispatching what changed.
    watch: watch

    --- What a path is. Symbolic links are followed, so a link never reports as
    --- one: "other" is a socket, a fifo or a device.
    type PathType = filesystemModule.PathType

    --- What the backend answered about one path.
    type Info = filesystemModule.Info

    --- Which of the platform's well-known folders to ask for.
    type UserFolder = filesystemModule.UserFolder

    --- How a pattern is matched.
    type GlobOptions = filesystemModule.GlobOptions

    --- A write that takes its bytes in pieces.
    type Writer = filesystemModule.Writer

    --- A read that hands its bytes over in pieces.
    type Reader = filesystemModule.Reader

    --- Organisation and application names, used to name the writable
    --- directory. Set before anything asks for `preferencePath`.
    organisation: string
    application: string

    --- Directory the executable was loaded from, with a trailing separator.
    ---
    --- @return The directory. Empty rather than nil when the platform declines
    ---     to say, which is the case on some targets and is not an error.
    basePath: function(): string

    --- Writable directory for this application, created if absent.
    ---
    --- @return The directory, with a trailing separator, named from
    ---     `organisation` and `application`. The only place a build may write:
    ---     everything else is read-only on at least one target.
    preferencePath: function(): string

    --- Root the engine reads content from, with a trailing separator.
    ---
    --- @return `TECS_ASSETS` if it is set, then what the host was told at build
    ---     time, then `basePath`. Cached until the platform changes.
    assetRoot: function(): string

    --- Resolves `relative` against the asset root.
    ---
    --- @param relative A path under the content root, with `/` separators.
    ---     Joined, not validated: nothing here asks whether the file is there.
    --- @return The absolute path.
    assetPath: function(relative: string): string

    --- Resolves `relative` against the writable root.
    ---
    --- @param relative A path under the preference directory.
    --- @return The absolute path.
    writablePath: function(relative: string): string

    --- Overrides the asset root, for a test or a tool.
    ---
    --- @param root The directory to read content from. A trailing separator is
    ---     added when it is missing rather than doubled when it is not.
    setAssetRoot: function(root: string)

    --- Forgets the cached roots. A platform change is noticed without this, so
    --- this is for a test that moved something under the process.
    resetPaths: function()

    --- What is at `path`, or nil when there is nothing there.
    ---
    --- @param path Any path the platform takes.
    --- @return The info, or nil for a path that does not exist, a broken
    ---     symbolic link, or a directory that cannot be searched.
    --- @return The reason, which is what separates those cases.
    info: function(path: string): filesystemModule.Info, string

    --- Whether anything is at `path`.
    ---
    --- @param path Any path the platform takes.
    --- @return Whether it is there. One syscall, as are `isFile` and
    ---     `isDirectory`, so ask `info` once when more than one bit is wanted.
    exists: function(path: string): boolean

    --- Whether `path` is a regular file, following symbolic links.
    ---
    --- @param path Any path the platform takes.
    --- @return Whether it is a file. False for a path that is not there.
    isFile: function(path: string): boolean

    --- Whether `path` is a directory, following symbolic links.
    ---
    --- @param path Any path the platform takes.
    --- @return Whether it is a directory. False for a path that is not there.
    isDirectory: function(path: string): boolean

    --- Entries under `path` matching `pattern`, as paths relative to `path`.
    ---
    --- @param path The directory to walk.
    --- @param pattern `*` and `?` wildcards, neither of which matches a
    ---     separator, or nil for the whole tree below `path`.
    --- @param options How the pattern is matched.
    --- @return The entries, joined with `/` whatever the platform's separator
    ---     is, in the platform's own order and not sorted. Directories are
    ---     among them and are not marked. Nil when `path` could not be
    ---     enumerated, which an empty list does not mean.
    --- @return The reason, when the first return is nil.
    glob: function(path: string, pattern?: string, options?: filesystemModule.GlobOptions): {string}, string

    --- Names directly inside `path`, not recursively.
    ---
    --- @param path The directory to read.
    --- @return The names, not paths: join them to `path` yourself, which is
    ---     what keeps this from being a second path resolver.
    --- @return The reason, when the first return is nil.
    list: function(path: string): {string}, string

    --- Creates `path`, and any parents it needs.
    ---
    --- @param path The directory to create.
    --- @return Whether it is there afterwards, which includes a directory that
    ---     already existed. SDL's backend leaves an error string set even on
    ---     success, so do not read `SDL_GetError` after this.
    --- @return The reason, when it failed.
    createDirectory: function(path: string): boolean, string

    --- Removes a file, or an empty directory.
    ---
    --- @param path What to remove. A directory with anything in it fails; this
    ---     does not recurse.
    --- @return Whether the path is gone, which is true when there was nothing
    ---     there to start with. Ask `exists` first if the difference matters.
    --- @return The reason, when it failed.
    remove: function(path: string): boolean, string

    --- Moves `from` to `to`, replacing whatever was at `to`.
    ---
    --- @param from A file or a directory.
    --- @param to The destination, overwritten with no warning and nothing to
    ---     undo it.
    --- @return Whether it moved. Whether this works across filesystems is the
    ---     platform's business.
    --- @return The reason, when it failed.
    rename: function(from: string, to: string): boolean, string

    --- Copies the file at `from` to `to`, replacing whatever was at `to`.
    ---
    --- @param from A file. A directory is refused.
    --- @param to The destination, whose parent must already exist.
    --- @return Whether it copied.
    --- @return The reason, when it failed.
    copy: function(from: string, to: string): boolean, string

    --- Records a path under the kind it was first read as.
    ---
    --- @param path The path that was opened.
    --- @param kind What the bytes are: "image", "sound", "font", or
    ---     "document". A named kind supersedes "document" whichever order the
    ---     two arrive in, since `read` answers bytes and cannot know what asked
    ---     for them.
    note: function(path: string, kind: string)

    --- Reads a whole file and returns its bytes.
    ---
    --- Synchronous, which is what makes it usable while a world is being built.
    --- A decode a frame should not wait on goes through `assets` instead.
    ---
    --- @param path An absolute path, or one `assetPath` has resolved.
    --- @param kind What the bytes were read as, for anything watching what this
    ---     process has opened. Omitted records the path as a document.
    --- @return The bytes, which carry their own length so a NUL in the middle
    ---     is a byte like any other. Nil when the file could not be read.
    read: function(path: string, kind?: string): string

    --- Every path this process has read or decoded, by the kind it was read as.
    ---
    --- @return The live table, so something consulting it periodically does not
    ---     copy it, and shared, so a caller that means to keep it does not also
    ---     mean to edit it. A path that failed to load is in it too, and is
    ---     exactly the one worth noticing a change to.
    loaded: function(): {string: string}

    --- Writes `bytes` to `path`, replacing whatever was there.
    ---
    --- @param path The file to write. Its parent directory must already exist.
    --- @param bytes What to write. The string's own length is written, so an
    ---     empty string makes an empty file.
    --- @return Whether it was written.
    --- @return The reason, when it failed.
    write: function(path: string, bytes: string): boolean, string

    --- Opens `path` for writing in pieces, replacing whatever was there.
    ---
    --- @param path The file to write.
    --- @return The writer, which must be closed: the bytes are not guaranteed
    ---     to be on disk until `close` answers, and that is the call a full
    ---     disk is reported by. Nil when there is none.
    --- @return The reason, when the first return is nil.
    openWrite: function(path: string): filesystemModule.Writer, string

    --- Opens `path` for reading in pieces. The mirror of `openWrite`.
    ---
    --- @param path The file to read.
    --- @return The reader, for a file to be handed over as it goes rather than
    ---     held whole. Nil when there is none.
    --- @return The reason, when the first return is nil.
    openRead: function(path: string): filesystemModule.Reader, string

    --- The process working directory, with a trailing separator.
    ---
    --- Where a command line tool resolves the relative paths it was given.
    --- Emphatically not where a game reads content or writes state:
    --- `assetRoot` and `preferencePath` answer that.
    ---
    --- @return The directory, or nil on a platform that has none, which is most
    ---     that are not a desktop.
    --- @return The reason, when the first return is nil.
    currentDirectory: function(): string, string

    --- One of the platform's well-known folders, with a trailing separator.
    ---
    --- @param which Which folder. A name the backend does not know raises.
    --- @return The folder, or nil, which is legitimate and common: macOS has no
    ---     saved-games, screenshots or templates folder, and a platform that is
    ---     not a desktop may have none of them. Never a place a build may
    ---     write; `preferencePath` is the only one.
    --- @return The reason, when the first return is nil.
    userFolder: function(which: filesystemModule.UserFolder): string, string
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
    physics: physics
    proc: proc
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
    filesystem = {
        module = "tecs.platform.filesystem",
        beside = {"tecs.platform.paths"},
        within = {watch = {module = "tecs.platform.watch"}},
    },
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
    physics = {module = "tecs.physics"},
    proc = {module = "tecs.platform.proc"},
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
        --- A namespace stands in front of several modules, and some of what
        --- they carry is assigned rather than called:
        --- `tecs.filesystem.organisation` is read back by
        --- `preferencePath`, so a write parked on this table would be a
        --- write nothing sees. Ownership is decided the way a read decides
        --- it, and a name no module below answers is the namespace's own.
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
