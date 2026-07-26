











local InverseIndex = {}










































local pool = require("tecs.utils.pool")

local InverseIndexImpl = {}





local EMPTY = pool.EMPTY
local INDEX_MT = { __index = InverseIndexImpl }

function InverseIndex.new()
   return setmetatable({ _inverse = {} }, INDEX_MT)
end

function InverseIndexImpl:link(sourceId, targetId)
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

function InverseIndexImpl:unlink(sourceId, targetId)
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

function InverseIndexImpl:forEachSource(targetId, callback, context)
   local sources = self._inverse[targetId]
   if sources then
      for sourceId in pairs(sources) do
         callback(sourceId, context)
      end
   end
end

function InverseIndexImpl:removeTarget(targetId)
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

function InverseIndexImpl:unlinkSourceFromTargets(sourceId, targets)
   local unlink = self.unlink
   for i = 1, #targets do
      unlink(self, sourceId, targets[i])
   end
end

return InverseIndex
