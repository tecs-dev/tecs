--[[
    DB.tl - New ECS database implementation using Transaction-based deferred mutations

    Replaces the old EcsContainer with a cleaner implementation that stages
    all mutations in a Transaction and commits them in bulk for performance.
]]

local types <const> = require("tecs.types")
local dbtypes <const> = require("tecs.internal.db.types")
local EntityIndex <const> = require("tecs.internal.db.EntityIndex")
local ArchetypeIndex <const> = require("tecs.internal.db.ArchetypeIndex")
local RelationshipTracker <const> = require("tecs.internal.db.RelationshipTracker")
local logging <const> = require("tecs.internal.utils.logging")
local WeakArray <const> = require("tecs.internal.utils.WeakArray")

local type Component = types.Component
local type Archetype = types.Archetype
local type ArchetypeChangeObserver = types.ArchetypeChangeObserver
local type Transaction = require("tecs.internal.db.Transaction")

local LOGGER <const> = logging.getLogger("tecs.DB")

local record DB is dbtypes.DB
    -- Core data structures
    entityIndex: EntityIndex
    archetypeIndex: ArchetypeIndex
    relationshipTracker: RelationshipTracker

    -- Entity ID allocation
    nextEntityId: integer
    freeIds: {integer}

    -- Transaction for deferred mutations
    transaction: Transaction

    -- Change observers (weak references to allow query GC)
    changeObservers: WeakArray<ArchetypeChangeObserver>

    -- Frame tracking
    frameCount: integer
    inFrame: boolean
    frozen: boolean  -- Track if DB is frozen during system execution

    -- Stats tracking
    entityCount: integer
    componentCount: integer
end

local DB_MT <const>: metatable<DB> = { __index = DB }

function DB.new(): DB
    local entityIndex = EntityIndex.new()
    local archetypeIndex = ArchetypeIndex.new()
    local relationshipTracker = RelationshipTracker.new()

    local self: DB = {
        entityIndex = entityIndex,
        archetypeIndex = archetypeIndex,
        relationshipTracker = relationshipTracker,
        nextEntityId = 1,
        freeIds = {},
        transaction = Transaction.new(
            entityIndex,
            archetypeIndex,
            relationshipTracker,
            1  -- Starting entity ID
        ),
        changeObservers = WeakArray.new(),
        frameCount = 0,
        inFrame = false,
        frozen = false,
        entityCount = 0,
        componentCount = 0
    }

    return setmetatable(self, DB_MT)
end

-- Begin a new frame
function DB:beginFrame(dt: number)
    if self.inFrame then
        LOGGER:warn("beginFrame called while already in frame")
        return
    end

    self.inFrame = true
    self.frameCount = self.frameCount + 1

    -- Reset transaction for the new frame
    self.transaction:reset(self.nextEntityId)

    -- Update transaction with current change observers
    self.transaction:setChangeObservers(self.changeObservers)

    LOGGER:debug("Frame %d started, dt=%.3f", self.frameCount, dt)
end

-- End the current frame
function DB:endFrame()
    if not self.inFrame then
        LOGGER:warn("endFrame called while not in frame")
        return
    end

    -- Final commit if there are any uncommitted changes
    -- This handles any mutations outside of systems
    if self.transaction:hasChanges() then
        self:commitTransaction()
    end

    self.inFrame = false
    LOGGER:debug("Frame %d ended", self.frameCount)
end

-- Tick update (called by pipeline)
function DB:tick(dt: number)
    -- For compatibility, can be called outside of beginFrame/endFrame
    if not self.inFrame then
        self:beginFrame(dt)
        self:endFrame()
    end
end

