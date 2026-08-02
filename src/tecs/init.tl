--[=[
Tecs, a typed entity component system for Lua, typed with Teal.
https://tecs.dev
]=]

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
-- the module below can still name `tecs.gfx.Camera2D` as a type. The values
-- arrive through the metatable further down.
--
-- Loading them here instead would end headless use. The engine reaches SDL,
-- Rapier and the worker library through the FFI, and those load when the module
-- that declares them loads, so a plain `require("tecs")` would demand a
-- graphics stack from a test, a server or a tool that only wanted the ECS.
local type Application = require("tecs.Application")
local type scopeModule = require("tecs.scope")
local type audio = require("tecs.audio")
local type Renderer = require("tecs.Renderer")
local type Camera2D = require("tecs.gfx.Camera2D")
local type Camera3D = require("tecs.gfx.Camera3D")
local type FlyCamera3D = require("tecs.gfx.FlyCamera3D")
local type View = require("tecs.gfx.View")
local type Model3D = require("tecs.gfx.Model3D")
local type animation = require("tecs.gfx.animation")
local type events = require("tecs.events")
local type input = require("tecs.input")
local type platformEvents = require("tecs.platform.events")
local type platformOS = require("tecs.platform.os")
local type platformTime = require("tecs.platform.time")
local type platformWindow = require("tecs.platform.window")
local type binaryIO = require("tecs.io")
local type layers = require("tecs.gfx.layers")
local type sequence = require("tecs.sequence")
local type components = require("tecs.components")
local type text = require("tecs.gfx.text")
local type particles = require("tecs.gfx.particles")
local type materials = require("tecs.gpu.materials")
local type assets = require("tecs.assets")
local type workers = require("tecs.workers")
local type ui = require("tecs.ui")
local type physics = require("tecs.physics")
local type log = require("tecs.log")
-- `math` is the standard library global, and shadowing it makes a clean
-- project type-check warn. The public name and required module are still math.
local type angleMath = require("tecs.math")
local type data = require("tecs.data")
local type regex = require("tecs.regex")
local type loader = require("tecs.ffi.loader")
local type Closeable = types.Closeable

-- The two records below are written for one reason: a public name that no
-- single module answers. `tecs.gfx` is the modules one level down and the
-- facilities a scene reaches for directly. `tecs.platform` is four independent
-- host facilities with no principal module. No module's own record types either
-- namespace, so their records live here.
--
-- A public name that one module answers needs none of this, and has none. It
-- resolves to that module, is typed by the record the module declares, and
-- carries the names one level down as fields of its own: `tecs.io` is
-- `src/tecs/io/init.tl`, `Path`, `Process`, `URI`, `files`, `http`, `mcp`, and
-- `watcher` included. That is
-- the shape to reach for, because a record here restates every signature and
-- every docblock the module already carries and nothing checks the two against
-- each other.
--
-- A class is a record nested inside the module named for it, so `tecs.audio` is
-- `src/tecs/audio.tl` and `tecs.audio.Audio` is the class it declares. One name
-- is the module and the other is the type, and the satellite records sit beside
-- the class on the same module, so a game reaches `tecs.platform.window.Options` without
-- going through `Window` first.
--
-- A module may also sit inside another module, one level and no deeper:
-- `tecs.gfx.layers`, `tecs.io.files`. `SURFACE` is what declares that,
-- through `within`, and a lowercase field of a record here is one of them only
-- where the parent has no module of its own.

