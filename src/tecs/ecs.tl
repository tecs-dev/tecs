--[=[
The ECS shared by game code and engine systems.

Build queries during setup, reuse them from systems, and put all game state on
entities:

```teal
local moving: tecs.Query

local function game(world: tecs.World)
    moving = world:query({include = {tecs.Transform}})

    world:addSystem({
        name = "game.Drift",
        phase = tecs.ecs.phases.Update,
        run = function(delta: number)
            for archetype, length in moving:iter() do
                local transform <const> = archetype:getMut(tecs.Transform)
                for row = 1, length do
                    transform[row].x = transform[row].x + 60 * delta
                end
            end
        end,
    })

    world:spawn(tecs.Transform(0, 0))
end
```

Read columns through `archetype:get`. Write through `getMut` so dirty-gated
systems can find the change. See [Worlds](/ecs/world),
[Components](/ecs/components/), [Queries](/ecs/queries/), and
[Systems](/ecs/systems) for the complete ECS model.
]=]

-- Implementation details:
-- Games reach this table as `tecs.ecs`, while engine modules require
-- `tecs.ecs` directly. Exported modules cannot depend on the root aggregator
-- without creating a Teal require cycle. Both paths reach the same table, so
-- the dependency graph stays one-way and each public name has one declaration.

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

-- `World`, `Query`, `System` and `Plugin` are `tecs.World` and its three
-- neighbours rather than names on this record. A plugin is handed a world, a
-- system is a `System`, a plugin is a `Plugin`, and what either iterates is a
-- `Query`, and physics, drawing, audio and the sequencer all write those four
-- in their own public signatures, so they cross subsystems and sit at the root
-- with one spelling each. Engine code that needs only the type reaches for
-- `tecs.types`, which sits below both; here `World` is aliased because the
-- signatures below name it constantly.
local type World = types.World

