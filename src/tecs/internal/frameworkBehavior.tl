-- Closed framework behavior dispatch for components that need internal mutation
-- semantics beyond plain archetype storage.
--
-- Component construction stamps internal behavior IDs and bit masks onto framework-owned
-- component families such as Key and relationships. World mutation paths use those bits to
-- decide whether set/remove/despawn must route here, and this module performs the small fixed
-- set of behaviors the framework owns. Relationship instances resolve behavior through their
-- wildcard container so every path treats `Rel` and `Rel(target)` consistently.

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local RelationshipStore <const> = require("tecs.internal.RelationshipStore")
local bit <const> = require("bit")

local type Component = types.components.Component
local type Archetype = internal.ArchetypeInternal
local type ComponentInternal = internal.ComponentInternal
local type WorldImpl = internal.WorldImpl

local band <const> = bit.band
local bor <const> = bit.bor

local Key <const> = 1
local SparseRelationship <const> = 2
local DenseRelationship <const> = 3

local NeedsSet <const> = 1
local NeedsRemove <const> = 2
local NeedsDespawn <const> = 4
local MustDeferSet <const> = 8
local MustDeferRemove <const> = 16
local NoBulkBatch <const> = 32

local record frameworkBehavior
    Key: integer
    SparseRelationship: integer
    DenseRelationship: integer

    NeedsSet: integer
    NeedsRemove: integer
    NeedsDespawn: integer
    MustDeferSet: integer
    MustDeferRemove: integer
    NoBulkBatch: integer

    behaviorOwner: function(component: Component): ComponentInternal
    hasBits: function(component: Component, bits: integer): boolean
    hasOwnerBits: function(owner: ComponentInternal, bits: integer): boolean

    keyBits: function(): integer
    sparseRelationshipBits: function(): integer
    denseExclusiveRelationshipBits: function(): integer
    denseReverseIndexRelationshipBits: function(): integer

    set: function(world: WorldImpl, id: integer, componentType: Component, value: any)
    remove: function(world: WorldImpl, id: integer, component: Component)
    despawn: function(world: WorldImpl, id: integer, component: Component, arch: Archetype, row: integer)
end

frameworkBehavior.Key = Key
frameworkBehavior.SparseRelationship = SparseRelationship
frameworkBehavior.DenseRelationship = DenseRelationship
frameworkBehavior.NeedsSet = NeedsSet
frameworkBehavior.NeedsRemove = NeedsRemove
frameworkBehavior.NeedsDespawn = NeedsDespawn
frameworkBehavior.MustDeferSet = MustDeferSet
frameworkBehavior.MustDeferRemove = MustDeferRemove
frameworkBehavior.NoBulkBatch = NoBulkBatch

-- Resolve the component that owns framework behavior metadata for a mutation.
-- Plain components and relationship containers own their behavior directly.
-- Dense relationship instances (`Rel(target)`) route through their
-- `wildcardContainer` (`Rel`), including when an instance is passed as either
-- the mutation component or the component's canonical `componentType`.
-- If no framework metadata exists, return the canonical component anyway so
-- callers can read zero/nil behavior bits without special-casing plain types.
function frameworkBehavior.behaviorOwner(component: Component): ComponentInternal
    local componentType = component.componentType as Component
    if componentType then
        local wildcard = componentType.wildcardContainer as ComponentInternal
        if wildcard then
            return wildcard
        end
        local cti = componentType as ComponentInternal
        if cti.frameworkBehavior ~= nil or cti.frameworkBehaviorBits ~= nil then
            return cti
        end
    end

    local wildcard = component.wildcardContainer as ComponentInternal
    if wildcard then
        return wildcard
    end

    return (componentType or component) as ComponentInternal
end

function frameworkBehavior.hasOwnerBits(owner: ComponentInternal, bits: integer): boolean
    return band(owner.frameworkBehaviorBits or 0, bits) ~= 0
end

function frameworkBehavior.hasBits(component: Component, bits: integer): boolean
    return frameworkBehavior.hasOwnerBits(frameworkBehavior.behaviorOwner(component), bits)
end

function frameworkBehavior.keyBits(): integer
    return bor(NeedsSet, NeedsRemove, NeedsDespawn, NoBulkBatch)