--- Drawing: what a frame is drawn from, what draws it, and the vocabularies a
--- scene is described in.
---
--- The facilities every scene reaches for sit here directly. The four
--- vocabularies are each their own module a level down rather than a section of
--- this one, because they share a subject and nothing else: a game that
--- positions bands never reads a glyph, and loading one has no reason to load
--- the rest.
local record gfx
    --- Marks a 3D point or spot light for the optional local-shadow atlas when
    --- included in the component's integer `flags` field.
    LIGHT_CASTS_SHADOWS: integer

    --- The view a frame is drawn from.
    Camera2D: Camera2D
    type Camera2DOptions = Camera2D.Options

    --- The perspective view used by the 3D mesh domain.
    Camera3D: Camera3D
    type Camera3DOptions = Camera3D.Options

    --- The noclip mouse-and-keyboard controller for a perspective camera.
    FlyCamera3D: FlyCamera3D
    type FlyCamera3DOptions = FlyCamera3D.Options

    --- The entity component that draws one ordered viewport.
    View: View

    --- The resident shared resources for one registered glTF model.
    type Model3D = Model3D
    --- One independently posed copy of a registered glTF model.
    type ModelInstance3D = Model3D.Instance
    --- One spawnable component bundle in a model instance.
    type ModelPrimitive3D = Model3D.Primitive
    --- Playback options accepted by `ModelInstance3D:play`.
    type ModelPlayOptions3D = Model3D.PlayOptions

    --- A world to a frame, through an extractor and a backend.
    Renderer: Renderer
    type RendererOptions = Renderer.Options
    --- Statistics reported by both 2D and 3D rendering domains.
    type DomainStats = Renderer.DomainStats
    type SpriteDomain = Renderer.SpriteDomain
    type SpriteOptions = Renderer.SpriteOptions
    type MeshDomain = Renderer.MeshDomain
    type MeshOptions = Renderer.MeshOptions
    type SpriteInstanceProducer = Renderer.SpriteInstanceProducer
    type SpriteClipRegion = Renderer.SpriteClipRegion
    type SpriteComputeStage = Renderer.SpriteComputeStage

    --- Builds a view onto the world.
    ---
    --- @param options Omit for an unrotated, unzoomed view at the world origin,
    ---     which a renderer recenters on its first drawn frame if the game
    ---     never moves it. No field is validated.
    --- @return A camera whose fields are plain and meant to be assigned to
    ---     frame by frame. It is not attached to anything. The renderer's
    ---     default lives on `renderer.sprites.camera`; assign another to a
    ---     [`View`](tealdoc:tecs.gfx.View) entity to draw it.
    newCamera2D: function(options?: Camera2D.Options): Camera2D

    --- Builds a perspective view into a right-handed 3D world.
    --- @param options Omit for a camera at the origin looking down negative z.
    --- @return A camera whose position, orientation, and projection fields the
    ---     caller assigns directly. Assign it to a
    ---     [`View`](tealdoc:tecs.gfx.View) entity to draw it.
    newCamera3D: function(options?: Camera3D.Options): Camera3D

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

    -- The components a game spawns to put something on screen. All but the two
    -- Renderable tags are FFI components, so their columns are contiguous C
    -- memory the sync walks row by row into mapped GPU staging: writing one
    -- through `world:get` needs an explicit `world:markComponentDirty`, since
    -- only `getMut` marks the column on its own.
    --
    -- `Transform2D` is not among them. It positions everything a world holds
    -- rather than only what draws, so it is the ECS builtin and is reached as
    -- `tecs.Transform2D`, at the root.

    --- The transform as it stood before the current fixed step. Presence is
    --- the opt-in to interpolation: an entity carrying it is drawn between
    --- this and its current transform, so physics does not step visibly.
    --- Carries `x`, `y` and `rotation` (radians) only, because scale and
    --- layer change by assignment rather than by integration.
    PreviousTransform2D: components.PreviousTransform2D

    --- Base color and coverage, each channel 0 to 1, defaulting to opaque
    --- white. The alpha decides which pass draws the entity: exactly 1 goes
    --- through the G-buffer and is lit once for the whole scene, anything
    --- below 1 goes through the forward pass instead, writes no depth, and
    --- is dropped when the forward list is full. Say 1 exactly for anything
    --- meant to be solid.
    Tint: components.Tint

    --- Samples a texture instead of drawing flat color. `image` is an
    --- `imageId` index, and 0 means no image; `u0, v0, u1, v1` select the
    --- region, defaulting to the whole of it, so an atlas entry and a whole
    --- image are the same thing. `slot` is the texture-array layer the
    --- renderer resolved `image` to, and a negative value means unresolved:
    --- pointing a live Sprite at another image means writing a negative slot
    --- along with the new `image`, or the row keeps drawing the old layer.
    --- Only the image name survives a snapshot.
    Sprite: components.Sprite

    --- Selects immutable geometry for the 3D mesh domain. `asset` is the
    --- process-local index returned by `meshId`; `slot` is engine-owned and a
    --- negative value means the asset has not been made resident.
    Mesh: components.Mesh

    --- Selects a resident joint palette for an entity in a skinning-enabled
    --- mesh domain. Omit it for rigid geometry.
    MeshSkin: components.MeshSkin

    --- Selects a resident morph-weight vector for an entity in a
    --- morphing-enabled mesh domain. Omit it for the undeformed base mesh.
    MeshMorph: components.MeshMorph

    --- Selects resident PBR data for the mesh domain. `asset` is a
    --- `meshMaterialId` identity and `slot` is engine-owned residency state.
    MeshMaterial: components.MeshMaterial

    --- Supplies a mesh's local-space bounding sphere. The mesh cull
    --- transforms its center and scales its radius by the largest absolute
    --- scale axis.
    Bounds3D: components.Bounds3D

    --- Selects a compiled 2D shader material. Absent selects the default
    --- material. Take `id` from `materials.id(name)` rather than writing a
    --- number because sorted material names determine ids and move when a
    --- file is added. Meshes use `MeshMaterial` instead. `param` runs from
    --- zero to one and means whatever the selected 2D material says it does.
    Material: components.Material

    --- A light the deferred lighting pass resolves, positioned by the
    --- entity's Transform2D and in the same world units. `height` is above the
    --- surface plane and at 0 the light contributes nothing at all;
    --- `radius` is its reach in world units; `r`, `g`, `b` and `intensity`
    --- default to white at 1.
    PointLight2D: components.PointLight2D

    --- An omnidirectional 3D light positioned by `Transform3D`.
    PointLight3D: components.PointLight3D

    --- A conical 3D light positioned and aimed by `Transform3D`.
    SpotLight3D: components.SpotLight3D

    --- Keeps a renderable's fragments inside one rectangle. `index` names a
    --- region set with `renderer.sprites:setClipRegion`, and 0, the default, means
    --- no clipping. A region is a single rectangle, so nesting is the
    --- caller's job: intersect the two and set that.
    Clip: components.Clip

    --- Blocks every light with the shape the entity draws. `height` is 0 to
    --- 1 of the world height `Deferred.shadowHeight` sets, so 1 is a full
    --- wall and 0 is something lying flat that blocks nothing. Needs
    --- `shadows` on the renderer; without it the entity draws and casts
    --- nothing.
    Occluder2D: components.Occluder2D

    --- Darkens the ground away from each of the nearest lights, ambient
    --- included, and blocks no light. `height` is 0 to 1 and decides how far
    --- the copy is thrown, under the same reading as `Occluder2D.height`. An
    --- entity carrying both is an occluder.
    DropShadow2D: components.DropShadow2D

    --- Marks an entity as contributing geometry. A tag, so it costs a
    --- column of nothing; without it a Transform2D is only a position, which
    --- is what most entities in a world are.
    Renderable2D: components.Renderable2D

    --- Marks an entity as contributing geometry to the mesh domain.
    --- Without it, a `Transform3D` and `Mesh` remain ordinary world state.
    Renderable3D: components.Renderable3D

    --- Index of an image name, assigning one the first time it is seen.
    ---
    --- The name is normalized lexically first, so `"a/b.png"` and
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
    --- @return The normalized name, or nil when the index names nothing.
    imageName: function(id: integer): string

    --- Index of a normalized mesh asset name, assigning one on first use.
    --- @param name A non-empty mesh asset name or path.
    --- @return A positive process-local index that snapshots replace with the
    ---     name.
    meshId: function(name: string): integer

    --- Name a mesh index stands for.
    --- @param id An index previously returned by `meshId`.
    --- @return The normalized name, or nil when the index names nothing.
    meshName: function(id: integer): string

    --- Returns a process-local identity for a mesh material name.
    --- @param name A non-empty stable material name.
    --- @return A positive process-local index.
    meshMaterialId: function(name: string): integer

    --- Returns the name represented by a mesh material identity.
    --- @param id An index previously returned by `meshMaterialId`.
    --- @return The normalized name, or nil.
    meshMaterialName: function(id: integer): string

    --- What `newTTF` answers with, and what a `Text` names.
    type Font = text.Font
    --- Whether a font stores scalable distance fields or direct alpha glyphs.
    type FontRaster = text.FontRaster
    --- What `newTTF` takes.
    type TTFOptions = text.TTFOptions
    --- What `textPlugin` takes.
    type TextOptions = text.TextOptions

    --- A run of shaped text, drawn as one entity whose glyphs are not entities.
    --- Needs `textPlugin` installed on the world.
    Text: text.Text

    --- Loads a TrueType or OpenType source font with SDL_ttf.
    --- @param options The caller supplies a source path and may select the
    ---     raster point size and snapshot identity.
    --- @return An immutable font after its source bytes have been read and opened.
    newTTF: function(options: text.TTFOptions): text.Font

    --- Extent of a `Text` in world units, laid out the way the system lays it
    --- out and without touching any entity.
    measureText: function(item: text.Text): number, number

    --- The plugin that lays texts out and produces their glyph instances.
    --- Named for what it installs, since `tecs.gfx.plugin` would read as the
    --- plugin for drawing rather than the one for text.
    textPlugin: function(options: text.TextOptions): function(types.World)

    --- How many texts have been laid out in a world since it was created,
    --- which is what asserts the dirty gates rather than assuming them.
    textLayouts: function(world: types.World): integer

    --- Where the `index`th glyph of an entity's `Text` landed, as world x, y,
    --- width and height.
    glyphAt: function(world: types.World, entity: integer, index: integer): number, number, number, number

    animation: animation
    layers: layers
    materials: materials
    particles: particles
