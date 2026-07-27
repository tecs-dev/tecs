--- Tecs, a typed entity component system for Lua, typed with Teal.
--- https://tecs.dev

require("tecs.internal.compat")

local types <const> = require("tecs.types")
local Context <const> = require("tecs.internal.Context")
local builtins <const> = require("tecs.internal.builtins")
local internalComponents <const> = require("tecs.internal.components")
local internalEvents <const> = require("tecs.internal.events")
local phases <const> = require("tecs.internal.phases")
local runIfHelpers <const> = require("tecs.internal.runif")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local WorldImpl <const> = require("tecs.internal.world")

--- Public API surface.
---
--- Support policy: values and types exported from `require("tecs")` are the
--- supported API, as are the `tecs.utils.*` modules (profile, pool, Bitset),
--- which may be required directly. `tecs.internal.*` modules are
--- implementation details unless re-exported here.
-- The engine half, named for its types and loaded on demand.
--
-- `local type` is erased at codegen, so these lines cost nothing at runtime and
-- the surface can still name `tecs.Application` as a type. The values arrive
-- through the metatable below.
--
-- Loading them here instead would end headless use. The engine reaches SDL,
-- Box2D and the worker library through the FFI, and those load when the module
-- that declares them loads, so a plain `require("tecs")` would demand a
-- graphics stack from a test, a server or a tool that only wanted the ECS.
local type Application = require("tecs.Application")
local type Renderer = require("tecs.Renderer")
local type Audio = require("tecs.Audio")
local type Camera = require("tecs.gfx.Camera")
local type sheet = require("tecs.gfx.sheet")
local type animation = require("tecs.gfx.animation")
local type Window = require("tecs.platform.Window")
local type Input = require("tecs.platform.Input")
local type Gamepad = require("tecs.platform.Gamepad")
local type clock = require("tecs.platform.clock")
local type events = require("tecs.platform.events")
local type clipboard = require("tecs.platform.clipboard")
local type capabilities = require("tecs.platform.capabilities")
local type paths = require("tecs.platform.paths")
local type watch = require("tecs.platform.watch")
local type components = require("tecs.components")
local type text = require("tecs.gfx.text")
local type materials = require("tecs.gpu.materials")
local type assets = require("tecs.assets")
local type workers = require("tecs.workers")
local type physics = require("tecs.physics")
local type log = require("tecs.log")
local type mcp = require("tecs.mcp")
local type json = require("tecs.json")

local record tecs
    type World = types.World
    type System = types.System
    type Plugin = types.Plugin
    type Pipeline = types.Pipeline
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

    --- The engine surface.
    Application: Application
    Renderer: Renderer
    Audio: Audio
    Camera: Camera
    sheet: sheet
    animation: animation
    Window: Window
    Input: Input
    Gamepad: Gamepad
    clock: clock
    events: events
    clipboard: clipboard
    capabilities: capabilities
    paths: paths
    watch: watch
    components: components
    text: text
    materials: materials
    assets: assets
    workers: workers
    physics: physics
    log: log
    mcp: mcp
    --- Version of this build.
    version: string
    application: function(config: Application.Config): Application

    json: json
    phases: phases
    builtins: builtins
    runif: runIfHelpers

    --- Absolute ceiling for `World.Config.maxEntities` (2^22 - 1 usable
    --- slots; slot 0 is reserved by the entity-id format).
    MAX_ENTITIES: integer

    --- Default `World.Config.maxEntities` when none is given (2^20).
    DEFAULT_MAX_ENTITIES: integer

    --- Create a new World.
    ---
    --- @param config Optional world configuration.
    --- @return the created World.
    newWorld: function(config?: types.World.Config): World

    --- Creates and registers a new table component. See `tecs.ComponentOptions` and the component docs for the
    --- shared `fields` / `defaults` / `init` / `.new` model.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Creates and registers a new scalar component.
    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): types.components.ScalarComponent<T>

    --- Creates and registers a new tag component that uses bitset storage for efficiency.
    newTagComponent: function(options: TagComponentOptions): Component

    --- Creates and registers a new relationship component. See the relationship
    --- docs for target/exclusive/sparse semantics. A target-only relationship
    --- (name plus flags, no `container`/`fields`) is backed by a compact FFI
    --- struct automatically; add `container`/`fields` for relationships that
    --- carry data.
    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    --- Create an FFI-backed relationship with data fields.
    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    --- Creates and registers an FFI-based component. Same constructor model
    --- as `newComponent`, but the base instance is an FFI struct.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Create a new typed configuration key for storing resources in a Context.
    ---
    --- Always pass a name: named keys are discoverable at runtime through
    --- `findKey`/`listKeys` and the tooling built on them (the MCP `inspect`
    --- tool, `tecs info --keys`), and a named key is a stable identity --
    --- calling `newKey` again with the same name returns the same key, so
    --- values keyed by it survive hot reload. An unnamed key works but logs a
    --- warning and stays invisible to name-based lookups.
    ---
    --- @param name A stable, unique name for the key, e.g. "game.state".
    --- @param forType Optional type parameter for type inference.
    --- @return A new key that can be used to store values of type T.
    newKey: function<T>(name?: string, forType?: T): Key<T>

    --- Find a named key created by `newKey`. Returns nil when unknown.
    ---
    --- @param name The name the key was created with.
    findKey: function<T>(name: string): Key<T> | nil

    --- All named keys, as a fresh name -> numeric key id table.
    listKeys: function(): {string: integer}

    --- Create a new Context instance.
    newContext: function(): Context

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- @param event The event instance to configure.
    newEvent: function<E is Event>(event: E)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- @param event The event type to configure.
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    newFFIEvent: function<E is Event>(
        event: E,
        fields: {{string, string}},
        structName?: string
    )

    --- Create a new address-based event message bus.
    newMessageBus: function(): MessageBus

    --- Look up a registered component by numeric ID.
    getComponentById: function(id: integer): Component

    --- Look up a registered component by name.
    componentByName: function(name: string): Component