end

function frameworkBehavior.sparseRelationshipBits(): integer
    return bor(NeedsSet, NeedsRemove, MustDeferSet, MustDeferRemove, NoBulkBatch)
end

function frameworkBehavior.denseExclusiveRelationshipBits(): integer
    return bor(NeedsSet, NoBulkBatch)
end

function frameworkBehavior.denseReverseIndexRelationshipBits(): integer
    return bor(NeedsSet, NeedsRemove, NeedsDespawn, NoBulkBatch)
end

local function denseStore(world: WorldImpl, owner: Component): RelationshipStore
    return world.relationshipStores[owner]
end

local function denseUnlink(world: WorldImpl, owner: Component, id: integer, value: any)
    if value ~= nil then
        local store = denseStore(world, owner)
        if store then
            store:unlink(id, (value as {string:integer}).target)
        end
    end
end

local function denseReadOld(component: Component, arch: Archetype, row: integer): any
    local col = arch.columns[component] as {any}
    if col ~= nil then
        return col[row + 1]
    end
end

-- Closed set dispatch for framework-owned component families.
-- Key claims must happen before the value is written. Sparse relationships
-- store per-target links outside the archetype and keep the relationship
-- container present as the archetype marker. Dense relationships write the
-- actual instance component; exclusive relationships first remove sibling
-- instances through normal remove dispatch, and reverse-index relationships
-- link after the new value has been written.
function frameworkBehavior.set(world: WorldImpl, id: integer, componentType: Component, value: any)
    local owner = frameworkBehavior.behaviorOwner(componentType)
    local behavior = owner.frameworkBehavior or 0

    if behavior == Key then
        world:_claimKey(id, value as string)
        return world:setRaw(id, componentType, value)
    end

    if behavior == SparseRelationship then
        if (value as {string:any}).target ~= nil then
            world:setSparseRaw(id, value)
        end
        return world:deferSetRaw(id, owner, owner)
    end

    if behavior ~= DenseRelationship then
        return world:setRaw(id, componentType, value)
    end

    if (owner as types.components.Relationship).exclusiveRelationship then
        local arch = world:currentArchetype(id)
        if arch then
            for existingComp in pairs(arch.columns as {Component:any}) do
                local existOwner = existingComp.wildcardContainer
                if existOwner == owner and existingComp ~= componentType then
                    world:remove(id, existingComp)
                end
            end
        end
    end

    world:setRaw(id, componentType, value)
    if owner.reverseIndex then
        local store = denseStore(world, owner)
        if store then
            store:link(id, (value as {string:integer}).target)
        end
    end
end

-- Closed remove dispatch for framework-owned component families.
-- Key releases must happen before the component leaves the entity. Sparse
-- relationship removal mutates the external relationship store instead of an
-- archetype column, with container removal clearing all targets. Dense
-- reverse-index relationships must read the old target before raw removal can
-- drop or move the old component value, then unlink after the structural
-- mutation succeeds.
function frameworkBehavior.remove(world: WorldImpl, id: integer, component: Component)
    local owner = frameworkBehavior.behaviorOwner(component)
    local behavior = owner.frameworkBehavior or 0

    if behavior == Key then
        world:_releaseKeyForEntity(id)
        return world:removeRaw(id, component)
    end

    if behavior == SparseRelationship then
        if component == owner then
            return world:removeSparseRaw(id, owner)
        end
        return world:removeSparseOneRaw(id, owner, component.target)
    end

    if behavior ~= DenseRelationship or not owner.reverseIndex then
        return world:removeRaw(id, component)
    end

    local oldValue = world:oldValueOf(id, component)
    world:removeRaw(id, component)
    denseUnlink(world, owner, id, oldValue)
end

function frameworkBehavior.despawn(world: WorldImpl, id: integer, component: Component, arch: Archetype, row: integer)
    local owner = frameworkBehavior.behaviorOwner(component)
    local behavior = owner.frameworkBehavior or 0
    if behavior == Key then
        return world:_releaseKeyForEntity(id)
    elseif behavior == DenseRelationship then
        denseUnlink(world, owner, id, denseReadOld(component, arch, row))
    end
end

return frameworkBehavior
