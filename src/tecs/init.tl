--- Tecs, a typed entity component system for Lua, typed with Teal.
--- https://tecs.dev

require("tecs.internal.compat")

local types <const> = require("tecs.types")
local Context <const> = require("tecs.internal.Context")
local builtins <const> = require("tecs.internal.builtins")
local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local phases <const> = require("tecs.internal.phases")
local runIfHelpers <const> = require("tecs.internal.runif")
local json <const> = require("tecs.utils.json")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local WorldImpl <const> = require("tecs.internal.world")

--- Public API surface.
---
--- Support policy: values and types exported from `require("tecs")` are the
--- supported API, as are the `tecs.utils.*` modules (json, logging, profile,
--- pool, Bitset), which may be required directly. `tecs.internal.*` modules
--- are implementation details unless re-exported here.
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
tecs.newComponent = components.newComponent
    as function<C is types.components.Component>(options: types.components.ComponentOptions<C>): C
tecs.newScalarComponent = components.newScalarComponent
    as function<T>(options: types.components.ScalarComponentOptions<T>): types.components.ScalarComponent<T>
tecs.newTagComponent = components.newTagComponent
    as function(options: types.components.TagComponentOptions): types.components.Component
tecs.newFFIComponent = components.newFFIComponent
    as function<C is types.components.Component>(options: types.components.FFIComponentOptions<C>): C
tecs.newRelationship = components.newRelationship
    as function<R is types.components.Relationship>(config: types.components.RelationshipOptions<R>): R
tecs.newFFIRelationship = components.newFFIRelationship
    as function<R is types.components.Relationship>(config: types.components.FFIRelationshipOptions<R>): R

function tecs.getComponentById(id: integer): types.components.Component
    return components.componentsById[id]
end

function tecs.componentByName(name: string): types.components.Component
    return components.registeredComponents[name]
end

tecs.newWorld = WorldImpl.new
tecs.newKey = Context.newKey
tecs.findKey = Context.findKey
tecs.listKeys = Context.listKeys
tecs.newContext = Context.new
tecs.newEvent = events.newEvent
tecs.newFFIEvent = events.newFFIEvent
tecs.newMessageBus = events.MessageBus.new
tecs.json = json
tecs.phases = phases
tecs.builtins = builtins
tecs.runif = runIfHelpers
tecs.MAX_ENTITIES = IdAllocator.ABSOLUTE_MAX_SLOT_COUNT
tecs.DEFAULT_MAX_ENTITIES = IdAllocator.DEFAULT_MAX_SLOT_COUNT

return tecs