end

-- Teal does not accept bare assignment of these polymorphic function values between record fields, even when the
-- signatures are structurally identical.
tecs.newComponent = internalComponents.newComponent
    as function<C is types.components.Component>(options: types.components.ComponentOptions<C>): C
tecs.newScalarComponent = internalComponents.newScalarComponent
    as function<T>(options: types.components.ScalarComponentOptions<T>): types.components.ScalarComponent<T>
tecs.newTagComponent = internalComponents.newTagComponent
    as function(options: types.components.TagComponentOptions): types.components.Component
tecs.newFFIComponent = internalComponents.newFFIComponent
    as function<C is types.components.Component>(options: types.components.FFIComponentOptions<C>): C
tecs.newRelationship = internalComponents.newRelationship
    as function<R is types.components.Relationship>(config: types.components.RelationshipOptions<R>): R
tecs.newFFIRelationship = internalComponents.newFFIRelationship
    as function<R is types.components.Relationship>(config: types.components.FFIRelationshipOptions<R>): R

function tecs.getComponentById(id: integer): types.components.Component
    return internalComponents.componentsById[id]
end

function tecs.componentByName(name: string): types.components.Component
    return internalComponents.registeredComponents[name]
end

tecs.newWorld = WorldImpl.new
tecs.newKey = Context.newKey
tecs.findKey = Context.findKey
tecs.listKeys = Context.listKeys
tecs.newContext = Context.new
tecs.newEvent = internalEvents.newEvent
tecs.newFFIEvent = internalEvents.newFFIEvent
tecs.newMessageBus = internalEvents.MessageBus.new
tecs.phases = phases
tecs.builtins = builtins
tecs.runif = runIfHelpers
tecs.MAX_ENTITIES = IdAllocator.ABSOLUTE_MAX_SLOT_COUNT
tecs.DEFAULT_MAX_ENTITIES = IdAllocator.DEFAULT_MAX_SLOT_COUNT

--- Builds the application an entry file returns.
---
--- Not a function that runs until done: an entry file ends with
--- `return tecs.application(config)` and the host drives it from there,
--- because a platform that never hands control back has no loop to block in.
function tecs.application(config: Application.Config): Application
    -- Required here rather than at the top, so the module that reaches SDL
    -- loads when a game asks for an application and not when a tool asks for
    -- the ECS.
    local module = require("tecs.Application") as {string: any}
    local create = module.create as function(Application.Config): Application
    return create(config)
end

--- Module paths resolved on first use, being everything that reaches native
--- code: the engine, and JSON, whose parser is C.
---
--- Listed rather than discovered, so `tecs.Aplication` is an error where it is
--- written instead of a nil where it is called.
local ENGINE <const>: {string: string} = {
    Application = "tecs.Application",
    Renderer = "tecs.Renderer",
    Audio = "tecs.Audio",
    Camera = "tecs.gfx.Camera",
    sheet = "tecs.gfx.sheet",
    animation = "tecs.gfx.animation",
    Window = "tecs.platform.Window",
    Input = "tecs.platform.Input",
    Gamepad = "tecs.platform.Gamepad",
    clock = "tecs.platform.clock",
    events = "tecs.platform.events",
    clipboard = "tecs.platform.clipboard",
    capabilities = "tecs.platform.capabilities",
    paths = "tecs.platform.paths",
    watch = "tecs.platform.watch",
    components = "tecs.components",
    text = "tecs.gfx.text",
    materials = "tecs.gpu.materials",
    assets = "tecs.assets",
    workers = "tecs.workers",
    physics = "tecs.physics",
    log = "tecs.log",
    mcp = "tecs.mcp",
    json = "tecs.json",
}

setmetatable(tecs as {string: any}, {
    __index = function(self: {string: any}, name: string): any
        local module = ENGINE[name]
        if module == nil then return nil end
        local resolved = require(module)
        rawset(self, name, resolved)
        return resolved
    end,
})

tecs.version = "0.1.0"

return tecs