end

--- Facilities supplied by the host platform.
---
--- Naming the namespace loads nothing. Each child resolves independently, so
--- a headless tool can use operating-system services or monotonic time without
--- loading window or event support.
local record platform
    --- Read-only. Exposes typed platform events routed through a world's
    --- event bus.
    events: platformEvents
    --- Read-only. Exposes operating-system capabilities, clipboard access,
    --- process signals, and desktop services.
    os: platformOS
    --- Read-only. Exposes monotonic time and an override for deterministic
    --- replay.
    time: platformTime
    --- Read-only. Exposes window creation, display information, and window
    --- modes.
    window: platformWindow
end

-- The four ECS types every subsystem's signatures name, and the only ECS
-- vocabulary here. A plugin is handed a `World`, a system is a `System`, a
-- plugin is a `Plugin`, and what either of them iterates is a `Query`, so
-- physics, drawing, audio and the sequencer all write these four in their own
-- public signatures. The rest of the vocabulary is machinery for configuring
-- the ECS rather than for reaching across it, so `Component`, `Archetype`,
-- `Bundle`, `SystemConfig` and the snapshot records are `tecs.ecs.*` and have
-- one spelling there.
local type World = types.World
local type Query = types.Query
local type System = types.System
local type Plugin = types.Plugin

