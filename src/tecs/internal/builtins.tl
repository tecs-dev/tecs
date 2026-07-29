local components <const> = require("tecs.internal.components")
local events <const> = require("tecs.internal.events")
local internal <const> = require("tecs.internal.types")
local behavior <const> = require("tecs.internal.behavior")
local phases <const> = require("tecs.internal.phases")
local types <const> = require("tecs.types")
local table_clear <const> = require("table.clear")

local type Component = types.components.Component
local type Relationship = types.components.Relationship

local math_sin <const> = math.sin
local math_cos <const> = math.cos

--- Builtin components, relationships, and events for Tecs.
local record builtins

    --- Provides a name for an entity. Scalar component (kind `string`):
    --- the column stores the raw string and `world:get(id, Name)`
    --- returns a string directly.
    Name: types.components.ScalarComponent<string>

    --- Provides a durable, unique lookup key for an entity. Unlike `Name`,
    --- `Key` is intended for save/load, hot reload, tooling, and authored
    --- references. A world rejects duplicate live keys.
    Key: types.components.ScalarComponent<string>

    --- Provides the coordinates and transform of an entity.
    record Transform is Component
        --- The x coordinate of the entity.
        x: number

        --- The y coordinate of the entity.
        y: number

        --- The z coordinate of the entity.
        z: number

        --- The layer of the entity
        layer: integer

        --- The rotation in radians (defaults to 0).
        rotation: number

        --- The x scale (defaults to 1).
        scaleX: number

        --- The y scale (defaults to 1).
        scaleY: number

        --- Creates a new Transform component from positional args.
        --- For the table form, use `Transform.new({x=…, y=…})`.
        ---
        --- @param x The x position.
        --- @param y The y position.
        --- @param z The z position.
        --- @param layer The layer (defaults to 1)
        --- @param rotation The rotation in radians (defaults to 0).
        --- @param scaleX The x scale (defaults to 1).
        --- @param scaleY The y scale (defaults to 1).
        --- @return the created transform component.
        metamethod __call: function(
            self,
            x?: number,
            y?: number,
            z?: number,
            layer?: integer,
            rotation?: number,
            scaleX?: number,
            scaleY?: number
        ): Transform

        --- Table-form constructor. `data` is a partial `{x, y, z, layer, rotation, scaleX, scaleY}`.
        new: function(data: {string: any}): Transform
    end

    --- Despawns an entity when the TTL reaches zero.
    record TTL is Component
        --- The total amount of time the entity had to live.
        startingTime: number

        --- The remaining time the entity has to live.
        remaining: number

        --- Compute the percentage of completion as a number between 0 and 1.
        percentComplete: function(self): number

        --- Create a new TTL component.
        ---
        --- @param remaining The amount of time the entity has to live.
        --- @return the created TTL component.
        metamethod __call: function(self, remaining: number): TTL
    end

    --- An event emitted when a specific entity is spawned.
    record OnSpawn is types.events.Event
        entity: integer

        --- Create a new OnSpawn event.
        metamethod __call: function(self, entity: integer): OnSpawn
    end

    --- An event emitted when a specific entity is despawned.
    record OnDespawn is types.events.Event
        entity: integer

        --- Create a new OnDespawn event.
        metamethod __call: function(self, entity: integer): OnDespawn
    end

    --- An event emitted at entity 0 (world) when a new archetype is created.
    record ArchetypeCreated is types.events.Event
        archetype: types.Archetype

        --- Create a new ArchetypeCreated event.
        metamethod __call: function(self, archetype: types.Archetype): ArchetypeCreated
    end

    --- An event emitted when a state is pushed onto the stack.
    record StateEnter is types.events.Event
        --- The state name being entered.
        state: string
        metamethod __call: function(self, state: string): StateEnter
    end

    --- An event emitted when a state is popped from the stack.
    record StateExit is types.events.Event
        --- The state name being exited.
        state: string
        metamethod __call: function(self, state: string): StateExit
    end

    --- An event emitted when a state loses focus (another state pushed on top).
    record StateBlur is types.events.Event
        --- The state losing focus.
        state: string
        --- The state being pushed on top.
        pushed: string
        metamethod __call: function(self, state: string, pushed: string): StateBlur
    end

    --- An event emitted when a state regains focus (state above popped).
    record StateFocus is types.events.Event
        --- The state regaining focus.
        state: string
        --- The state that was popped.
        popped: string
        metamethod __call: function(self, state: string, popped: string): StateFocus
    end

    --- An event emitted on entity 0 at the start of `tecs.saveSnapshot`,
    --- BEFORE archetype data is written. Listeners can:
    ---   - Attach arbitrary keyed metadata via `ev:addData(key, value)`
    ---     (queued; flushed into the data section after archetypes).
    ---   - Mark plugin-derived entities for omission via
    ---     `ev:exclude(component)`. Entities carrying any excluded
    ---     component are skipped entirely; on load the plugin re-derives
    ---     them from durable source-of-truth entities that ARE saved.
    record OnSnapshotSave is types.events.Event
        --- Encode a (key, value) pair into the snapshot's data section.
        --- Keys MUST be strings; values must be `string.buffer`-encodable.
        --- Plugins typically use namespaced keys (e.g. `"tecs.physics"`,
        --- `"mygame.scoreboard"`) to avoid collisions.
        addData: function(self, key: string, value: any)
        --- Exclude every entity that carries `component` from the
        --- snapshot. Use this when a plugin owns derived state (e.g.
        --- TileChunk projection of a Tilemap, physics body backing a
        --- RigidBody marker) and can re-spawn those entities on load
        --- from a durable source component that IS saved.
        exclude: function(self, component: types.components.Component)
        metamethod __call: function(self): OnSnapshotSave
    end

    --- An event emitted on entity 0 at the start of `tecs.loadSnapshot`,
    --- AFTER the world has been fully restored and BEFORE the data
    --- section is dispatched. Listeners register per-key callbacks via
    --- `ev:onData(key, callback)`; each callback fires once per matching
    --- data entry written by `OnSnapshotSave`.
    record StartSnapshotLoad is types.events.Event
        --- Register a callback for a data entry keyed by `key`. The
        --- callback receives the decoded value. Multiple listeners may
        --- register the same key; all fire in registration order.
        onData: function(self, key: string, callback: function(value: any))
        metamethod __call: function(self): StartSnapshotLoad
    end

    --- An event emitted on entity 0 once `tecs.loadSnapshot` finishes --
    --- after all entities are restored AND every data callback has run.
    --- Useful for cleanup or "load is complete" callbacks.
    record FinishSnapshotLoad is types.events.Event
        --- The snapshot prelude (version, counts).
        prelude: any
        metamethod __call: function(self): FinishSnapshotLoad
    end

    --- Marks an entity as paused.
    ---
    --- Unlike Disabled, Paused is not auto-excluded from every query, because
    --- paused entities keep rendering. Queries declared `type = "logic"` skip
    --- them; `exclude = {Paused}` does the same explicitly.
    Paused: Component

    --- A built-in child relationship.
    ChildOf: Relationship

    --- Marks an entity as disabled, causing it to be excluded from queries by default.
    Disabled: Component

    --- A component that defines an entity's transform relative to its parent (ChildOf).
    ---
    --- The relative transform system computes the world-space Transform by composing
    --- the parent's Transform with this RelativeTransform's offset data.
    ---
    --- Note: Requires ChildOf to be present. The parent is determined by ChildOf.target.
    record RelativeTransform is Component
        --- The x offset from the parent.
        x: number

        --- The y offset from the parent.
        y: number

        --- The z offset from the parent.
        z: number

        --- The rotation offset in radians from the parent.
        rotation: number

        --- The x scale multiplier relative to the parent.
        scaleX: number

        --- The y scale multiplier relative to the parent.
        scaleY: number

        --- The origin X as a percentage (0-1) of the entity's width. 0 = left edge, 0.5 = center, 1 = right edge.
        --- Defaults to 0 (left edge).
        originX: number

        --- The origin Y as a percentage (0-1) of the entity's height. 0 = top edge, 0.5 = center, 1 = bottom edge.
        --- Defaults to 0 (top edge).
        originY: number

        --- Creates a new RelativeTransform component from positional args.
        --- For the table form, use `RelativeTransform.new({x=…, y=…})`.
        ---
        --- @param x The x offset from the parent.
        --- @param y The y offset (defaults to 0).
        --- @param z The z offset (defaults to 0).
        --- @param rotation The rotation offset in radians (defaults to 0).
        --- @param scaleX The x scale multiplier (defaults to 1).
        --- @param scaleY The y scale multiplier (defaults to 1).
        --- @param originX The origin X as a percentage (defaults to 0).
        --- @param originY The origin Y as a percentage (defaults to 0).
        --- @return the created RelativeTransform component.
        metamethod __call: function(
            self,
            x?: number,
            y?: number,
            z?: number,
            rotation?: number,
            scaleX?: number,
            scaleY?: number,
            originX?: number,
            originY?: number
        ): RelativeTransform

        --- Table-form constructor.
        new: function(data: {string: any}): RelativeTransform
    end

    --- The builtin plugin that registers TTL and RelativeTransform systems.
    plugin: function(w: types.World)
