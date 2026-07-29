--- The ECS, for a game and for engine code alike.
---
--- A world, a query built once outside the system that reads it, a system
--- placed in a phase, and an entity for it to find:
---
--- ```teal
--- local game <const> = tecs.ecs.newWorld()
--- local moving <const> = game:query({include = {tecs.Transform}})
---
--- game:addSystem({
---     name = "game.Drift",
---     phase = tecs.ecs.phases.Update,
---     run = function(delta: number)
---         for archetype, length in moving:iter() do
---             local transform <const> = archetype:getMut(tecs.Transform)
---             for row = 1, length do
---                 transform[row].x = transform[row].x + 60 * delta
---             end
---         end
---     end,
--- })
---
--- game:spawn(tecs.Transform(0, 0))
--- game:update(1 / 60)
--- ```
---
--- A query is built at setup and reused for the world's lifetime, never inside
--- `run`. Reads go through `archetype:get` and writes through `getMut`, which
--- is what marks the column dirty for everything gated on it.
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
    --- Composable run conditions, for `SystemConfig.runIf`.
    runif: runIfHelpers
    --- Seeded generation, in named streams a snapshot carries.
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

    --- Positions everything a world holds: the hierarchy, physics, the
    --- sequencer and the renderer all move the same one. Not a drawing
    --- component, which is why it is here and not on `tecs.gfx`, and why a
    --- headless world has it.
    Transform: builtins.Transform

    --- A transform expressed relative to a `ChildOf` parent. The builtin
    --- hierarchy system composes it with the parent's `Transform` into the
    --- child's world-space one, so a game writes this and reads `Transform`.
    RelativeTransform: builtins.RelativeTransform

    --- Parent and child. Sparse, so adding one does not split archetypes, and
    --- cascade-deleting, so despawning a parent takes its children.
    ChildOf: Relationship

    --- A label for an entity, stored as the raw string. Not unique: use
    --- `EntityKey` where something has to find one entity again.
    Name: ScalarComponent<string>

    --- A durable, unique lookup key, read back with `world:byKey`. For hot
    --- reload, authored references, tooling and save-compatible lookup, where
    --- an entity id is meaningless across runs.
    ---
    --- Spelled `EntityKey` here and registered as `"Key"`, because `Key` on
    --- this module is the typed `world.resources` key `newKey` hands out, and
    --- Teal refuses the second declaration outright. The registered name is a
    --- save format and does not move; this one is the surface.
    EntityKey: ScalarComponent<string>

    --- Despawns an entity once its time to live reaches zero, counted down in
    --- `FixedUpdate` by a query declared `type = "logic"`, so a `Paused`
    --- entity does not burn through it.
    TTL: builtins.TTL

    --- Excluded from every query that does not ask for it.
    Disabled: Component

    --- Excluded from logic queries and still drawn, which is the difference
    --- from `Disabled`: a paused world is one that renders and does not think.
    Paused: Component

    --- Emitted at the entity when it is spawned.
    OnSpawn: builtins.OnSpawn
    --- Emitted at the entity when it is despawned.
    OnDespawn: builtins.OnDespawn
    --- Emitted at entity 0 when a new archetype is created.
    ArchetypeCreated: builtins.ArchetypeCreated

    --- Emitted when a state is pushed onto the stack.
    StateEnter: builtins.StateEnter
    --- Emitted when a state is popped off it.
    StateExit: builtins.StateExit
    --- Emitted at the state losing focus when another is pushed above it.
    StateBlur: builtins.StateBlur
    --- Emitted at the state regaining focus when the one above it is popped.
    StateFocus: builtins.StateFocus

    --- Emitted at entity 0 before a snapshot's archetypes are written, which
    --- is where a plugin attaches keyed data or excludes what it re-derives.
    OnSnapshotSave: builtins.OnSnapshotSave
    --- Emitted at entity 0 after a snapshot's world is restored and before its
    --- data section is dispatched, which is where a plugin registers what to
    --- do with each key it wrote.
    StartSnapshotLoad: builtins.StartSnapshotLoad
    --- Emitted at entity 0 once every entity is restored and every data
    --- callback has run.
    FinishSnapshotLoad: builtins.FinishSnapshotLoad

    --- Absolute ceiling for `World.Config.maxEntities` (2^22 - 1 usable
    --- slots; slot 0 is reserved by the entity-id format).
    MAX_ENTITIES: integer

    --- Default `World.Config.maxEntities` when none is given (2^20).
    DEFAULT_MAX_ENTITIES: integer

    --- Create a new World.
    ---
    --- @param config May be nil, which takes `DEFAULT_MAX_ENTITIES` slots and
    ---     the default pipeline. `maxEntities` is the one field worth deciding
    ---     up front: it sizes the entity index at creation and is not grown
    ---     later, so a world that runs out of slots raises rather than
    ---     reallocating.
    --- @return A world with the builtin components already registered and no
    ---     systems. Worlds are independent: an entity id is meaningful only in
    ---     the world that issued it, while a component id is process-wide and
    ---     shared by every world that carries one.
    newWorld: function(config?: types.World.Config): World

    --- Creates and registers a new table component. See `ecs.ComponentOptions`
    --- and the component docs for the shared `fields` / `defaults` / `init` /
    --- `.new` model.
    ---
    --- @param options Its `name` is the registry key, so it has to be unique in
    ---     the process and is what queries, snapshots and the MCP tools address
    ---     the component by.
    --- @return The same `container` record passed in, now registered and
    ---     callable as a constructor. Registration is process-wide and
    ---     permanent, so this belongs at module scope rather than in a plugin
    ---     that may be added to two worlds.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Creates and registers a new scalar component.
    ---
    --- @param options Describes a component that is one value rather than a
    ---     record of fields, so its column holds that value directly.
    --- @return The registered component, whose rows are read and written as
    ---     bare values rather than through a field.
    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): ScalarComponent<T>

    --- Creates and registers a new tag component that uses bitset storage for efficiency.
    ---
    --- @param options Name only: a tag carries no fields, which is what lets it
    ---     be stored as one bit.
    --- @return The registered tag. Queries match it by archetype rather than by
    ---     scanning, so a stable flag is cheaper as a tag than as a boolean
    ---     field, while one toggled often is not: every flip moves the entity
    ---     between archetypes.
    newTagComponent: function(options: TagComponentOptions): Component

    --- Creates and registers an FFI-based component. Same constructor model
    --- as `newComponent`, but the base instance is an FFI struct.
    ---
    --- @param options Its `fields` have to map to a C struct, so numbers,
    ---     booleans and fixed-size arrays only. One field needing a Lua table
    ---     makes the whole component a table component.
    --- @return The registered component. Its columns are contiguous cdata, so
    ---     writing a row through `world:get` bypasses dirty tracking and needs
    ---     an explicit `world:markComponentDirty`, and `world:batchSpawn`
    ---     skips its defaults.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Creates and registers a new relationship component. See the relationship
    --- docs for target/exclusive/sparse semantics. A target-only relationship
    --- (name plus flags, no `container`/`fields`) is backed by a compact FFI
    --- struct automatically; add `container`/`fields` for relationships that
    --- carry data.
    ---
    --- @param config `exclusive` keeps one target per entity, replacing rather
    ---     than adding. `sparse` keeps edges out of the archetype key, so
    ---     adding one does not split archetypes. `cascadeDelete` despawns the
    ---     sources when the target goes, and raises here unless `exclusive` and
    ---     `reverseIndex` are both set, since finding the sources is what the
    ---     reverse index is for.
    --- @return The registered relationship, called with a target to make an
    ---     instance. A dense relationship registers one component per target
    ---     under a stamped name, which is why `declaredComponents` leaves those
    ---     out.
    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    --- Create an FFI-backed relationship with data fields.
    ---
    --- @param config As `newRelationship`, plus the `fields` the edge itself
    ---     carries, under the same C-struct restriction `newFFIComponent` has.
    --- @return The registered relationship.
    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- @param event Mutated in place rather than copied, so the record the
    ---     caller declared is the one that becomes callable. Its `init`, where
    ---     it has one, is what the constructor's arguments are handed to, so
    ---     `init` is what decides the call signature.
    newEvent: function<E is Event>(event: E)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- @param event Mutated in place, as `newEvent` does it.
    --- @param fields Name and C type per field, in declaration order, which is
    ---     also the order the constructor takes them in. The same C-struct
    ---     restriction `newFFIComponent` has applies.
    --- @param structName Optional. One is generated when it is left out, and it
    ---     only needs naming when something else has to name the same struct.
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- Create a new address-based event message bus.
    ---
    --- @return A bus of its own, unconnected to any world's. A world already
    ---     carries one, which `world:emit` and `world:observe` reach, so this
    ---     is for messaging that should outlive or sit outside a world.
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
    --- @param name Namespaced, like "game.state". Omitting it is what triggers
    ---     the warning above, and the key it returns is still usable, just
    ---     anonymous and new on every call.
    --- @param forType Never read. It exists so the call site can say what `T`
    ---     is, since Teal has no explicit type argument; pass `nil as T`.
    --- @return The key for that name, which is the same one every later call
    ---     with the same name gets rather than a fresh one. That is what makes
    ---     values keyed by it survive a module re-running under hot reload.
    newKey: function<T>(name?: string, forType?: T): Key<T>

    --- Find a named key created by `newKey`. Returns nil when unknown.
    ---
    --- @param name The name the key was created with. Unnamed keys are
    ---     unreachable here, which is the reason `newKey` warns about them.
    --- @return The existing key, so a value stored under it is readable without
    ---     the module that created it. Nil when no key of that name has been
    ---     created yet, which is a question of load order rather than of
    ---     spelling: the key appears once its module has run.
    findKey: function<T>(name: string): Key<T> | nil

    --- All named keys, as a fresh name -> numeric key id table.
    ---
    --- @return A fresh table each call, so the caller may keep it and the
    ---     registry stays unwritable from outside `newKey`. Names span the
    ---     process rather than one world, so a key here is not evidence that
    ---     any world has a value under it.
    listKeys: function(): {string: integer}

    --- Create a new Context instance.
    ---
    --- @return An empty context, which is the keyed store `world.resources` is
    ---     one of. For something wanting that store without a world.
    newContext: function(): Context

    --- Look up a registered component by numeric ID.
    ---
    --- @param id A component id, which is allocated once at registration and is
    ---     the same in every world in the process.
    --- @return The component, or nil for an id that was never allocated. Ids
    ---     are not stable across runs: registration order decides them, so a
    ---     saved id is only meaningful within the run that wrote it.
    findComponentById: function(id: integer): Component

    --- The component registered under `name`, or nil.
    ---
    --- The registry is process-wide, because a component's id is allocated
    --- once at registration and every world that carries one agrees on it. So
    --- this answers what can be named, and a world answers what is present.
    ---
    --- Finds a dense relationship instance by its stamped name as well, which
    --- `declaredComponents` leaves out.
    ---
    --- @param name The `name` the component was registered under, which is the
    ---     record's own name by convention.
    --- @return The component, or nil when nothing has registered that name yet.
    ---     Nil is a question of whether the declaring module has been required,
    ---     not of whether any world carries the component.
    findComponentByName: function(name: string): Component

    --- Every component declared in this process, name to component.
    ---
    --- A fresh table per call, so the registry itself stays unwritable from
    --- outside registration.
    ---
    --- Dense relationship instances are left out. One is registered per target
    --- under a stamped `Rel->42` name, so a world with many edges has many of
    --- them, and none of them is a component anybody declared.
    ---
    --- @return A fresh table each call, built by walking the whole registry, so
    ---     this is for tooling rather than for a per-frame path. What is
    ---     declared in the process, which is a superset of what any one world
    ---     carries.
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
