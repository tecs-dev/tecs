--[[
types.tl - Core type definitions for Tecs

This module contains all the interleaving type definitions that multiple modules need.
By defining them all in one place, we avoid circular dependencies.

Users should typically access these through the main tecs module rather than importing this directly.
]]

local Context <const> = require("tecs.internal.Context")
local events <const> = require("tecs.internal.events")
local state <const> = require("tecs.internal.state")

local type Event = events.Event
local type States<V> = state.States<V>

local record types
    --- An ECS component.
    ---
    --- ECS components are used to store data that is attached to entities. They can be easily created using
    --- `tecs.newComponent`. Components can be attached to entities using `world:set(component, value)` where
    --- "component" is the component container and "value" is an instance of the component.
    interface Component
        --- The container type of the component, available on instances and containers.
        componentType: self

        --- The name of the component.
        componentName: string

        --- The auto-incrementing ID of the component container.
        componentId: integer

        --- Pre-computed hash contribution for this component.
        componentHash: integer

        --- Hook called when this component is added to an entity (optional).
        onAdd: OnAdd

        --- Hook called when this component is removed from an entity (optional).
        onRemove: OnRemove

        --- Gets the storage implementation for this component type.
        ---
        --- @return Storage implementation.
        getStorage: function(self): Storage

        --- Creates an instance of the component from the container.
        ---
        --- @param value The component container to create the component instance from.
        --- @param ... Arguments used to create the component.
        --- @return the created component.
        metamethod __call: function(self, ...: any): self
    end

    --- A relationship component that links one or more entities together.
    interface Relationship is Component
        where self.exclusiveRelationship ~= nil

        --- A property of the component container used to indicate that the relationship is exclusive (e.g., has-one).
        ---
        --- When an exclusive relationship is added to an entity, other relationships the same type are removed.
        exclusiveRelationship: boolean

        --- Reference to the relationship container/type that created this instance.
        relationshipType: Relationship

        --- The target of the relationship.
        ---
        --- Do not attempt to modify this value directly. Modifications of entity relationships must only be done
        --- through a World so that archetypes and indices are correctly updated able to track the changes.
        target: integer

        --- Creates an instance of the Relationship that targets a specific entity.
        ---
        --- Relationship instances are value types where their identity is based on the target entity ID.
        --- Relationship implementations should cache previously created relationships to avoid treating them
        --- as different types.
        ---
        --- @param id The entity ID target to assign to the relationship.
        --- @return the created instance of the specific kind of Relationship.
        metamethod __call: function(self, id: integer): self

        --- Returns the component type for a specific target, suitable for queries and world operations.
        ---
        --- For basic relationships (no container), returns the component instance directly.
        --- For data relationships (with container), returns the component type for that target.
        ---
        --- @param targetId The entity ID to target.
        --- @return For basic relationships: component instance. For data relationships: component type.
        targeting: function(self, targetId: integer): self
    end

    --- Component constructor function to used when __call creates an instance of a component.
    type ComponentConstructor = function<C is Component>(...: any): C

    --- Hook called when a component is added to an entity.
    type OnAdd<C is Component> = function(self: C, world: World, entityId: integer, changes: ChangeView)

    --- Hook called when a component is removed from an entity.
    type OnRemove<C is Component> = function(self: C, world: World, entityId: integer, changes: ChangeView)

    --- Storage interface for managing component data.
    interface Storage
        --- Create a new storage table with the given size hint.
        --- @param size Initial size hint (may be ignored).
        --- @return Storage table for component data.
        new: function(self, size: integer): {Component}

        --- Clear all data from the storage table.
        --- @param column The storage table to clear.
        clear: function(self, column: {Component})

        --- Ensure the column has capacity for at least the specified number of components.
        --- @param column The column array to check/resize.
        --- @param needed The minimum capacity required.
        --- @return The column array (may be a new array if reallocation was needed).
        ensureCapacity: function(self, column: {Component}, needed: integer): {Component}


        --- Batch commit components from temporary storage to archetype columns.
        --- @param column The target column in the archetype.
        --- @param startIndex Starting index in the column (1-based).
        --- @param components Array of component instances to commit.
        --- @return The potentially reallocated column.
        commitBatch: function(
            self,
            column: {Component},
            startIndex: integer,
            components: {integer:Component}
        ): {Component}

        --- Called after all changes are committed for this frame.
        --- Allows storage to reset scratch buffers, handle memory management, etc.
        --- @param dt Delta time since last frame in seconds.
        postCommit: function(self, dt: number)

        --- Recycle a component instance back to its storage pool if recycling is enabled.
        --- This is a no-op if recycling is disabled for this storage type.
        --- @param component The component instance to recycle.
        recycle: function(self, component: Component)

        --- Swap two components in the storage column.
        --- @param column The storage column array.
        --- @param indexA First component index (1-based for table storage, 0-based for FFI).
        --- @param indexB Second component index (1-based for table storage, 0-based for FFI).
        swap: function(self, column: {Component}, indexA: integer, indexB: integer)
    end

    --- FFI-specific storage interface.
    interface FFIStorage is Storage
        --- Create a component constructor function for FFI structs.
        --- @param container The component container type.
        --- @return A constructor function that creates FFI component instances.
        createComponent: function(self, container: Component): ComponentConstructor<Component>

        --- Bulk copy operation for FFI arrays (FFI-specific optimization).
        --- @param column The target column array.
        --- @param destOffset Destination offset in the column.
        --- @param srcData Source data array.
        --- @param srcOffset Source offset in the source array.
        --- @param count Number of elements to copy.
        bulkCopy: function(
            self,
            column: {Component},
            destOffset: integer,
            srcData: {Component},
            srcOffset: integer,
            count: integer
        )
    end

    --- An archetype is a collection of entities with the same components.
    interface Archetype
        --- The unique identifier of the archetype in the ECS container.
        id: integer

        --- An immutable array of entity IDs that belong in this archetype.
        entities: Int32Array

        --- The raw mapping of component types to their column of data.
        columns: {Component: {Component}}

        --- The number of columns in this archetype.
        columnsCount: integer

        --- A hash of the components in this archetype.
        componentHash: integer

        --- Provides a type-safe way to get a component column for a component type using normal table access.
        ---
        --- @param component The component type to get the column for.
        --- @return The column of component data for the specified component type or nil.
        metamethod __index: function<C is Component>(self: Archetype, component: C): {C}

        --- Gets a component value for a specific entity in this archetype.
        ---
        --- @param component The component type to retrieve.
        --- @param row The row position of the entity in this archetype (not the entity ID).
        --- @return The component value, or nil if the component or entity doesn't exist in this archetype.
        get: function<T is Component>(self, component: T, row: integer): T

        --- Checks if this archetype exactly matches the given components.
        ---
        --- @param components The components to check against this archetype.
        --- @return true if this archetype matches the components exactly, false otherwise.
        isExactMatch: function(self, components: {Component}): boolean

        --- Checks if this archetype has any of the given components.
        ---
        --- @param components The components to check for.
        --- @return true if this archetype has at least one of the components, false otherwise.
        hasAnyOf: function(self, components: {Component}): boolean


        --- Creates an iterator for all relationship instances of the given relationship container for an entity.
        ---
        --- @param relationshipContainer The relationship container to retrieve relationships from.
        --- @param row The row position of the entity in this archetype (not the entity ID).
        --- @return A lazy iterator that yields each relationship of this type for the given entity.
        getRelationships: function<T is Relationship>(self, relationshipContainer: T, row: integer): function(): T

        --- Gets the first relationship instance of the given relationship container for an entity, if any.
        ---
        --- @param relationshipContainer The relationship container to retrieve a relationship from.
        --- @param row The row position of the entity in this archetype (not the entity ID).
        --- @return The first relationship of this type for the given entity, or nil if none exists.
        getFirstRelationship: function<T is Relationship>(self, relationshipContainer: T, row: integer): T
    end

    --- An observer interface for monitoring changes to archetypes.
    interface ArchetypeChangeObserver
        --- Called when a new archetype is created.
        ---
        --- @param archetype The newly created archetype.
        onNewArchetype: function(self, archetype: Archetype)

        --- Called when an entity is added to, removed from, or changes archetypes.
        ---
        --- @param id The entity ID that changed.
        --- @param from The archetype the entity was previously in, or nil if the entity was just spawned.
        --- @param to The archetype the entity moved to, or nil if the entity was despawned.
        --- @param row The row position of the entity in the new archetype (only applicable when 'to' is not nil).
        onEntityChange: function(self, id: integer, from: Archetype, to: Archetype, row: integer)
    end

    --- A view of pending changes for an entity, used in component hooks.
    interface ChangeView
        --- Get a component that exists or will exist after this change.
        get: function<T is Component>(self, component: T): T

        --- Add or update a component in this change batch.
        set: function(self, component: Component)

        --- Remove a component in this change batch.
        remove: function(self, component: Component)

        --- Check if a component exists or will exist.
        has: function(self, component: Component): boolean
    end

    --- Query descriptor for creating queries.
    interface QueryDescriptor
        --- An optional name to give the query, used in logging.
        name: string

        --- The components an archetype must contain in order to match the query.
        include: {Component}

        --- The components an archetype must not contain in order to match the query.
        exclude: {Component}

        --- Called when an entity matches the query.
        onMatch: function(entityId: integer, archetype: Archetype, row: integer)

        --- Called when an entity no longer matches the query.
        onRemove: function(entityId: integer, archetype: Archetype, row: integer)

        --- Whether to save the query in the world (strong reference).
        save: boolean
    end

    --- A query for finding entities with specific components.
    interface Query
        --- Iterate over archetypes and entities.
        --- Returns (archetype, length, entities) for each matching archetype.
        --- Use archetype[Component] to retrieve component data.
        metamethod __call: function(self): function(): (Archetype, integer, {integer})
    end

    --- A `System` used to update the world on each tick of the game loop.
    ---
    --- The system takes the delta time and the world as parameters.
    type System = function(dt: number, world: World)

    --- A command that can be deferred and executed later.
    ---
    --- Commands are useful for making changes to the world from within systems
    --- without causing archetype transitions during iteration.
    --- Commands should access the world through closure rather than parameters.
    type Command = function()

    --- A phase in the game loop pipeline.
    interface Phase
        --- The name of the phase.
        name: string

        --- Whether the phase is enabled.
        enabled: boolean

        --- The position of the phase in the pipeline.
        position: integer

        --- Child phases of this phase.
        children: {Phase}
    end

    --- The pipeline that executes systems in phases.
    interface Pipeline
        --- The number of systems in the pipeline.
        count: integer

        --- Update the pipeline.
        update: function(self, dt: number, world: World)

        --- Run a specific phase.
        run: function(self, phase: Phase, dt: number, world: World)

        --- Add a system to the pipeline.
        addSystem: function(self, config: SystemConfig)

        --- Remove a system from the pipeline.
        removeSystem: function(self, phase: Phase, system: System | string)

        --- Enable a phase.
        enablePhase: function(self, phase: Phase)

        --- Disable a phase.
        disablePhase: function(self, phase: Phase)
    end

    --- System configuration used when adding systems to the world
    interface SystemConfig
        name: string
        phase: Phase
        run: System
        dependencies: {System | string}
        before: {string}
        after: {string}
        runIf: function(dt: number, world: World): boolean
    end

    --- The main World interface for the ECS system.
    interface World
        --- The pipeline that executes systems.
        pipeline: Pipeline

        --- Resources stored in the world.
        resources: Context

        -------------------------------------------------------------------------------
        -- Plugin methods
        -------------------------------------------------------------------------------

        --- Add a plugin to the world.
        ---
        --- @param plugin The plugin to add.
        addPlugin: function(self, plugin: Plugin)

        -------------------------------------------------------------------------------
        -- System methods
        -------------------------------------------------------------------------------

        --- Add a system to the world.
        ---
        --- @param config The system configuration.
        addSystem: function(self, config: SystemConfig)

        --- Remove a system from the world.
        ---
        --- @param phase The phase to remove the system from.
        --- @param system The system or name to remove.
        removeSystem: function(self, phase: Phase, system: System | string)

        --- Update the world.
        ---
        --- @param dt The time since the last update.
        update: function(self, dt: number)

        --- Run the startup systems.
        startup: function(self)

        --- Run the shutdown systems.
        shutdown: function(self)

        --- Add a command to be executed later.
        ---
        --- @param command The command to add.
        command: function(self, command: Command)

        -------------------------------------------------------------------------------
        -- Entity methods
        -------------------------------------------------------------------------------

        --- Spawn a new entity with optional variadic components.
        ---
        --- @param ... Variable number of components to add to the entity.
        --- @return The ID of the spawned entity.
        spawn: function(self, ...: Component): integer

        --- Despawn an entity.
        ---
        --- @param entity The entity to despawn.
        despawn: function(self, entity: integer)

        --- Check if an entity is alive.
        ---
        --- @param entity The entity to check.
        --- @return true if the entity is alive, false otherwise.
        isAlive: function(self, entity: integer): boolean

        -------------------------------------------------------------------------------
        -- Component methods
        -------------------------------------------------------------------------------

        --- Get a component instance attached to an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component type to get.
        --- @return The component instance or nil if not found.
        get: function<T is Component>(self, entity: integer, component: T): T

        --- Add or update a component on an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component instance to set.
        set: function(self, entity: integer, component: Component)

        --- Remove a component from an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component type to remove.
        remove: function(self, entity: integer, component: Component)

        -------------------------------------------------------------------------------
        -- Query methods
        -------------------------------------------------------------------------------

        --- Creates a new query and registers it with the World to be updated as archetypes change.
        ---
        --- By default, queries are held with weak references and may be garbage collected if not stored.
        --- Set descriptor.save = true to have the World maintain a strong reference to the query.
        ---
        --- @param descriptor The query descriptor to create the query from.
        --- @return the created query.
        query: function(self, descriptor: QueryDescriptor): Query

        --- Find archetypes that have the given component.
        ---
        --- @param component The component to find.
        --- @return an iterator over the archetypes that have the component.
        findArchetypes: function(self, component: Component): function(): (Archetype, integer, Int32Array)

        -------------------------------------------------------------------------------
        -- State methods
        -------------------------------------------------------------------------------

        --- Get the current value of a state.
        ---
        --- @param state The state to get.
        --- @return The current value of the state.
        getState: function<V, S is States<V>>(self, state: S): V

        --- Set the value of a state.
        ---
        --- @param state The state to set.
        --- @param value The value to set.
        setState: function<V, S is States<V>>(self, state: S, value: V)

        --- Check if a state has a specific value.
        ---
        --- @param state The state to check.
        --- @param value The value to check for.
        --- @return true if the state has the value, false otherwise.
        inState: function<V, S is States<V>>(self, state: S, value: V): boolean

        --- Observe when a specific state is exited.
        ---
        --- @param state The state to observe.
        --- @param value The value to observe when exiting the state.
        --- @param callback The callback to call when the state is exited.
        onExitState: function<V, S is States<V>>(self, state: S, value: V, callback: function())

        --- Observe when a specific state is transitioned to another specific state.
        ---
        --- @param state The state to observe.
        --- @param from The value to observe when exiting the state.
        --- @param to The value to observe when entering the state.
        --- @param callback The callback to call when the state is transitioned from `from` to `to`.
        onTransitionState: function<V, S is States<V>>(self, state: S, from: V, to: V, callback: function())

        --- Observe when a specific state is entered.
        ---
        --- @param state The state to observe.
        --- @param value The value to observe when entering the state.
        --- @param callback The callback to call when the state is entered.
        onEnterState: function<V, S is States<V>>(self, state: S, value: V, callback: function())

        -------------------------------------------------------------------------------
        -- Phase methods
        -------------------------------------------------------------------------------

        --- Enable a phase.
        ---
        --- @param phase The phase to enable.
        enablePhase: function(self, phase: Phase)

        --- Disable a phase.
        ---
        --- @param phase The phase to disable.
        disablePhase: function(self, phase: Phase)

        -------------------------------------------------------------------------------
        -- Event methods
        -------------------------------------------------------------------------------

        --- Get the event emitter for an entity.
        ---
        --- @param entity The entity to get the emitter for.
        --- @return The event emitter.
        getEntityEmitter: function(self, entity: integer): events.Emitter

        --- Emit an event.
        ---
        --- @param event The event to emit.
        emit: function(self, event: Event)

        --- Observe an event.
        ---
        --- @param event The event type to observe.
        --- @param callback The callback to call when the event is emitted.
        --- @param id Optional ID for the observer.
        observe: function<T is Event>(self, event: T, callback: function(event: T), id?: string)

        --- Observe an event once.
        ---
        --- @param event The event type to observe.
        --- @param callback The callback to call when the event is emitted.
        observeOnce: function<T is Event>(self, event: T, callback: function(event: T))

        --- Stop observing an event.
        ---
        --- @param event The event type to stop observing.
        --- @param observer The observer function or ID.
        stopObserving: function<T is Event>(self, event: T, observer: function(T) | string)

        --- Check if there are observers for an event.
        ---
        --- @param event The event type to check.
        --- @return true if there are observers, false otherwise.
        hasObservers: function<T is Event>(self, event: T): boolean

        -------------------------------------------------------------------------------
        -- Stats methods
        -------------------------------------------------------------------------------

        --- Get stats about the World.
        ---
        --- @param fill Optional stats table to fill instead of allocating a new one.
        --- @return the stats.
        getStats: function(self, fill?: Stats): Stats
    end

    --- World configuration
    interface WorldConfig
        timestep: number
        pipelineFactory: function(number, function(any)): Pipeline
    end

    --- A plugin that can be added to a world to extend its functionality.
    ---
    --- Plugins are functions that receive the world and can add systems, resources, etc.
    type Plugin = function(world: World)

    --- World stats information.
    interface Stats
        --- The number of active entities.
        entities: integer

        --- The number of archetypes.
        archetypes: integer

        --- The number of components.
        components: integer

        --- The number of systems.
        systems: integer
    end

    --- Array types (opaque - could be FFI or table internally)
    interface Int32Array is {integer}
        metamethod __len: function(self) = macroexp(self: Int32Array)
            return self[0]
        end
    end

    interface Float32Array is {number}
        metamethod __len: function(self) = macroexp(self: Float32Array)
            return self[0]
        end
    end
end

return types