end

-------------------------------------------------------------------------------
--- Setup relationships
-------------------------------------------------------------------------------

builtins.ChildOf = components.newRelationship(
    {
        name = "ChildOf",
        exclusive = true,
        sparse = true,
        reverseIndex = true,
        cascadeDelete = true,
    }
)

-------------------------------------------------------------------------------
--- Setup events
-------------------------------------------------------------------------------

events.newFFIEvent(builtins.OnSpawn, {{"entity", "double"}}, "Tecs_OnSpawn")

events.newFFIEvent(builtins.OnDespawn, {{"entity", "double"}}, "Tecs_OnDespawn")

builtins.ArchetypeCreated.init = function(e: builtins.ArchetypeCreated, archetype: types.Archetype)
    e.archetype = archetype
end
events.newEvent(builtins.ArchetypeCreated)

-------------------------------------------------------------------------------
--- Setup state stack events
-------------------------------------------------------------------------------

builtins.StateEnter.init = function(e: builtins.StateEnter, state: string) e.state = state end
events.newEvent(builtins.StateEnter)

builtins.StateExit.init = function(e: builtins.StateExit, state: string) e.state = state end
events.newEvent(builtins.StateExit)

builtins.StateBlur.init = function(e: builtins.StateBlur, state: string, pushed: string)
    e.state = state
    e.pushed = pushed
