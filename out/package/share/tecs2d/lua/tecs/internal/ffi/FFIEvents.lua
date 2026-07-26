



local C = require("ffi")
local Arena = require("tecs.internal.ffi.EpochArena")

local DEFAULT_ARENA_PAGE_SIZE = 64

local FFIEvents = { EventRegistration = {}, Manager = {} }



































local definedStructs = {}
local structCounter = 0
local GLOBAL_MANAGER = nil

local function generateStructDef(name, fields)
   local parts = { "typedef struct { int32_t typeId; " }

   for i = 1, #fields do
      local tuple = fields[i]
      local fieldName = tuple[1]
      local fieldType = tuple[2]
      local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")
      if baseType and arraySize then
         parts[#parts + 1] = baseType .. " " .. fieldName .. "[" .. arraySize .. "]; "
      else
         parts[#parts + 1] = fieldType .. " " .. fieldName .. "; "
      end
   end

   parts[#parts + 1] = "} " .. name .. ";"
   return table.concat(parts)
end

local function ensureSliceArena(
   manager,
   registration,
   sliceId)

   local arena = registration.arenasBySlice[sliceId]
   if not arena then
      arena = Arena.new(registration.structName, DEFAULT_ARENA_PAGE_SIZE)
      registration.arenasBySlice[sliceId] = arena
      local list = manager.arenasPerSlice[sliceId]
      if not list then
         list = {}
         manager.arenasPerSlice[sliceId] = list
      end
      list[#list + 1] = arena
   end
   return arena
end

local FFI_EVENTS_MANAGER_MT = { __index = FFIEvents.Manager }

function FFIEvents.new()
   local manager = {
      nextTypeId = 1,
      registrations = {},
      registrationsById = {},
      nextSliceId = 1,
      freeSlices = {},
      freeSliceCount = 0,
      arenasPerSlice = {},
   }
   return setmetatable(manager, FFI_EVENTS_MANAGER_MT)
end

function FFIEvents.global()
   if not GLOBAL_MANAGER then
      GLOBAL_MANAGER = FFIEvents.new()
   end
   return GLOBAL_MANAGER
end

function FFIEvents.Manager:registerEvent(eventType, fields, structName)
   local existing = self.registrations[eventType]
   if existing then
      return existing.typeId
   end

   if not structName then
      structCounter = structCounter + 1
      structName = "FFIEvent" .. structCounter
   end

   local structDef = generateStructDef(structName, fields)
   local existingDef = definedStructs[structName]
   if existingDef then
      if existingDef ~= structDef then
         error("FFI struct name collision: '" .. structName .. "' already defined with a different layout")
      end
   else
      C.cdef(structDef)
      definedStructs[structName] = structDef
   end

   local typeId = self.nextTypeId
   self.nextTypeId = typeId + 1

   local registration = {
      typeId = typeId,
      structName = structName,
      size = C.sizeof(structName),
      arenasBySlice = {},
   }

   self.registrations[eventType] = registration
   self.registrationsById[typeId] = registration
   return typeId
end

function FFIEvents.Manager:acquireSlice()
   local count = self.freeSliceCount
   if count > 0 then
      local sliceId = self.freeSlices[count]
      self.freeSlices[count] = nil
      self.freeSliceCount = count - 1
      return sliceId
   end

   local sliceId = self.nextSliceId
   self.nextSliceId = sliceId + 1
   return sliceId
end

function FFIEvents.Manager:clearSlice(sliceId)
   local list = self.arenasPerSlice[sliceId]
   if not list then return end
   for i = 1, #list do
      list[i]:clear()
   end
end

function FFIEvents.Manager:releaseSlice(sliceId)
   self:clearSlice(sliceId)
   local nextIndex = self.freeSliceCount + 1
   self.freeSlices[nextIndex] = sliceId
   self.freeSliceCount = nextIndex
end

function FFIEvents.Manager:vendEvent(sliceId, eventType)
   local registration = self.registrations[eventType]
   if not registration then
      error("Event type not registered for FFI events")
   end

   local arena = ensureSliceArena(self, registration, sliceId)
   local data, index = arena:allocate()
   local event = (data)[index]
   C.fill(event, registration.size, 0);
   (event).typeId = registration.typeId
   return event
end

function FFIEvents.Manager:getTypeId(eventType)
   local registration = self.registrations[eventType]
   if not registration then
      return 0
   end
   return registration.typeId
end

return FFIEvents