-- Spawn a new entity with components
function DB:spawn(...: Component): integer
    local components = {...}

    -- If not in a frame, auto-begin one
    if not self.inFrame then
        self:beginFrame(0)
    end

    -- Allocate entity ID (reuse free IDs or allocate new)
    local id: integer
    if #self.freeIds > 0 then
        id = self.freeIds[#self.freeIds]
        self.freeIds[#self.freeIds] = nil
    else
        id = self.nextEntityId
        self.nextEntityId = self.nextEntityId + 1
    end

    -- Stage spawn in transaction
    self.transaction:spawn(id)

    -- Add initial components
    for i = 1, #components do
        local comp = components[i]
        local componentType: Component

        -- Try to get componentType from the instance (works for both FFI and table components)
        local compAny = comp as {string:any}
        componentType = compAny.componentType as Component

        if not componentType then
            -- Fallback: check metatable
            local mt = getmetatable(comp)
            if mt and type(mt) == "table" then
                local mtTable = mt as metatable<Component>
                if mtTable.__index then
                    componentType = mtTable.__index as Component
                end
            end
        end

        if not componentType then
            error("Each component passed to spawn must have a componentType. Missing at component " .. i)
        end

        self.transaction:addComponent(id, componentType, comp)
    end

    return id
end

function DB:despawn(id: integer)
    -- If not in a frame, auto-begin one
    if not self.inFrame then
        self:beginFrame(0)
    end

    self.transaction:despawn(id)
    self.freeIds[#self.freeIds + 1] = id
end

function DB:hasComponent(id: integer, component: Component): boolean
    -- Check live data only (transactions handle staged changes at commit)
    local archetypeId, _ = self.entityIndex:get(id)
    if not archetypeId then
        return false
    end

    local archetype = self.archetypeIndex[archetypeId]
    return archetype and archetype.columns[component] ~= nil
end

function DB:getComponent<C is Component>(id: integer, component: C): C
    -- First check pending changes in transaction
    local pendingComponent = self.transaction:getPendingComponent(id, component)
    if pendingComponent ~= nil then
        return pendingComponent
    end

    -- Then check committed data
    local archetypeId, row = self.entityIndex:get(id)
    if not archetypeId then
        return nil as C
    end

    local archetype = self.archetypeIndex[archetypeId]
    if not archetype then
        return nil as C
    end

    local column = archetype.columns[component]
    if not column then
        return nil as C
    end

    return column[row + 1] as C  -- +1 for Lua indexing
end

function DB:addComponent(id: integer, component: Component)
    -- If not in a frame, auto-begin one
    if not self.inFrame then
        self:beginFrame(0)
    end
    -- Extract component type from instance
    local componentAny = component as {string: any}
    local componentType = componentAny["componentType"] as Component or component
    self.transaction:addComponent(id, componentType, component)
end

function DB:removeComponent(id: integer, component: Component)
    -- If not in a frame, auto-begin one
    if not self.inFrame then
        self:beginFrame(0)
    end
    self.transaction:removeComponent(id, component)
end

function DB:getArchetype(components: {Component}): Archetype
    return self.archetypeIndex:getOrCreate(components)
end

function DB:findArchetypes(include: {Component}, exclude: {Component}): {Archetype}
    return self.archetypeIndex:findMatching(include, exclude)
end

function DB:addChangeObserver(observer: ArchetypeChangeObserver)
    self.changeObservers[#self.changeObservers + 1] = observer
end

function DB:commitTransaction()
    if not self.transaction:hasChanges() then
        return
    end

    -- Commit all staged changes
    self.transaction:commit()

    -- Notify change observers about new archetypes
    local newArchetypes = self.transaction:getNewArchetypes()

    if newArchetypes and #newArchetypes > 0 then
        for i = 1, #self.changeObservers do
            local observer = self.changeObservers[i]
            if observer then  -- Skip GC'd weak references
                for j = 1, #newArchetypes do
                    local archetype = newArchetypes[j]
                    if observer.onNewArchetype then
                        LOGGER:debug("Calling onNewArchetype for archetype %d", archetype.id)
                        observer:onNewArchetype(archetype)
                    end
                end
            end
        end
    end

    self.transaction:clearStagingData()
    LOGGER:debug("Transaction committed")
end

function DB:commit(_transaction?: dbtypes.Transaction)
    self:commitTransaction()
end

function DB:setWorld(world: types.World)
    self.transaction:setWorld(world)
end

function DB:setFrozen(frozen: boolean)
    self.frozen = frozen
end

function DB:getStats(): integer, integer, integer
    -- Count actual entities across all archetypes
    local actualEntityCount = 0
    local componentTypes: {Component: boolean} = {}

    for i = 1, #self.archetypeIndex do
        local archetype = self.archetypeIndex[i]
        actualEntityCount = actualEntityCount + archetype.entities[0]
        for component in pairs(archetype.columns) do
            componentTypes[component] = true
        end
    end

    local componentCount = 0
    for _ in pairs(componentTypes) do
        componentCount = componentCount + 1
    end

    return actualEntityCount, #self.archetypeIndex, componentCount
end

return DB