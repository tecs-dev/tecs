--[=[
The declarations behind the public ECS types.
]=]

-- Implementation details:
-- ECS records refer to one another in both directions. Keeping their
-- declarations together lets Teal resolve those references without a require
-- cycle. The public API publishes them under `tecs` and `tecs.ecs`.

local StringBuffer <const> = require("string.buffer")
local type Store = require("tecs.data.store")

--- An owned value that releases its active lifetime explicitly.
---
--- `close` may be called through this structural interface when the caller
--- does not need a more specific result. Implementations may return additional
--- status values, and their own contracts define whether repeated calls are
--- safe.
local interface Closeable
    --- Releases the value's active lifetime.
    ---
    --- @param self The value to close.
    close: function(self: Closeable)
end

--- Public type definitions for Tecs.
local record types
    type Closeable = Closeable

    --- A plugin configures a world with systems, resources, observers, and
    --- initial entities.
    type Plugin = function(world: World)

    --- A system function runs once when its phase dispatches.
    type System = function(dt: number, world: World)

    --- Component factory option shapes, collated separately from the
    --- runtime implementation so factory code can live under
    --- `tecs.internal.*` without losing a stable typed surface.
    record components
        --- An ECS component.
        interface Component
            --- Read-only. The container type of the component, available on instances and containers.
            componentType: self

            --- Read-only. The name of the component.
            componentName: string

            --- Read-only. The auto-incrementing ID of the component container.
            componentId: integer

            --- Read-only. Relationship components only: the relationship container type (nil for non-relationships).
            --- For containers, this equals self. For instances, it points to the container.
            relationshipType: Component

            --- Read-only. Relationship instance wildcard container (nil for non-relationships and containers).
            --- For `Rel(target)` dense instances, this points back to `Rel`.
            wildcardContainer: Component

            --- Read-only. Relationship components only: The target entity ID (for relationship instances only).
            target: integer

            --- Read-only. True if this component is runtime-only and omitted from snapshots.
            transient: boolean

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
            --- @param ... Field values in declaration order. One left nil takes the
            ---     field's registered default, so trailing arguments may be omitted.
            --- @return A new instance, not a shared one, so two calls with the same
            ---     arguments answer two values.
            metamethod __call: function(self, ...: any): self
        end

        --- Scalar component container. Rows store scalar payloads directly.
        interface ScalarComponent<T> is Component
            --- Read-only. Which primitive the column holds. Fixed at registration and
            --- never widened afterwards.
            scalarKind: ScalarKind

            --- Read-only. The value a row takes when the component is added without one.
            --- Never nil: `newScalarComponent` fills an omitted `default` with
            --- the zero of `kind` (`0`, `false` or `""`).
            scalarDefault: T

            --- The primitives a scalar column may hold. Anything else, tables
            --- and cdata included, is a table or FFI component instead.
            enum ScalarKind
                --- Defaults to `0`.
                "number"
                --- Defaults to `false`.
                "boolean"
                --- Defaults to `""`, not nil.
                "string"
            end
        end

        --- A relationship component that links one or more entities together.
        interface Relationship is Component where self.relationshipType ~= nil
            --- Read-only. Component container property indicating that the relationship is exclusive (e.g., has-one).
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

            --- If true, this component is runtime-only and is never written
            --- to snapshots. Mutually exclusive with custom `serialize`.
            transient: boolean
        end

        --- Shared options for creating different components.
        interface ContainerComponentOptions<C is Component> is BasicComponentOptions<C>
            --- Caller-writable. The component container/type to use (required).
            container: C
        end

        --- Options for creating a new component.
        interface ComponentOptions<C is Component> is ContainerComponentOptions<C>
            --- Caller-writable. Ordered field names for positional construction and `.new(data)`.
            --- Example: `fields = {"x", "y"}` means `Component(1, 2)` maps to
            --- `{x = 1, y = 2}` and `Component.new({x = 1, y = 2})` unpacks by
            --- the same order. The generated constructor is `load`ed so LuaJIT
            --- sees literal field assignments.
            fields: {string}

            --- Caller-writable. Positional defaults, in the same order as `fields`. Use `nil` for
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

        --- Options for creating a tag component: a component with no fields,
        --- whose presence on an entity is the whole payload. Queries match a
        --- tag by archetype rather than by scanning a column, so a tag is the
        --- cheaper spelling of a flag that rarely changes. A flag that flips
        --- often moves the entity between archetypes on every flip and is
        --- better as a boolean field.
        interface TagComponentOptions is BasicComponentOptions<Component>
            --- Caller-writable. Optional container to use for the tag component.
            container: Component
        end

        --- Options for creating an FFI-backed component.
        interface FFIComponentOptions<C is Component> is ContainerComponentOptions<C>
            --- Caller-writable. FFI field definitions for the backing struct.
            fields: {{string, string}}

            --- Caller-writable. Positional defaults, in the same order as `fields`.
            defaults: {any}

            --- Caller-writable. Optional metatable to apply to FFI instances (for instance methods).
            metatable: {any: any}

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
        --- to attach methods or fields to -- typed exports are done by
        --- declaring the field type on the owning module record (e.g.
        --- `Health: types.components.ScalarComponent<number>`) and assigning the
        --- registration result to it.
        interface ScalarComponentOptions<T> is BasicComponentOptions<ScalarComponent<T>>
            --- Caller-writable. Required. One of `"number"`, `"boolean"` or `"string"`;
            --- anything else errors at registration rather than at first use.
            kind: string

            --- Caller-writable. Optional. Omitting it takes the zero of `kind` (`0`, `false`
            --- or `""`), so a scalar column never reads back nil.
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
        interface RelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, ComponentOptions<R>
        end

        --- FFI relationship component configuration.
        interface FFIRelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, FFIComponentOptions<R>
        end
    end

    -- User component lifecycle hooks are not part of the public component
    -- model. Use query observers for lifecycle reactions, `requires` for
    -- auto-add dependencies, and explicit domain APIs for invariants.

    --- An archetype is a collection of entities with the same components.
    ---
    --- The public surface is deliberately small: identity, entity row
    --- access, per-row component access, and dirty tracking. Layout,
    --- column storage, observer registration, and all transaction
    --- internals live on the concrete implementation in
    --- `tecs.internal.Archetype` and are not part of the
    --- supported API.
    interface Archetype
        --- Read-only. The unique identifier of the archetype in the ECS container.
        id: integer

        --- Read-only. Entity IDs that belong to this archetype. Length is
        --- `entities[0]`; rows are 1-based (`entities[1]` is the
        --- first entity).
        entities: DoubleArray

        --- Read-only. Components in this archetype, in the order they were passed
        --- at construction. Finalized at creation -- archetypes never
        --- add or remove components. Iterate with `#componentList` /
        --- `ipairs` to walk the archetype's signature.
        componentList: {components.Component}

        --- Read-only column access. Returns the row-indexed column for
        --- the given component type, or nil if the archetype doesn't
        --- carry it. Does NOT mark the component dirty.
        ---
        --- @return The archetype's live column, indexed from one and not a
        ---     copy, so it is valid only until something moves an entity in or
        ---     out of this archetype. Nil only when this archetype does not
        ---     carry the component at all. A sparse relationship answers with a
        ---     row-indexed proxy rather than a stored column, which reads the
        ---     same and is not writable. Writing through this leaves the column
        ---     clean, and on an FFI component that means the GPU never
        ---     re-syncs.
        get: function<T is components.Component>(self, component: T): {T}

        --- Mutable column access. Returns the row-indexed column AND
        --- marks the component dirty on this archetype. Use this at
        --- every site where you intend to write into the column.
        ---
        --- @return The same column `get` answers with, dirty-marked before it
        ---     is handed over. Marked whether or not anything is then written,
        ---     so calling this in a loop that might not write defeats every
        ---     dirty-gated consumer; take it on the first row that actually
        ---     changes instead.
        getMut: function<T is components.Component>(self, component: T): {T}

        --- Set a component value at a row and mark it dirty. Use for
        --- in-place updates that don't change the entity's archetype.
        ---
        --- @param row 1-based row position.
        --- @param value New component value (must carry a `componentType`).
        ---     Stored as given rather than copied field by field, so a table
        ---     component holds the caller's table afterwards.
        set: function<C is components.Component>(self, row: integer, value: C)

        --- Iterate all relationship instances of the given container
        --- for the entity at `row`.
        ---
        --- @param row 1-based row position.
        --- @param callback Called once per matching relationship instance, in no
        ---     defined order. Adding or removing relationships on this entity
        ---     from inside it is not safe.
        forEachRelationship: function<T is components.Relationship>(
            self, relationshipContainer: T, row: integer, callback: function(T)
        )

        --- Get the first relationship instance of the given container
        --- for the entity at `row`, or nil if none exists.
        ---
        --- @param row 1-based row position.
        --- @return The one instance for an exclusive relationship, and an
        ---     arbitrary one of several for a relationship that is not: "first"
        ---     is storage order rather than the order they were added. Nil when
        ---     the entity has none.
        getFirstRelationship: function<T is components.Relationship>(self, relationshipContainer: T, row: integer): T

        --- True if the given component's column on this archetype is
        --- currently marked dirty.
        ---
        --- @param component False for a component this archetype does not
        ---     carry, so a consumer may name one without testing membership.
        --- @return True for a value write to this column, and true for any
        ---     structural change to the archetype: a row moving in has every
        ---     column newly written at that row.
        isComponentDirty: function(self, component: components.Component): boolean

        --- True if any component on this archetype is currently dirty.
        --- Useful for bulk re-sync paths that don't track dirty
        --- granularity below the archetype level.
        anyComponentDirty: function(self): boolean

        --- Mark a single component dirty on this archetype. Idempotent.
        markComponentDirty: function(self, component: components.Component)

        --- Mark every component on this archetype dirty.
        ---
        --- Says that every column changed and says nothing about where, so a
        --- consumer that can resync single rows resyncs the whole archetype
        --- after it. Prefer `markComponentDirty` for a column you can name.
        markAllComponentsDirty: function(self)

        --- Iterate components currently marked dirty on this archetype.
        dirtyComponents: function(self): function(): components.Component

        --- Register an observer for lifecycle changes on this archetype.
        --- The observer remains attached for the archetype's lifetime.
        --- Registration applies only to this archetype; it does not discover
        --- other archetypes with the same components.
        --- See `ArchetypeEntityObserver`.
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
            self, archetype: Archetype, firstRow: integer, lastRow: integer, count: integer, sourceArchetype?: Archetype
        )

        --- Called once per contiguous range of entities removed from the archetype.
        ---
        --- @param archetype The archetype the range is being removed from.
        --- @param firstRow The 1-based row of the first removed entity.
        --- @param lastRow The 1-based row of the last removed entity (inclusive).
        --- @param count Number of entities in the range (lastRow - firstRow + 1).
        --- @param destArchetype The archetype the range is moving to (nil for despawns).
        onEntitiesRemoved: function(
            self, archetype: Archetype, firstRow: integer, lastRow: integer, count: integer, destArchetype?: Archetype
        )

        --- Called when an entity is swap-popped into a different row.
        --- Implementing `onEntitiesAdded` is not required.
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

    --- A reusable filter over the archetypes in a world.
    interface Query
        --- Whether a query drives simulation or presentation.
        enum Kind
            --- `Paused` is added to the query's exclude set, so pausing a
            --- state stops the systems that move, damage or think.
            "logic"
            --- Records the opposite intent and changes no mask: paused
            --- entities keep drawing. Identical in effect to omitting the
            --- field, and worth writing anyway so the intent is on the page.
            "render"
        end

        --- The options passed to `world:newQuery`.
        interface Descriptor
            --- Caller-writable. Names the query in logs, profiles, and debug
            --- tools.
            name: string

            --- Caller-writable. Selects simulation or presentation behavior.
            ---
            --- `"logic"` excludes `Paused` entities, so pausing a state stops
            --- the systems that move, damage, or think. `"render"` records the
            --- opposite intent: paused entities keep drawing. Omitting the
            --- field leaves the query unfiltered, which matches every query
            --- written before this option existed.
            type: Kind

            --- Caller-writable. Lists every component a matching archetype
            --- must contain.
            include: {components.Component}

            --- Caller-writable. Lists components of which a matching
            --- archetype must contain at least one.
            includeAny: {components.Component}

            --- Caller-writable. Lists every component a matching archetype
            --- must omit.
            exclude: {components.Component}

            --- Caller-writable. Receives each contiguous range of entities
            --- that enters the query.
            ---
            --- @param archetype The archetype that contains the range.
            --- @param firstRow The first row in the range.
            --- @param lastRow The last row in the range.
            --- @param count The number of rows in the range.
            onEntitiesAdded: function(archetype: Archetype, firstRow: integer, lastRow: integer, count: integer)

            --- Caller-writable. Receives each contiguous range of entities
            --- that leaves the query.
            ---
            --- @param archetype The archetype that contains the range.
            --- @param firstRow The first row in the range.
            --- @param lastRow The last row in the range.
            --- @param count The number of rows in the range.
            onEntitiesRemoved: function(archetype: Archetype, firstRow: integer, lastRow: integer, count: integer)

            --- Caller-writable. Set true to match only the archetypes that
            --- exist when the query is created.
            temp: boolean

            --- Caller-writable. Assigns an integer group to each archetype.
            --- Archetypes with the same group are iterated contiguously.
            --- Use with groups() and group(id) for efficient grouped iteration.
            ---
            --- @param archetype The archetype to classify.
            --- @return The group identifier.
            groupBy: function(archetype: Archetype): integer
        end

        --- An opt-in query iterator that can be closed before exhaustion.
        ---
        --- Create one with `query:newCursor()` when an archetype-level loop may
        --- `break` or return early. Call `close()` after leaving the loop.
        --- Natural exhaustion closes the cursor automatically, and repeated
        --- `close()` calls are safe.
        interface Cursor is Closeable
            --- The step function `cursor:iter()` returns. Yields the
            --- archetype, its live row count, and its entity id column; the
            --- entity column is the archetype's own, not a copy.
            type IterFn = function(Cursor, any): (Archetype, integer, {integer})

            --- The step function `cursor:groups()` returns. Yields group ids
            --- in ascending order.
            type GroupsIterFn = function(Cursor, any): integer

            --- The step function `cursor:group(id)` returns, with the same
            --- three values as `IterFn` narrowed to one group.
            type GroupIterFn = function(Cursor, any): (Archetype, integer, {integer})

            --- Iterate over every active archetype matched by the query.
            iter: function(self): (IterFn, Cursor, any)

            --- Iterate over active group IDs in sorted order.
            groups: function(self): (GroupsIterFn, Cursor, any)

            --- Iterate over active archetypes in one group.
            ---
            --- @param groupId The group to traverse.
            --- @return The cursor's grouped step function.
            --- @return This cursor.
            --- @return The iterator's initial control value.
            group: function(self, groupId: integer): (GroupIterFn, Cursor, any)

            --- Close this cursor's deferred scope.
            ---
            --- Safe to call before iteration, after natural exhaustion, or
            --- more than once. A closed cursor cannot be reused.
            close: function(self)
        end

        --- The step function `query:iter()` returns. Yields the archetype,
        --- its live row count, and its entity id column; the entity column is
        --- the archetype's own, not a copy, and is only valid until the world
        --- next commits.
        type IterFn = function(Query, any): (Archetype, integer, {integer})

        --- The step function `query:groups()` returns. Yields group ids in
        --- ascending order.
        type GroupsIterFn = function(Query, any): integer

        --- The step function `query:group(id)` returns, with the same three
        --- values as `IterFn` narrowed to one group.
        type GroupIterFn = function(Query, any): (Archetype, integer, {integer})

        --- Read-only. Returns the descriptor used to create the query.
        --- Exposed for inspection. Mutating it after query construction does
        --- not rebuild component masks, subscriptions, or grouping state.
        descriptor: Descriptor

        --- Explicit iterator protocol form.
        --- Returns (archetype, length, entities) for each matching archetype.
        --- Use `archetype:get(Component)` or `archetype:getMut(Component)`
        --- to retrieve component data.
        ---
        --- Usage: `for archetype, length, entities in query:iter() do ... end`
        ---
        --- @return The three values a generic `for` takes. Iteration opens a
        ---     deferred scope on the world and closes it when the loop runs out
        ---     of archetypes, so a `break` or an early `return` leaves the world
        ---     deferred and every later spawn silently queues. Use
        ---     `newCursor()` for a loop that may stop early. The `entities`
        ---     table and the columns are the archetype's own and are valid only
        ---     for that turn of the loop.
        iter: function(self): (IterFn, Query, any)

        --- Create an opt-in cursor for a traversal that may stop early.
        ---
        --- Cursors allocate a small traversal object. Keep using `iter()`,
        --- `groups()`, and `group(id)` for loops that run to exhaustion.
        --- When breaking or returning early, retain the cursor and call
        --- `cursor:close()` to close its deferred scope and drain staged
        --- mutations.
        ---
        --- @return A cursor the caller has to `close`, once, on every path out
        ---     of the loop including an early return. Closing it twice is
        ---     harmless; never closing it leaves the world deferred for good.
        newCursor: function(self): Cursor

        --- Iterate over active group IDs in sorted order.
        --- Only available when groupBy is specified.
        --- Usage: `for blendId in query:groups() do ... end`.
        groups: function(self): (GroupsIterFn, Query, any)

        --- Iterate over archetypes in a specific group.
        --- Only available when groupBy is specified.
        --- Usage: `for archetype, len, entities in query:group(id) do ... end`.
        --- Yields nothing if the group has no archetypes.
        ---
        --- @param groupId The group to traverse.
        --- @return The query's grouped step function.
        --- @return This query.
        --- @return The iterator's initial control value.
        group: function(self, groupId: integer): (GroupIterFn, Query, any)

        --- Returns the cached group identifier for an archetype.
        ---
        --- Only available when `groupBy` is specified. Returns nil when the
        --- archetype does not match this query.
        ---
        --- @param archetype The archetype to inspect.
        --- @return Its cached group identifier, or nil when it has none.
        getGroup: function(self, archetype: Archetype): integer

        --- Returns the total entity count for a group.
        ---
        --- @param groupId The group to count.
        --- @return Its entity count, or zero when the group does not exist.
        getGroupCount: function(self, groupId: integer): integer

        --- Total number of entities currently matched by this query.
        --- One pass over matching archetypes, not entities.
        count: function(self): integer
    end

    --- A phase in the game loop pipeline.
    interface Phase
        --- Read-only. The name of the phase.
        name: string

        --- Read-only. The public pipeline position for this phase.
        position: integer

        --- Read-only. Child phases of this phase.
        children: {Phase}
    end

    --- What a frame does when catching the fixed step up to wall time would
    --- take more steps than it is allowed.
    ---
    --- `drop` bounds the work one frame can be asked for: the steps that do
    --- not fit are abandoned and the simulated time they stood for is counted
    --- as lost. Wall time and simulated time resynchronize immediately, at the
    --- cost of a discontinuity anything integrating over the step can see.
    ---
    --- `accumulate` abandons nothing. The remainder stays in the accumulator
    --- and is worked off by the frames that follow, so the simulation is exact
    --- and a replay of the same steps is reproducible. On a machine that is
    --- genuinely too slow the accumulator grows without bound and every frame
    --- costs more than the last, which is the death spiral `drop` exists to
    --- stop, so this is the deliberate choice of a simulation that would
    --- rather stall than lie.
    enum FixedOverload
        --- Abandon the steps that did not fit and count the simulated time
        --- they stood for in `fixedTimeDropped`. The default.
        "drop"
        --- Keep the remainder in the accumulator and work it off later,
        --- abandoning nothing and reporting nothing dropped.
        "accumulate"
    end

    --- The pipeline that executes systems in phases.
    interface Pipeline
        --- Read-only. The number of systems in the pipeline.
        count: integer

        --- Read-only. The fixed timestep interval in seconds (e.g., 1/60 for 60Hz physics).
        fixedTimestep: number

        --- Read-only. Accumulated time not yet consumed by fixed updates.
        --- Use with fixedTimestep to compute interpolation alpha: accumulator / timestep.
        fixedAccumulator: number

        --- Read-only. Fixed steps run since the pipeline was made.
        fixedStepCount: integer

        --- Read-only. The most fixed steps one `update` will run before the overload
        --- policy decides what happens to the rest. Defaults to 10.
        fixedMaxSteps: integer

        --- Read-only. What happens to the time those steps would have consumed.
        --- Defaults to `"drop"`.
        fixedOverload: FixedOverload

        --- Read-only. Simulated seconds abandoned by the `"drop"` policy since the
        --- pipeline was made. Stays at zero under `"accumulate"`, which
        --- abandons nothing, and stays at zero on a machine that keeps up.
        ---
        --- Read it. A simulation, a replay or anything networked is wrong by
        --- exactly this much, and nothing else in the world says so.
        fixedTimeDropped: number

        --- Read-only. Fixed steps that were owed and never ran, on the same terms. Whole
        --- steps only: `fixedTimeDropped` is this many timesteps, because a
        --- drop leaves the sub-step remainder alone rather than resetting the
        --- interpolation alpha along with it.
        fixedStepsDropped: integer

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
        --- Caller-writable. Optional, and unique across the whole pipeline: registering a
        --- second system under a name already taken errors. Omitting it
        --- assigns a synthetic `_anonymousSystemN`, so `removeSystem` always
        --- has a handle, but the debugger, the MCP tools and profiles then
        --- show that instead of anything readable. Name every persistent
        --- system.
        name: string

        --- Caller-writable. Required, and must already be registered with the pipeline;
        --- `addSystem` errors on an unregistered phase rather than creating
        --- one.
        phase: Phase

        --- Caller-writable. Required. Receives `(dt, world)`, where `dt` is seconds and, in a
        --- fixed phase, is the fixed timestep rather than frame time.
        run: System

        --- Caller-writable. Names of systems this one must run before. A name that no system
        --- in the SAME phase carries is ignored silently: ordering is solved
        --- per phase, so a constraint naming a system in another phase does
        --- nothing. Mutual constraints across a group error as a cycle.
        before: {string}

        --- Caller-writable. Names of systems this one must run after, on the same terms as
        --- `before`. Systems with no constraint between them keep
        --- registration order.
        after: {string}

        --- Optional gate evaluated immediately before each dispatch, so a
        --- false answer skips this frame only and does not unregister
        --- anything. Receives the same `dt` the system would have, plus the
        --- system's name, which is what a self-removing predicate passes back
        --- to `removeSystem`.
        runIf: function(dt: number, world: World, systemName: string): boolean
    end

    --- A world owns entities, components, queries, systems, resources, events,
    --- snapshots, and the state stack.
    interface World
        --- The options passed to `tecs.ecs.newWorld`.
        interface Config
            --- Caller-writable. Sets the positive duration of one fixed step
            --- in seconds. Defaults to 1/60.
            timestep: number
            --- Caller-writable. Sets the positive number of fixed steps one
            --- update may run before the overload policy applies. Defaults
            --- to 10.
            fixedMaxSteps: integer
            --- Caller-writable. Selects what happens to catch-up steps that
            --- exceed `fixedMaxSteps`. Defaults to `"drop"`.
            fixedOverload: FixedOverload
            --- Caller-writable. Builds a custom system pipeline once during
            --- world construction. Most callers omit this field.
            ---
            --- @param timestep The configured fixed timestep.
            --- @param fixedMaxSteps The configured fixed-step limit.
            --- @param fixedOverload The configured overload policy.
            --- @return The pipeline this world will run.
            pipelineFactory: function(number, integer, FixedOverload): Pipeline
            --- Caller-writable. Sets the positive number of concurrent entity
            --- slots, up to 2^22 - 1. Defaults to 2^20.
            maxEntities: integer
        end

        --- One component the snapshot's archetypes refer to. Archetype
        --- frames name components by 1-based index into the component table
        --- rather than repeating the name per archetype.
        interface SnapshotComponentTableEntry
            --- Caller-writable. Names the registered component a load
            --- resolves this entry against.
            name: string

            --- Caller-writable. Carries the canonical FFI field-layout
            --- fingerprint, or nil for a non-FFI component.
            --- Binary output embeds it so a load can detect that the saved
            --- struct layout differs from the current one and route those
            --- rows through per-entity migration. nil for every non-FFI
            --- component, and absent entirely from `"table"` output, whose
            --- loads go through field-name-keyed `deserialize` and migrate
            --- without it.
            fingerprint: string | nil
        end

        --- The header of a snapshot, and what `loadSnapshot` answers with.
        interface SnapshotPrelude
            --- Read-only. Reports the snapshot format version, not the game
            --- version.
            version: integer

            --- Read-only. Reports where entity slot allocation resumes. A load moves the
            --- allocator forward to this when it is ahead of where the
            --- allocator already is, and never backwards, so ids handed out
            --- after a load cannot collide with restored ones.
            nextEntityId: integer

            --- Read-only. Reports the entity count when the writer knew it,
            --- or nil for a streaming writer.
            entityCount: integer

            --- Read-only. Reports the archetype count when the writer knew
            --- it, or nil for a streaming writer.
            archetypeCount: integer

            --- Read-only. Lists every referenced component in archetype index
            --- order.
            componentTable: {SnapshotComponentTableEntry}
        end

        --- One archetype's worth of entities in a `"table"` snapshot.
        interface SnapshotArchetypeEntry
            --- Caller-writable. Lists 1-based indices into
            --- `Snapshot.componentTable`, in the same
            --- order the per-entity payloads appear.
            columnIndices: {integer}

            --- Caller-writable. Holds one entry per entity, shaped
            --- `{id, data1, ..., dataN}`, where
            --- `dataI` is whatever the component at `columnIndices[i]`
            --- returned from `serialize`.
            entities: {{any}}
        end

        --- One keyed value in a snapshot's data section.
        interface SnapshotDataEntry
            --- Caller-writable. Names the key a `SnapshotHandler` or
            --- `customData` entry wrote under.
            --- Keys beginning `__tecs.` are the engine's own.
            key: string

            --- Caller-writable. Holds the value written under `key`. It must
            --- survive the chosen format: a
            --- `"binary"` snapshot can carry anything the serializer accepts,
            --- a `"table"` one anything a plain Lua table can hold.
            value: any
        end

        --- A whole snapshot in plain-table form, which is what
        --- `saveSnapshot` returns under `format = "table"`.
        interface Snapshot
            --- Caller-writable. Sets the snapshot format version.
            version: integer

            --- Caller-writable. Sets the slot where entity allocation
            --- resumes.
            nextEntityId: integer

            --- Caller-writable. Lists the components referenced by the
            --- archetype entries;
            --- `SnapshotArchetypeEntry.columnIndices` points into it.
            componentTable: {SnapshotComponentTableEntry}

            --- Caller-writable. Lists archetypes in save order.
            archetypes: {SnapshotArchetypeEntry}

            --- Caller-writable. Lists keyed values after every archetype, in
            --- the order they
            --- were added, from `opts.customData` and from `OnSnapshotSave`
            --- listeners.
            data: {SnapshotDataEntry}
        end

        --- Which of the two representations `saveSnapshot` produces.
        enum SnapshotFormat
            --- A LuaJIT `string.buffer`. The default, and the only format
            --- `opts.path` and FFI-layout migration apply to.
            "binary"
            --- A plain Lua table, which JSON and hand inspection can reach
            --- and which carries no FFI fingerprints.
            "table"
        end

        --- Options passed to `saveSnapshot`. All fields are optional.
        interface SnapshotOptions
            --- Caller-writable. Selects `"binary"` for a LuaJIT
            --- `string.buffer` or `"table"` for a plain table.
            format: SnapshotFormat
            --- Caller-writable. Supplies a `string.buffer` to reset and reuse
            --- for binary output.
            --- It is reset before anything is written, so whatever it held is
            --- gone. Binary output only: passing one with `format = "table"`
            --- errors rather than being ignored.
            buffer: StringBuffer
            --- Caller-writable. Supplies an optional path for binary output.
            --- When provided, `saveSnapshot` writes the
            --- bytes to disk and still returns the tagged buffer result.
            --- Binary output only: passing one with `format = "table"` errors
            --- rather than being ignored.
            path: string
            --- Caller-writable. Selects saved archetypes through a temporary
            --- query.
            filterQuery: Query.Descriptor
            --- Caller-writable. Allows only the listed `Transform.layer`
            --- values from 0 through 31.
            layers: {integer}
            --- Caller-writable. Adds keyed metadata to the snapshot.
            customData: {string: any}
        end

        --- What `saveSnapshot` answers with. Exactly one of `buffer` and
        --- `snapshot` is set, and `format` says which; the other is nil.
        --- `loadSnapshot` accepts this record whole, so a round trip needs no
        --- unpacking.
        interface SnapshotOutput
            --- Read-only. Reports which representation carries the snapshot.
            format: SnapshotFormat

            --- Read-only. Returns the bytes under `format = "binary"`, or nil
            --- for table output. This is `opts.buffer`
            --- itself when one was passed, so a caller that reuses a buffer
            --- gets the same object back and must read it before the next
            --- save overwrites it.
            buffer: StringBuffer | nil

            --- Read-only. Returns the snapshot under `format = "table"`, or
            --- nil for binary output. The table is freshly built
            --- and the caller's to keep.
            snapshot: Snapshot | nil
        end

        --- Named snapshot participant for custom non-component data.
        ---
        --- `save` writes one keyed value into the snapshot data section when it
        --- returns non-nil. `load` receives that value after the ECS world has
        --- been restored. `finish` runs after every data callback has completed.
        interface SnapshotHandler
            --- Caller-writable. Sets the non-empty key used to store the
            --- value
            --- or registration errors. Namespace it with dots
            --- (`"myGame.gameState"`); keys beginning `__tecs.` are the
            --- engine's own.
            name: string

            --- Caller-writable. Optionally returns data to save. Returning
            --- nil writes no entry, which is how
            --- a handler declines rather than storing an empty value.
            ---
            --- @param world The world being saved.
            --- @return The value to store, or nil to omit this handler.
            save: function(world: World): any | nil

            --- Caller-writable. Optionally receives saved data. Tecs calls
            --- it only when the snapshot carries
            --- this handler's key, so a snapshot saved before the handler
            --- existed simply does not call it.
            load: function(world: World, value: any) | nil

            --- Caller-writable. Optionally runs after every data callback has
            --- completed, which is the place for work that depends on more
            --- than one handler's value.
            finish: function(world: World, prelude: SnapshotPrelude) | nil
        end

        --- Caller-writable. Stores world resources under typed keys.
        resources: Store

        --- Open a defer scope. Mutations within the scope are staged and
        --- drained on the matching `commit`. Pairs with `commit`.
        defer: function(self)

        --- Close one scope level and drain pending changes when the
        --- outermost scope finishes.
        commit: function(self)

        --- Close every open scope and apply what they staged.
        ---
        --- The recovery path after something threw part way through a frame.
        --- A throw inside `query:iter()` skips the pop that ends the loop's
        --- scope, and a world left deferred stages every later mutation rather
        --- than applying it, silently. This is what puts it back, and it is
        --- safe on a healthy world: at depth zero it is the drain `commit`
        --- already does.
        unwind: function(self)

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

        --- Return fixed-step timing for interpolation consumers.
        ---
        --- The return values are the fixed timestep, the residual time not
        --- consumed by fixed updates, and the residual divided by the
        --- timestep clamped to `[0, 1]`. This method does not allocate.
        ---
        --- The fixed-step clock advances even when fixed phases are disabled.
        ---
        --- @return timestep Fixed update interval in seconds.
        --- @return accumulator Residual time in seconds.
        --- @return alpha Clamped interpolation fraction.
        getFixedTiming: function(self): number, number, number

        --- Fixed steps run since the world was made.
        ---
        --- The clock for anything that advances on the simulation rather than
        --- on frame time. It counts steps rather than summing seconds, so two
        --- runs fed the same steps read the same number however many frames
        --- either of them drew, and the value stays a whole number.
        ---
        --- Counted whether or not any system is registered in a fixed phase.
        ---
        --- @return Steps run, from zero.
        fixedStepCount: function(self): integer

        --- Run the startup systems.
        startup: function(self)

        --- Run the shutdown systems.
        shutdown: function(self)

        --- Run every system registered to `phase` (and its enabled
        --- descendants) with the given `dt`. Unlike `update`, this does
        --- NOT pre-commit or clear dirty bits
        --- -- it only dispatches systems. Useful for piecewise phase
        --- execution (e.g. custom game loops splitting Update and
        --- Render across distinct ticks).
        ---
        --- @param phase The phase to run.
        --- @param dt The elapsed seconds passed to its systems, or zero when omitted.
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
        --- Resolves the target archetype once at call time and defers the
        --- actual row placement and `callback` invocation until the next
        --- commit.
        ---
        --- Returns `(firstId, nil)` when it can allocate a contiguous ID
        --- range. In that case IDs are `firstId`, `firstId + 1`, ...,
        --- `firstId + count - 1`.
        ---
        --- Returns `(nil, ids)` when it falls back to recycled,
        --- non-contiguous IDs. In that case iterate the returned `ids`
        --- list explicitly.
        ---
        --- Returned IDs are valid immediately -- you can call
        --- `world:set`, `world:remove`, or `world:despawn` on them before
        --- commit and the mutations are ordered correctly.
        ---
        --- At commit time the target archetype's row range is claimed,
        --- then `callback(archetype, firstRow, lastRow, count)` runs so you can
        --- write per-entity data via mutable column access
        --- (`archetype:getMut(Component)[row] = ...`).
        ---
        --- Relationship components (dense or sparse) are supported in
        --- the signature as either the bare container (e.g. `ChildOf`)
        --- or as a specific-target instance (e.g. `ChildOf(parent)`).
        --- When an instance is passed, its wildcard container is added
        --- to the archetype automatically -- no follow-up `world:set`
        --- is needed for queries on the bare container to match.
        ---
        --- Sparse relationship columns are row-indexed proxies that
        --- error on direct writes from the `callback`. For per-entity
        --- *varying* target values, call `world:set(spawnedId,
        --- SparseRel(target))` either inside the callback or any time
        --- before commit. Use `firstId + i` only when the return was
        --- contiguous; otherwise use the explicit `ids` list. The staged
        --- sparse sets drain alongside the batchSpawn placement.
        ---
        --- @param count Number of entities to spawn.
        --- @param componentTypes Array of component types defining the archetype.
        --- @param callback Called at commit with `(archetype, firstRow, lastRow, count)`.
        ---   Iterate rows with `for i = firstRow, lastRow do ... end`.
        --- @return firstId First entity ID when the allocation is contiguous, otherwise nil.
        --- @return ids Explicit entity ID list when fallback uses non-contiguous IDs, otherwise nil.
        batchSpawn: function(
            self,
            count: integer,
            componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer)
        ): integer | nil, {integer} | nil

        --- Like `batchSpawn`, but uses the supplied entity IDs instead of
        --- allocating a new contiguous range. Intended for snapshot loads
        --- where each restored entity keeps its original ID. The archetype
        --- resolution, capacity check, and required-component expansion happen
        --- once per call regardless of ID ordering.
        ---
        --- @param ids Explicit entity IDs to spawn, in order.
        --- @param componentTypes Array of component types defining the archetype.
        --- @param callback Called at commit with `(archetype, firstRow, lastRow, count)`.
        batchSpawnAt: function(
            self,
            ids: {integer},
            componentTypes: {components.Component},
            callback: function(Archetype, integer, integer, integer)
        )

        --- Despawn an entity.
        ---
        --- @param entity The entity to despawn.
        despawn: function(self, entity: integer)

        --- Bulk-despawn every entity matching `query`. The actual
        --- teardown is deferred until the next commit.
        ---
        --- `query` must be a `Query` object built via `world:newQuery(...)`
        --- and reused across calls -- batch ops do not accept
        --- QueryDescriptors or raw component-type arrays. Build the
        --- query once outside your hot loop.
        ---
        --- At commit time, events and relationship bookkeeping run as expected:
        ---   * `OnDespawn` events fire for each despawned entity
        ---     (global observers and per-entity observers).
        ---   * Per-entity observer subscriptions are cleared after the
        ---     event fans out.
        ---   * Query observers receive a single `onEntitiesRemoved` for
        ---     the full range, followed by `onDeactivated` when the
        ---     archetype empties.
        ---   * Archetypes with dense relationships or entities that are
        ---     reverse-index targets fall back to per-entity despawn so
        ---     cascade-delete and reverse-index unlink run correctly.
        ---
        --- @param query Query built via `world:newQuery(...)`.
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
        --- Fast path runs when the **target component** is "plain": it has
        --- no bulk-incompatible behavior flag, is not a dense relationship
        --- instance (no wildcard container), and is not sparse. Fast path
        --- does one move plan per (src, dst) archetype, bulk column copy,
        --- and whole-archetype truncate. Relationship-bearing or otherwise
        --- non-bulk components fall back to per-entity `world:set` for
        --- correctness (const form only; see below).
        ---
        --- Callback form additionally requires the target component to be
        --- plain because the callback is the value-write step. Non-bulk
        --- components must use the constant-value form.
        ---
        --- Sparse relationships always route through the per-entity
        --- path since they live in per-world stores, not archetype
        --- columns.
        ---
        --- @param query Query built via `world:newQuery(...)`.
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
        --- bulk-incompatible behavior flag, no wildcard container, not
        --- sparse): one bulk move to `src:withoutComponent(type)` per
        --- matched archetype, no per-entity dispatch. Relationship-bearing
        --- or otherwise non-bulk components fall back to per-entity
        --- `world:remove` so reverse-index unlink and cascade delete run
        --- correctly. Other components in the source archetype do not
        --- affect path selection.
        ---
        --- @param query Query built via `world:newQuery(...)`.
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
        --- just call `tecs.ecs.newWorld()` -- same path, clearer intent.
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

        --- Return the live entity currently carrying `tecs.ecs.EntityKey(key)`,
        --- or nil if no live entity has that key.
        ---
        --- @param key The durable key to find.
        --- @return The live entity, or nil when the key has none.
        byKey: function(self, key: string): integer | nil

        --- Return the live entity currently carrying `tecs.ecs.EntityKey(key)`,
        --- or error if no live entity has that key.
        ---
        --- @param key The durable key to find.
        --- @return The live entity.
        requireKey: function(self, key: string): integer

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
        --- STAGING: an entity spawned earlier in the SAME frame is staged
        --- until the commit drain, so getMut on it returns nil. Spawn with
        --- final values via constructor args instead of spawn-then-mutate.
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
        --- @param component The component instance or scalar component type.
        --- @param value The scalar value, or nil to use the registered default.
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
        --- @param descriptor Read here and not retained, so editing it afterwards
        ---     does not change the query. Give it a `name` for anything that
        ---     outlives a call: the debugger and the profiles address queries by
        ---     name.
        --- @return A query that keeps itself current as archetypes appear, so it
        ---     is built once during plugin setup and reused. Building one inside
        ---     a system's `run` pays the match cost every frame.
        newQuery: function(self, descriptor: Query.Descriptor): Query

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
        --- (`function(srcId)`) keep working -- Lua silently drops extra args.
        ---
        --- @param entity The target entity ID.
        --- @param relationship The sparse relationship container.
        --- @param callback Receives (sourceId, context) for each source.
        --- @param context Optional context value forwarded to the callback.
        targets: function<T>(
            self, entity: integer, relationship: components.Relationship, callback: function(integer, T), context: T
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
        --- @param ... Constructor arguments when `eventOrType` is an event type.
        emit: function(self, address: integer, eventOrType: events.Event, ...: any)

        --- Observe an event at an address.
        --- Use 0 for world-level events, entity ID for entity events.
        ---
        --- @param address The address to observe (0 for world, entity ID for entity).
        --- @param event The event type to observe.
        --- @param callback The callback to call when the event is emitted.
        --- @param id Optional ID for the observer.
        observe: function<T is events.Event>(
            self, address: integer, event: T, callback: function(event: T), id?: string
        )

        --- Stop observing an event at an address.
        ---
        --- @param address The address to stop observing.
        --- @param event The event type to stop observing.
        --- @param observer The observer function or ID.
        stopObserving: function<T is events.Event>(self, address: integer, event: T, observer: function(T) | string)

        --- Check if there are observers for an event at an address.
        ---
        --- @param address The world address or entity identifier.
        --- @param event The event type to inspect.
        --- @return True when the address has an observer for this event type.
        hasObservers: function<T is events.Event>(self, address: integer, event: T): boolean

        --- Clear all observers for an address (used on entity despawn).
        ---
        --- @param address Every event type at this address is cleared, not one.
        ---     Address zero is the world's own, so clearing it removes every
        ---     broadcast observer the world has.
        clearObservers: function(self, address: integer)

        -------------------------------------------------------------------------------
        -- Stats methods
        -------------------------------------------------------------------------------

        --- Get stats about the World.
        ---
        --- @param fill Optional stats table to fill instead of allocating a new one.
        ---     Passing one every frame is how this is read without adding a table
        ---     per frame to the collector.
        --- @return The same table `fill` named when one was given, so the caller
        ---     already holds it. A fresh one otherwise, and either way a copy
        ---     rather than a view: the numbers do not update on their own.
        getStats: function(self, fill?: World.Stats): World.Stats

        -------------------------------------------------------------------------------
        -- Snapshot methods
        -------------------------------------------------------------------------------

        --- Save the world to either binary or table form.
        ---
        --- Binary is the default. Set `opts.format = "table"` for a
        --- plain Lua snapshot table. `opts.path` is supported only for
        --- binary output.
        ---
        --- @param opts May be nil, which writes binary and returns it rather
        ---     than writing a file. Components registered `transient` are left
        ---     out whatever this says, so a snapshot never carries a live
        ---     handle.
        --- @return The snapshot, in whichever form was asked for. Taken from the
        ---     world as it stands, so this is a point-in-time copy and later
        ---     changes do not reach it.
        saveSnapshot: function(self, opts?: SnapshotOptions): SnapshotOutput

        --- Restore the world from either binary or table form.
        ---
        --- `source` may be a Lua string, a LuaJIT `string.buffer`, or
        --- a snapshot table previously returned by `saveSnapshot` with
        --- `format = "table"` (or parsed from JSON).
        ---
        --- @param source One of the three forms above. Every entity already in
        ---     the world is despawned before the first one is restored, so this
        ---     replaces a world rather than merging into one.
        --- @return What the snapshot said about itself. The prelude is read
        ---     first but handed back last, so a caller that meant to reject an
        ---     unwanted version reads it after the world has already been
        ---     replaced.
        loadSnapshot: function(self, source: any): SnapshotPrelude

        --- Register named save/load callbacks for custom snapshot data.
        ---
        --- This is a convenience wrapper over `OnSnapshotSave`,
        --- `StartSnapshotLoad`, and `FinishSnapshotLoad`. Use the raw
        --- snapshot events when you need lower-level behavior such as
        --- excluding derived entities.
        ---
        --- @param handler Its `name` is an externally typed snapshot key and
        ---     must remain stable across builds.
        addSnapshotHandler: function(self, handler: SnapshotHandler)

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
        --- @return A fresh map of bundle name to bundle.
        getBundles: function(self): {string: Bundle}

        --- Get a registered bundle by name.
        ---
        --- @param name The bundle name.
        --- @return The bundle, or nil if not found.
        getBundle: function(self, name: string): Bundle | nil

        --- Counts and fixed-step loss reported by `world:getStats`.
        interface Stats
            --- Read-only. Reports the number of active entities.
            entities: integer

            --- Read-only. Reports the number of archetypes.
            archetypes: integer

            --- Read-only. Reports the number of registered components.
            components: integer

            --- Read-only. Reports the number of registered systems.
            systems: integer

            --- Read-only. Reports simulated seconds abandoned by the fixed
            --- step overload policy.
            fixedTimeDropped: number

            --- Read-only. Reports fixed steps abandoned by the overload
            --- policy.
            fixedStepsDropped: integer
        end
    end

    --- A registered bundle with metadata and spawn capability.
    interface Bundle
        --- Declarative bundle definition.
        interface Definition
            --- Caller-writable. Components that must be provided as positional args to spawn().
            required: {components.Component}
            --- Caller-writable. Components with defaults, keyed by component type.
            --- Value is either a factory function returning a component instance,
            --- or `true` to call the component's default constructor.
            with: {components.Component: boolean | function(): components.Component}
        end

        --- Read-only. The name of the bundle.
        name: string

        --- Read-only. Component names that must be provided when spawning.
        required: {string}

        --- Read-only. Component names with default factories.
        defaulted: {string}

        --- Spawn an entity using this bundle.
        --- @param ... Required component instances in declaration order.
        --- @return The entity ID.
        spawn: function(self, ...: components.Component): integer
    end

    --- 64-bit double array type used for entity IDs. Uses double so the
    --- 53-bit packed (slot, gen, flag) id survives read/write without
    --- truncation. Opaque shape -- callers treat it like a 1-based
    --- integer array with length at `[0]`.
    interface DoubleArray is {integer}
        --- Reads the count out of slot 0 rather than probing for a border, so
        --- `#array` is exact even though slot 0 is occupied and would
        --- otherwise make the array look empty to Lua's own length operator.
        --- A macro, so it costs one load at the call site.
        metamethod __len: function(self) = macroexp(self: DoubleArray)
            return self[0]
        end
    end

    --- Event-specific helper types.
    record events
        --- An event that can be emitted.
        interface Event
            --- Read-only. The unique ID of the event.
            eventId: integer

            --- Positional initializer used by `newEvent` / `newFFIEvent`.
            --- @local
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
            ---
            --- @param self The message bus that owns the subscription.
            --- @param address Use 0 for world-level events or an entity ID for
            ---     entity events.
            --- @param eventType The registered event type to observe.
            --- @param observer Called synchronously with each matching event.
            --- @param id An optional stable name accepted by `stopObserving`.
            observe: function<E is Event>(
                self: MessageBus, address: integer, eventType: E, observer: function(event: E), id?: string
            )

            --- Observe an event type at a specific address, at most once.
            observeOnce: function<E is Event>(self: MessageBus, address: integer, eventType: E, observer: function(E))

            --- Stop observing an event type at a specific address.
            stopObserving: function<E is Event>(
                self: MessageBus, address: integer, eventType: E, observerOrId: function(E) | string
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
            --- Caller-writable. Built-in action: "pause", "resume", "despawn", "disable"
            apply: string
            --- Custom function called with the world
            call: function(World)
        end

        --- Caller-writable. Fires when this state is no longer top (another state pushed on top).
        onBlur: string | Action | function(World)
        --- Caller-writable. Fires when this state becomes top again (state above popped).
        onFocus: string | Action | function(World)
        --- Fires when this state is first pushed. Only accepts a plugin function.
        onEnter: function(World)
        --- Caller-writable. Fires when this state is popped (default: "despawn").
        onExit: string | Action | function(World)
    end
end

return types