local record tecs
    --- An owned value that releases its active lifetime through `close`.
    type Closeable = Closeable

    type World = World
    type Query = Query
    type System = System
    type Plugin = Plugin

    --- The application the host drives, and what a game reaches the window,
    --- the device, the input, the renderer and the audio through.
    ---
    --- At the root because it is not a subsystem: it owns one of each of them
    --- and is handed to the entry plugin beside the world.
    Application: Application

    --- What `newApplication` takes. Named here so a game can annotate the
    --- table it passes without reaching through the class for it.
    type ApplicationConfig = Application.Config

    --- `Scope` owns explicitly registered resources for one lexical lifetime.
    type Scope = scopeModule.Scope

    --- Runs a callback inside a fresh named resource scope and JIT zone.
    ---
    --- Every [`Closeable`](tealdoc:tecs.Closeable) registered through the
    --- callback's [`Scope`](tealdoc:tecs.Scope) closes in reverse order after
    --- the callback returns or raises. Cleanup attempts every close. Inside a
    --- system, the callback may suspend through a cooperative engine call;
    --- owned resources remain live until it resumes and cleanup begins. A
    --- captured scope refuses registration after cleanup starts.
    ---
    --- @param name The non-empty diagnostic and profiler-zone name.
    --- @param body The lexical callback that owns the scope and every resource
    ---     registered through it. Returned values are ignored.
    scoped: function(name: string, body: function(scopeModule.Scope))

    --- Builds the application an entry file returns.
    ---
    --- Not a function that runs until done: an entry file ends with
    --- `return tecs.newApplication(config)` and the host drives it from there,
    --- because a platform that never hands control back has no loop to block
    --- in.
    ---
    --- @param config Read here, so a field changed on the table afterwards is
    ---     not seen. Nothing is opened yet: the window, the GPU device and the
    ---     audio mixer are the host's to bring up on the first callback, which
    ---     is what lets an entry file be loaded by a tool that never runs one.
    --- @return The application the host drives through its init, event, iterate
    ---     and quit callbacks. Returning it is the whole contract; a game that
    ---     calls into it itself is doing the host's job.
    newApplication: function(config: Application.Config): Application

    --- Worlds, components, queries, systems, events and resources. The one
    --- half that reaches nothing below Lua, so it is here rather than
    --- resolved on demand.
    ecs: ecs

    --- Where an entity is: `x`, `y`, `z`, `layer`, `rotation`, `scaleX` and
    --- `scaleY`, in world units and radians.
    ---
    --- At the root because it is the one component every subsystem moves. The
    --- hierarchy composes it, physics writes it back from the solver, the
    --- sequencer tweens it, animation drives it and the extractor reads it, so
    --- filing it under any one of those would tell the other four they are
    --- reaching into somebody else's module. It is the only component here:
    --- everything else a game spawns belongs to whichever module owns what it
    --- does, and `tecs.gfx.Sprite` says which one that is.
    ---
    --- Not on `tecs.gfx`, and that is the load-bearing half. The ECS registers
    --- it for every world whether a renderer exists or not, while reading a
    --- name on `tecs.gfx` resolves SDL through the FFI: a headless tool that
    --- positions an entity would be made to find a graphics stack to do it.
    ---
    --- Published here off `tecs.ecs`, which costs nothing that naming it one
    --- level down would not: `ecs` is loaded by the time `tecs` is.
    Transform2D: ecs.Transform2D

    --- Where a 3D entity is: world position, local-to-world quaternion, and
    --- local scale. The default is the identity transform. It sits at the root
    --- beside `Transform2D` because simulation and rendering share it.
    Transform3D: ecs.Transform3D

    assets: assets
    audio: audio
    physics: physics
    data: data
    events: events
    input: input
    gfx: gfx
    io: binaryIO
    log: log
    math: angleMath
    platform: platform
    regex: regex
    sequence: sequence
    ui: ui
    workers: workers

    --- Read-only. Version of this build.
    version: string
