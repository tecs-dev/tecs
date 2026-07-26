

















local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local workers = require("tecs2d.workers")

local C = sdl.C


local DECODER = [==[
local sdl = require("tecs2d.ffi.sdl3")
local image = require("tecs2d.ffi.sdl3image")
local workers = require("tecs2d.workers")

local C = sdl.C
local IMG = image.C

-- SDL_PIXELFORMAT_RGBA32 is a byte-order alias resolved by the preprocessor,
-- so it never reaches the cdef. On a little-endian host it is ABGR8888.
local RGBA32 = C.SDL_PIXELFORMAT_ABGR8888

local self = workers.current()

while true do
    local task = self:receive()
    if task == nil then break end

    local surface = IMG.IMG_Load(task.path)
    if surface == nil then
        self:send({ id = task.id, error = "cannot decode " .. task.path })
    else
        -- Normalising here means the upload path handles exactly one layout,
        -- and the conversion cost lands off the main thread with the decode.
        local converted = C.SDL_ConvertSurface(surface, RGBA32)
        C.SDL_DestroySurface(surface)
        if converted == nil then
            self:send({ id = task.id, error = "cannot convert " .. task.path })
        else
            self:send({
                id = task.id,
                surface = tonumber(require("ffi").cast("uintptr_t", converted)),
                width = converted.w,
                height = converted.h,
                pitch = converted.pitch,
            })
        end
    end
end
]==]

local Handle = {}














local assets = {}



local HandleMT = { __index = Handle }

local pending = {}
local nextId = 1
local worker = nil


function assets.install(luaPath)
   worker = workers.spawn({
      source = DECODER,
      luaPath = luaPath or package.path,
   })
end


function assets.loadImage(path)
   if worker == nil then
      error("tecs2d: assets.install must run before loading", 2)
   end

   local handle = setmetatable({ status = "loading", path = path },
   HandleMT)
   local id = nextId
   nextId = nextId + 1
   pending[id] = handle
   worker:send({ id = id, path = path })
   return handle
end


local function complete(result)
   local id = result.id
   local handle = pending[id]
   pending[id] = nil
   if handle == nil then return false end

   if result.error ~= nil then
      handle.status = "failed"
      handle.error = result.error
      return true
   end



   local surface = ffi.cast("SDL_Surface *",
   ffi.cast("uintptr_t", result.surface))
   handle._surface = surface
   handle.pixels = surface.pixels
   handle.width = result.width
   handle.height = result.height
   handle.pitch = result.pitch
   handle.status = "ready"
   return true
end





function Handle:release()
   if self._surface == nil then return end
   C.SDL_DestroySurface(self._surface)
   self._surface = nil
   self.pixels = nil
end


function assets.update()
   if worker == nil then return 0 end
   local completed = 0
   while true do
      local result = worker:receive(0)
      if result == nil then break end
      if complete(result) then completed = completed + 1 end
   end
   return completed
end


function assets.pending()
   local count = 0
   for _ in pairs(pending) do count = count + 1 end
   return count
end




function assets.waitAll(timeoutMs)
   local remaining = timeoutMs or 5000
   while assets.pending() > 0 and remaining > 0 do
      local result = worker:receive(16)
      if result ~= nil then complete(result) end
      remaining = remaining - 16
   end
end


function assets.shutdown()
   if worker == nil then return end
   worker:stop()
   worker = nil
   pending = {}
end

return assets
