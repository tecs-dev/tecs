























































local types = require("tecs.types")
local internal = require("tecs.internal.types")
local components = require("tecs.internal.components")
local builtins = require("tecs.internal.builtins")
local FFIStorage = require("tecs.internal.ffi.FFIStorage")
local IdAllocator = require("tecs.internal.IdAllocator")
local bit = require("bit")
local StringBuffer = require("string.buffer")



local BUF_PROBE = StringBuffer.new()
local BUF_ENCODE = (BUF_PROBE).encode
local BUF_DECODE = (BUF_PROBE).decode











local _ffi = require("ffi")
local function ffiNew(ct, n) return _ffi.new(ct, n) end
local function ffiCopy(dst, src, n) _ffi.copy(dst, src, n) end
local function ffiTypeof(ct) return _ffi.typeof(ct) end


local ffiNewOne =
(load("return function(ct) return ct() end"))()




local ffiOffsetCharPtr =
(load("local cast = ...; return function(src, n) return cast('char*', src) + n end"))(_ffi.cast)






local ffiOffsetDoublePtr =
(load("local cast = ...; return function(src, n) return cast('double*', src) + n end"))(_ffi.cast)









local table_move = table.move

local SNAPSHOT_VERSION = 2



local ROW_MASK_MAX_COLUMNS = 52
local POW2 = {}
do
   local p = 1
   for i = 1, ROW_MASK_MAX_COLUMNS do
      POW2[i] = p
      p = p * 2
   end
end
local STATE_STACK_DATA_KEY = "__tecs.stateStack"
local PIPELINE_DATA_KEY = "__tecs.pipeline"

local snapshot = { Prelude = {}, ComponentTableEntry = {}, EntityRow = {}, ArchetypeEntry = {}, DataEntry = {}, Snapshot = {}, SaveOptions = {} }




































































































































































































































































local migStructCounter = 0
local migSchemaCache = {}



