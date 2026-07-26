




local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local builtins = require("tecs.internal.builtins")
local shared = require("tecs.internal.world.shared")





local BundleCodegen = {}












local function seq(prefix, lo, hi, sep)
   if hi < lo then return "" end
   local parts = {}
   for i = lo, hi do parts[#parts + 1] = prefix .. i end
   return table.concat(parts, sep)
end


local function requiredChecksSrc(requiredCount)
   local parts = {}
   for i = 1, requiredCount do
      parts[#parts + 1] = string.format(
      "    if r%d == nil then error('Required component missing: ' .. T%d.componentName, 2) end",
      i, i)
   end
   return table.concat(parts, "\n")
end





local function codegenKeyedSrc(n, requiredCount)
   local upvalueList; do
      local parts = { "world" }
      for i = 1, n do parts[#parts + 1] = "T" .. i end
      for i = requiredCount + 1, n do parts[#parts + 1] = "f" .. i end
      upvalueList = table.concat(parts, ", ")
   end
   local paramList = seq("r", 1, requiredCount, ", ")
   if paramList ~= "" then paramList = ", " .. paramList end
   local argParts = {}
   for i = 1, requiredCount do argParts[#argParts + 1] = "r" .. i end
   for i = requiredCount + 1, n do argParts[#argParts + 1] = "f" .. i .. "()" end

   local src = [[
local __UPVALUES__ = ...

local function spawn(_self__PARAM_LIST__)
__REQUIRED_CHECKS__
    return world:spawn(__ARGS__)
end

return spawn
]]
   src = src:gsub("__UPVALUES__", upvalueList)
   src = src:gsub("__PARAM_LIST__", paramList)
   src = src:gsub("__REQUIRED_CHECKS__", requiredChecksSrc(requiredCount))
   src = src:gsub("__ARGS__", table.concat(argParts, ", "))
   return src
end

local function codegenSrc(n, requiredCount, isSparse, isScalar)




   local queueSlot = {}
   local nonSparseCount = 0
   for i = 1, n do
      if not isSparse[i] then
         nonSparseCount = nonSparseCount + 1
         queueSlot[i] = nonSparseCount
      end
   end
   local stride = 2 + nonSparseCount



   local upvalueList; do
      local parts = { "world", "allocSlot", "OnSpawn" }
      for i = 1, n do parts[#parts + 1] = "T" .. i end
      for i = requiredCount + 1, n do parts[#parts + 1] = "f" .. i end
      upvalueList = table.concat(parts, ", ")
   end

   local paramList = seq("r", 1, requiredCount, ", ")
   if paramList ~= "" then paramList = ", " .. paramList end

   local typeList = seq("T", 1, n, ", ")

   local cachedColDecls; do
      local parts = {}
      for i = 1, n do
         if not isSparse[i] then parts[#parts + 1] = "col" .. i end
      end
      cachedColDecls = #parts > 0 and ("local " .. table.concat(parts, ", ")) or ""
   end
   local fetchColsResolve; do
      local parts = {}
      for i = 1, n do
         if not isSparse[i] then
            parts[#parts + 1] = "    col" .. i .. " = a.columns[T" .. i .. "]"
         end
      end
      fetchColsResolve = table.concat(parts, "\n")
   end
   local fetchColsGrow; do
      local parts = {}
      for i = 1, n do
         if not isSparse[i] then
            parts[#parts + 1] = "            col" .. i .. " = a.columns[T" .. i .. "]"
         end
      end
      fetchColsGrow = table.concat(parts, "\n")
   end






   local function valueExpr(i)
      local base = i <= requiredCount and ("r" .. i) or ("f" .. i .. "()")
      if isScalar[i] then return "(" .. base .. ").value" end
      return base
   end



   local columnWritesImmediate; do
      local parts = {}
      for i = 1, n do
         if isSparse[i] then
            parts[#parts + 1] = "    world:applySparseRaw(id, " .. valueExpr(i) .. ")"
         else
            parts[#parts + 1] = "    col" .. i .. "[row] = " .. valueExpr(i)
         end
      end
      columnWritesImmediate = table.concat(parts, "\n")
   end



   local enqueuePushes; do
      local parts = {}
      parts[#parts + 1] = "        spawnQueue[c + 1] = a.id"
      parts[#parts + 1] = "        spawnQueue[c + 2] = slot"
      for i = 1, n do
         if isSparse[i] then
            parts[#parts + 1] = "        world:setSparseRaw(id, " .. valueExpr(i) .. ")"
         else
            parts[#parts + 1] = "        spawnQueue[c + " .. (queueSlot[i] + 2) .. "] = " .. valueExpr(i)
         end
      end
      enqueuePushes = table.concat(parts, "\n")
   end



   local drainColumnWrites; do
      local parts = {}
      for i = 1, n do
         if not isSparse[i] then
            parts[#parts + 1] = "            col" .. i .. "[row] = spawnQueue[i + " .. (queueSlot[i] + 1) .. "]"
         end
      end
      drainColumnWrites = table.concat(parts, "\n")
   end

   local requiredChecks = requiredChecksSrc(requiredCount)









   local src = [[
local __UPVALUES__ = ...

local cachedArch = nil
local cachedAutoState = nil
local cachedGen = -1
local requiredList = nil
__CACHED_COL_DECLS__

local spawnQueue = {}
local spawnQueueCount = 0
local pendingDrain = false
local drain  -- forward ref

local componentTypes = { __TYPE_LIST__ }

local function resolveArch()
    -- Shared spawn resolution: requires expansion, wildcard containers,
    -- and the active auto-state component.
    local a, reqs = world:_resolveSpawnArchetype(componentTypes)
    requiredList = reqs
    cachedArch = a
    cachedAutoState = world.autoStateComponent
    cachedGen = a.generation
__FETCH_COLS_RESOLVE__
    return a
end

-- Write `requires`-supplied defaults into a spawned row. Mirrors the
-- batch drain's fan-out semantics: table storage gets a fresh factory
-- value per row, everything else the shared value (scalars unwrapped).
local function writeRequired(a, row)
    for ri = 1, #requiredList do
        local entry = requiredList[ri]
        local rcol = a.columns[entry.type]
        if rcol then
            local storage = entry.type.storageType
            local v
            if storage == "table" then
                v = entry.factory()
            else
                v = entry.sharedValue
                if v == nil then v = entry.factory() end
                if storage == "scalar" then v = v.value end
            end
            rcol[row] = v
        end
    end
end

local function spawn(_self__PARAM_LIST__)
__REQUIRED_CHECKS__
    local a = cachedArch
    if a == nil or world.autoStateComponent ~= cachedAutoState then
        a = resolveArch()
    end

    local slot = allocSlot(world.allocator)
    local es = world.allocator.slots[slot]
    local id = slot + es.generation * __GEN_STRIDE__

    -- OnSpawn observers force the staged route so the event contract
    -- (entity staged, observer mutations stage) matches world:spawn.
    local staged = world._scopeDepth > 0
    local synthetic = false
    if not staged and world.messages._totalObservers > 0
            and world:hasObservers(0, OnSpawn) then
        staged = true
        synthetic = true
        world._scopeDepth = 1
    end

    if staged then
        -- Deferred: enqueue + register drain. Entity isn't visible to
        -- queries until `_drain` fires the registered drain callback.
        -- Slot is fresh from allocSlot so its stamp doesn't match the
        -- current epoch; claim + zero state companion.
        local epoch = world._transactionEpoch
        if world._slotStamp[slot] ~= epoch then
            world._slotStamp[slot] = epoch
            world._stateArr[slot] = 0
        end
        world._pendingArchArr[slot] = a.id
        local c = spawnQueueCount
__ENQUEUE_PUSHES__
        spawnQueueCount = c + __STRIDE__
        if not pendingDrain then
            local bc = a.pendingBundleDrainCount + 1
            a.pendingBundleDrains[bc] = drain
            a.pendingBundleDrainCount = bc
            if a.dirtyQueuedEpoch ~= world._dirtyEpoch then
                a.dirtyQueuedEpoch = world._dirtyEpoch
                local dc = world.dirtyArchetypeCount + 1
                world.dirtyArchetypeList[dc] = a
                world.dirtyArchetypeCount = dc
            end
            pendingDrain = true
            world.isDirty = true
        end
        world:emit(0, OnSpawn, id)
        if synthetic then
            world:_drain()
            world._scopeDepth = 0
        end
        return id
    end

    -- Immediate placement.
    local entities = a.entities
    local row = entities[0] + 1
    if row > a.capacity then
        a:reserveCapacity(row)
        entities = a.entities
        cachedGen = a.generation
__FETCH_COLS_GROW_IMMEDIATE__
    elseif a.generation ~= cachedGen then
        -- Another spawn path grew the archetype and swapped its columns.
        cachedGen = a.generation
__FETCH_COLS_GROW_IMMEDIATE__
    end
    entities[row] = id
    entities[0] = row
    es.archetypeId = a.id
    es.row = row - 1

    if requiredList then writeRequired(a, row) end
__COLUMN_WRITES_IMMEDIATE__

    a:onRowsAdded(row - 1, 1, nil)

    return id
end

drain = function()
    local slots = world.allocator.slots
    local slotStamp = world._slotStamp
    local stateArr = world._stateArr
    local epoch = world._transactionEpoch
    local archIndex = world.archetypeIndex
    local a = nil
    local currentArchId = 0

    local i = 1
    while i <= spawnQueueCount do
        local entryArchId = spawnQueue[i]
        local slot = spawnQueue[i + 1]
        -- A despawn staged before commit wins; skip placement.
        if not (slotStamp[slot] == epoch and stateArr[slot] == __STATE_DESPAWN__) then
            if entryArchId ~= currentArchId then
                -- Entries carry their enqueue-time target so a mid-scope
                -- state change places each burst correctly.
                a = archIndex[entryArchId]
                currentArchId = entryArchId
__FETCH_COLS_GROW__
            end
            local entities = a.entities
            local row = entities[0] + 1
            if row > a.capacity then
                a:reserveCapacity(row)
                entities = a.entities
__FETCH_COLS_GROW__
            end
            local es = slots[slot]
            es.archetypeId = entryArchId
            es.row = row - 1
            local id = slot + es.generation * __GEN_STRIDE__
            entities[row] = id
            entities[0] = row

            if requiredList then writeRequired(a, row) end
__DRAIN_COLUMN_WRITES__

            a:onRowsAdded(row - 1, 1, nil)
        end
        i = i + __STRIDE__
    end

    spawnQueueCount = 0
    pendingDrain = false
    -- Entries may have targeted several archetypes; the shared column
    -- upvalues now belong to the last one. Force a re-resolve.
    cachedArch = nil
end

return spawn, drain
]]

   local fetchColsGrowImmediate; do
      local parts = {}
      for i = 1, n do
         if not isSparse[i] then
            parts[#parts + 1] = "        col" .. i .. " = a.columns[T" .. i .. "]"
         end
      end
      fetchColsGrowImmediate = table.concat(parts, "\n")
   end

   src = src:gsub("__UPVALUES__", upvalueList)
   src = src:gsub("__PARAM_LIST__", paramList)
   src = src:gsub("__REQUIRED_CHECKS__", requiredChecks)
   src = src:gsub("__TYPE_LIST__", typeList)
   src = src:gsub("__STATE_DESPAWN__", tostring(shared.STATE_DESPAWN))
   src = src:gsub("__CACHED_COL_DECLS__", cachedColDecls)
   src = src:gsub("__FETCH_COLS_RESOLVE__", fetchColsResolve)
   src = src:gsub("__FETCH_COLS_GROW_IMMEDIATE__", fetchColsGrowImmediate)
   src = src:gsub("__FETCH_COLS_GROW__", fetchColsGrow)
   src = src:gsub("__COLUMN_WRITES_IMMEDIATE__", columnWritesImmediate)
   src = src:gsub("__ENQUEUE_PUSHES__", enqueuePushes)
   src = src:gsub("__DRAIN_COLUMN_WRITES__", drainColumnWrites)
   src = src:gsub("__STRIDE__", tostring(stride))
   src = src:gsub("__GEN_STRIDE__", "2^22")
   return src
end

function BundleCodegen.codegenBundleSpawn(
   world,
   typeArray,
   factoryArray,
   requiredCount)

   local n = #typeArray

   if n == 0 then
      return function(_self)
         return world:spawn()
      end
   end

   local isSparse = {}
   local isScalar = {}
   local hasKey = false
   local Key = builtins.Key
   for i = 1, n do
      local ci = typeArray[i]
      isSparse[i] = ci.isSparse or false
      isScalar[i] = ci.storageType == "scalar"
      if typeArray[i] == Key then
         hasKey = true
      end
   end

   if hasKey then
      local keyedSrc = codegenKeyedSrc(n, requiredCount)
      local keyedChunk, keyedErr = load(keyedSrc, "=bundle_spawn_keyed", "t")
      if not keyedChunk then
         error("bundle codegen failed: " .. tostring(keyedErr))
      end
      local keyedArgs = { world }
      for i = 1, n do keyedArgs[#keyedArgs + 1] = typeArray[i] end
      for i = requiredCount + 1, n do keyedArgs[#keyedArgs + 1] = factoryArray[i] end
      return (keyedChunk)(
      table.unpack(keyedArgs, 1, #keyedArgs))
   end

   local src = codegenSrc(n, requiredCount, isSparse, isScalar)
   local chunk, err = load(src, "=bundle_spawn", "t")
   if not chunk then error("bundle codegen failed: " .. tostring(err)) end



   local args = {
      world,
      IdAllocator.allocSlot,
      builtins.OnSpawn,
   }
   for i = 1, n do args[#args + 1] = typeArray[i] end
   for i = requiredCount + 1, n do args[#args + 1] = factoryArray[i] end
   local packed = { (chunk)(table.unpack(args, 1, #args)) }




   return packed[1]
end

return BundleCodegen
