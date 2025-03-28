--[[
    ChangeView.tl - Implementation of the ChangeView interface for component hooks

    Provides a view of pending changes for an entity during hook execution,
    allowing hooks to inspect and modify components in the same mutation batch.
]]

local types <const> = require("tecs.types")

local type Component = types.Component
local type EntityIndex = require("tecs.internal.db.EntityIndex")

-- Implementation of ChangeView interface
local record ChangeView is types.ChangeView
    entityId: integer
    transaction: any -- Transaction type, but we can't import it due to circular dependency
    entityIndex: EntityIndex

    -- Track components added/removed by this change view
    localAdds: {Component: any}
    localRemoves: {Component: boolean}

    -- Methods
    get: function<T is Component>(self: ChangeView, component: T): T
    set: function(self: ChangeView, component: Component)
    remove: function(self: ChangeView, component: Component)
    has: function(self: ChangeView, component: Component): boolean
end

local ChangeView_mt: metatable<ChangeView> = {
    __index = ChangeView
}

-- Create a new ChangeView for an entity
function ChangeView.new(entityId: integer, transaction: any, entityIndex: EntityIndex): ChangeView
    return setmetatable({
        entityId = entityId,
        transaction = transaction,
        entityIndex = entityIndex,
        localAdds = {},
        localRemoves = {}
    }, ChangeView_mt)
end

-- Get a component that exists or will exist after this change
function ChangeView:get<T is Component>(component: T): T
    -- Check if removed locally
    if self.localRemoves[component] then
        return nil
    end

    -- Check local additions first
    local localValue = self.localAdds[component]
    if localValue ~= nil then
        return localValue as T
    end

    -- Check if this is a spawned entity
    local trans = self.transaction as {string: any}
    local isSpawnFn = trans.isSpawn as function(any, integer): boolean
    if isSpawnFn and isSpawnFn(trans, self.entityId) then
        -- Check spawn values
        local spawnValues = trans.spawnValues as {integer: {Component: any}}
        local entityValues = spawnValues[self.entityId]
        if entityValues and entityValues[component] then
            return entityValues[component] as T
        end
        return nil
    end

    -- Check pending mutations in transaction
    local mutatedValues = trans.mutatedValues as {integer: {Component: any}}
    local entityMutations = mutatedValues[self.entityId]
    if entityMutations and entityMutations[component] ~= nil then
        return entityMutations[component] as T
    end

    -- Check pending removals
    local pendingRemove = trans.pendingRemove as {integer: {Component: boolean}}
    local entityRemovals = pendingRemove[self.entityId]
    if entityRemovals and entityRemovals[component] then
        return nil
    end

    -- Check existing components in the world
    local archetypeId, row = self.entityIndex:get(self.entityId)
    if archetypeId then
        local archetypeIndex = trans.archetypeIndex
        local archetype = (archetypeIndex as {integer: any})[archetypeId]
        if archetype then
            local archColumns = (archetype as {string: any}).columns as {Component: any}
            local column = archColumns and archColumns[component]
            if column then
                return (column as {T})[row + 1]
            end
        end
    end

    return nil
end

-- Add or update a component in this change batch
function ChangeView:set(component: Component)
    -- Remove from local removes if it was there
    self.localRemoves[component as Component] = nil

    -- Get the component type (the container, not the instance)
    local componentAny = component as {string: any}
    local componentType = componentAny["componentType"] as Component or component

    -- Store in local adds (use component type as key, instance as value)
    self.localAdds[componentType] = component

    -- Apply to transaction
    local trans = self.transaction as {string: any}

    -- Always use addComponent - it handles both new components and mutations
    local addFn = trans.addComponent as function(any, integer, Component, any)
    addFn(trans, self.entityId, componentType, component)
end

-- Remove a component in this change batch
function ChangeView:remove(component: Component)
    -- Can't remove from spawned entities
    local trans = self.transaction as {string: any}
    local isSpawnFn = trans.isSpawn as function(any, integer): boolean
    if isSpawnFn and isSpawnFn(trans, self.entityId) then
        -- Just ignore, as the entity is being built
        return
    end

    -- Remove from local adds if it was there
    self.localAdds[component] = nil

    -- Mark as locally removed
    self.localRemoves[component] = true

    -- Apply to transaction
    local removeFn = trans.removeComponent as function(any, integer, Component)
    removeFn(trans, self.entityId, component)
end

-- Check if a component exists or will exist
function ChangeView:has(component: Component): boolean
    -- Check if removed locally
    if self.localRemoves[component] then
        return false
    end

    -- Check local additions
    if self.localAdds[component] ~= nil then
        return true
    end

    -- Check if this is a spawned entity
    local trans = self.transaction as {string: any}
    local isSpawnFn = trans.isSpawn as function(any, integer): boolean
    if isSpawnFn and isSpawnFn(trans, self.entityId) then
        -- Check spawn components
        local spawnComponents = trans.spawnComponents as {integer: {Component}}
        local entityComponents = spawnComponents[self.entityId]
        if entityComponents then
            for _, comp in ipairs(entityComponents) do
                if comp == component then
                    return true
                end
            end
        end
        return false
    end

    -- Check pending additions in transaction
    local pendingAdd = trans.pendingAdd as {integer: {Component: boolean}}
    local entityAdds = pendingAdd[self.entityId]
    if entityAdds and entityAdds[component] then
        return true
    end

    -- Check pending removals
    local pendingRemove = trans.pendingRemove as {integer: {Component: boolean}}
    local entityRemovals = pendingRemove[self.entityId]
    if entityRemovals and entityRemovals[component] then
        return false
    end

    -- Check existing components in the world
    local archetypeId, _row = self.entityIndex:get(self.entityId)
    if archetypeId then
        local archetypeIndex = trans.archetypeIndex
        local archetype = (archetypeIndex as {integer: any})[archetypeId]
        local archColumns = archetype and (archetype as {string: any}).columns as {Component: any}
        if archColumns and archColumns[component] then
            return true
        end
    end

    return false
end

return ChangeView