local record ecs
    --- `Pipeline` identifies a world update pipeline.
    type Pipeline = types.Pipeline
    --- `FixedOverload` selects fixed-step overload
    --- behavior.
    type FixedOverload = types.FixedOverload
    --- `Component` names any component definition.
    type Component = types.components.Component
    --- `ScalarComponent` names a single-value component.
    type ScalarComponent<T> = types.components.ScalarComponent<T>
    --- `ComponentOptions` configures a table component.
    type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
    --- `FFIComponentOptions` configures an FFI component.
    type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
    --- `ScalarComponentOptions` configures a scalar
    --- component.
    type ScalarComponentOptions<T> = types.components.ScalarComponentOptions<T>
    --- `TagComponentOptions` configures a tag component.
    type TagComponentOptions = types.components.TagComponentOptions
    --- `Relationship` names any relationship definition.
    type Relationship = types.components.Relationship
    --- `RelationshipOptions` configures a relationship.
    type RelationshipOptions<R is Relationship> = types.components.RelationshipOptions<R>
    --- `FFIRelationshipOptions` configures an FFI
    --- relationship.
    type FFIRelationshipOptions<R is Relationship> = types.components.FFIRelationshipOptions<R>
    --- `QueryDescriptor` configures a query.
    type QueryDescriptor = types.Query.Descriptor
    --- `QueryCursor` controls an explicitly closed query
    --- traversal.
    type QueryCursor = types.Query.Cursor
    --- `Archetype` stores contiguous component columns.
    type Archetype = types.Archetype
    --- `ArchetypeEntityObserver` receives entity changes
    --- within an archetype.
    type ArchetypeEntityObserver = types.ArchetypeEntityObserver
    --- `Event` names any ECS event record.
    type Event = types.events.Event
    --- `EventListener` receives matching ECS events.
    type EventListener = types.events.EventListener
    --- `EventInit` initializes an event definition.
    type EventInit = types.events.EventInit
    --- `MessageBus` dispatches events outside a world.
    type MessageBus = types.events.MessageBus
    --- `Context` stores values under typed keys.
    type Context = types.Context
    --- `Key` identifies one typed context value.
    type Key<T> = types.Context.Key<T>
    --- `StatePolicy` controls state-stack participation.
    type StatePolicy = types.StatePolicy
    --- `Stats` reports live world counts.
    type Stats = types.World.Stats
    --- `Phase` identifies one system phase.
    type Phase = types.Phase
    --- `SystemConfig` configures a system.
    type SystemConfig = types.SystemConfig
    --- `DoubleArray` names an FFI array of doubles.
    type DoubleArray = types.DoubleArray
    --- `Bundle` names a reusable component collection.
    type Bundle = types.Bundle
    --- `BundleDef` configures a bundle.
    type BundleDef = types.Bundle.Definition
    --- `Snapshot` names serialized world state.
    type Snapshot = types.World.Snapshot
    --- `SnapshotPrelude` names snapshot metadata.
    type SnapshotPrelude = types.World.SnapshotPrelude
    --- `SnapshotComponentTableEntry` identifies one
    --- component in a snapshot.
    type SnapshotComponentTableEntry = types.World.SnapshotComponentTableEntry
    --- `SnapshotOptions` controls snapshot serialization.
    type SnapshotOptions = types.World.SnapshotOptions
    --- `SnapshotOutput` collects serialized data.
    type SnapshotOutput = types.World.SnapshotOutput
    --- `SnapshotHandler` saves and restores plugin data.
    type SnapshotHandler = types.World.SnapshotHandler

    --- Read-only. `phases` contains the phases a system may join.
    phases: phases
    --- Read-only. `runif` contains composable system run conditions.
    runif: runIfHelpers
    --- Read-only. `random` provides seeded named streams that snapshots carry.
    random: random

    -- The components, the relationship and the events every world registers
    -- for itself, directly on this module rather than grouped under a name of
    -- their own. `builtins` said where they came from, which is a fact about
    -- this implementation; a game asking for a parent link wants `ChildOf`,
    -- and having to know it was registered here rather than by a plugin is a
    -- level of indirection that answers nothing.
    --
    -- `phases`, `random` and `runif` stay grouped, because their members
    -- cannot say what they are alone: `ecs.PostUpdate` and `ecs.every` would
    -- each be one name in a list of a hundred with nothing to place them.
    --
    -- The names below are what a snapshot writes and reads, so they are also
    -- a save format. Moving one of these fields does not move the string it
    -- is registered under, and neither may be changed casually.

    --- Read-only. [`Transform`](/ecs/#tecs.ecs.Transform) positions everything a
    --- world holds. Hierarchy, physics, sequencing, and rendering all use it.
    Transform: builtins.Transform

    --- Read-only.
    --- [`RelativeTransform`](/ecs/#tecs.ecs.RelativeTransform) expresses a
    --- pose relative to a [`ChildOf`](/ecs/#tecs.ecs.ChildOf) parent. The
    --- hierarchy system composes it with the parent's
    --- [`Transform`](/ecs/#tecs.ecs.Transform), so a game writes this component
    --- and reads the world-space transform.
    RelativeTransform: builtins.RelativeTransform

    --- Read-only. [`ChildOf`](/ecs/#tecs.ecs.ChildOf) links a parent and child.
    --- It stores edges sparsely and cascade-deletes children with their parent.
    ChildOf: Relationship

    --- Read-only. [`Name`](/ecs/#tecs.ecs.Name) stores an entity label as a
    --- raw string. It does not enforce uniqueness. Use
    --- [`EntityKey`](/ecs/#tecs.ecs.EntityKey) for durable unique lookup.
    Name: ScalarComponent<string>

    --- Read-only. [`EntityKey`](/ecs/#tecs.ecs.EntityKey) stores a durable
    --- unique lookup key for `world:byKey`. It supports hot reload, authored
    --- references, tooling, and save-compatible lookup.
    ---
    --- The snapshot-compatible registration name remains `"Key"`;
    --- `ecs.Key` names typed context keys.
    EntityKey: ScalarComponent<string>

    --- Read-only. [`TTL`](/ecs/#tecs.ecs.TTL) despawns an entity when its time
    --- to live reaches zero. The engine counts it down in `FixedUpdate` through
    --- a logic query, so a [`Paused`](/ecs/#tecs.ecs.Paused) entity does not
    --- burn through it.
    TTL: builtins.TTL

    --- Read-only. [`Disabled`](/ecs/#tecs.ecs.Disabled) excludes an entity
    --- from queries that do not ask for it.
    Disabled: Component

    --- Read-only. [`Paused`](/ecs/#tecs.ecs.Paused) excludes an entity from
    --- logic queries while keeping it visible.
    --- [`Disabled`](/ecs/#tecs.ecs.Disabled) excludes both logic and rendering
    --- queries.
    Paused: Component

    --- Read-only. `OnSpawn` fires at an entity after spawning.
    OnSpawn: builtins.OnSpawn
    --- Read-only. `OnDespawn` fires at an entity before removal.
    OnDespawn: builtins.OnDespawn
    --- Read-only. `ArchetypeCreated` fires at entity 0 after archetype creation.
    ArchetypeCreated: builtins.ArchetypeCreated

    --- Read-only. `StateEnter` fires when a state enters the stack.
    StateEnter: builtins.StateEnter
    --- Read-only. `StateExit` fires when a state leaves the stack.
    StateExit: builtins.StateExit
    --- Read-only. `StateBlur` fires at a state when another takes focus above
    --- it.
    StateBlur: builtins.StateBlur
    --- Read-only. `StateFocus` fires at a state when it regains focus.
    StateFocus: builtins.StateFocus

    --- Read-only. `OnSnapshotSave` fires at entity 0 before snapshot archetype
    --- serialization so plugins can attach keyed data or exclude derived data.
    OnSnapshotSave: builtins.OnSnapshotSave
    --- Read-only. `StartSnapshotLoad` fires at entity 0 after world restoration
    --- and before data dispatch so plugins can register their keyed handlers.
    StartSnapshotLoad: builtins.StartSnapshotLoad
    --- Read-only. `FinishSnapshotLoad` fires at entity 0 after every entity and
    --- data callback finishes restoration.
    FinishSnapshotLoad: builtins.FinishSnapshotLoad

    --- Read-only. `MAX_ENTITIES` sets the absolute
    --- `World.Config.maxEntities` ceiling (2^22 - 1 usable
    --- slots; the entity-id format reserves slot 0).
    MAX_ENTITIES: integer

    --- Read-only. `DEFAULT_MAX_ENTITIES` supplies 2^20 when world configuration
    --- omits `maxEntities`.
    DEFAULT_MAX_ENTITIES: integer

    --- Creates a new World.
    ---
    --- @param config The caller supplies world settings or omits them for
    ---     `DEFAULT_MAX_ENTITIES` and the default pipeline. The entity ceiling
    ---     cannot grow after creation.
    --- @return Returns an independent world with builtins registered and no
    ---     systems.
    newWorld: function(config?: types.World.Config): World

    --- Creates and registers a new table component. See `ecs.ComponentOptions`
    --- and the component docs for the shared `fields` / `defaults` / `init` /
    --- `.new` model.
    ---
    --- @param options The caller supplies a process-unique name and the table
    ---     component definition.
    --- @return Returns the supplied container after permanent process-wide
    ---     registration makes it callable.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Creates and registers a new scalar component.
    ---
    --- @param options The caller supplies the scalar type, name and defaults.
    --- @return Returns the registered component whose rows hold bare values.
    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): ScalarComponent<T>

    --- Creates and registers a tag component.
    ---
    --- @param options The caller supplies the tag name.
    --- @return Returns the registered bitset-backed tag.
    newTagComponent: function(options: TagComponentOptions): Component

    --- Creates and registers an FFI-based component. Same constructor model
    --- as `newComponent`, but the base instance is an FFI struct.
    ---
    --- @param options The caller supplies fields that map to a C struct:
    ---     numbers, booleans and fixed-size arrays.
    --- @return Returns the registered component with contiguous cdata columns.
    ---     Direct writes through `world:get` require
    ---     `world:markComponentDirty`.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Creates and registers a relationship component.
    ---
    --- A target-only relationship needs a name and flags. Add `container` and
    --- `fields` when each edge carries data.
    ---
    --- @param config The caller supplies target, exclusivity, sparsity, reverse
    ---     index and cascade behavior.
    --- @return Returns the registered relationship, callable with a target to
    ---     create an instance.
    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    --- Creates an FFI-backed relationship with data fields.
    ---
    --- @param config The caller supplies relationship behavior and C-compatible
    ---     edge fields.
    --- @return Returns the registered relationship.
    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    --- Configures an event with a callable constructor.
    ---
    --- @param event The caller supplies the event record to configure in place.
    newEvent: function<E is Event>(event: E)

    --- Configures an FFI event with a callable constructor.
    ---
    --- @param event The caller supplies the event record to configure in place.
    --- @param fields The caller supplies each field name and C type in
    ---     constructor order.
    --- @param structName The caller supplies a shared C struct name or omits it
    ---     to generate one.
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- Creates an address-based event message bus.
    ---
    --- @return Returns an independent bus for messaging outside a world.
    newMessageBus: function(): MessageBus

    --- Creates a typed key for `world.resources`.
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
    --- @param name The caller supplies a namespaced identity such as
    ---     `"game.state"`. Omitting it creates an anonymous key and warns.
    --- @param forType The caller passes `nil as T` to carry the phantom value
    ---     type; the function does not read it.
    --- @return Returns the stable key for a name or a fresh anonymous key.
    newKey: function<T>(name?: string, forType?: T): Key<T>

    --- Returns a named key created by `newKey`.
    ---
    --- @param name The caller supplies the name used during key creation.
    --- @return Returns the existing key, or nil before any module creates it.
    findKey: function<T>(name: string): Key<T> | nil

    --- Returns all named keys as name-to-id entries.
    ---
    --- @return Returns a fresh caller-owned process-wide table.
    listKeys: function(): {string: integer}

    --- Creates a Context.
    ---
    --- @return Returns an empty typed key-value store.
    newContext: function(): Context

    --- Returns a registered component by numeric id.
    ---
    --- @param id The caller supplies a process-wide component id.
    --- @return Returns the component, or nil for an unallocated id. Numeric ids
    ---     do not remain stable across runs.
    findComponentById: function(id: integer): Component

    --- Returns the component registered under `name`.
    ---
    --- The process-wide registry allocates each component id once, and every
    --- world agrees on it. This function answers which components have names;
    --- a world answers which components it carries.
    ---
    --- Finds a dense relationship instance by its stamped name as well, which
    --- `declaredComponents` leaves out.
    ---
    --- @param name The caller supplies the process-wide registration name.
    --- @return Returns the component, or nil when nothing has registered that
    ---     name.
    findComponentByName: function(name: string): Component

    --- Returns every component declared in this process.
    ---
    --- A fresh table per call, so the registry itself stays unwritable from
    --- outside registration.
    ---
    --- The result omits dense relationship instances. Registration creates one
    --- stamped component per target, and no caller declared those components.
    ---
    --- @return Returns a fresh caller-owned name-to-component table that omits
    ---     generated dense relationship instances.
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

function ecs.findComponentById(id: integer): types.components.Component
    return components.componentsById[id]
end

function ecs.findComponentByName(name: string): types.components.Component
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
ecs.runif = runIfHelpers
ecs.random = random

-- `plugin` is deliberately not among these. The world installs it itself when
-- one is constructed, so nothing outside this tree calls it, and `ecs.plugin`
-- would name the plugin for the ECS rather than the one that owns the `TTL`
-- and hierarchy systems. Internal code reaches it through
-- `tecs.internal.builtins`, which is where it is declared.
ecs.Transform = builtins.Transform
ecs.RelativeTransform = builtins.RelativeTransform
ecs.ChildOf = builtins.ChildOf
ecs.Name = builtins.Name
ecs.EntityKey = builtins.Key
ecs.TTL = builtins.TTL
ecs.Disabled = builtins.Disabled
ecs.Paused = builtins.Paused
ecs.OnSpawn = builtins.OnSpawn
ecs.OnDespawn = builtins.OnDespawn
ecs.ArchetypeCreated = builtins.ArchetypeCreated
ecs.StateEnter = builtins.StateEnter
ecs.StateExit = builtins.StateExit
ecs.StateBlur = builtins.StateBlur
ecs.StateFocus = builtins.StateFocus
ecs.OnSnapshotSave = builtins.OnSnapshotSave
ecs.StartSnapshotLoad = builtins.StartSnapshotLoad
ecs.FinishSnapshotLoad = builtins.FinishSnapshotLoad

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
