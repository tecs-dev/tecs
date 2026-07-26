























local InverseIndex = require("tecs.internal.InverseIndex")
local types = require("tecs.types")














local RelationshipStore = {}







































local EMPTY = {}





local SparseImpl = {}





function SparseImpl:get(entityId)
   return self._forward[entityId]
end

function SparseImpl:getFirst(entityId)
   local val = self._forward[entityId]
   if val == nil or self._exclusive then
      return val
   end
   local _, first = next(val)
   return first
end

function SparseImpl:getTarget(entityId, targetId)
   if self._exclusive then
      local val = self._forward[entityId]
      if val and (val).target == targetId then
         return val
      end
      return nil
   else
      local map = self._forward[entityId]
      return map and map[targetId] or nil
   end
end

function SparseImpl:set(entityId, value)
   local target = value.target
   local inverse = self._inverse

   if self._exclusive then
      local oldValue = self._forward[entityId]

      if inverse and oldValue ~= nil then
         local oldTarget = (oldValue).target
         if oldTarget then
            inverse:unlink(entityId, oldTarget)
         end
      end

      self._forward[entityId] = value

      if inverse and target then
         inverse:link(entityId, target)
      end

      return oldValue
   else

      local map = self._forward[entityId]
      if not map then
         map = {}
         self._forward[entityId] = map
      end

      local oldValue = map[target]


      if inverse and oldValue == nil and target then
         inverse:link(entityId, target)
      end

      map[target] = value
      return oldValue
   end
end

function SparseImpl:remove(entityId)
   local oldValue = self._forward[entityId]
   if oldValue == nil then
      return nil
   end
   local inverse = self._inverse

   if inverse then
      if self._exclusive then
         local oldTarget = (oldValue).target
         if oldTarget then
            inverse:unlink(entityId, oldTarget)
         end
      else
         local map = oldValue
         for targetId in pairs(map) do
            inverse:unlink(entityId, targetId)
         end
      end
   end

   self._forward[entityId] = nil
   return oldValue
end

function SparseImpl:removeOne(entityId, targetId)
   local inverse = self._inverse
   if self._exclusive then
      local val = self._forward[entityId]
      if val and (val).target == targetId then
         self._forward[entityId] = nil
         if inverse then
            inverse:unlink(entityId, targetId)
         end
         return val, false
      end
      return nil, self._forward[entityId] ~= nil
   else
      local map = self._forward[entityId]
      if not map then return nil, false end

      local val = map[targetId]
      if val == nil then
         return nil, next(map) ~= nil
      end

      map[targetId] = nil
      if inverse then
         inverse:unlink(entityId, targetId)
      end

      local hasRemaining = next(map) ~= nil
      if not hasRemaining then
         self._forward[entityId] = nil
      end
      return val, hasRemaining
   end
end

function SparseImpl:has(entityId)
   return self._forward[entityId] ~= nil
end

function SparseImpl:pairs()
   local k = nil
   local forward = self._forward
   return function()
      local nextK, nextV = next(forward, k)
      k = nextK
      return nextK, nextV
   end
end

function SparseImpl:link(sourceId, targetId)
   if self._inverse then
      self._inverse:link(sourceId, targetId)
   end
end

function SparseImpl:unlink(sourceId, targetId)
   if self._inverse then
      self._inverse:unlink(sourceId, targetId)
   end
end

function SparseImpl:forEachSource(targetId, callback, context)
   if not self._inverse then return end
   self._inverse:forEachSource(targetId, callback, context)
end

function SparseImpl:removeTarget(targetId)
   local inverse = self._inverse
   if not inverse then
      return EMPTY
   end

   local sources = inverse:removeTarget(targetId)
   if next(sources) == nil then
      return EMPTY
   end



   local fullyCleared = {}
   for sourceId in pairs(sources) do
      if self._exclusive then
         self._forward[sourceId] = nil
         fullyCleared[sourceId] = true
      else
         local map = self._forward[sourceId]
         if map then
            map[targetId] = nil
            if next(map) == nil then
               self._forward[sourceId] = nil
               fullyCleared[sourceId] = true
            end
         end
      end
   end

   return fullyCleared
end

local SPARSE_MT = { __index = SparseImpl }





local DenseImpl = {}




function DenseImpl:get(_entityId) return nil end
function DenseImpl:getFirst(_entityId) return nil end
function DenseImpl:getTarget(_entityId, _targetId) return nil end
function DenseImpl:set(_entityId, _value) return nil end
function DenseImpl:remove(_entityId) return nil end
function DenseImpl:removeOne(_entityId, _targetId)
   return nil, false
end
function DenseImpl:has(_entityId) return false end
function DenseImpl:pairs()
   return function() return nil, nil end
end


function DenseImpl:link(sourceId, targetId)
   self._inverse:link(sourceId, targetId)
end

function DenseImpl:unlink(sourceId, targetId)
   self._inverse:unlink(sourceId, targetId)
end

function DenseImpl:forEachSource(targetId, callback, context)
   self._inverse:forEachSource(targetId, callback, context)
end

function DenseImpl:removeTarget(targetId)
   return self._inverse:removeTarget(targetId)
end

local DENSE_MT = { __index = DenseImpl }










function RelationshipStore.create(config)
   if config.sparse then
      local inverse = nil
      if config.reverseIndex then
         inverse = InverseIndex.new();
         (inverse)._onTargetAdded = config.onTargetAdded;
         (inverse)._onTargetRemoved = config.onTargetRemoved
      end
      local store = {
         _forward = {},
         _inverse = inverse,
         _exclusive = config.exclusive or false,
      }
      return setmetatable(store, SPARSE_MT)
   elseif config.reverseIndex then
      local inverse = InverseIndex.new();
      (inverse)._onTargetAdded = config.onTargetAdded;
      (inverse)._onTargetRemoved = config.onTargetRemoved
      local store = {
         _inverse = inverse,
      }
      return setmetatable(store, DENSE_MT)
   end
   return nil
end

return RelationshipStore
