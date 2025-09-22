--- InverseIndex: target -> {source: true, ...} mapping for relationship reverse lookups.
---
--- Used by both sparse and dense relationships when reverseIndex = true.
--- Enables O(1) world:targets() and world:traverse() lookups, and cascade delete via removeTarget() during despawn.
---
--- Internal layout: each target maps to a SET of source entity IDs (a Lua table with `{[sourceId] = true}` entries).
--- This makes link/unlink/membership-check all O(1) and link is idempotent — calling it twice with the same
--- (source, target) pair is a no-op rather than producing duplicate entries.
---
--- Iteration order is non-deterministic (uses pairs). No "ordered relationship" config exists in the codebase, and
--- world:targets/world:traverse don't promise insertion order, so this is acceptable.

local record InverseIndex
    --- Create a new InverseIndex.
    --- @returns a new InverseIndex instance.
    new: function(): InverseIndex

    --- Add a (source, target) edge. Idempotent: calling twice with the same
    --- pair has no additional effect.
    --- @param sourceId the source entity ID
    --- @param targetId the target entity ID
    link: function(self, sourceId: integer, targetId: integer)

    --- Remove a specific (source, target) edge.
    --- @param sourceId the source entity ID
    --- @param targetId the target entity ID
    unlink: function(self, sourceId: integer, targetId: integer)

    --- Callback-based iteration over source entities targeting a given target.
    --- The optional `context` is passed through to the callback as its second
    --- argument, so visitors can be hoisted to module scope without per-call
    --- closure allocation. Existing single-arg callbacks (`function(srcId)`)
    --- keep working since Lua silently drops extra args.
    --- @param targetId the target entity ID
    --- @param callback the function to call for each (sourceId, context)
    --- @param context optional value forwarded to the callback as its 2nd arg
    forEachSource: function<T>(self, targetId: integer, callback: function(integer, T), context: T)

    --- Remove all edges to a target. Returns the source set as a {[sourceId] = true}
    --- map (caller iterates with `for sourceId in pairs(...) do`). Returns an
    --- empty sentinel if there are no sources. The internal entry is removed
    --- atomically; the returned map is the same table that was stored, so it
    --- must not be mutated by the caller.
    --- @param targetId the target entity ID
    --- @returns a map of source IDs that were linked to the target, or an empty map if there were none
    removeTarget: function(self, targetId: integer): {integer: boolean}

    --- Remove ALL edges from a source entity (used on entity despawn).
    --- Iterates over the source's outgoing edges in caller-provided arg list since
    --- we don't track them per-source — caller must pass the targets to unlink.
    --- @param sourceId the source entity ID
    --- @param targets the list of target entity IDs to unlink from the source
    unlinkSourceFromTargets: function(self, sourceId: integer, targets: {integer})
end

local pool <const> = require("tecs.utils.pool")

local record InverseIndexImpl
    _inverse: {integer: {integer: boolean}}
    _onTargetAdded: function(integer)
    _onTargetRemoved: function(integer)
end

local EMPTY <const> = pool.EMPTY as {integer: boolean}
local INDEX_MT <const> = {__index = InverseIndexImpl}

function InverseIndex.new(): InverseIndex
    return setmetatable({_inverse = {}}, INDEX_MT) as InverseIndex
end

function InverseIndexImpl:link(sourceId: integer, targetId: integer)
    local inverse = self._inverse
    local sources = inverse[targetId]
    if not sources then
        sources = {}
        inverse[targetId] = sources
        local onTargetAdded = self._onTargetAdded
        if onTargetAdded then
            onTargetAdded(targetId)
        end
    end
    sources[sourceId] = true
end

function InverseIndexImpl:unlink(sourceId: integer, targetId: integer)
    local sources = self._inverse[targetId]
    if not sources then return end
    sources[sourceId] = nil
    if next(sources) == nil then
        self._inverse[targetId] = nil
        local onTargetRemoved = self._onTargetRemoved
        if onTargetRemoved then
            onTargetRemoved(targetId)
        end
    end
end

function InverseIndexImpl:forEachSource(targetId: integer, callback: function(integer, any), context: any)
    local sources = self._inverse[targetId]
    if sources then
        for sourceId in pairs(sources) do
            callback(sourceId, context)
        end
    end
end

function InverseIndexImpl:removeTarget(targetId: integer): {integer: boolean}
    local sources = self._inverse[targetId]
    if not sources then
        return EMPTY
    end

    self._inverse[targetId] = nil
    local onTargetRemoved = self._onTargetRemoved
    if onTargetRemoved then
        onTargetRemoved(targetId)
    end
    return sources
end

function InverseIndexImpl:unlinkSourceFromTargets(sourceId: integer, targets: {integer})
    local unlink = self.unlink
    for i = 1, #targets do
        unlink(self, sourceId, targets[i])
    end
end

return InverseIndex
