--[=[
Internal type definitions for breaking circular dependencies.

Declares `WorldImpl` as a concrete record with all fields + every
method signature (public API + `_`-prefixed internal staging/drain
methods). Implementations live in `world.tl` and `world/*.tl`; each
file aliases `internal.WorldImpl` and attaches methods via
`function WorldImpl:foo(...)`. This is the only way Teal's type
checker accepts cross-file method extension -- the concrete record
declaration must exist in a module with no cyclic imports.
]=]

local types <const> = require("tecs.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local pool <const> = require("tecs.utils.pool")
local RelationshipStore <const> = require("tecs.internal.RelationshipStore")
local BitsetImpl <const> = require("tecs.utils.Bitset")

local type Component = types.components.Component
local type Query = types.Query
local type QueryDescriptor = types.Query.Descriptor
local type Relationship = types.components.Relationship
local type DoubleArray = types.DoubleArray
local type StatePolicy = types.StatePolicy
local type Event = types.events.Event
local type Phase = types.Phase
local type Plugin = types.Plugin
local type Bundle = types.Bundle
local type SystemConfig = types.SystemConfig
local type EntitySlot = IdAllocator.EntitySlot
local type Bitset = BitsetImpl

local record internal

    --- Optional cold-path observer for committed entity/archetype and state
    --- transitions. Debug tooling installs this only while a breakpoint is
    --- armed; normal worlds pay one nil check at structural mutation sites.
    record TransitionObserver
        entity: function(id: integer, before: ArchetypeInternal, after: ArchetypeInternal)
        state: function(kind: string, before: string, after: string, changed: string)
    end

    --- A single resolved entry in a component's `_requiresClosure`.
    --- Built once per (registering) component and walked on every
    --- mutation that adds the owning component, so field reads here
    --- have to be hot-loop-safe (no table/closure allocs per entry).
    record RequireEntry
        --- The component TYPE (container) to ensure present in the
        --- destination archetype. Used as the `columns` key.
        type: types.components.Component

        --- Pre-resolved value to write at the entity's row. Non-nil
        --- for tag containers (self), for instances, and for any other
        --- case where the value is shareable across entities. Nil for
        --- data-container entries where each entity needs a fresh
        --- allocation -- `factory` is used in that case.
        sharedValue: any

        --- When `sharedValue` is nil, this is the container callable
        --- (invoked with no args to produce a fresh default instance
        --- per entity).
        factory: any

        --- False for tag-storage types (column `__newindex` is a
        --- no-op); skip the write entirely when false.
        writeColumn: boolean
    end

    --- Archetype interface extended with framework-internal layout,
    --- observer, drain, and graph fields. Public `types.Archetype`
    --- exposes only the supported surface (id, entities,
    --- componentList, column `__index`, get/set, forEachRelationship,
    --- getFirstRelationship, and dirty-row tracking); internal code
    --- that holds a `types.Archetype`-typed value casts via
    --- `arch as ArchetypeInternal` to reach these fields. The concrete
    --- record in `tecs.internal.Archetype` declares the same set
    --- directly (it can't `is` this interface -- importing this module
    --- from Archetype.tl would create a circular require).
    interface ArchetypeInternal is types.Archetype
        onDespawnComponents: {types.components.Component}
        onDespawnCount: integer

        -- Layout / storage
        signatureBits: Bitset
        signatureWordBits: Bitset
        columns: {types.components.Component: {types.components.Component}}
        columnArray: {{types.components.Component}}
        columnIndexByComponent: {types.components.Component: integer}
        columnsCount: integer
        dataColumnsCount: integer
        capacity: integer

        -- Observer registration / counters
        observerCount: integer
        hasRemoveObservers: integer
        hasAddObservers: integer
        addEntityObserver: function(self, observer: types.ArchetypeEntityObserver)
        clearDirtyComponents: function(self)

        -- Structural dirt told apart from value dirt, and the rows a
        -- structural change wrote. `isComponentDirty` on the public surface
        -- answers for both together; a consumer that can rewrite single rows
        -- rather than whole columns needs them separated, and these are that
        -- separation. They are counts rather than flags for the other reason
        -- such a consumer exists: a flag clears with the frame, and one whose
        -- work runs before the frame's later phases would never see what they
        -- changed. See `tecs.internal.Archetype` for the contract on each.
        valueCount: function(self): integer
        structuralCount: function(self): integer
        structuralDescribed: function(self, count: integer): boolean
        structuralAdded: function(self): integer
        structuralTouched: function(self): {integer}, integer

        -- Transaction / drain staging state
        isEphemeral: boolean
        pendingWrites: integer
        pendingDespawn: {integer}
        pendingDespawnCount: integer
        pendingClear: boolean
        pendingSpawnIds: {integer}
        pendingSpawnCount: integer
        pendingValues: {integer: {any}}
        pendingValueSlots: {integer}
        pendingValueCount: integer
        pendingScalarTypes: {integer: {types.components.Component}}
        pendingScalarValues: {integer: {any}}
        hasScalarPending: boolean
        hasPendingDespawns: boolean
        hasPendingSpawns: boolean
        hasPendingMoveOut: boolean
        dirtyQueuedEpoch: integer
        pendingBundleDrains: {any}
        pendingBundleDrainCount: integer
        batchSpawnQueue: {any}
        batchSpawnQueueCount: integer
        batchSpawnAtQueue: {any}
        batchSpawnAtQueueCount: integer

        -- Archetype graph edges
        addEdges: {types.components.Component: ArchetypeInternal}
        removeEdges: {types.components.Component: ArchetypeInternal}

        -- Cache / invalidation
        generation: integer

        -- Mutation / drain methods
        reserveCapacity: function(self, targetRows: integer)
        withComponent: function(
            self, component: types.components.Component, archetypeIndex: ArchetypeIndexInternal
        ): ArchetypeInternal
        withoutComponent: function(
            self, component: types.components.Component, archetypeIndex: ArchetypeIndexInternal
        ): ArchetypeInternal
        getMovePlanTo: function(self, dstArch: ArchetypeInternal): MovePlan
        removeEntity: function(self, row: integer, destArchetype?: ArchetypeInternal): integer, integer
        onRowsAdded: function(self, rowStart: integer, count: integer, sourceArchetype?: ArchetypeInternal)
        notifyAdded: function(self, rowStart: integer, count: integer, sourceArchetype?: ArchetypeInternal)
        notifyRemoved: function(self, rowStart: integer, count: integer, destArchetype?: ArchetypeInternal)
        notifyDeactivatedExternal: function(self)
        notifyArchetypeDestroyed: function(self)
        clearEntities: function(self)
        compact: function(self)
        resetPending: function(self)
        appendPendingValue: function(self, slot: integer, value: any, vals?: {any})
        getPendingValues: function(self, slot: integer): {any}
        findPendingValue: function(self, slot: integer, componentType: types.components.Component): any
        movePendingValuesTo: function(self, dst: ArchetypeInternal, slot: integer)
    end

    interface ArchetypeIndexInternal is {ArchetypeInternal}
        componentIndex: {Component: {ArchetypeInternal: boolean}}
        dirtySet: {ArchetypeInternal: boolean}
        emptyArchetype: ArchetypeInternal
        relationshipStoreGetter: function(Component): any
        onNewArchetype: function(ArchetypeInternal)
        maxId: integer

        freeIds: {integer}
        freeIdCount: integer

        getOrCreate: function(self, components: {Component}): ArchetypeInternal
        findMatching: function(self, include: {Component}, masks: CompiledQueryMasks): {ArchetypeInternal}
        getArchetypesWithComponent: function(self, component: Component): {ArchetypeInternal: boolean} | nil
        destroy: function(self, archetype: ArchetypeInternal)
    end

    record CompiledQueryMasks
        includeBits: Bitset
        includeWordBits: Bitset
        includeAnyBits: Bitset
        includeAnyWordBits: Bitset
        excludeBits: Bitset
        excludeWordBits: Bitset
    end

    --- Cached "move" plan describing how to migrate a row from one
    --- archetype to another. Built lazily by
    --- `Archetype:getMovePlanTo` and stashed on `movePlansOut`; reused
    --- across drain ticks until the source or destination archetype
    --- bumps its `generation`. Fields are arrays-of-parallel-arrays
    --- indexed `1..count`.
    record MovePlan
        --- Snapshot of the source archetype's `generation` at build
        --- time. The cached plan is reused only while it still equals
        --- the live `srcGen`.
        srcGen: integer

        --- Snapshot of the destination archetype's `generation` at
        --- build time.
        dstGen: integer

        --- Number of valid entries in the parallel arrays below.
        count: integer

        --- Source-side column refs (live tables that own the rows).
        srcCols: {{types.components.Component}}

        --- Destination-side column refs.
        dstCols: {{types.components.Component}}

        --- Per-column FFI struct size in bytes; 0 for table-backed
        --- columns. Drives the `ffi.copy` bulk-memcpy fast path on
        --- single-row moves.
        structSizes: {integer}

        --- Component containers parallel to the col arrays. Used by
        --- the swap-when-empty fast path to rewire `columns[comp]`
        --- and `columnArray[idx]` on both sides.
        comps: {types.components.Component}

        --- Per-column source archetype index (1-based) into
        --- `srcArch.componentList` / `columnArray`.
        srcColIndices: {integer}

        --- Per-column destination archetype index (1-based) into
        --- `dstArch.componentList` / `columnArray`.
        dstColIndices: {integer}
    end

    --- Component interface extended with framework-internal fields. Public
    --- `types.components.Component` omits these so users can't rely on them; internal
    --- code casts via `comp as ComponentInternal` to read/write.
    interface ComponentInternal is types.components.Component
        --- Declarative auto-dependencies. When this component is added, any
        --- listed components not already present on the entity are added in
        --- the same archetype transition. Entries may be component types
        --- (default-constructed) or instances (used as-is). Transitive.
        --- Set at registration via `cfg.requires`; not user-introspectable
        --- post-registration.
        requires: {types.components.Component}

        --- The storage implementation for this component type.
        --- Typed as `any` here because `Storage` lives in
        --- `tecs.internal.storage` and importing it would create a
        --- circular require. Internal code casts to `storage.Storage`.
        storage: any

        --- Cached storage kind, mirrors `storage.storageType`. Typed loosely
        --- as string (internal) for the same circular-require reason as the
        --- `storage` field.
        storageType: string

        --- True iff a reverse index store is maintained for this
        --- relationship container (lets `world:targets` answer "who points
        --- at this entity"). Set at registration via `cfg.reverseIndex`.
        reverseIndex: boolean

        --- True iff despawning the target of this relationship should
        --- cascade-despawn all sources. Set at registration via
        --- `cfg.cascadeDelete`. Implies `reverseIndex` and `exclusive`.
        cascadeDelete: boolean

        --- True iff this relationship type uses sparse storage. Set on the
        --- container at registration; instances inherit via metatable
        --- __index. Read together with `componentType ~= self` to
        --- distinguish container from instance when needed.
        isSparse: boolean

        --- True iff this is a relationship container (`componentType == self`).
        isContainer: boolean

        --- Precomputed discriminator: true only on per-target sparse instance
        --- values (`SparseRel(target)`). Lets `world:has` / `world:get` route
        --- to the per-world relationship store via a single field read,
        --- avoiding the chained `isSparse and componentType ~= self`.
        isSparseInstance: boolean

        --- Write the component's raw bytes directly into a LuaJIT
        --- `string.buffer`. Optional; auto-installed for FFI components.
        --- Used by the binary snapshot writer to skip the field-table
        --- round trip.
        serializeRaw: function(instance: types.components.Component, buf: any)

        --- Read a component instance back from a string.buffer. Paired
        --- with `serializeRaw`.
        deserializeRaw: function(buf: any): types.components.Component

        --- Canonical schema fingerprint for FFI components, formatted as
        --- "field1:type1,field2:type2|sizeBytes". Snapshot uses this to
        --- detect schema drift between save and load. Nil for non-FFI.
        fingerprint: string

        --- Total bytes per FFI struct instance. Nil for non-FFI components.
        --- Used by snapshot to bulk-memcpy whole columns.
        structSize: integer

        --- True iff this component is runtime-only and should not be written
        --- to snapshots.
        transient: boolean

        --- True iff value writes to this component's columns are counted on
        --- `ArchetypeInternal.valueCount`. Nil until a consumer sets it, which
        --- reads as off.
        ---
        --- A consumer sets it for the columns it reads and no others: the count
        --- is one number per archetype, so a column counted for nobody's
        --- benefit reports a change to everybody. It lives on the component
        --- rather than in a per-archetype cache so it takes effect on
        --- archetypes that already exist, which is the ordering a consumer
        --- loaded lazily cannot otherwise guarantee.
        valueCounted: boolean

        --- Fast-path flag: true iff `requires` is non-empty. Set at
        --- registration so dispatch can short-circuit the closure walk.
        _hasRequires: boolean

        --- Precomputed bitset position for archetype signatures.
        signatureIndex: integer
        signatureWordIndex: integer

        --- Lazily-built transitive closure of `requires`. Populated on
        --- first use so late-binding of dependent components works.
        _requiresClosure: {RequireEntry}

        --- Closed framework behavior id. Nil means no framework-owned
        --- mutation behavior.
        frameworkBehavior: integer

        --- Bitmask describing which mutation paths the behavior needs.
        frameworkBehaviorBits: integer
    end

    --- The concrete world record. All fields live here; all methods attach
    --- via `function WorldImpl:foo` across world.tl + world/*.tl.
    record WorldImpl is types.World
        -- ----- Construction / orchestration -----
        pipeline: types.Pipeline
        resources: types.Context
        messages: types.events.MessageBus
        _ffiSliceId: integer
        _eventPool: pool.TablePool

        -- ----- Entity store -----
        allocator: IdAllocator
        -- `_slots` caches `allocator.slots` directly on the world so hot
        -- lookups (world:get / :isAlive / :markDirty) skip the `allocator.`
        -- field hop. The cdata pointer is preallocated and never reassigned,
        -- so a once-at-construction snapshot is always correct.
        _slots: {integer: EntitySlot}
        archetypeIndex: ArchetypeIndexInternal
        _bundles: {string: Bundle}
        _dirtyArchetypes: {ArchetypeInternal: boolean}
        -- Builtin hierarchy sampler, run after every system and before dirty
        -- bits clear so writes later than PostUpdate survive into its gate.
        _sampleHierarchyDirty: function()
        _stateStack: {string}
        _stateComponents: {string: Component}
        _statePolicies: {string: StatePolicy}
        _keyIndex: {string: integer}
        _transitionObserver: TransitionObserver

        relationshipStores: {Component: RelationshipStore}
        _targetRefCounts: {integer: integer}
        _hasRelationshipStores: boolean

        _archetypeSnapshotPool: pool.TablePool

        -- Merged scope counter. Incremented by `defer()` and query
        -- iteration entry; decremented by matching `commit()` and
        -- query exhaustion. Mutations stage rather than apply instantly
        -- while this is > 0; a drain fires when it returns to 0.
        _scopeDepth: integer

        -- ----- Staging / drain state -----
        -- Dirty-archetype dedupe uses an epoch + per-archetype marker
        -- (`arch.dirtyQueuedEpoch`) instead of a hashset. Bumping
        -- `_dirtyEpoch` on reset is O(1) and renders every archetype's
        -- marker stale without touching them.
        _dirtyEpoch: integer
        dirtyArchetypeList: {ArchetypeInternal}
        dirtyArchetypeCount: integer

        -- Epoch-stamped FFI transaction state. A single `_slotStamp[slot]`
        -- governs both `_stateArr[slot]` and `_pendingArchArr[slot]`: when
        -- `stamp != epoch`, both are treated as unset (0). On first write
        -- this epoch the stamp is bumped and the companion field zeroed
        -- (since its stored bytes are stale). Reset bumps
        -- `_transactionEpoch` in O(1); on 32-bit wrap the stamp array is
        -- cleared (every ~4B transactions -- effectively never).
        _stateArr: any -- uint8[maxSlotCount+1]
        _pendingArchArr: any -- uint32[maxSlotCount+1]  -- archetype ids
        _slotStamp: any -- uint32[maxSlotCount+1]  -- shared stamp
        _transactionEpoch: integer
        _maxSlotCount: integer
        entityStateCount: integer
        sparseSets: {integer: {Component}}
        sparseSetCount: integer
        _swapRemoveQueue: {integer}
        batchMutations: {any}
        batchMutationCount: integer
        _valsPool: {{any}}
        _valsPoolSize: integer
        _valsPoolNext: integer
        _sparseArraysPool: pool.TablePool
        _exclusivePool: pool.TablePool
        isDirty: boolean
        lastCompType: Component
        lastArch: ArchetypeInternal
        lastColumn: {any}
        autoStateComponent: Component
        emptyArchetype: ArchetypeInternal

        -- Constructor -- implemented in world.tl.
        new: function(config?: types.World.Config): types.World

        -- ----- Public API (mirrors types.World; redeclared for concrete-record resolution) -----
        addPlugin: function(self: WorldImpl, plugin: Plugin)
        get: function<T is Component>(self: WorldImpl, id: integer, component: T): T
        has: function(self: WorldImpl, id: integer, component: Component): boolean
        getFirstRelationship: function<T is Relationship>(self: WorldImpl, id: integer, relationship: T): T
        set: function(self: WorldImpl, id: integer, component: Component, value?: any)
        markDirty: function(self: WorldImpl, id: integer)
        remove: function(self: WorldImpl, id: integer, component: Component)
        spawn: function(self: WorldImpl, ...: Component): integer
        spawnAt: function(self: WorldImpl, id: integer, ...: Component)
        forEachArchetype: function(self: WorldImpl, callback: function(ArchetypeInternal))
        dirtyArchetypes: function(self: WorldImpl): function(): ArchetypeInternal
        batchSpawn: function(
            self: WorldImpl,
            count: integer,
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        ): integer | nil, {integer} | nil
        batchSpawnAt: function(
            self: WorldImpl,
            ids: {integer},
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        )
        batchSpawnAtRaw: function(
            self: WorldImpl,
            ids: any,
            count: integer,
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        )
        despawn: function(self: WorldImpl, id: integer)
        batchDespawn: function(self: WorldImpl, query: Query)
        batchSet: function(
            self: WorldImpl,
            query: Query,
            componentOrInstance: Component,
            callback?: function(ArchetypeInternal, integer, integer, integer)
        )
        batchRemove: function(self: WorldImpl, query: Query, componentType: Component)
        clearEntities: function(self: WorldImpl)
        compact: function(self: WorldImpl): integer, integer
        isAlive: function(self: WorldImpl, id: integer): boolean
        createState: function(self: WorldImpl, name: string, policy?: StatePolicy): Component
        pushState: function(self: WorldImpl, name: string)
        popState: function(self: WorldImpl)
        peekState: function(self: WorldImpl): string
        targets: function<T>(
            self: WorldImpl, id: integer, relationship: Relationship, callback: function(integer, T), context: T
        )
        walkUp: function<T>(
            self: WorldImpl,
            id: integer,
            relationship: Relationship,
            callback: function(integer, integer, T): boolean,
            context: T,
            maxDepth?: number
        )
        traverse: function(self: WorldImpl, root: integer, relationship: Relationship): function(): (integer, integer)
        addSystem: function(self: WorldImpl, config: SystemConfig)
        removeSystem: function(self: WorldImpl, systemName: string)
        query: function(self: WorldImpl, descriptor: QueryDescriptor): Query
        findArchetypes: function(
            self: WorldImpl, component: Component
        ): function(): (ArchetypeInternal, integer, DoubleArray)
        observe: function<E is Event>(
            self: WorldImpl, address: integer, eventType: E, observer: function(E), id?: string
        )
        stopObserving: function<E is Event>(
            self: WorldImpl, address: integer, eventType: E, observer: function(E) | string
        )
        hasObservers: function<E is Event>(self: WorldImpl, address: integer, eventType: E): boolean
        emit: function<E is Event>(self: WorldImpl, address: integer, eventOrType: E, ...: any)
        clearObservers: function(self: WorldImpl, address: integer)
        _pushQueryScope: function(self: WorldImpl)
        _popQueryScope: function(self: WorldImpl)
        defer: function(self: WorldImpl)
        commit: function(self: WorldImpl)
        unwind: function(self: WorldImpl)
        update: function(self: WorldImpl, dt: number)
        enablePhase: function(self: WorldImpl, phase: Phase)
        disablePhase: function(self: WorldImpl, phase: Phase)
        registerPhase: function(self: WorldImpl, phase: Phase)
        startup: function(self: WorldImpl)
        shutdown: function(self: WorldImpl)
        runPhase: function(self: WorldImpl, phase: Phase, dt?: number)
        newBundle: function(self: WorldImpl, name: string, def?: types.Bundle.Definition): Bundle
        spawnBundle: function(self: WorldImpl, name: string, ...: Component): integer
        getBundles: function(self: WorldImpl): {string: Bundle}
        getBundle: function(self: WorldImpl, name: string): Bundle | nil
        getStats: function(self: WorldImpl, fill?: types.World.Stats): types.World.Stats
        saveSnapshot: function(self: WorldImpl, opts?: types.World.SnapshotOptions): types.World.SnapshotOutput
        loadSnapshot: function(self: WorldImpl, source: any): types.World.SnapshotPrelude
        addSnapshotHandler: function(self: WorldImpl, handler: types.World.SnapshotHandler)

        -- ----- Internal staging / drain / batch / sparse methods -----
        findOldValue: function(
            self: WorldImpl, slot: integer, componentType: Component, sourceArch: ArchetypeInternal, sourceRow: integer
        ): any
        _deferSpawn: function(self: WorldImpl, ...: Component): integer
        _deferSpawnAt: function(self: WorldImpl, id: integer, ...: Component)
        _deferDespawn: function(self: WorldImpl, id: integer)
        -- Dispatchers (underscored, core-internal): run component-specific
        -- behavior when present, otherwise delegate to the raw entry below.
        _deferSet: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        _deferRemove: function(self: WorldImpl, id: integer, component: Component)
        _instantSet: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        _instantRemove: function(self: WorldImpl, id: integer, component: Component)

        -- Raw entries (no underscore): component-specific callbacks call
        -- these to invoke default behavior without re-dispatching into
        -- themselves.
        deferSetRaw: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        deferRemoveRaw: function(self: WorldImpl, id: integer, component: Component)
        instantSetRaw: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        instantRemoveRaw: function(self: WorldImpl, id: integer, component: Component)
        setRaw: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        removeRaw: function(self: WorldImpl, id: integer, component: Component)
        oldValueOf: function(self: WorldImpl, id: integer, component: Component): any
        currentArchetype: function(self: WorldImpl, id: integer): ArchetypeInternal
        _claimKey: function(self: WorldImpl, id: integer, key: string)
        _releaseKeyForEntity: function(self: WorldImpl, id: integer)
        _rebuildKeyIndex: function(self: WorldImpl)
        setSparseRaw: function(self: WorldImpl, id: integer, value: any)
        applySparseRaw: function(self: WorldImpl, id: integer, value: any)
        removeSparseRaw: function(self: WorldImpl, id: integer, container: Component)
        removeSparseOneRaw: function(self: WorldImpl, id: integer, container: Component, targetId: integer)
        _resolveSpawnArchetype: function(
            self: WorldImpl, componentTypes: {Component}
        ): ArchetypeInternal, {RequireEntry}

        -- Pure-mechanism workers; component-specific callbacks do not call
        -- these directly.
        _deferSetSlow: function(self: WorldImpl, id: integer, componentType: Component, value: any)
        _instantSpawn: function(self: WorldImpl, ...: Component): boolean, integer
        _instantDespawn: function(self: WorldImpl, id: integer): boolean
        _deferBatchSpawn: function(
            self: WorldImpl,
            count: integer,
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        ): integer | nil, {integer} | nil
        _deferBatchSpawnList: function(
            self: WorldImpl,
            count: integer,
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        ): {integer}
        _deferBatchSpawnAt: function(
            self: WorldImpl,
            ids: {integer},
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        )
        _deferBatchSpawnAtRaw: function(
            self: WorldImpl,
            ids: any,
            count: integer,
            componentTypes: {Component},
            callback: function(ArchetypeInternal, integer, integer, integer)
        )
        _deferBatchDespawn: function(self: WorldImpl, archetypes: {ArchetypeInternal})
        _deferBatchSet: function(
            self: WorldImpl, archetypes: {ArchetypeInternal}, componentType: Component, value: Component
        )
        _deferBatchSetCallback: function(
            self: WorldImpl,
            archetypes: {ArchetypeInternal},
            componentType: Component,
            callback: function(ArchetypeInternal, integer, integer, integer)
        )
        _deferBatchRemove: function(self: WorldImpl, archetypes: {ArchetypeInternal}, componentType: Component)
        _drainArchBatchSpawn: function(self: WorldImpl, archetype: ArchetypeInternal)
        _drainArchBatchSpawnAt: function(self: WorldImpl, archetype: ArchetypeInternal)
        _drainBatchMutations: function(self: WorldImpl)
        _truncateArchetype: function(self: WorldImpl, arch: ArchetypeInternal)
        _drainPendingSpawns: function(self: WorldImpl, arch: ArchetypeInternal)
        _drainPendingMoves: function(self: WorldImpl, srcArch: ArchetypeInternal)
        _drainPendingDespawns: function(self: WorldImpl, arch: ArchetypeInternal)
        _codegenBundleSpawn: function(
            self: WorldImpl, typeArray: {Component}, factoryArray: {function(): Component}, requiredCount: integer
        ): function(any, ...: Component): integer
        _drain: function(self: WorldImpl)
        _resetTxn: function(self: WorldImpl)
        _validateIntegrity: function(self: WorldImpl)
    end
end

return internal