end

tecs.ecs = ecs

-- Assigned rather than resolved, for the same reason `ecs` is: the module it
-- comes off is already loaded here, so there is nothing to defer.
tecs.Transform2D = ecs.Transform2D
tecs.Transform3D = ecs.Transform3D

--- How one public name resolves, at whatever depth it is written.
---
--- A descriptor with one principal `module` answers with that module's own
--- table, so `tecs.io` and `require("tecs.io")` are
--- one value rather than a copy of one. Names one level down are hung off it
--- lazily, so a `within` costs nothing until one of them is read.
---
--- A descriptor naming a `member` answers with that one name off the module
--- instead, which is what a public name that is a function rather than a table
--- resolves through.
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
    --- The one name taken off `module`, for a public name that is a function
    --- rather than a table. `tecs.newApplication` is the constructor declared
    --- in `tecs.Application`, and naming it loads that module and nothing else.
    member: string
    --- Further modules read at this level, searched before `module`.
    beside: {string}
    --- The names one level down, each described the same way and each resolved
    --- on the first read of its own name.
    within: {string: Namespace}
end

--- What every public name resolves to, described once and used at both levels.
---
--- Everything here is resolved on first use: the engine, which reaches SDL,
--- Rapier and the worker library through the FFI, JSON, whose parser is C, and
--- the byte facilities, which cost nothing to skip and which most programs
--- never ask for. A tool that names none of them loads none of them, and that
--- holds a level down too: reading `tecs.gfx.layers` loads layers and nothing
--- else under `gfx`.
---
--- Listed rather than discovered, so `tecs.anmation` is an error where it is
--- written instead of a nil where it is called.
---
--- `gfx` and `platform` are the namespaces with no principal module. No
--- candidate can answer for `gfx` without loading SDL when the name is read,
--- and platform is only a grouping over five independent facilities. Every
--- other name here answers with one module, which is what lets that module's
--- own record type it.
local SURFACE <const>: {string: Namespace} = {
    Application = {module = "tecs.Application"},
    newApplication = {module = "tecs.Application", member = "newApplication"},
    scoped = {module = "tecs.scope", member = "scoped"},
    assets = {module = "tecs.assets"},
    audio = {module = "tecs.audio"},
    physics = {module = "tecs.physics"},
    data = {
        module = "tecs.data",
        within = {
            utf8 = {module = "tecs.data.utf8"},
        },
    },
    events = {module = "tecs.events"},
    input = {module = "tecs.input"},
    gfx = {
        beside = {
            "tecs.components",
            "tecs.gfx.Camera2D",
            "tecs.gfx.Camera3D",
            "tecs.gfx.View",
            "tecs.Renderer",
            "tecs.gfx.text",
        },
        within = {
            Camera2D = {module = "tecs.gfx.Camera2D"},
            Camera3D = {module = "tecs.gfx.Camera3D"},
            FlyCamera3D = {module = "tecs.gfx.FlyCamera3D"},
            View = {module = "tecs.gfx.View"},
            Renderer = {module = "tecs.Renderer"},
            animation = {module = "tecs.gfx.animation"},
            layers = {module = "tecs.gfx.layers"},
            materials = {module = "tecs.gpu.materials"},
            particles = {module = "tecs.gfx.particles"},
        },
    },
    io = {
        module = "tecs.io",
        within = {
            Path = {module = "tecs.io.Path"},
            Process = {module = "tecs.io.Process"},
            URI = {module = "tecs.io.URI"},
            files = {module = "tecs.io.files"},
            http = {module = "tecs.io.http"},
            mcp = {module = "tecs.io.mcp"},
            watcher = {module = "tecs.io.watcher"},
        },
    },
    log = {module = "tecs.log"},
    math = {
        module = "tecs.math",
        within = {
            noise = {module = "tecs.math.noise"},
            vec2 = {module = "tecs.math.vec2"},
        },
    },
    platform = {
        within = {
            events = {module = "tecs.platform.events"},
            os = {module = "tecs.platform.os"},
            time = {module = "tecs.platform.time"},
            window = {module = "tecs.platform.window"},
        },
    },
    regex = {module = "tecs.regex"},
    sequence = {module = "tecs.sequence"},
    ui = {module = "tecs.ui"},
    workers = {module = "tecs.workers"},
}