local function parseSchema(fingerprint)
   local fieldsPart, sizePart = fingerprint:match("^(.-)|(%d+)$")
   if not fieldsPart then
      error("snapshot: invalid fingerprint format: " .. fingerprint)
   end
   local size = tonumber(sizePart)
   local fields = {}
   for part in fieldsPart:gmatch("[^,]+") do
      local name, ctype = part:match("^([^:]+):(.+)$")
      if not name or not ctype then
         error("snapshot: invalid schema field: '" .. part .. "' in " .. fingerprint)
      end
      fields[#fields + 1] = { name, ctype }
   end
   return fields, size
end






local function getOrBuildMigSchema(fingerprint)
   local cached = migSchemaCache[fingerprint]
   if cached then return cached end

   local fields, size = parseSchema(fingerprint)
   migStructCounter = migStructCounter + 1
   local structName = "__tecs_mig_" .. migStructCounter
   local structType, _ = FFIStorage.defineStruct(structName, fields)

   local info = {
      structType = structType,
      fields = fields,
      size = size,
   }
   migSchemaCache[fingerprint] = info
   return info
end





local function buildMigrator(comp, savedFingerprint)
   local savedInfo = getOrBuildMigSchema(savedFingerprint)
   local savedFields = savedInfo.fields
   local nSaved = #savedFields
   local savedSize = savedInfo.size

   local currentFingerprint = (comp).fingerprint or ""
   local currentInfo = getOrBuildMigSchema(currentFingerprint)
   local currentNames = {}
   for i = 1, #currentInfo.fields do
      currentNames[currentInfo.fields[i][1]] = true
   end



   local scratch = ffiNewOne(savedInfo.structType)
   local scratchFields = scratch
   local constructor = comp

   return function(buf)
      local ref = (buf).ref
      local skip = (buf).skip
      ffiCopy(scratch, ref(buf), savedSize)
      skip(buf, savedSize)

      local instance = constructor()
      local instanceFields = instance
      for i = 1, nSaved do
         local name = savedFields[i][1]
         if currentNames[name] then
            instanceFields[name] = scratchFields[name]
         end
      end
      return instance
   end
end















local archetypeColumnsCache =
setmetatable({}, { __mode = "k" })

local function archetypeColumns(arch)
   local cached = archetypeColumnsCache[arch]
   if cached then return cached.cols, cached.hasSparse end

   local cols = {}
   local hasSparse = false
   for i = 1, arch.columnsCount do
      local comp = arch.componentList[i]
      local emit = false
      if (comp).transient then
         emit = false
      elseif (comp).isSparse and (comp).isContainer then
         emit = comp.serialize ~= nil
         if emit then hasSparse = true end
      elseif not (comp).isContainer then
         emit = comp.serialize ~= nil
      end
      if emit then
         cols[#cols + 1] = comp
      end
   end
   archetypeColumnsCache[arch] = { cols = cols, hasSparse = hasSparse }
   return cols, hasSparse
end

local function captureStateStack(world)
   local stack = (world)._stateStack
   if stack == nil or #stack == 0 then return nil end
   local out = {}
   for i = 1, #stack do
      out[i] = stack[i]
   end
   return out
end

local function restoreStateStack(world, saved)
   if saved == nil then return end
   local worldAny = world
   local states = worldAny._stateComponents
   local stack = {}
   for i = 1, #saved do
      local name = saved[i]
      if states[name] == nil then
         error("loadSnapshot: saved state '" .. tostring(name) ..
         "' is not registered in this world; call world:createState('" ..
         tostring(name) .. "') before loading")
      end
      stack[#stack + 1] = name
   end
   worldAny._stateStack = stack
   local top = stack[#stack]
   worldAny.autoStateComponent = top and states[top] or nil
end

local function capturePipelineState(world)
   local pipeline = (world).pipeline
   if not pipeline then return nil end
   if pipeline.fixedAccumulator == nil and pipeline.phaseStates == nil then return nil end

   local out = {}
   if pipeline.fixedAccumulator ~= nil then
      out.fixedAccumulator = pipeline.fixedAccumulator
   end

   local phaseStates = pipeline.phaseStates
   if phaseStates then
      local states = {}
      for i = 1, #phaseStates do
         states[i] = phaseStates[i] == true
      end
      out.phaseStates = states
   end
   return out
end

local function restorePipelineState(world, saved)
   if saved == nil then return end
   local pipeline = (world).pipeline
   if not pipeline then return end

   if saved.fixedAccumulator ~= nil and pipeline.fixedAccumulator ~= nil then
      pipeline.fixedAccumulator = saved.fixedAccumulator
   end

   local savedPhaseStates = saved.phaseStates
   local phaseStates = pipeline.phaseStates
   if savedPhaseStates and phaseStates then
      for i = 1, #savedPhaseStates do
         if phaseStates[i] ~= nil then
            phaseStates[i] = savedPhaseStates[i] == true
         end
      end
      pipeline.dirty = true
   end
end

local function cloneComponentList(list)
   if not list then return nil end
   local out = {}
   for i = 1, #list do out[i] = list[i] end
   return out
end

local function cloneQueryDescriptor(d)
   if not d then return nil end
   local out = {}
   for k, v in pairs(d) do
      (out)[k] = v
   end
   out.include = cloneComponentList(d.include)
   out.includeAny = cloneComponentList(d.includeAny)
   out.exclude = cloneComponentList(d.exclude)
   return out
end




local function buildLayerMask(layers)
   local mask = 0
   for i = 1, #layers do
      local l = layers[i]
      if l < 0 or l > 31 then
         error("saveSnapshot: layer " .. tostring(l) .. " out of range 0..31 for bitmask matching")
      end
      mask = bit.bor(mask, bit.lshift(1, l))
   end
   return mask
end






local function resolveSaveFilters(world, opts, filterQuery)
   local layerMask = nil
   if opts.layers then
      layerMask = buildLayerMask(opts.layers)
   end

   local query
   if filterQuery then
      local d = cloneQueryDescriptor(filterQuery)
      d.temp = true
      query = world:query(d)
   end
   return query, layerMask
end



local function archetypeHasTransform(arch)
   return arch.columns[builtins.Transform] ~= nil
end




local function countFilteredArchetype(arch, layerMask, hasTransform)
   local full = arch.entities[0]
   if full == 0 then return 0 end
   if layerMask == nil or not hasTransform then return full end
   local transforms = arch.columns[builtins.Transform]
   local n = 0
   for row = 1, full do
      local layer = transforms[row].layer
      if bit.band(layerMask, bit.lshift(1, layer)) ~= 0 then
         n = n + 1
      end
   end
   return n
end



local doubleArrayType = ffiTypeof("double[?]")
local function buildFilteredIds(arch, layerMask, count)
   local ids = ffiNew(doubleArrayType, count)
   local transforms = arch.columns[builtins.Transform]
   local entities = arch.entities
   local idx = 0
   for row = 1, arch.entities[0] do
      if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
         ids[idx] = entities[row]
         idx = idx + 1
      end
   end
   return ids
end



local newBufferWriterImpl
local newTableWriterImpl





local function saveSnapshotImpl(world, writer, opts)





   local pendingDataPairs = {}
   local excludedComponents = {}
   local stateStack = captureStateStack(world)
   local pipelineState = capturePipelineState(world)
   do
      local saveEvent = builtins.OnSnapshotSave()
      local evAny = saveEvent
      evAny.addData = function(_self, k, v)
         pendingDataPairs[#pendingDataPairs + 1] = { k, v }
      end
      evAny.exclude = function(_self, comp)
         excludedComponents[#excludedComponents + 1] = comp
      end
      world:emit(0, saveEvent)
   end




   local filterQuery = opts.filterQuery
   if #excludedComponents > 0 then
      local d = cloneQueryDescriptor(filterQuery) or {}
      local exclude = d.exclude
      if not exclude then
         exclude = {}
         d.exclude = exclude
      end
      for i = 1, #excludedComponents do
         exclude[#exclude + 1] = excludedComponents[i]
      end
      filterQuery = d
   end

   local query, layerMask = resolveSaveFilters(world, opts, filterQuery)







   local componentTable = {}
   local componentIndex = {}












   local emitList = {}
   local totalEntityCount = 0

   local function addComponent(comp)
      local idx = componentIndex[comp]
      if idx then return idx end
      idx = #componentTable + 1
      componentIndex[comp] = idx






      local name = comp.componentName
      local wildcard = (comp).wildcardContainer
      if wildcard and comp.target ~= nil then
         name = wildcard.componentName .. "->" .. tostring(comp.target)
      end
      componentTable[idx] = {
         name = name,
         fingerprint = (comp).fingerprint or "",
      }
      return idx
   end

   local function processArchetype(arch)
      local hasTransform = archetypeHasTransform(arch)
      local count = countFilteredArchetype(arch, layerMask, hasTransform)
      if count == 0 then return end





      local cols, hasSparse = archetypeColumns(arch)

      local columnIndices = {}
      for i = 1, #cols do
         columnIndices[i] = addComponent(cols[i])
      end

      emitList[#emitList + 1] = {
         arch = arch,
         cols = cols,
         columnIndices = columnIndices,
         count = count,
         hasSparse = hasSparse,
         applyLayerFilter = layerMask ~= nil and hasTransform,
      }
      totalEntityCount = totalEntityCount + count
   end

   if query then
      for arch, _len in query:iter() do processArchetype(arch) end
   else
      world:forEachArchetype(processArchetype)
   end

   writer:writePrelude(
   SNAPSHOT_VERSION,


   ((world).allocator).nextFreshSlot,
   totalEntityCount,
   #emitList,
   componentTable)

   local stores = (world).relationshipStores
   local vals = {}
   local writerAny = writer
   local hasBulkColumnRaw = writerAny.writeColumnRaw ~= nil

   for _, entry in ipairs(emitList) do
      local arch = entry.arch
      local cols = entry.cols
      local count = entry.count
      local hasSparse = entry.hasSparse
      local applyLayerFilter = entry.applyLayerFilter
      local mode = hasSparse and 1 or 0

      writer:startArchetype(#cols, count, entry.columnIndices, mode)

      if mode == 0 then



         local idsArray
         if applyLayerFilter then
            idsArray = buildFilteredIds(arch, layerMask, count)
         else







            idsArray = ffiOffsetDoublePtr(arch.entities, 1)
         end
         writer:writeIds(idsArray, count)

         for c = 1, #cols do
            local comp = cols[c]
            local structSize = (comp).structSize





            local bulkEligible = hasBulkColumnRaw and structSize and (comp).serializeRaw and
            not (comp).isContainer
            local column = arch.columns[comp]
            if bulkEligible and not applyLayerFilter then



               writer:writeColumnRaw(c, ffiOffsetCharPtr(column, structSize), structSize * count)
            elseif bulkEligible then


               local typedColumn = column
               local transforms = arch.columns[builtins.Transform]
               for row = 1, arch.entities[0] do
                  if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
                     writer:writeColumnValue(c, typedColumn[row], comp)
                  end
               end
            else

               local typedColumn = column
               if applyLayerFilter then
                  local transforms = arch.columns[builtins.Transform]
                  for row = 1, arch.entities[0] do
                     if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
                        writer:writeColumnValue(c, typedColumn[row], comp)
                     end
                  end
               else
                  for row = 1, arch.entities[0] do
                     writer:writeColumnValue(c, typedColumn[row], comp)
                  end
               end
            end
         end
      else



         local entities = arch.entities
         local transforms
         if applyLayerFilter then
            transforms = arch.columns[builtins.Transform]
         end

         for row = 1, arch.entities[0] do
            if applyLayerFilter then
               if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) == 0 then
                  goto continue
               end
            end

            local entityId = entities[row]
            for i = 1, #cols do
               local comp = cols[i]
               if (comp).isSparse and (comp).isContainer then
                  local store = stores[comp]
                  if store and comp.serialize then
                     local value = store.get(store, entityId)





                     if value ~= nil and
                        not (comp).exclusiveRelationship then
                        error("snapshot: non-exclusive sparse relationship '" ..
                        comp.componentName ..
                        "' cannot be serialized; mark it transient")
                     end
                     vals[i] = value
                  else
                     vals[i] = nil
                  end
               elseif not (comp).isContainer then
                  local col = arch.columns[comp]
                  vals[i] = col[row]
               else
                  vals[i] = nil
               end
            end
            writer:writeEntity(entityId, vals, #cols, cols)
            ::continue::
         end
      end

      writer:endArchetype()
   end






   if stateStack ~= nil then
      writer:writeData(STATE_STACK_DATA_KEY, stateStack)
   end
   if pipelineState ~= nil then
      writer:writeData(PIPELINE_DATA_KEY, pipelineState)
   end
   if opts.customData then
      for k, v in pairs(opts.customData) do
         writer:writeData(k, v)
      end
   end
   for i = 1, #pendingDataPairs do
      writer:writeData(pendingDataPairs[i][1], pendingDataPairs[i][2])
   end
   writer:writeDataEnd()

   writer:writeEnd()
end

local function writeBufferToPath(path, buf)
   local f, err = io.open(path, "wb")
   if not f then
      error("saveSnapshot: failed to open '" .. path .. "': " .. tostring(err))
   end
   local bufToString = (buf).tostring
   local ok, writeErr = f:write(bufToString(buf))
   f:close()
   if not ok then
      error("saveSnapshot: failed to write '" .. path .. "': " .. tostring(writeErr))
   end
end

local function saveBinary(world, opts)
   local buf = opts.buffer
   if buf then
      local bufAny = buf
      bufAny.reset(buf)
   else
      buf = StringBuffer.new()
   end
   saveSnapshotImpl(world, newBufferWriterImpl(buf), opts)
   if opts.path ~= nil then
      writeBufferToPath(opts.path, buf)
   end
   return {
      format = "binary",
      buffer = buf,
      snapshot = nil,
   }
end

local function saveTable(world, opts)
   if opts.buffer ~= nil then
      error("saveSnapshot: opts.buffer is only valid for binary output")
   end
   if opts.path ~= nil then
      error("saveSnapshot: opts.path is only valid for binary output")
   end
   local writer, get = newTableWriterImpl()
   saveSnapshotImpl(world, writer, opts)
   return {
      format = "table",
      buffer = nil,
      snapshot = get(),
   }
end

function snapshot.saveSnapshot(world, opts)
   opts = opts or {}
   if opts.format == "table" then
      return saveTable(world, opts)
   end
   return saveBinary(world, opts)
end





local function clearWorld(world)





   world:clearEntities()
end




local function loadColumnMajor(
   world,
   reader,
   componentTypes,
   entityCount)

   if entityCount == 0 then return end





   local ids = reader:readIds(entityCount)

   world:batchSpawnAtRaw(ids, entityCount, componentTypes,
   function(arch, rowStart, _rowEnd, count)
      for col = 1, #componentTypes do
         local comp = assert(
         componentTypes[col],
         "loadSnapshot: unknown component in saved archetype")

         local structSize = (comp).structSize
         local archColumn = arch.columns[comp]





         local bulkEligible = structSize and
         comp.deserializeRaw and
         not comp.isContainer and
         reader.readColumnRawInto and
         reader:schemaMatchesForColumn(col)
         if bulkEligible then

            reader:readColumnRawInto(archColumn, rowStart * structSize, structSize * count)
         else



            for k = 0, count - 1 do
               local val = reader:readColumnValue(col, world)






               if val ~= nil then
                  if comp.storageType == "scalar" and type(val) == "table" then
                     val = (val).value
                  end
                  (archColumn)[rowStart + k] = val
               end
            end
         end
      end
   end)
end





local function loadRowMajor(world, reader)
   world:defer()
   while true do
      local row = reader:readRow()
      if not row then break end
      world:spawnAt(row.id,
      (table.unpack)(
      row.components, 1, row.count))
   end
   world:commit()
end


local newBufferReaderImpl
local newTableReaderImpl
local attachWorld




local function loadSnapshotImpl(world, reader)
   local worldImpl = world
   local prelude = reader:readPrelude()
   assert(prelude, "reader:readPrelude returned nil")
   assert(prelude.version == SNAPSHOT_VERSION,
   "unsupported snapshot version: " .. tostring(prelude.version))

   clearWorld(world)







   local savedAutoState = worldImpl.autoStateComponent
   worldImpl.autoStateComponent = nil

   while true do
      local componentTypes, _columnIndices, entityCount, mode = reader:nextArchetype()
      if not componentTypes then break end

      if mode == 0 then
         loadColumnMajor(worldImpl, reader, componentTypes, entityCount)
      else
         loadRowMajor(world, reader)
      end




      world:commit()
   end

   worldImpl.autoStateComponent = savedAutoState




   local allocator = worldImpl.allocator
   if prelude.nextEntityId > allocator.nextFreshSlot then
      allocator.nextFreshSlot = prelude.nextEntityId
   end



   IdAllocator.rebuildFreeStack(allocator)

   do
      local rebuildKeyIndex = (world)._rebuildKeyIndex
      if rebuildKeyIndex then
         rebuildKeyIndex(world)
      end
   end





   local handlers = {}
   local startEvent = builtins.StartSnapshotLoad()
   local startEventAny = startEvent
   startEventAny.onData = function(_self, key, cb)
      local arr = handlers[key]
      if not arr then
         arr = {}
         handlers[key] = arr
      end
      arr[#arr + 1] = cb
   end
   world:emit(0, startEvent)

   while true do
      local key, value = reader:nextData()
      if key == nil then break end
      if key == STATE_STACK_DATA_KEY then
         restoreStateStack(world, value)
         goto continue_data
      end
      if key == PIPELINE_DATA_KEY then
         restorePipelineState(world, value)
         goto continue_data
      end
      local arr = handlers[key]
      if arr then
         for i = 1, #arr do
            arr[i](value)
         end
      end
      ::continue_data::
   end
   reader:readEnd()

   local finishEvent = builtins.FinishSnapshotLoad()
   local finishEventAny = finishEvent
   finishEventAny.prelude = prelude
   world:emit(0, finishEvent)
   return prelude
end

function snapshot.loadSnapshot(world, source)
   assert(source, "loadSnapshot requires a source (snapshot table, string, or string.buffer)")

   if type(source) == "table" then
      local srcAny = source
      if srcAny.format == "table" and srcAny.snapshot ~= nil then
         source = srcAny.snapshot
      elseif srcAny.format == "binary" and srcAny.buffer ~= nil then
         source = srcAny.buffer
      end
   end

   if type(source) == "table" then
      return snapshot.loadSnapshotTable(world, source)
   end




   local buf
   if type(source) == "string" then
      buf = StringBuffer.new()
      local bufFns = buf
      bufFns.put(buf, source)
   else
      buf = source
   end

   local reader = newBufferReaderImpl(buf)
   attachWorld(reader, world)
   return loadSnapshotImpl(world, reader)
end









local function buildEntry(id, comps, count, cols)
   local entry = {}
   entry[1] = id
   for i = 1, count do
      local inst = comps[i]
      if inst == nil then
         entry[i + 1] = nil
      else


         local ct = cols[i]
         if ct and ct.serialize then
            local serialize = ct.serialize
            entry[i + 1] = serialize(inst)
         else
            entry[i + 1] = nil
         end
      end
   end
   return entry
end

local function buildByName()
   local byName = {}
   for _, comp in pairs(components.componentsById) do
      byName[comp.componentName] = comp
   end
   return byName
end





local function resolveInstanceByName(byName, name)
   local base, targetStr = name:match("^(.-)%->([%d%.]+)$")
   if not base then return nil end
   local container = byName[base]
   if not container then return nil end
   local target = tonumber(targetStr)
   if not target then return nil end
   return (container)(target)
end




local function expandEntry(entry, componentTypes, comps, world)
   local rawId = entry[1]
   local id
   local ty = type(rawId)
   if ty == "number" then
      id = rawId
   elseif ty == "string" then
      id = tonumber(rawId)
   end
   if not id then return nil, 0 end

   local width = #componentTypes
   for i = 1, width do
      local ct = componentTypes[i]
      local data = entry[i + 1]
      if ct and data ~= nil and ct.deserialize then
         comps[i] = ct.deserialize(world, data)
      else
         comps[i] = nil
      end
   end
   return id, width
end



local worldAttachers = setmetatable(
{},
{ __mode = "k" })


attachWorld = function(reader, world)
   local fn = worldAttachers[reader]
   if fn then fn(reader, world) end
end









local TableWriterImpl = {}






local TABLE_WRITER_MT = { __index = TableWriterImpl }

function TableWriterImpl:writePrelude(
   version,
   nextEntityId,
   _entityCount,
   _archetypeCount,
   componentTable)




   local strippedTable = {}
   for i = 1, #componentTable do
      strippedTable[i] = { name = componentTable[i].name }
   end
   self._snap = {
      version = version,
      nextEntityId = nextEntityId,
      componentTable = strippedTable,
      archetypes = {},
      data = {},
   }
end

function TableWriterImpl:startArchetype(
   _columnCount,
   _entityCount,
   columnIndices,
   _mode)
   local entry = {
      columnIndices = columnIndices,
      entities = {},
   }
   self._currentArch = entry
   self._columnBuffers = {}
   self._columnCounts = {}
   for i = 1, #columnIndices do
      self._columnBuffers[i] = {}
      self._columnCounts[i] = 0
   end
   local archs = self._snap.archetypes
   archs[#archs + 1] = entry
end

function TableWriterImpl:writeIds(idsArray, count)


   local ids = {}

   if type(idsArray) == "cdata" then
      for k = 0, count - 1 do
         ids[k + 1] = (idsArray)[k]
      end
   else
      local arr = idsArray
      table_move(arr, 1, count, 1, ids)
   end
   (self._currentArch)._pendingIds = ids
end






function TableWriterImpl:writeColumnValue(colIdx, value, comp)



   local k = self._columnCounts[colIdx] + 1
   self._columnCounts[colIdx] = k
   if comp.serialize then
      self._columnBuffers[colIdx][k] = comp.serialize(value)
   end
end

function TableWriterImpl:writeEntity(id, comps, count, cols)

   local entry = buildEntry(id, comps, count, cols)
   local entities = self._currentArch.entities
   entities[#entities + 1] = entry
end

function TableWriterImpl:endArchetype()


   local arch = self._currentArch
   local pendingIds = arch._pendingIds
   if pendingIds then
      local entities = self._currentArch.entities
      local nCols = #self._columnBuffers
      for k = 1, #pendingIds do
         local row = { pendingIds[k] }
         for c = 1, nCols do
            row[c + 1] = self._columnBuffers[c][k]
         end
         entities[#entities + 1] = row
      end
   end




   arch._pendingIds = nil
   self._currentArch = nil
   self._columnBuffers = nil
end

function TableWriterImpl:writeData(key, value)
   local data = self._snap.data
   data[#data + 1] = { key = key, value = value }
end

function TableWriterImpl:writeDataEnd() end

function TableWriterImpl:writeEnd() end

function newTableWriterImpl()
   local impl = setmetatable({}, TABLE_WRITER_MT)
   local function get() return impl._snap end
   return impl, get
end




local TableReaderImpl = {}










local TABLE_READER_MT = { __index = TableReaderImpl }

function TableReaderImpl:readPrelude()
   local snap = self._snap
   local archs = snap.archetypes
   local total = 0
   for i = 1, #archs do
      total = total + #(archs[i].entities)
   end
   return {
      version = snap.version,
      nextEntityId = snap.nextEntityId,
      entityCount = total,
      archetypeCount = #archs,
      componentTable = snap.componentTable,
   }
end

function TableReaderImpl:nextArchetype()
   local archs = self._snap.archetypes
   local idx = self._archCursor + 1
   if idx > #archs then return nil, nil, 0, 0 end
   self._archCursor = idx
   self._entityCursor = 0
   local entry = archs[idx]
   local ents = entry.entities


   if not self._byName then self._byName = buildByName() end
   local componentTable = self._snap.componentTable
   local columnIndices = entry.columnIndices
   local compTypes = {}
   for i = 1, #columnIndices do
      local nameEntry = componentTable[columnIndices[i]]
      local comp = self._byName[nameEntry.name]
      if not comp then
         comp = resolveInstanceByName(self._byName, nameEntry.name)
      end
      compTypes[i] = comp
   end
   self._currentTypes = compTypes

   return compTypes, columnIndices, #ents, 1
end

function TableReaderImpl:readIds(_count)
   error("TableReader: readIds not used (table reader always reports row mode)")
end

function TableReaderImpl:readColumnRawInto(_destBase, _byteOffset, _byteCount)
   error("TableReader: readColumnRawInto not used (table reader always reports row mode)")
end

function TableReaderImpl:readColumnValue(_colIdx, _world)
   error("TableReader: readColumnValue not used (table reader always reports row mode)")
end

function TableReaderImpl:schemaMatchesForColumn(_colIdx)



   return true
end

function TableReaderImpl:readRow()
   local archs = self._snap.archetypes
   local archIdx = self._archCursor
   if archIdx == 0 or archIdx > #archs then return nil end
   local entities = archs[archIdx].entities
   local idx = self._entityCursor + 1
   if idx > #entities then return nil end
   self._entityCursor = idx
   local entry = entities[idx]

   local row = self._rowScratch
   if not row then row = { components = {} }; self._rowScratch = row end
   local comps = row.components
   local id, width = expandEntry(entry, self._currentTypes, comps, self._world)
   if not id then return nil end
   local packed = 0
   for i = 1, width do
      local comp = comps[i]
      if comp ~= nil then
         packed = packed + 1
         comps[packed] = comp
      end
   end
   for i = packed + 1, width do
      comps[i] = nil
   end
   row.id = id
   row.count = packed
   return row
end

function TableReaderImpl:nextData()
   local data = self._snap.data
   if not data then return nil, nil end
   local idx = (self._dataCursor or 0) + 1
   if idx > #data then return nil, nil end
   self._dataCursor = idx
   local entry = data[idx]
   return entry.key, entry.value
end

function TableReaderImpl:readEnd() end

function newTableReaderImpl(snap)
   assert(snap, "newTableReader requires a snapshot")
   local impl = setmetatable({
      _snap = snap,
      _archCursor = 0,
      _entityCursor = 0,
   }, TABLE_READER_MT)
   worldAttachers[impl] = function(r, w)
      (r)._world = w
   end
   return impl
end


































local BufferWriterImpl = {}



local BUFFER_WRITER_MT = { __index = BufferWriterImpl }

function BufferWriterImpl:writePrelude(
   version,
   nextEntityId,
   entityCount,
   archetypeCount,
   componentTable)
   local buf = self._buf
   local encode = (buf).encode
   encode(buf, version)
   encode(buf, nextEntityId)
   encode(buf, entityCount)
   encode(buf, archetypeCount)
   local componentCount = #(componentTable)
   encode(buf, componentCount)
   for i = 1, componentCount do
      local entry = componentTable[i]
      encode(buf, entry.name)
      encode(buf, entry.fingerprint)
   end
end

function BufferWriterImpl:startArchetype(
   columnCount,
   entityCount,
   columnIndices,
   mode)
   local buf = self._buf
   local encode = (buf).encode
   encode(buf, columnCount)
   encode(buf, entityCount)
   for i = 1, columnCount do
      encode(buf, columnIndices[i])
   end
   encode(buf, mode)
end

function BufferWriterImpl:writeIds(idsArray, count)


   local put = (self._buf).putcdata
   put(self._buf, idsArray, count * 8)
end

function BufferWriterImpl:writeColumnRaw(_colIdx, srcPtr, byteCount)


   local put = (self._buf).putcdata
   put(self._buf, srcPtr, byteCount)
end

function BufferWriterImpl:writeColumnValue(_colIdx, value, comp)

   local buf = self._buf
   local compI = comp
   if compI.serializeRaw then
      compI.serializeRaw(value, buf)
   elseif comp.serialize then
      BUF_ENCODE(buf, comp.serialize(value))
   else
      BUF_ENCODE(buf, nil)
   end
end

function BufferWriterImpl:writeEntity(id, comps, count, cols)




   if count > ROW_MASK_MAX_COLUMNS then
      error("snapshot: row-major archetype exceeds " .. ROW_MASK_MAX_COLUMNS .. " columns")
   end
   local buf = self._buf
   local encode = BUF_ENCODE
   encode(buf, id)
   local mask = 0
   for i = 1, count do
      if comps[i] ~= nil then
         mask = mask + POW2[i]
      end
   end
   encode(buf, mask)
   for i = 1, count do
      local inst = comps[i]
      if inst ~= nil then



         local ct = cols[i]
         if ct.serializeRaw then
            ct.serializeRaw(inst, buf)
         elseif ct.serialize then
            encode(buf, ct.serialize(inst))
         else
            encode(buf, nil)
         end
      end
   end
end

function BufferWriterImpl:endArchetype() end

function BufferWriterImpl:writeData(key, value)


   local buf = self._buf
   local encode = (buf).encode
   encode(buf, true)
   encode(buf, key)
   encode(buf, value)
end

function BufferWriterImpl:writeDataEnd()
   local buf = self._buf
   local encode = (buf).encode
   encode(buf, false)
end

function BufferWriterImpl:writeEnd() end

function newBufferWriterImpl(buf)
   assert(buf, "newBufferWriter requires a LuaJIT string.buffer")
   local impl = setmetatable({
      _buf = buf,
   }, BUFFER_WRITER_MT)
   return impl
end












local BufferReaderImpl = {}












local BUFFER_READER_MT = { __index = BufferReaderImpl }

local function bufEmpty(buf)
   return (#(buf)) == 0
end

function BufferReaderImpl:readPrelude()
   local buf = self._buf
   local decode = (buf).decode
   local version = decode(buf)
   local nextEntityId = decode(buf)
   local entityCount = decode(buf)
   local archetypeCount = decode(buf)





   local componentCount = decode(buf)
   if not self._byName then self._byName = buildByName() end
   local componentTable = {}
   local resolved = {}
   for i = 1, componentCount do
      local name = decode(buf)
      local fingerprint = decode(buf)
      componentTable[i] = { name = name, fingerprint = fingerprint }
      local comp = self._byName[name]
      if not comp then
         comp = resolveInstanceByName(self._byName, name)
      end



      if not comp then
         error("loadSnapshot: snapshot references component '" .. name ..
         "' which is not registered in this world; register it before loading", 0)
      end
      local currentSchema = (comp).fingerprint or ""
      local match = (fingerprint == currentSchema)
      local migrate = nil
      if not match and fingerprint ~= "" then
         if (comp).deserializeRaw then



            migrate = buildMigrator(comp, fingerprint)
         elseif currentSchema == "" then
            error("loadSnapshot: component '" .. name ..
            "' was saved as an FFI struct but is now registered without one; cannot migrate", 0)
         end



      end
      resolved[i] = {
         comp = comp,
         schemaMatch = match,
         savedFingerprint = fingerprint,
         migrate = migrate,
      }
   end
   self._resolvedTable = resolved
   self._archetypesRemaining = archetypeCount

   return {
      version = version,
      nextEntityId = nextEntityId,
      entityCount = entityCount,
      archetypeCount = archetypeCount,
      componentTable = componentTable,
   }
end

function BufferReaderImpl:nextArchetype()
   if self._archetypesRemaining <= 0 then return nil, nil, 0, 0 end
   self._archetypesRemaining = self._archetypesRemaining - 1
   if bufEmpty(self._buf) then return nil, nil, 0, 0 end
   local buf = self._buf
   local decode = (buf).decode
   local columnCount = decode(buf)
   if columnCount == nil then return nil, nil, 0, 0 end
   local entityCount = decode(buf)
   local indices = {}
   local compTypes = {}
   for i = 1, columnCount do
      local idx = decode(buf)
      indices[i] = idx
      compTypes[i] = self._resolvedTable[idx].comp
   end
   local mode = decode(buf)
   self._currentTypes = compTypes
   self._currentIndices = indices
   self._currentMode = mode
   self._archRemaining = entityCount
   return compTypes, indices, entityCount, mode
end

function BufferReaderImpl:readIds(count)

   local buf = self._buf
   local ref = (buf).ref
   local skip = (buf).skip
   local bytes = count * 8
   local ids = ffiNew(doubleArrayType, count)
   ffiCopy(ids, ref(buf), bytes)
   skip(buf, bytes)
   return ids
end

function BufferReaderImpl:readColumnRawInto(destBase, byteOffset, byteCount)


   local buf = self._buf
   local ref = (buf).ref
   local skip = (buf).skip
   ffiCopy(ffiOffsetCharPtr(destBase, byteOffset), ref(buf), byteCount)
   skip(buf, byteCount)
end

function BufferReaderImpl:schemaMatchesForColumn(colIdx)
   local compIdx = self._currentIndices[colIdx]
   return self._resolvedTable[compIdx].schemaMatch
end





function BufferReaderImpl:_decodeOne(colIdx, world)
   local buf = self._buf
   local compIdx = self._currentIndices[colIdx]
   local resolved = self._resolvedTable[compIdx]
   local ct = resolved.comp
   if resolved.migrate then
      return resolved.migrate(buf)
   end
   local ctI = ct
   if ct and ctI.deserializeRaw then
      return ctI.deserializeRaw(buf)
   elseif ct and ct.deserialize then
      local payload = BUF_DECODE(buf)





      if payload == nil then return nil end
      return ct.deserialize(world, payload)
   else
      BUF_DECODE(buf)
      return nil
   end
end

function BufferReaderImpl:readColumnValue(colIdx, world)
   return self:_decodeOne(colIdx, world)
end

function BufferReaderImpl:readRow()
   if self._archRemaining <= 0 then return nil end
   self._archRemaining = self._archRemaining - 1
   local buf = self._buf
   local decode = BUF_DECODE
   local id = decode(buf)
   local mask = decode(buf)
   local compTypes = self._currentTypes
   local width = #compTypes
   local row = self._rowScratch
   if not row then row = { components = {} }; self._rowScratch = row end
   local comps = row.components
   for i = 1, width do
      local p = POW2[i]
      if mask % (p + p) >= p then
         comps[i] = self:_decodeOne(i, self._world)
      else
         comps[i] = nil
      end
   end
   local packed = 0
   for i = 1, width do
      local comp = comps[i]
      if comp ~= nil then
         packed = packed + 1
         comps[packed] = comp
      end
   end
   for i = packed + 1, width do
      comps[i] = nil
   end
   row.id = id
   row.count = packed
   return row
end

function BufferReaderImpl:nextData()
   local buf = self._buf
   local decode = (buf).decode
   local more = decode(buf)
   if not more then return nil, nil end
   local key = decode(buf)
   local value = decode(buf)
   return key, value
end

function BufferReaderImpl:readEnd() end

function newBufferReaderImpl(buf)
   assert(buf, "newBufferReader requires a LuaJIT string.buffer")
   local impl = setmetatable({
      _buf = buf,
      _archRemaining = 0,
      _archetypesRemaining = 0,
   }, BUFFER_READER_MT)
   worldAttachers[impl] = function(r, w)
      (r)._world = w
   end
   return impl
end





function snapshot.saveSnapshotTable(world, opts)
   local writer, get = newTableWriterImpl()
   saveSnapshotImpl(world, writer, opts or {})
   return get()
end

function snapshot.loadSnapshotTable(world, snap)
   local reader = newTableReaderImpl(snap)
   attachWorld(reader, world)
   return loadSnapshotImpl(world, reader)
end

return snapshot
