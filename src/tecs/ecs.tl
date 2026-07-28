--- The ECS, for a game and for engine code alike.
---
--- One table, two readers. A game writes `tecs.ecs.newWorld()`, because
--- `tecs.ecs` is the field the public API publishes this under. An engine
--- module writes `require("tecs.ecs")`, because `tecs` is the aggregator that
--- pulls every engine module in and a module `tecs` exports cannot also depend
--- on `tecs` without making a cycle, which Teal rejects even through a
--- type-only require.
---
--- So the rule is one direction. Internal code depends on this half; only a
--- game depends on the whole. Both spellings reach the same table, so there is
--- one place a name is defined and one place to read about it.

-- First, as in before anything else. `componentcodegen` captures
-- `table.unpack` when it loads, and on this interpreter that name only exists
-- once this has run. Requiring the halves in either order has to work, and
-- this half is what a tool reaching for the ECS alone requires.
require("tecs.internal.compat")

local types <const> = require("tecs.types")
local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local builtins <const> = require("tecs.internal.builtins")
local phases <const> = require("tecs.internal.phases")
local runIfHelpers <const> = require("tecs.internal.runif")
local random <const> = require("tecs.random")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local WorldImpl <const> = require("tecs.internal.world")
local Context <const> = require("tecs.internal.Context")

local record ecs
    type World = types.World
    type System = types.System
    type Plugin = types.Plugin
    type Pipeline = types.Pipeline
    type FixedOverload = types.FixedOverload
    type Component = types.components.Component
    type ScalarComponent<T> = types.components.ScalarComponent<T>
    type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
    type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
    type ScalarComponentOptions<T> = types.components.ScalarComponentOptions<T>
    type TagComponentOptions = types.components.TagComponentOptions
    type Relationship = types.components.Relationship
    type RelationshipOptions<R is Relationship> = types.components.RelationshipOptions<R>
    type FFIRelationshipOptions<R is Relationship> = types.components.FFIRelationshipOptions<R>
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

    --- The phases a system can be scheduled into.
    phases: phases
    --- The components every world carries: `ChildOf`, `Transform`, `TTL`,
    --- `Paused`, `Disabled` and the state transition events.
    builtins: builtins
    --- Composable run conditions, for `SystemConfig.runIf`.
    runif: runIfHelpers
    --- Seeded generation, in named streams a snapshot carries.
    random: random

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

    --- Creates and registers a new table component. See `ecs.ComponentOptions`
    --- and the component docs for the shared `fields` / `defaults` / `init` /
    --- `.new` model.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Creates and registers a new scalar component.
    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): ScalarComponent<T>

    --- Creates and registers a new tag component that uses bitset storage for efficiency.
    newTagComponent: function(options: TagComponentOptions): Component

    --- Creates and registers an FFI-based component. Same constructor model
    --- as `newComponent`, but the base instance is an FFI struct.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Creates and registers a new relationship component. See the relationship
    --- docs for target/exclusive/sparse semantics. A target-only relationship
    --- (name plus flags, no `container`/`fields`) is backed by a compact FFI
    --- struct automatically; add `container`/`fields` for relationships that
    --- carry data.
    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    --- Create an FFI-backed relationship with data fields.
    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- @param event The event instance to configure.
    newEvent: function<E is Event>(event: E)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- @param event The event type to configure.
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- Create a new address-based event message bus.
    newMessageBus: function(): MessageBus

    --- A typed key for `world.resources`, and the way an engine module stores
    --- something scoped to one world.
    ---
    --- Always pass a name: named keys are discoverable at runtime through
    --- `findKey`/`listKeys` and the tooling built on them (the MCP `inspect`
    --- tool, `tecs info --keys`), and a named key is a stable identity --
    --- calling `newKey` again with the same name returns the same key, so
    --- values keyed by it survive hot reload. An unnamed key works but logs a
    --- warning and stays invisible to name-based lookups.
    ---
    --- `forType` carries the phantom type, because Teal has no explicit type
    --- argument at a call site: pass `nil as T` for `world.resources[key]` to
    --- read as a `T` rather than as `any`.
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

    --- Look up a registered component by numeric ID.
    getComponentById: function(id: integer): Component

    --- The component registered under `name`, or nil.
    ---
    --- The registry is process-wide, because a component's id is allocated
    --- once at registration and every world that carries one agrees on it. So
    --- this answers what can be named, and a world answers what is present.
    ---
    --- Finds a dense relationship instance by its stamped name as well, which
    --- `declaredComponents` leaves out.
    componentByName: function(name: string): Component

    --- Every component declared in this process, name to component.
    ---
    --- A fresh table per call, so the registry itself stays unwritable from
    --- outside registration.
    ---
    --- Dense relationship instances are left out. One is registered per target
    --- under a stamped `Rel->42` name, so a world with many edges has many of
    --- them, and none of them is a component anybody declared.
    declaredComponents: function(): {string: Component}
end

-- Teal does not accept bare assignment of these polymorphic function values
-- between record fields, even when the signatures are structurally identical.
ecs.newComponent = components.newComponent as function<C is types.components.Component>(
    options: types.components.ComponentOptions<C>
): C
ecs.newScalarComponent = components.newScalarComponent as function<T>(
    options: types.components.ScalarComponentOptions<T>
): types.components.ScalarComponent<T>
ecs.newTagComponent = components.newTagComponent as function(
    options: types.components.TagComponentOptions
): types.components.Component
ecs.newFFIComponent = components.newFFIComponent as function<C is types.components.Component>(
    options: types.components.FFIComponentOptions<C>
): C
ecs.newRelationship = components.newRelationship as function<R is types.components.Relationship>(
    config: types.components.RelationshipOptions<R>
): R
ecs.newFFIRelationship = components.newFFIRelationship as function<R is types.components.Relationship>(
    config: types.components.FFIRelationshipOptions<R>
): R
ecs.newKey = Context.newKey as function<T>(name?: string, forType?: T): types.Context.Key<T>

function ecs.getComponentById(id: integer): types.components.Component
    return components.componentsById[id]
end

function ecs.componentByName(name: string): types.components.Component
    return components.registeredComponents[name]
end

function ecs.declaredComponents(): {string: types.components.Component}
    local declared: {string: types.components.Component} = {}
    for name, component in pairs(components.registeredComponents) do
        if component.wildcardContainer == nil then
            declared[name] = component
        end
    end
    return declared
end

ecs.phases = phases
ecs.builtins = builtins
ecs.runif = runIfHelpers
ecs.random = random
ecs.newWorld = WorldImpl.new
ecs.newEvent = events.newEvent
ecs.newFFIEvent = events.newFFIEvent
ecs.newMessageBus = events.MessageBus.new
ecs.findKey = Context.findKey
ecs.listKeys = Context.listKeys
ecs.newContext = Context.new
ecs.MAX_ENTITIES = IdAllocator.ABSOLUTE_MAX_SLOT_COUNT
ecs.DEFAULT_MAX_ENTITIES = IdAllocator.DEFAULT_MAX_SLOT_COUNT

return ecs
