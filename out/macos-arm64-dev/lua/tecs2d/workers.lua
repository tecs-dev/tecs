
















local ffi = require("ffi")
local buffer = require("string.buffer")
local loader = require("tecs2d.ffi.loader")

loader.declare("worker")

local C, libraryPath =
loader.library("tecs2dworker", "tecs2d", "TECS2D_WORKER_PATH")


local FOREVER = -1

local Channel = {}




local Worker = {}








local workers = {}






workers.Channel = Channel
workers.Worker = Worker
workers.path = libraryPath

local ChannelMT = { __index = Channel }
local WorkerMT = { __index = Worker }

local messageOut = loader.newArray("void*[1]")






function Channel.create()
   local handle = C.tecs2dChannelCreate()
   if handle == nil then error("tecs2d: cannot create channel", 2) end
   local self = setmetatable({}, ChannelMT)
   self.handle = handle
   self._destroyed = false
   return self
end


function Channel.wrap(handle)
   local self = setmetatable({}, ChannelMT)
   self.handle = handle

   self._destroyed = true
   return self
end




local SENDABLE = {
   number = true, string = true, boolean = true, ["nil"] = true,
}








local function unsendable(value, path, depth)
   local kind = type(value)
   if SENDABLE[kind] then return nil end
   if kind ~= "table" then
      return ("%s is a %s"):format(path, kind)
   end
   if depth > 32 then
      return ("%s nests deeper than 32 levels"):format(path)
   end
   for key, item in pairs(value) do
      if not SENDABLE[type(key)] then
         return ("%s has a %s key"):format(path, type(key))
      end
      local found = unsendable(item, ("%s.%s"):format(path, tostring(key)),
      depth + 1)
      if found ~= nil then return found end
   end
   return nil
end


function Channel:send(value)
   local rejected = unsendable(value, "value", 0)
   if rejected ~= nil then
      error(("tecs2d: cannot send to a worker: %s"):format(rejected), 2)
   end



   local encoded = buffer.encode(value)
   if not C.tecs2dChannelPush(self.handle, encoded, #encoded) then
      error("tecs2d: channel send failed", 2)
   end
end





function Channel:receive(timeoutMs)
   local size = tonumber(
   C.tecs2dChannelPop(self.handle, messageOut, timeoutMs or 0))
   if size == 0 then return nil end

   local message = messageOut[0]
   local payload = C.tecs2dChannelData(message)


   local encoded = ffi.string(payload, size)
   C.tecs2dChannelFree(message)
   return buffer.decode(encoded)
end


function Channel:count()
   return tonumber(C.tecs2dChannelCount(self.handle))
end


function Channel:close()
   C.tecs2dChannelClose(self.handle)
end


function Channel:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.tecs2dChannelDestroy(self.handle)
   self.handle = nil
end















function workers.spawn(options)
   if options.source == nil then
      error("tecs2d: a worker needs source", 2)
   end

   local toWorker = Channel.create()
   local fromWorker = Channel.create()

   local handle = C.tecs2dWorkerSpawn(options.source,
   options.luaPath or package.path, toWorker.handle, fromWorker.handle)
   if handle == nil then
      toWorker:destroy()
      fromWorker:destroy()
      error("tecs2d: cannot spawn worker", 2)
   end

   local self = setmetatable({}, WorkerMT)
   self._handle = handle
   self._toWorker = toWorker
   self._fromWorker = fromWorker
   self._joined = false
   self.pending = 0
   return self
end


function Worker:send(value)
   self._toWorker:send(value)
   self.pending = self._toWorker:count()
end


function Worker:receive(timeoutMs)
   return self._fromWorker:receive(timeoutMs)
end


function Worker:available()
   return self._fromWorker:count()
end





function Worker:stop()
   if self._joined then return 0 end
   self._joined = true
   self._toWorker:close()
   local status = tonumber(C.tecs2dWorkerJoin(self._handle))
   self._handle = nil
   self._toWorker:destroy()
   self._fromWorker:destroy()
   return status
end
















function workers.current()
   local globals = _G
   local inbox = globals["__tecs2dWorkerIn"]
   local outbox = globals["__tecs2dWorkerOut"]
   if inbox == nil or outbox == nil then
      error("tecs2d: workers.current is only valid inside a worker", 2)
   end

   local incoming = Channel.wrap(ffi.cast("void *", inbox))
   local results = Channel.wrap(ffi.cast("void *", outbox))

   return {
      receive = function(_self, timeoutMs)
         return incoming:receive(timeoutMs or FOREVER)
      end,
      send = function(_self, value)
         results:send(value)
      end,
   }
end

return workers