--- Answers what one descriptor describes, at the root and one level down
--- alike. Declared ahead of `namespace` because the two call each other: a
--- namespace resolves the descriptors under it, and each of those is a
--- descriptor like any other.
---
--- @param spec What the name resolves through. A descriptor with one principal
---     module answers with that module and loads it now, with the names below
---     it hung off it unloaded, or with one `member` off it; anything else
---     answers with a table that loads nothing until a member is read.
--- @return The module, the member, or the namespace, which is what the name is
---     from here on: the caller memoizes it, so this runs once per name.
local resolve: function(spec: Namespace): any

--- Builds the table a namespace answers with. Nothing under it loads until a
--- member is read, so naming `tecs.gfx` costs nothing until something is taken
--- out of it.
---
--- `within` is searched first and `beside` second, both ahead of `module`,
--- because they are the cheaper ones to load and no name is in more than one: a
--- module below is its own file, and reading a layer band does not load the
--- renderer.
---
--- What is resolved is remembered in a table beside the one answered with
--- rather than on it. The table a caller holds stays empty, so both metamethods
--- keep being consulted: memoizing onto it would stop `__index` firing after
--- the first read, and `__newindex` fires only for a name the table does not
--- already carry, so the first write after a read would land here instead of on
--- the module that owns the name.
local function namespace(spec: Namespace): {string: any}
    local resolved: {string: any} = {}
    return setmetatable(
        {} as {string: any},
        {
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
                    member = (require(spec.module) as {string: any})[name]
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
        }
    )
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
---     `require("tecs.io").files` is the same name reached the
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
    if spec.beside ~= nil or spec.module == nil then
        return namespace(spec)
    end
    local module = require(spec.module) as {string: any}
    if spec.member ~= nil then
        return module[spec.member]
    end
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
