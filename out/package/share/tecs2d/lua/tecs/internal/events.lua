local table_clear = require("table.clear")
local table_new = require("table.new")
local C = require("ffi")
local schema = require("tecs.internal.ffi.schema")
local FFIEvents = require("tecs.internal.ffi.FFIEvents")
local types = require("tecs.types")
local pool = require("tecs.utils.pool")





local NEXT_ID = 1

local NOOP_INIT = function(_instance) end

local events = { MessageBus = {} }













































































function events.newEvent(event)
   if event.eventId then
      error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
   end

   local id = NEXT_ID
   NEXT_ID = NEXT_ID + 1
   event.eventId = id
   local MT = { __index = event }
   local eventAny = event
   local init = eventAny.init or NOOP_INIT
   eventAny.init = init

   eventAny.__tecs_mt = MT
   setmetatable(event, {
      __call = function(_self, ...)
         local instance = setmetatable({ eventId = id }, MT)
         init(instance, ...)
         return instance
      end,
   })
end

function events.newFFIEvent(
   event,
   fields,
   structName)

   if event.eventId then
      error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
   end

   schema.validateFields(fields, { eventId = true, typeId = true })

   local resolvedStructName = structName


   local nFields = #fields
   local ffiFields = table_new(nFields + 1, 0)
   ffiFields[1] = { "eventId", "int32_t" }
   for i = 1, nFields do
      ffiFields[i + 1] = fields[i]
   end


   local fieldNames = table_new(nFields, 0)
   for i = 1, nFields do
      fieldNames[i] = fields[i][1]
   end



   local ffiManager = FFIEvents.global()
   local ffiTypeId = ffiManager:registerEvent(event, ffiFields, resolvedStructName)
   resolvedStructName = ffiManager.registrations[event].structName

   local id = NEXT_ID
   NEXT_ID = NEXT_ID + 1
   event.eventId = id
   local eventAny = event
   eventAny.__tecs_ffi = true
   eventAny.__tecs_ffi_fields = ffiFields
   eventAny.__tecs_ffi_structName = resolvedStructName
   eventAny.__tecs_ffi_typeId = ffiTypeId

   local init = eventAny.init
   if not init then



      local n = #fieldNames
      local parts = { "return function(instance" }
      for i = 1, n do
         parts[#parts + 1] = ", a" .. i
      end
      parts[#parts + 1] = ")\n"
      for i = 1, n do
         parts[#parts + 1] = string.format(
         "    if a%d ~= nil then instance.%s = a%d end\n", i, fieldNames[i], i)
      end
      parts[#parts + 1] = "end"
      local chunk = assert(load(table.concat(parts), "=ffi_event_init", "t"))
      init = chunk()
      eventAny.init = init
   end



   local eventCtype = C.typeof(resolvedStructName)
   setmetatable(event, {
      __call = function(_self, ...)
         local instance = eventCtype()
         instance.eventId = id
         instance.typeId = ffiTypeId
         init(instance, ...)
         return instance
      end,
   })
end





local MessageBus = events.MessageBus

local MESSAGE_BUS_MT = {
   __index = MessageBus,
}

function MessageBus.new()
   local bus = {
      _observers = {},
      _totalObservers = 0,
      _entityObserverCount = 0,
      _emitDepth = 0,
      _callbacksPool = pool.newTablePool({ clearOn = "release" }),
      _byAddressPool = pool.newTablePool({ clearOn = "acquire" }),
   }
   return setmetatable(bus, MESSAGE_BUS_MT)
end

function MessageBus:observe(address, eventType, observer, id)
   local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")

   local byAddress = self._observers[address]
   if not byAddress then
      byAddress = self._byAddressPool:acquire()
      self._observers[address] = byAddress
   end

   local callbacks = byAddress[eventId]
   if not callbacks then
      callbacks = self._callbacksPool:acquire()
      callbacks[0] = 0
      byAddress[eventId] = callbacks
   end

   local n = callbacks[0]
   callbacks[n + 1] = id or false
   callbacks[n + 2] = observer
   callbacks[0] = n + 2
   self._totalObservers = self._totalObservers + 1
   if address ~= 0 then
      self._entityObserverCount = self._entityObserverCount + 1
   end
end

function MessageBus:observeOnce(address, eventType, observer)
   local wrappedFunction
   wrappedFunction = function(e)
      self:stopObserving(address, eventType, wrappedFunction)
      observer(e)
   end
   self:observe(address, eventType, wrappedFunction)
end



local function removeAtIndex(callbacks, idx, size)

   if idx < size - 1 then
      callbacks[idx] = callbacks[size - 1]
      callbacks[idx + 1] = callbacks[size]
   end
   callbacks[size - 1] = nil
   callbacks[size] = nil
end

function MessageBus:stopObserving(address, eventType, observerOrId)
   local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")


   if self._emitDepth > 0 then
      local deferred = self._deferredUnsubscribes
      if not deferred then
         deferred = {}
         self._deferredUnsubscribes = deferred
      end
      local n = deferred[0] or 0
      deferred[n + 1] = address
      deferred[n + 2] = eventId
      deferred[n + 3] = observerOrId
      deferred[0] = n + 3
      return
   end

   local byAddress = self._observers[address]
   if not byAddress then
      return
   end

   local callbacks = byAddress[eventId]
   if not callbacks then
      return
   end

   local size = callbacks[0]
   if size == 0 then
      return
   end
   local originalSize = size


   if type(observerOrId) == "string" then

      for i = 1, size - 1, 2 do
         if callbacks[i] == observerOrId then
            removeAtIndex(callbacks, i, size)
            size = size - 2
            break
         end
      end
   else

      local i = size - 1
      while i >= 1 do
         if callbacks[i + 1] == observerOrId then
            removeAtIndex(callbacks, i, size)
            size = size - 2
         end
         i = i - 2
      end
   end

   callbacks[0] = size

   local removed = math.floor((originalSize - size) / 2)
   self._totalObservers = self._totalObservers - removed
   if address ~= 0 then
      self._entityObserverCount = self._entityObserverCount - removed
   end

   if size == 0 then
      self._callbacksPool:release(callbacks)
      byAddress[eventId] = nil

      if next(byAddress) == nil then
         self._byAddressPool:release(byAddress)
         self._observers[address] = nil
      end
   end
end

local function processDeferredUnsubscribes(self)
   local deferred = self._deferredUnsubscribes
   if not deferred then
      return
   end

   local dSize = deferred[0] or 0
   if dSize == 0 then
      return
   end

   local observers = self._observers


   for i = 1, dSize - 2, 3 do
      local address = deferred[i]
      local eventId = deferred[i + 1]
      local observerOrId = deferred[i + 2]

      local byAddress = observers[address]
      if byAddress then
         local callbacks = byAddress[eventId]
         if callbacks then
            local size = callbacks[0]
            if size > 0 then
               local originalSize = size
               if type(observerOrId) == "string" then
                  for j = 1, size - 1, 2 do
                     if callbacks[j] == observerOrId then
                        removeAtIndex(callbacks, j, size)
                        size = size - 2
                        break
                     end
                  end
               else
                  local j = size - 1
                  while j >= 1 do
                     if callbacks[j + 1] == observerOrId then
                        removeAtIndex(callbacks, j, size)
                        size = size - 2
                     end
                     j = j - 2
                  end
               end
               callbacks[0] = size
               local removed = math.floor((originalSize - size) / 2)
               self._totalObservers = self._totalObservers - removed
               if address ~= 0 then
                  self._entityObserverCount = self._entityObserverCount - removed
               end
               if size == 0 then
                  self._callbacksPool:release(callbacks)
                  byAddress[eventId] = nil
                  if next(byAddress) == nil then
                     self._byAddressPool:release(byAddress)
                     observers[address] = nil
                  end
               end
            end
         end
      end
   end

   table_clear(deferred)
end

function MessageBus:emit(address, event)
   local byAddress = self._observers[address]
   if not byAddress then
      return
   end

   local callbacks = byAddress[event.eventId]
   if not callbacks then
      return
   end

   local size = callbacks[0]
   if size == 0 then
      return
   end

   self._emitDepth = self._emitDepth + 1


   for i = 2, size, 2 do
      (callbacks[i])(event)
   end

   self._emitDepth = self._emitDepth - 1

   if self._emitDepth == 0 then
      processDeferredUnsubscribes(self)
   end
end

function MessageBus:hasObservers(address, eventType)


   if self._totalObservers == 0 then return false end
   local byAddress = self._observers[address]
   if not byAddress then
      return false
   end
   local callbacks = byAddress[eventType.eventId]
   return callbacks ~= nil and callbacks[0] > 0
end

function MessageBus:clearAddress(address)
   local byAddress = self._observers[address]
   if byAddress then




      local pooling = self._emitDepth == 0
      local removed = 0
      for _, callbacks in pairs(byAddress) do
         removed = removed + math.floor((callbacks[0]) / 2)
         if pooling then
            self._callbacksPool:release(callbacks)
         end
      end
      if pooling then
         self._byAddressPool:release(byAddress)
      end
      self._observers[address] = nil
      self._totalObservers = self._totalObservers - removed
      if address ~= 0 then
         self._entityObserverCount = self._entityObserverCount - removed
      end
   end
end






function MessageBus:clearEntityObservers()
   if self._totalObservers == 0 then return end
   local addresses = {}
   local n = 0
   for address in pairs(self._observers) do
      if address ~= 0 then
         n = n + 1
         addresses[n] = address
      end
   end
   for i = 1, n do
      self:clearAddress(addresses[i])
   end
end

function MessageBus:reset()
   if self._totalObservers > 0 then

      if self._emitDepth == 0 then
         for _, byAddress in pairs(self._observers) do
            for _, callbacks in pairs(byAddress) do
               self._callbacksPool:release(callbacks)
            end
            self._byAddressPool:release(byAddress)
         end
      end
      table_clear(self._observers)
      self._totalObservers = 0
      self._entityObserverCount = 0
   end

   self._emitDepth = 0
   if self._deferredUnsubscribes then
      table_clear(self._deferredUnsubscribes)
   end
end

return events