end
events.newEvent(builtins.StateBlur)

builtins.StateFocus.init = function(e: builtins.StateFocus, state: string, popped: string)
    e.state = state
    e.popped = popped
end
events.newEvent(builtins.StateFocus)

-- Snapshot lifecycle events. OnSnapshotSave fires during save with
-- `addData` for plugins to attach metadata. StartSnapshotLoad fires at
-- the start of a load for listeners to register per-key data callbacks;
-- FinishSnapshotLoad fires after every callback has run.
builtins.OnSnapshotSave.init = function(_e: builtins.OnSnapshotSave) end
builtins.StartSnapshotLoad.init = function(_e: builtins.StartSnapshotLoad) end
builtins.FinishSnapshotLoad.init = function(_e: builtins.FinishSnapshotLoad) end
events.newEvent(builtins.OnSnapshotSave)
events.newEvent(builtins.StartSnapshotLoad)
events.newEvent(builtins.FinishSnapshotLoad)

-------------------------------------------------------------------------------
--- Setup components
-------------------------------------------------------------------------------

builtins.Name = components.newScalarComponent(
    {
        name = "Name",
        kind = "string",
    }
) as types.components.ScalarComponent<string>

builtins.Key = components.newScalarComponent(
    {
        name = "Key",
        kind = "string",
    }
) as types.components.ScalarComponent<string>

do
    local Key <const> = builtins.Key as Component
    local keyI = Key as {string: any}
    keyI.frameworkBehavior = behavior.Key
    keyI.frameworkBehaviorBits = behavior.keyBits()
end

components.newFFIComponent(
    {
        name = "Transform",
        container = builtins.Transform,
        fields = {
            {"x", "float"},
            {"y", "float"},
            {"z", "float"},
            {"layer", "int32_t"},
            {"rotation", "float"},
            {"scaleX", "float"},
            {"scaleY", "float"},
        },
        defaults = {0, 0, 0, 1, 0, 1, 1},
        init = function(instance: builtins.Transform)
            if instance.layer < 1 then
                error("Transform layer must be greater than 0, got: " .. tostring(instance.layer))
            end
        end,
    }
)

