local StringBuffer <const> = require("string.buffer")

--- Public type definitions for Tecs.
local record types
    --- Context is a type-safe bag of data.
    record Context
        --- Type-safe Key interface.
        interface Key<T> end

        --- Get a context value using a type-safe key.
        metamethod __index: function<T>(Context, key: Key<T>): T

        --- Set a context value using a type-safe key.
        metamethod __newindex: function<T>(Context, key: Key<T>, value: T)
    end

    --- Plugins are functions that receive the world and can add systems, resources, etc.
    type Plugin = function(world: World)

    --- A `System` used to update the world on each tick of the game loop.
    type System = function(dt: number, world: World)

    --- Component factory option shapes, collated separately from the
    --- runtime implementation so factory code can live under
    --- `tecs.internal.*` without losing a stable typed surface.
    record components
        --- An ECS component.
        interface Component
            --- The container type of the component, available on instances and containers.
            componentType: self

            --- The name of the component.
            componentName: string

            --- The auto-incrementing ID of the component container.
            componentId: integer

            --- Relationship components only: the relationship container type (nil for non-relationships).
            --- For containers, this equals self. For instances, it points to the container.
            relationshipType: Component

            --- Relationship components only: The target entity ID (for relationship instances only).
            target: integer

            --- Serialize a component instance to a plain table.
            ---
            --- @param instance The component instance to serialize.
            --- @return A plain table representation of the component data.
            serialize: function(instance: self): {string: any}

            --- Deserialize a component instance from a plain table.
            --- @param world The world context for loading resources.
            --- @param data The plain table data to deserialize.
            --- @return A new component instance.
            deserialize: function(world: World, data: {string: any}): self

            --- Build a component instance from a table of named fields.
            --- The positional `__call` form is the hot path; `new` is the ergonomic/snapshot form.
            new: function(data: {string: any}): self

            --- Optional post-allocation positional initializer used by the
            --- built-in factories. Runs after the base instance has been
            --- allocated and any declarative field population has occurred.
            init: function(instance: self, ...: any)

            --- Creates an instance of the component from the container using positional arguments.
            --- @param value The component container to create the component instance from.
            --- @param ... Arguments used to create the component.
            --- @return the created component.
            metamethod __call: function(self, ...: any): self
        end

        --- Scalar component container. Rows store scalar payloads directly.
        interface ScalarComponent<T> is Component
            scalarKind: ScalarKind
            scalarDefault: T
            enum ScalarKind
                "number"
                "boolean"
                "string"
            end
        end

        --- A relationship component that links one or more entities together.
        interface Relationship is Component where self.relationshipType ~= nil
            --- Component container property indicating that the relationship is exclusive (e.g., has-one).
            exclusiveRelationship: boolean

            --- Returns the component type for a specific target.
            targeting: function(self, targetId: integer): self
        end

        --- Component allocator function used internally to create an instance
        --- from positional arguments before any `init` hook runs.
        type ComponentAllocator = function<C is Component>(...: any): C

        --- Shared options for creating different components.
        interface BasicComponentOptions<C is Component>
            --- The name of the component (required).
            name: string

            --- Declarative auto-dependencies. When this component is added
            --- to an entity via `world:set` or `world:spawn`, any listed
            --- components not already present are added to the same
            --- archetype transition. Entries may be component TYPES (the
            --- constructor is called with no args to produce a default
            --- instance) or INSTANCES (used as-is). Transitive: the
            --- framework walks `requires` of required components too.
            requires: {Component}
        end

        --- Shared options for creating different components.
        interface ContainerComponentOptions<C is Component> is BasicComponentOptions<C>
            --- The component container/type to use (required).
            container: C
        end

        --- Options for creating a new component.
        interface ComponentOptions<C is Component> is ContainerComponentOptions<C>
            --- Ordered field names for positional construction and `.new(data)`.
            --- Example: `fields = {"x", "y"}` means `Component(1, 2)` maps to
            --- `{x = 1, y = 2}` and `Component.new({x = 1, y = 2})` unpacks by
            --- the same order. The generated constructor is `load`ed so LuaJIT
            --- sees literal field assignments.
            fields: {string}

            --- Positional defaults, in the same order as `fields`. Use `nil` for
            --- fields that have no default. Requires `fields`.
            defaults: {any}

            --- Optional post-allocation positional initializer. Runs after the
            --- base instance has been allocated and any declarative
            --- `fields` / `defaults` have been applied. Use for validation,
            --- normalization, or derived state. If provided without `fields` or
            --- `new`, registration errors because Tecs would have no clear way to
            --- implement `.new(data)`.
            init: function(instance: C, ...: any)

            --- Optional custom constructor hook for the container's `__call`.
            --- When present, Tecs allocates a base instance, applies declarative
            --- `defaults`, then invokes this hook as `__call(instance, ...)`.
            --- On this path, `init` is NOT auto-run; call `Component.init(...)`
            --- explicitly from `__call` if desired.
            __call: function(instance: C, ...: any)

            --- Optional table-form constructor, called as `Component.new(data)`.
            --- When `fields` are present, Tecs generates this automatically by
            --- unpacking named fields and routing through `__call`.
            new: function(data: {string: any}): C

            --- Custom serialization function (optional).
            --- Converts a component instance to a plain table for JSON serialization.
            serialize: function(instance: C): {string: any}

            --- Custom deserialization function (optional).
            --- Reconstructs a component instance from a plain table.
            deserialize: function(world: World, data: {string: any}): C
        end

        interface TagComponentOptions is BasicComponentOptions<Component>
            --- Optional container to use for the tag component.
            container: Component
        end

        --- Options for creating an FFI-based component with high performance storage.
        interface FFIComponentOptions<C is Component> is ContainerComponentOptions<C>
            --- FFI field definitions for the backing struct.
            fields: {{string, string}}

            --- Positional defaults, in the same order as `fields`.
            defaults: {any}

            --- Optional metatable to apply to FFI instances (for instance methods).
            metatable: {any:any}

            --- Optional post-allocation positional initializer. Same semantics as
            --- `ComponentOptions.init`, but the base instance is an FFI struct.
            init: function(instance: C, ...: any)

            --- Optional custom constructor hook. Same semantics as
            --- `ComponentOptions.__call`, but the base instance is an FFI struct.
            __call: function(instance: C, ...: any)

            --- Optional table-form constructor. Defaults to unpacking `fields` by
            --- name into positional args and routing through `__call`.
            new: function(data: {string: any}): C

            --- Custom serialization function (optional).
            --- Converts a component instance to a plain table for JSON serialization.
            --- Return `nil` to omit the component from snapshots.
            serialize: function(instance: C): {string: any}

            --- Custom deserialization function (optional).
            --- Reconstructs a component instance from a plain table. Typically
            --- reruns the same construction path a fresh spawn would take so the
            --- restored instance gets valid runtime state.
            deserialize: function(world: World, data: {string: any}): C
        end

        --- Scalar component configuration. Scalar storage holds the raw
        --- primitive directly in the column, so there is no container shape
        --- to attach methods or fields to — typed exports are done by
        --- declaring the field type on the owning module record (e.g.
        --- `Health: types.components.ScalarComponent<number>`) and assigning the
        --- registration result to it.
        interface ScalarComponentOptions<T> is BasicComponentOptions<ScalarComponent<T>>
            kind: string
            default: T
        end

        --- Relationship component configuration.
        interface BaseRelationshipOptions<R is Relationship> is ContainerComponentOptions<R>
            --- Whether or not the relationship is exclusive (e.g., can only be the child of one parent).
            exclusive: boolean

            --- If true, store in entity-indexed sparse storage instead of archetype columns.
            --- Eliminates archetype fragmentation from per-target component types.
            sparse: boolean

            --- If true, maintain an inverse index (target → sources) for O(1) reverse lookups.
            --- Enables world:targets() and world:traverse() for both sparse and dense relationships.
            reverseIndex: boolean

            --- If true, despawning the target entity automatically despawns all source entities.
            --- Requires reverseIndex = true and exclusive = true.
            cascadeDelete: boolean
        end

        --- Relationship component configuration.
        interface RelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, ComponentOptions<R> end

        --- FFI relationship component configuration.
        interface FFIRelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, FFIComponentOptions<R> end
    end

    -- Component hooks (onAdd / onRemove / onReplace) have been
    -- removed. Use query observers (`onEntitiesAdded` /
    -- `onEntitiesRemoved` in `world:query`) for lifecycle reactions,
    -- the declarative `requires` list for auto-add dependencies, or
    -- explicit domain APIs (e.g. `blend.set`) for mutex invariants.

    --- An archetype is a collection of entities with the same components.
    ---
    --- The public surface is deliberately small: identity, entity row
    --- access, per-row component access, and dirty tracking. Layout,
    --- column storage, observer registration, and all transaction
    --- internals live on the concrete implementation in
    --- `tecs.internal.Archetype` and are not part of the
    --- supported API.
    interface Archetype
        --- The unique identifier of the archetype in the ECS container.
        id: integer

        --- Columns in the archetype. Treat as read-only.
        columns: {components.Component: {components.Component}}

        --- Entity IDs that belong to this archetype. Length is
        --- `entities[0]`; rows are 1-based (`entities[1]` is the
        --- first entity).
        entities: DoubleArray

        --- Components in this archetype, in the order they were passed
        --- at construction. Finalized at creation — archetypes never
        --- add or remove components. Iterate with `#componentList` /
        --- `ipairs` to walk the archetype's signature.
        componentList: {components.Component}

        --- Read-only column access. Returns the row-indexed column for
        --- the given component type, or nil if the archetype doesn't
        --- carry it. Does NOT mark the component dirty.
        ---
        --- @param component The component type to retrieve.
        get: function<T is components.Component>(self, component: T): {T}

        --- Mutable column access. Returns the row-indexed column AND
        --- marks the component dirty on this archetype. Use this at
        --- every site where you intend to write into the column.
        ---
        --- @param component The component type to retrieve.
        getMut: function<T is components.Component>(self, component: T): {T}

        --- Set a component value at a row and mark it dirty. Use for
        --- in-place updates that don't change the entity's archetype.
        ---
        --- @param row 1-based row position.
        --- @param value New component value (must carry a `componentType`).
        set: function<C is components.Component>(self, row: integer, value: C)

        --- Iterate all relationship instances of the given container
        --- for the entity at `row`.
        ---
        --- @param relationshipContainer The relationship container.
        --- @param row 1-based row position.
        --- @param callback Called once per matching relationship instance.
        forEachRelationship: function<T is components.Relationship>(
            self, relationshipContainer: T, row: integer, callback: function(T))

        --- Get the first relationship instance of the given container
        --- for the entity at `row`, or nil if none exists.
        ---
        --- @param relationshipContainer The relationship container.
        --- @param row 1-based row position.
        getFirstRelationship: function<T is components.Relationship>(self, relationshipContainer: T, row: integer): T

        --- True if the given component's column on this archetype is
        --- currently marked dirty.
        isComponentDirty: function(self, component: components.Component): boolean

        --- True if any component on this archetype is currently dirty.
        --- Useful for bulk re-sync paths that don't track dirty
        --- granularity below the archetype level.
        anyComponentDirty: function(self): boolean

        --- Mark a single component dirty on this archetype. Idempotent.
        markComponentDirty: function(self, component: components.Component)

        --- Mark every component on this archetype dirty.
        markAllComponentsDirty: function(self)

        --- Clear every component-dirty bit on this archetype.
        clearDirtyComponents: function(self)

        --- Iterate components currently marked dirty on this archetype.
        dirtyComponents: function(self): function(): components.Component

        observerCount: integer
        hasRemoveObservers: integer
        hasAddObservers: integer
        addEntityObserver: function(self, observer: ArchetypeEntityObserver)
    end

    --- Observer interface for entity lifecycle events within an archetype.
    ---
    --- Every method below is optional. Implement only the events you need.
    interface ArchetypeEntityObserver
        --- Called once per contiguous range of entities added to the archetype.
        ---
        --- @param archetype The archetype the range was placed in.
        --- @param firstRow The 1-based row of the first new entity.
        --- @param lastRow The 1-based row of the last new entity (inclusive).
        --- @param count Number of entities in the range (lastRow - firstRow + 1).
        --- @param sourceArchetype The archetype the range originated from (nil for spawns).
        onEntitiesAdded: function(
            self,
            archetype: Archetype,
            firstRow: integer,
            lastRow: integer,
            count: integer,
            sourceArchetype?: Archetype
        )

        --- Called once per contiguous range of entities removed from the archetype.
        ---
        --- @param archetype The archetype the range is being removed from.
        --- @param firstRow The 1-based row of the first removed entity.
        --- @param lastRow The 1-based row of the last removed entity (inclusive).
        --- @param count Number of entities in the range (lastRow - firstRow + 1).
        --- @param destArchetype The archetype the range is moving to (nil for despawns).
        onEntitiesRemoved: function(
            self,
            archetype: Archetype,
            firstRow: integer,
            lastRow: integer,
            count: integer,
            destArchetype?: Archetype
        )

        --- Called when an entity is swap-popped into a different row (the row your `onEntitiesAdded` saw is now
        --- a different entity). Only fires when the observer also implements `onEntitiesAdded`.
        ---
        --- @param archetype The archetype.
        --- @param entity The entity ID that moved.
        --- @param fromRow The original row position (0-based).
        --- @param toRow The new row position (0-based).
        onEntityMove: function(self, archetype: Archetype, entity: integer, fromRow: integer, toRow: integer)

        --- Called when archetype transitions from empty to non-empty (0 -> 1 entities).
        ---
        --- @param archetype The archetype that became active.
        onActivated: function(self, archetype: Archetype)

        --- Called when archetype transitions from non-empty to empty (1 -> 0 entities).
        ---
        --- @param archetype The archetype that became inactive.
        onDeactivated: function(self, archetype: Archetype)

        --- Called when an archetype is being permanently destroyed (during `world:compact()`).
        --- Observers must remove all references to the archetype.
        onArchetypeDestroyed: function(self, archetype: Archetype)
    end

    --- A query for finding entities with specific components.
    interface Query
        --- Query descriptor for creating queries.
        interface Descriptor
            --- An optional name to give the query, used in logging.
            name: string

            --- The components an archetype must contain in order to match the query.
            include: {components.Component}

            --- The components an archetype must have at least one of (OR condition).
            --- Archetype matches if it has ALL of include AND at least one of includeAny.
            includeAny: {components.Component}

            --- The components an archetype must not contain in order to match the query.
            exclude: {components.Component}

            --- Called once per contiguous range of newly-matched entities.
            onEntitiesAdded: function(archetype: Archetype, firstRow: integer, lastRow: integer, count: integer)

            --- Called once per contiguous range of entities leaving the match set.
            onEntitiesRemoved: function(archetype: Archetype, firstRow: integer, lastRow: integer, count: integer)

            --- If true, the query is a snapshot of current archetypes only and does not register subscriptions.
            temp: boolean

            --- Optional function to group archetypes by an integer key.
            --- Archetypes with the same group are iterated contiguously.
            --- Use with groups() and group(id) for efficient grouped iteration.
            groupBy: function(archetype: Archetype): integer
        end

        type IterFn = function(Query, any): (Archetype, integer, {integer})
        type GroupsIterFn = function(Query, any): integer
        type GroupIterFn = function(Query, any): (Archetype, integer, {integer})

        --- The query descriptor used to create the query.
        descriptor: Descriptor

        --- Explicit iterator protocol form.
        --- Returns (archetype, length, entities) for each matching archetype.
        --- Use archetype[Component] to retrieve component data.
        ---
        --- Usage: `for archetype, length, entities in query:iter() do ... end`
        iter: function(self): (IterFn, Query, any)

        --- Iterate over active group IDs in sorted order.
        --- Only available when groupBy is specified.
        --- Usage: `for blendId in query:groups() do ... end`.
        groups: function(self): (GroupsIterFn, Query, any)

        --- Iterate over archetypes in a specific group.
        --- Only available when groupBy is specified.
        --- Usage: `for archetype, len, entities in query:group(id) do ... end`.
        --- Yields nothing if the group has no archetypes.
        group: function(self, groupId: integer): (GroupIterFn, Query, any)

        --- Get the cached group ID for an archetype.
        --- Only available when groupBy is specified.
        --- Returns nil if archetype is not in this query or groupBy not specified.
        getGroup: function(self, archetype: Archetype): integer

        --- Get the total entity count for a group.
        --- Only available when groupBy is specified.
        --- Returns 0 if group doesn't exist or has no entities.
        getGroupCount: function(self, groupId: integer): integer
    end

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

        --- The fixed timestep interval in seconds (e.g., 1/60 for 60Hz physics).
        fixedTimestep: number

        --- Accumulated time not yet consumed by fixed updates.
        --- Use with fixedTimestep to compute interpolation alpha: accumulator / timestep.
        fixedAccumulator: number

        --- Update the pipeline.
        --- @param dt The delta time since the last update.
        --- @param world The world to update.
        update: function(self, dt: number, world: World)

        --- Run a specific phase.
        --- @param phase The phase to run.
        --- @param dt The delta time since the last update.
        --- @param world The world to run the phase on.
        run: function(self, phase: Phase, dt: number, world: World)

        --- Add a system to the pipeline.
        --- @param config The system configuration.
        addSystem: function(self, config: SystemConfig)

        --- Remove a system from the pipeline.
        ---
        --- @param systemName The name of the system to remove.
        removeSystem: function(self, systemName: string)

        --- Enable a phase.
        --- @param phase The phase to enable.
        enablePhase: function(self, phase: Phase)

        --- Disable a phase.
        --- @param phase The phase to disable.
        disablePhase: function(self, phase: Phase)

        --- Register a custom phase with the pipeline.
        --- @param phase The phase to register.
        registerPhase: function(self, phase: Phase)
    end

    --- System configuration used when adding systems to the world
    interface SystemConfig
        name: string
        id: string
        phase: Phase
        run: System
        before: {string}
        after: {string}
        runIf: function(dt: number, world: World, systemName: string): boolean
    end

    --- The main World interface.
    interface World
        --- World configuration
        interface Config
            timestep: number
            pipelineFactory: function(number): Pipeline
            --- Maximum number of concurrent entity slots. Must be a power of 2, at most 2^22 (~4M, format cap).
            --- Defaults to 2^20 (~1M). Arena memory is preallocated to accomodate this size.
            maxEntities: integer
        end

        interface SnapshotComponentTableEntry
            name: string
            fingerprint: string | nil
        end

        interface SnapshotPrelude
            version: integer
            nextEntityId: integer
            entityCount: integer
            archetypeCount: integer
            componentTable: {SnapshotComponentTableEntry}
        end

        interface SnapshotArchetypeEntry
            columnIndices: {integer}
            entities: {{any}}
        end

        interface SnapshotDataEntry
            key: string
            value: any
        end

        interface Snapshot
            version: integer
            nextEntityId: integer
            componentTable: {SnapshotComponentTableEntry}
            archetypes: {SnapshotArchetypeEntry}
            data: {SnapshotDataEntry}
        end

        enum SnapshotFormat
            "binary"
            "table"
        end

        --- Options passed to `saveSnapshot`. All fields are optional.
        interface SnapshotOptions
            --- `"binary"` (default) returns a LuaJIT string.buffer;
            --- `"table"` returns a plain Lua snapshot table.
            format: SnapshotFormat
            --- Reuse this `string.buffer` instead of allocating a fresh one.
            --- Only used for binary output.
            buffer: StringBuffer
            --- Optional file path for binary output. When provided,
            --- saveSnapshot writes the bytes to disk and still returns
            --- the tagged buffer result.
            path: string
            --- Query descriptor whose include/includeAny/exclude set selects the
            --- archetypes that should be saved. Built into a temp query internally.
            filterQuery: Query.Descriptor
            --- Allow-list of `Transform.layer` values (must fit in 0..31).
            layers: {integer}
            --- Ad-hoc keyed metadata to attach to this snapshot.
            customData: {string: any}
        end

        interface SnapshotOutput
            format: SnapshotFormat
            buffer: StringBuffer | nil
            snapshot: Snapshot | nil
        end

        --- Resources stored in the world.
        resources: Context

        --- Open a defer scope. Mutations within the scope are staged and
        --- drained on the matching `commit`. Pairs with `commit`.
        defer: function(self)

        --- Close one scope level and drain pending changes when the
        --- outermost scope finishes.
        commit: function(self)

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
        --- @param systemName The name of the system to remove.
        removeSystem: function(self, systemName: string)

        --- Update the world.
        ---
        --- @param dt The time since the last update.
        update: function(self, dt: number)

        --- Run the startup systems.
        startup: function(self)

        --- Run the shutdown systems.
        shutdown: function(self)

        --- Run every system registered to `phase` (and its enabled
        --- descendants) with the given `dt`. Unlike `update`, this does
        --- NOT pre-commit or clear dirty bits
        --- — it only dispatches systems. Useful for piecewise phase
        --- execution (e.g. custom game loops splitting Update and
        --- Render across distinct ticks).
        runPhase: function(self, phase: Phase, dt?: number)

        -------------------------------------------------------------------------------
        -- Entity methods
        -------------------------------------------------------------------------------

        --- Spawn a new entity with optional variadic components.
        ---
        --- @param ... Variable number of components to add to the entity.
        --- @return The ID of the spawned entity.
        spawn: function(self, ...: components.Component): integer

        --- Spawn an entity at a specific packed id rather than auto-
        --- allocating. The id carries both slot and generation, so
        --- relationship targets resolve to the same entity across a
        --- save/load cycle. The caller is responsible for ensuring the
        --- id's slot is not already live.
        ---
        --- @param id The packed entity id to reuse.
        --- @param ... Variable number of components to add to the entity.
        spawnAt: function(self, id: integer, ...: components.Component)

        --- Iterate all archetypes in the world. Mainly useful for save
        --- game / debugging tools that need to walk entity state without
        --- matching a specific component signature.
        ---
        --- @param callback Called with each archetype.
        forEachArchetype: function(self, callback: function(Archetype))

        --- Return an iterator over archetypes whose rows have been
        --- mutated since the last `world:update()`. Used by systems
        --- that consume dirty state incrementally (GPU shadow upload,
        --- reactive systems, debug tooling). The set is cleared
        --- automatically at the end of each `update()` after the
        --- pipeline finishes.
        ---
        --- Same iteration constraint as queries: do not mutate the
        --- world during iteration.
        dirtyArchetypes: function(self): function(): Archetype

        --- Bulk-spawn `count` entities sharing one component signature.
        --- Resolves the target archetype once at call time, allocates a
        --- contiguous ID range, and defers the actual row placement and
        --- `callback` invocation until the next commit. The returned
        --- `firstId` is valid immediately — you can call `world:set`,
        --- `world:remove`, or `world:despawn` on any of the allocated
        --- IDs before commit and the mutations are ordered correctly.
        ---
        --- Entity IDs are contiguous: `firstId`, `firstId + 1`, ...,
        --- `firstId + count - 1`.
        ---
        --- At commit time the target archetype's row range is claimed,
        --- then `callback(archetype, startRow, count)` runs so you can
        --- write per-entity data via direct column access
        --- (`archetype[Component][row] = ...`). `onAdd` hooks fire after
        --- the callback for every spawned entity, and query observers
        --- are notified.
        ---
        --- Relationship components (dense or sparse) are supported in
        --- the signature as either the bare container (e.g. `ChildOf`)
        --- or as a specific-target instance (e.g. `ChildOf(parent)`).
        --- When an instance is passed, its wildcard container is added
        --- to the archetype automatically — no follow-up `world:set`
        --- is needed for queries on the bare container to match.
        ---
        --- Sparse relationship columns are row-indexed proxies that
        --- error on direct writes from the `callback`. For per-entity
        --- *varying* target values, call
        --- `world:set(firstId + i, SparseRel(target))` either inside
        --- the callback or any time before commit. The staged sparse
        --- sets drain alongside the batchSpawn placement.
        ---
        --- @param count Number of entities to spawn.
        --- @param componentTypes Array of component types defining the archetype.
        --- @param callback Called at commit with `(archetype, firstRow, lastRow, count)`.
        ---   Iterate rows with `for i = firstRow, lastRow do ... end`.
        --- @return The first entity ID in the contiguous allocation.
        batchSpawn: function(self, count: integer, componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer)): integer

        --- Lenient counterpart to `batchSpawn`: allocates as many
        --- contiguous fresh slots as possible, then tops up the remainder
        --- from the LIFO free stack. Use this when you want to succeed
        --- despite fragmentation, at the cost of losing the `firstId + i`
        --- contiguous-id guarantee. Errors only when the allocator is
        --- fully exhausted.
        ---
        --- Returned ids are in allocation order (fresh first, then free).
        --- Iterate the returned list explicitly instead of using
        --- arithmetic on the first id.
        ---
        --- @param count Number of entities to spawn.
        --- @param componentTypes Array of component types defining the archetype.
        --- @param callback Called at commit with `(archetype, firstRow, lastRow, count)`.
        --- @return The list of spawned entity IDs (non-contiguous).
        batchSpawnBestEffort: function(self, count: integer, componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer)): {integer}

        --- Like `batchSpawn`, but uses the supplied entity IDs instead of
        --- allocating a new contiguous range. Intended for snapshot loads
        --- where each restored entity keeps its original ID. The archetype
        --- resolution, capacity check, and hook sweep happen once per call
        --- regardless of ID ordering.
        ---
        --- @param ids Explicit entity IDs to spawn, in order.
        --- @param componentTypes Array of component types defining the archetype.
        --- @param callback Called at commit with `(archetype, firstRow, lastRow, count)`.
        batchSpawnAt: function(self, ids: {integer}, componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer))

        --- Internal raw-FFI variant of `batchSpawnAt`. `ids` is an
        --- `int32_t[count]` (or compatible cdata) indexed 0..count-1.
        --- Used by the snapshot loader to consume FFI-read ids directly
        --- without a Lua-table intermediate. Not intended for user code.
        batchSpawnAtRaw: function(self, ids: any, count: integer,
            componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer))

        --- Despawn an entity.
        ---
        --- @param entity The entity to despawn.
        despawn: function(self, entity: integer)

        --- Bulk-despawn every entity matching `query`. The actual
        --- teardown is deferred until the next commit.
        ---
        --- `query` must be a `Query` object built via `world:query(...)`
        --- and reused across calls — batch ops do not accept
        --- QueryDescriptors or raw component-type arrays. Build the
        --- query once outside your hot loop.
        ---
        --- At commit time, events and hooks fire as expected:
        ---   * `OnDespawn` events fire for each despawned entity
        ---     (global observers and per-entity observers).
        ---   * Per-entity observer subscriptions are cleared after the
        ---     event fans out.
        ---   * Query observers receive a single `onEntitiesRemoved` for
        ---     the full range, followed by `onDeactivated` when the
        ---     archetype empties.
        ---   * Archetypes with remove hooks, dense relationships, or
        ---     entities that are reverse-index targets fall back to
        ---     per-entity despawn so cascade-delete, unlink, and
        ---     `onRemove` run correctly.
        ---
        --- @param query Query built via `world:query(...)`.
        batchDespawn: function(self, query: Query)

        --- Bulk-set a component on every entity matching `query`.
        ---
        --- Two modes:
        ---   * Constant: `world:batchSet(q, Stunned)` or
        ---     `world:batchSet(q, Position(0, 0))`. The instance is
        ---     copied to every matched row. If an archetype lacks the
        ---     component, entities are bulk-moved to the archetype
        ---     `src:withComponent(type)` first, then the new column is
        ---     filled.
        ---   * Callback: `world:batchSet(q, Position, function(arch,
        ---     firstRow, lastRow, count) ... end)`. Component is
        ---     ensured to exist (bulk move if needed), then the
        ---     callback is invoked once per affected archetype with
        ---     1-based inclusive row bounds so the caller can write the
        ---     column directly.
        ---
        --- Fast path runs when the **target component** is "plain": no
        --- onAdd / onReplace / onRemove hooks, not a dense-relationship
        --- instance (no wildcard container), and not a sparse
        --- relationship. Other components in the source archetype and
        --- their hooks do not matter — bulk moves don't re-fire
        --- pass-through components' hooks. Fast path does one move
        --- plan per (src, dst) archetype, bulk column copy, whole-
        --- archetype truncate. Hook-bearing or relationship-bearing
        --- components fall back to per-entity `world:set` for
        --- correctness (const form only — see below).
        ---
        --- Callback form additionally requires the target component to
        --- be plain: the callback IS the value-write step, so there's
        --- no clean way to fire `onReplace` around it (no old-value
        --- snapshot) or `onAdd` (no per-entity value to pass). The
        --- enqueue call asserts on this. Hook-bearing components must
        --- use the constant-value form.
        ---
        --- Sparse relationships always route through the per-entity
        --- path since they live in per-world stores, not archetype
        --- columns.
        ---
        --- @param query Query built via `world:query(...)`.
        --- @param componentOrInstance Component instance (const mode) or component type (callback mode).
        --- @param callback Optional chunk writer `(arch, firstRow, lastRow, count)`.
        batchSet: function(
            self,
            query: Query,
            componentOrInstance: components.Component,
            callback?: function(Archetype, integer, integer, integer)
        )

        --- Bulk-remove a component from every entity matching `query`
        --- whose archetype currently carries it. Archetypes in the
        --- query that lack the component are skipped silently (no-op).
        ---
        --- Fast path runs when the **target component** is plain (no
        --- onRemove hook, no wildcard container, not sparse) — one
        --- bulk move to `src:withoutComponent(type)` per matched
        --- archetype, no per-entity dispatch. Hook-bearing or
        --- relationship-bearing components fall back to per-entity
        --- `world:remove` so `onRemove`, reverse-index unlink, and
        --- cascade delete all fire correctly. Other components in the
        --- source archetype do not affect path selection.
        ---
        --- @param query Query built via `world:query(...)`.
        --- @param componentType Component to remove.
        batchRemove: function(self, query: Query, componentType: components.Component)

        --- Wipe all entity data but preserve structural state (pipeline,
        --- registered systems, queries, query observers, archetype column
        --- capacity). Use this for per-test reuse, benchmark setup, and
        --- save/load clear-before-load.
        ---
        --- Clears: entities, pending transaction, sparse relationship
        --- stores and queued messages.
        --- Preserves: systems, queries, archetype columns, observers.
        ---
        --- If you need post-construction state (systems gone, queries gone),
        --- just call `tecs.newWorld()` — same path, clearer intent.
        clearEntities: function(self)

        --- Compact the world: prune dead archetypes whose relationship
        --- targets have been despawned and shrink overallocated archetype
        --- storage. Must be called on a quiet world (no pending mutations).
        ---
        --- @return archetypesPruned Number of dead archetypes removed.
        --- @return archetypesCompacted Number of archetypes whose storage was shrunk.
        compact: function(self): integer, integer

        --- Check if an entity is committed and alive.
        ---
        --- @param entity The entity to check.
        --- @return true if the entity is committed and alive, false otherwise.
        isAlive: function(self, entity: integer): boolean

        -------------------------------------------------------------------------------
        -- Component methods
        -------------------------------------------------------------------------------

        --- Check whether an entity currently has a component.
        ---
        --- For sparse relationships:
        --- - passing the relationship container checks whether the entity has
        ---   any target for that relationship
        --- - passing a relationship instance checks that specific target
        ---
        --- @param entity Entity ID.
        --- @param component Component type (or relationship instance) to check.
        --- @return true if present, false otherwise.
        has: function(self, entity: integer, component: components.Component): boolean

        --- Get a component instance attached to an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component type to get.
        --- @return The component instance or nil if not found.
        get: function<T is components.Component>(self, entity: integer, component: T): T

        --- Mutable counterpart to `get`. Returns the component AND
        --- marks it dirty on the entity's archetype so dirty-gated
        --- consumers (shadow pipeline, change observers) re-process the
        --- row after subsequent cdata writes. Use this whenever you
        --- intend to mutate the component through the returned
        --- reference. `get` + cdata write silently bypasses dirty
        --- tracking and leaves stale state downstream.
        ---
        --- @param entity Entity ID.
        --- @param component Component type to get-and-mark-dirty.
        --- @return The component instance or nil if not found.
        getMut: function<T is components.Component>(self, entity: integer, component: T): T

        --- Get the first relationship instance for a relationship container on an entity.
        --- For exclusive relationships (like ChildOf), this returns the single instance.
        ---
        --- @param entity Entity ID.
        --- @param relationship Relationship container type.
        --- @return The relationship instance or nil if not found.
        getFirstRelationship: function<T is components.Relationship>(self, entity: integer, relationship: T): T

        --- Add or update a component on an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component instance to set.
        set: function(self, entity: integer, component: components.Component, value?: any)

        --- Remove a component from an entity.
        ---
        --- @param entity Entity ID.
        --- @param component Component type to remove.
        remove: function(self, entity: integer, component: components.Component)

        --- Mark a component dirty on the entity's archetype. Used when
        --- code mutates a component's bytes through a path that
        --- doesn't go through `archetype:getMut` (e.g. a smart
        --- wrapper that holds an entity id and writes through a
        --- fetched FFI cdata).
        ---
        --- @param entity Entity ID.
        --- @param component Component type whose column was mutated.
        markComponentDirty: function(self, entity: integer, component: components.Component)

        -------------------------------------------------------------------------------
        -- Query methods
        -------------------------------------------------------------------------------

        --- Creates a new query. Iteration does NOT auto-mark anything
        --- dirty; mutation intent lives at the access site via
        --- `archetype:getMut(Foo)` inside the iter loop, which
        --- marks just that component dirty on the archetype.
        ---
        --- @param descriptor The query descriptor to create the query from.
        --- @return the created query.
        query: function(self, descriptor: Query.Descriptor): Query

        --- Find archetypes that have the given component.
        ---
        --- @param component The component to find.
        --- @return an iterator over the archetypes that have the component.
        findArchetypes: function(self, component: components.Component): function(): (Archetype, integer, DoubleArray)

        -------------------------------------------------------------------------------
        -- State Stack methods
        -------------------------------------------------------------------------------

        --- Create a named state with an optional lifecycle policy.
        ---
        --- Returns a tag component that is auto-added to entities spawned while
        --- this state is on top of the stack.
        ---
        --- @param name The name of the state.
        --- @param policy Optional lifecycle policy for state transitions.
        --- @return The tag component for this state.
        createState: function(self, name: string, policy?: StatePolicy): components.Component

        --- Push a state onto the state stack.
        ---
        --- Fires the previous top state's onBlur policy and the new state's onEnter policy.
        --- Entities spawned after this call will automatically receive the state's tag component.
        ---
        --- @param name The state name (must have been created with createState).
        pushState: function(self, name: string)

        --- Pop the current state from the state stack.
        ---
        --- Fires the current state's onExit policy and the new top state's onFocus policy.
        popState: function(self)

        --- Peek at the current top state name.
        ---
        --- @return The name of the top state, or nil if the stack is empty.
        peekState: function(self): string

        -------------------------------------------------------------------------------
        -- Sparse relationship methods
        -------------------------------------------------------------------------------

        --- Get all source entities that target a given entity via a sparse relationship.
        --- For ChildOf, this returns the children of the entity.
        ---
        --- The optional `context` is forwarded to the callback as its second
        --- argument so visitors can be hoisted to module scope and read/write
        --- state via the context table without per-call closure allocation.
        --- Context is appended last so existing single-arg callbacks
        --- (`function(srcId)`) keep working — Lua silently drops extra args.
        ---
        --- @param entity The target entity ID.
        --- @param relationship The sparse relationship container.
        --- @param callback Receives (sourceId, context) for each source.
        --- @param context Optional context value forwarded to the callback.
        targets: function<T>(
            self,
            entity: integer,
            relationship: components.Relationship,
            callback: function(integer, T),
            context: T
        )

        --- Depth-first traversal over a sparse relationship's inverse index.
        --- For example, this can be used to walk the ChildOf hierarchy of a node from the top down.
        ---
        --- @param root The root entity ID.
        --- @param relationship The sparse relationship container.
        --- @return An iterator yielding (depth, entityId) for each descendant.
        traverse: function(self, root: integer, relationship: components.Relationship): function(): (integer, integer)

        --- Walk up a relationship chain, calling `callback` for each ancestor.
        --- Follows the first target per level (equivalent to repeated
        --- `getFirstRelationship`), so semantics match exclusive relationships
        --- like `ChildOf` exactly and fall back to "first edge" for non-exclusive ones.
        ---
        --- Depth starts at 1 (direct parent) and increments per level. The callback
        --- may return `false` to stop the walk early; any other return value (including
        --- nil / no return) continues. `maxDepth` defaults to 100 and triggers a
        --- hard error if exceeded so accidental cycles surface immediately.
        ---
        --- The optional `context` is passed through to the callback unchanged, so a
        --- visitor function can live at module scope and read/write its state via the
        --- context table without per-call closure allocation.
        ---
        --- @param entity The entity to walk up from.
        --- @param relationship The relationship to follow.
        --- @param callback Receives (ancestorId, depth, context). Return `false` to stop.
        --- @param context Optional context value forwarded to the callback as its 3rd arg.
        --- @param maxDepth Safety cap, defaults to 100. Errors if exceeded.
        walkUp: function<T>(
            self,
            entity: integer,
            relationship: components.Relationship,
            callback: function(integer, integer, T): boolean,
            context: T,
            maxDepth?: number
        )

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

        --- Register a custom phase with the world's pipeline.
        --- This allows external modules to define their own phases.
        ---
        --- @param phase The phase to register.
        registerPhase: function(self, phase: Phase)

        -------------------------------------------------------------------------------
        -- Event methods
        -------------------------------------------------------------------------------

        --- Emit an event to an address.
        --- Use 0 for world-level events, entity ID for entity events.
        ---
        --- @param address The address to emit to (0 for world, entity ID for entity).
        --- @param eventOrType The event instance to emit, or an event type plus constructor args.
        emit: function(self, address: integer, eventOrType: events.Event, ...: any)

        --- Observe an event at an address.
        --- Use 0 for world-level events, entity ID for entity events.
        ---
        --- @param address The address to observe (0 for world, entity ID for entity).
        --- @param event The event type to observe.
        --- @param callback The callback to call when the event is emitted.
        --- @param id Optional ID for the observer.
        observe: function<T is events.Event>(self, address: integer, event: T, callback: function(event: T), id?: string)

        --- Stop observing an event at an address.
        ---
        --- @param address The address to stop observing.
        --- @param event The event type to stop observing.
        --- @param observer The observer function or ID.
        stopObserving: function<T is events.Event>(self, address: integer, event: T, observer: function(T) | string)

        --- Check if there are observers for an event at an address.
        ---
        --- @param address The address to check.
        --- @param event The event type to check.
        --- @return true if there are observers, false otherwise.
        hasObservers: function<T is events.Event>(self, address: integer, event: T): boolean

        --- Clear all observers for an address (used on entity despawn).
        ---
        --- @param address The address to clear.
        clearObservers: function(self, address: integer)

        -------------------------------------------------------------------------------
        -- Stats methods
        -------------------------------------------------------------------------------

        --- Get stats about the World.
        ---
        --- @param fill Optional stats table to fill instead of allocating a new one.
        --- @return the stats.
        getStats: function(self, fill?: World.Stats): World.Stats

        -------------------------------------------------------------------------------
        -- Snapshot methods
        -------------------------------------------------------------------------------

        --- Save the world to either binary or table form.
        ---
        --- Binary is the default. Set `opts.format = "table"` for a
        --- plain Lua snapshot table. `opts.path` is supported only for
        --- binary output.
        saveSnapshot: function(self, opts?: SnapshotOptions): SnapshotOutput

        --- Restore the world from either binary or table form.
        ---
        --- `source` may be a Lua string, a LuaJIT `string.buffer`, or
        --- a snapshot table previously returned by `saveSnapshot` with
        --- `format = "table"` (or parsed from JSON).
        loadSnapshot: function(self, source: any): SnapshotPrelude

        -------------------------------------------------------------------------------
        -- Bundle methods
        -------------------------------------------------------------------------------

        --- Create and register a bundle with the world.
        ---
        --- @param name The name of the bundle.
        --- @param def Bundle definition with required and with-default components.
        --- @return The registered bundle.
        newBundle: function(self, name: string, def?: Bundle.Definition): Bundle

        --- Spawn an entity using a registered bundle.
        ---
        --- @param name The name of the bundle.
        --- @param ... Component overrides (required components must be provided).
        --- @return The entity ID.
        spawnBundle: function(self, name: string, ...: components.Component): integer

        --- Get all registered bundles.
        ---
        --- @return Map of bundle name to bundle.
        getBundles: function(self): {string: any}

        --- Get a registered bundle by name.
        ---
        --- @param name The bundle name.
        --- @return The bundle, or nil if not found.
        getBundle: function(self, name: string): Bundle

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
    end

    --- A registered bundle with metadata and spawn capability.
    interface Bundle
        --- Declarative bundle definition.
        interface Definition
            --- Components that must be provided as positional args to spawn().
            required: {components.Component}
            --- Components with defaults, keyed by component type.
            --- Value is either a factory function returning a component instance,
            --- or `true` to call the component's default constructor.
            with: {components.Component: boolean | function(): components.Component}
        end

        --- The name of the bundle.
        name: string

        --- Component names that must be provided when spawning.
        required: {string}

        --- Component names with default factories.
        defaulted: {string}

        --- Spawn an entity using this bundle.
        --- @param ... Required component instances in declaration order.
        --- @return The entity ID.
        spawn: function(self, ...: components.Component): integer
    end

    --- 64-bit double array type used for entity IDs. Uses double so the
    --- 53-bit packed (slot, gen, flag) id survives read/write without
    --- truncation. Opaque shape — callers treat it like a 1-based
    --- integer array with length at `[0]`.
    interface DoubleArray is {integer}
        metamethod __len: function(self) = macroexp(self: DoubleArray)
            return self[0]
        end
    end

    --- 32-bit float array type (opaque -- could be FFI or table internally)
    interface Float32Array is {number}
        metamethod __len: function(self) = macroexp(self: Float32Array)
            return self[0]
        end
    end

    --- Event-specific helper types.
    record events
        --- An event that can be emitted.
        interface Event
            --- The unique ID of the event.
            eventId: integer

            --- Positional initializer used by `newEvent` / `newFFIEvent`.
            init: function(instance: self, ...: any)
        end

        --- An event listener that synchronously receives an event of type `E`.
        type EventListener = function<E is Event>(event: E)

        --- Event initializer that mutates a passed-in instance.
        type EventInit = function<E is Event>(instance: E, ...: any)

        --- Centralized message bus for address-based event routing.
        --- Addresses are integers: 0 for world-level events, entity IDs for entity events.
        interface MessageBus
            --- Observe an event type at a specific address.
            --- Address 0 is for world-level events, entity IDs for entity events.
            observe: function<E is Event>(
                self: MessageBus,
                address: integer,
                eventType: E,
                observer: function(E), id?: string
            )

            --- Observe an event type at a specific address, at most once.
            observeOnce: function<E is Event>(
                self: MessageBus,
                address: integer,
                eventType: E,
                observer: function(E)
            )

            --- Stop observing an event type at a specific address.
            stopObserving: function<E is Event>(
                self: MessageBus,
                address: integer,
                eventType: E,
                observerOrId: function(E)|string
            )

            --- Emit an event to all observers at the specified address.
            emit: function<E is Event>(self: MessageBus, address: integer, event: E)

            --- Check if any observers exist for an event type at an address.
            hasObservers: function<E is Event>(self: MessageBus, address: integer, eventType: E): boolean

            --- Clear all observers for an address (used on entity despawn).
            clearAddress: function(self: MessageBus, address: integer)

            --- Clear per-entity observers (every address except the global
            --- address 0), preserving global subscriptions. Used by
            --- world:clearEntities so query infrastructure stays subscribed.
            clearEntityObservers: function(self: MessageBus)

            --- Reset the entire message bus.
            reset: function(self: MessageBus)
        end
    end

    --- Policy for state lifecycle hooks.
    record StatePolicy
        --- Action for a state lifecycle hook.
        --- A string action ("pause", "resume", "despawn", "disable"),
        --- a plugin function, or a policy with both.
        record Action
            --- Built-in action: "pause", "resume", "despawn", "disable"
            apply: string
            --- Custom function called with the world
            call: function(World)
        end

        --- Fires when this state is no longer top (another state pushed on top).
        onBlur: string | Action | function(World)
        --- Fires when this state becomes top again (state above popped).
        onFocus: string | Action | function(World)
        --- Fires when this state is first pushed. Only accepts a plugin function.
        onEnter: function(World)
        --- Fires when this state is popped (default: "despawn").
        onExit: string | Action | function(World)
    end

    --- Interface for components that provide axis-aligned bounding boxes.
    --- Used for layout calculations, culling, and collision detection.
    interface Rect
        --- Get the offset and size for this component relative to the entity's position.
        --- @return offsetX The x offset from the entity position.
        --- @return offsetY The y offset from the entity position.
        --- @return width The width of the bounding box.
        --- @return height The height of the bounding box.
        getRect: function(self): number, number, number, number
    end
end

return types