local function percentComplete(self: builtins.TTL): number
    return 1 - (self.remaining / self.startingTime)
end

components.newComponent(
    {
        name = "TTL",
        container = builtins.TTL,
        fields = {"remaining", "startingTime"},
        init = function(instance: builtins.TTL, remaining: number, startingTime?: number)
            assert(remaining > 0, "TTL must be greater than 0")
            if startingTime ~= nil then
                assert(startingTime > 0, "TTL startingTime must be greater than 0")
                assert(startingTime >= remaining, "TTL startingTime must be >= remaining")
            end
            instance.remaining = remaining
            instance.startingTime = startingTime or remaining
            instance.percentComplete = percentComplete
        end,
    }
)

builtins.Disabled = components.newTagComponent({name = "Disabled"})

builtins.Paused = components.newTagComponent({name = "Paused"})

components.newFFIComponent(
    {
        name = "RelativeTransform",
        container = builtins.RelativeTransform,
        fields = {
            {"x", "float"},
            {"y", "float"},
            {"z", "float"},
            {"rotation", "float"},
            {"scaleX", "float"},
            {"scaleY", "float"},
            {"originX", "float"},
            {"originY", "float"},
        },
        defaults = {0, 0, 0, 0, 1, 1, 0, 0},
        -- RelativeTransform auto-adds Transform via the declarative
        -- `requires` trait. ChildOf is required by convention (the
        -- composition system errors downstream if absent); users should
        -- add it explicitly alongside RelativeTransform.
        requires = {builtins.Transform},
    }
)

-------------------------------------------------------------------------------
--- Plugin implementation
-------------------------------------------------------------------------------

--- Composes a parent transform with a relative transform, mutating the output transform in place.
--- This is the simple version without origin awareness. For origin-aware positioning, use tecs.ui.
local function composeTransforms(
    parentTransform: builtins.Transform,
    relativeTransform: builtins.RelativeTransform,
    outputTransform: builtins.Transform
)
    local pRot, pScaleX, pScaleY = parentTransform.rotation, parentTransform.scaleX, parentTransform.scaleY

    -- Apply parent rotation and scale to relative position
    local cosRot = math_cos(pRot)
    local sinRot = math_sin(pRot)
    local scaledX = relativeTransform.x * pScaleX
    local scaledY = relativeTransform.y * pScaleY
    local rotatedX = scaledX * cosRot - scaledY * sinRot
    local rotatedY = scaledX * sinRot + scaledY * cosRot

    -- Mutate output transform in place
    outputTransform.x = parentTransform.x + rotatedX
    outputTransform.y = parentTransform.y + rotatedY
    outputTransform.z = parentTransform.z + relativeTransform.z
    outputTransform.layer = parentTransform.layer
    outputTransform.rotation = pRot + relativeTransform.rotation
    outputTransform.scaleX = pScaleX * relativeTransform.scaleX
    outputTransform.scaleY = pScaleY * relativeTransform.scaleY
end

function builtins.plugin(w: types.World)
    local TTL <const> = builtins.TTL
    local Transform <const> = builtins.Transform
    local RelativeTransform <const> = builtins.RelativeTransform
    local ChildOf <const> = builtins.ChildOf

    -- Handle despawning entities with TTLs.
    do
        local ttlQuery = w:query({include = {TTL}, type = "logic"})
        w:addSystem(
            {
                name = "ttl",
                phase = phases.FixedUpdate,
                run = function(dt: number)
                    for archetype, len, entities in ttlQuery:iter() do
                        local ttls = archetype:getMut(TTL)
                        for row = 1, len do
                            local ttl = ttls[row]
                            ttl.remaining = ttl.remaining - dt
                            if ttl.remaining <= 0 then
                                w:despawn(entities[row])
                            end
                        end
                    end
                end,
            }
        )
    end

    -- Relative transform system
    do
        -- Composition scratch: results land here first so the write to
        -- the child's column (and its dirty mark) only happens when the
        -- float32-rounded values actually changed. An idle hierarchy
        -- walk therefore marks nothing and the gate below converges.
        local scratchTransform = Transform(0, 0)

        -- Memoized world transform resolution via __index.
        -- On first access, recursively resolves the parent chain and caches the result.
        -- Subsequent accesses for the same entity are plain table lookups.
        local worldTransformCache: {integer: builtins.Transform} = {}
        setmetatable(
            worldTransformCache as {any: any},
            {
                __index = function(self: {integer: builtins.Transform}, entityId: integer): builtins.Transform
                    local transform = w:get(entityId, Transform)
                    if not transform then
                        return nil
                    end

                    local relTransform = w:get(entityId, RelativeTransform)
                    if not relTransform then
                        -- Root entity: world transform is its own transform
                        self[entityId] = transform
                        return transform
                    end

                    local childOf = w:getFirstRelationship(entityId, ChildOf)
                    if not childOf then
                        self[entityId] = transform
                        return transform
                    end

                    -- Recurse to resolve parent's world transform (triggers __index if not cached)
                    local parentWorldTransform = self[childOf.target]
                    if parentWorldTransform then
                        local scratch = scratchTransform
                        composeTransforms(parentWorldTransform, relTransform, scratch)
                        if
                            transform.x ~= scratch.x
                            or transform.y ~= scratch.y
                            or transform.z ~= scratch.z
                            or transform.layer ~= scratch.layer
                            or transform.rotation ~= scratch.rotation
                            or transform.scaleX ~= scratch.scaleX
                            or transform.scaleY ~= scratch.scaleY
                        then
                            transform.x = scratch.x
                            transform.y = scratch.y
                            transform.z = scratch.z
                            transform.layer = scratch.layer
                            transform.rotation = scratch.rotation
                            transform.scaleX = scratch.scaleX
                            transform.scaleY = scratch.scaleY
                            -- Downstream dirty-gated consumers (GPU shadow
                            -- uploads) must see the write; marking here also
                            -- covers ancestors resolved recursively from
                            -- another row's chain.
                            w:markComponentDirty(entityId, Transform)
                        end
                    end

                    self[entityId] = transform
                    return transform
                end,
            }
        )

        local hierarchyQuery = w:query(
            {
                name = "RelativeTransform",
                include = {RelativeTransform, ChildOf, Transform},
            }
        )

        local wImpl <const> = w as internal.WorldImpl
        local function hierarchyStateDirty(): boolean
            -- The set is walked directly rather than through
            -- `world:dirtyArchetypes`, which builds an iterator closure over
            -- its own upvalues per call. This runs twice a frame on every
            -- world, and `pairs` over the set costs nothing.
            for arch in pairs(wImpl._dirtyArchetypes) do
                local cols = arch.columns
                if cols[Transform] or cols[RelativeTransform] or cols[ChildOf] then
                    return true
                end
            end
            return false
        end

        -- Dirty bits clear at the end of each update, but this system
        -- runs in PostUpdate; direct writes made after it (render-phase
        -- systems, MCP run_lua) would be wiped before the gate sees
        -- them. Sample at frame end and carry the result into the next
        -- frame's gate.
        local pendingHierarchyDirty = false
        w:addSystem(
            {
                name = "RelativeTransformDirtySampler",
                phase = phases.RenderLast,
                run = function() pendingHierarchyDirty = hierarchyStateDirty() end,
            }
        )

        w:addSystem(
            {
                name = "RelativeTransform",
                phase = phases.PostUpdate,
                run = function()
                    -- Dirty-skip: recompute only when an archetype carrying
                    -- hierarchy state changed this frame or at the end of
                    -- the previous one. Sparse ChildOf retargets mark the
                    -- container column at commit, so they open this gate too.
                    if not pendingHierarchyDirty and not hierarchyStateDirty() then
                        return
                    end
                    pendingHierarchyDirty = false

                    table_clear(worldTransformCache)
                    for _archetype, len, entities in hierarchyQuery:iter() do
                        -- The resolver writes world transforms in place and
                        -- marks Transform dirty per changed entity.
                        for row = 1, len do
                            -- Access triggers __index, which recursively resolves the parent chain
                            local _ = worldTransformCache[entities[row]]
                        end
                    end
                end,
            }
        )
    end
end

return builtins
