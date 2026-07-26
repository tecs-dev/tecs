
local ffi = require("ffi")
local string_format = string.format
local os_date = os.date
local tonumber = tonumber








ffi.cdef([[
    typedef int64_t time_t;
    time_t time(time_t *t);
]])
local TIME_NULL = ffi.cast("time_t*", 0)




local C_time
do
   local osFallback = function(_) return os.time() end
   local ok, fn = pcall(function() return ffi.C.time end)
   if ok and fn then
      local candidate = fn

      local valOk, cv = pcall(candidate, TIME_NULL)
      local diff = valOk and (tonumber(cv) - os.time()) or math.huge
      C_time = (diff > -2 and diff < 2) and candidate or osFallback
   else
      C_time = osFallback
   end
end

local logging = { Logger = {} }






















































logging.sink = io.stderr
logging.dateFormat = "%Y-%m-%d %H:%M:%S "
logging.level = "INFO"

local NO_OP = function() end
local registry = {}



local cachedTick = -1
local cachedDateStr = ""
local cachedDateFormat = ""

local function getDateStr(dateFormat)
   local tick = tonumber(C_time(TIME_NULL))
   if tick ~= cachedTick or dateFormat ~= cachedDateFormat then
      cachedTick = tick
      cachedDateFormat = dateFormat
      cachedDateStr = os_date(dateFormat)
   end
   return cachedDateStr
end

local function writeDebug(self, msg, ...)
   self.sink:write(getDateStr(self.dateFormat), self.debugPrefix, string_format(msg, ...), "\n")
end

local function writeInfo(self, msg, ...)
   self.sink:write(getDateStr(self.dateFormat), self.infoPrefix, string_format(msg, ...), "\n")
end

local function writeWarn(self, msg, ...)
   self.sink:write(getDateStr(self.dateFormat), self.warnPrefix, string_format(msg, ...), "\n")
end

local function writeError(self, msg, ...)
   self.sink:write(getDateStr(self.dateFormat), self.errorPrefix, string_format(msg, ...), "\n")
end

local function stampLogger(logger)
   local level = logging.level
   logger.debug = (level == "DEBUG") and writeDebug or NO_OP
   logger.info = (level == "INFO" or level == "DEBUG") and writeInfo or NO_OP
   logger.warn = (level ~= "OFF" and level ~= "ERROR") and writeWarn or NO_OP
   logger.error = (level ~= "OFF") and writeError or NO_OP
   logger.sink = logging.sink
   logger.dateFormat = logging.dateFormat
end

function logging.getLogger(name)
   local logger = registry[name]
   if not logger then
      logger = {
         debugPrefix = name .. " DEBUG: ",
         infoPrefix = name .. " INFO: ",
         warnPrefix = name .. " WARN: ",
         errorPrefix = name .. " ERROR: ",
      }
      stampLogger(logger)
      registry[name] = logger
   end
   return logger
end

local function restampAll()
   for _, logger in pairs(registry) do
      stampLogger(logger)
   end
end

function logging.setLevel(level)
   logging.level = level
   restampAll()
end

function logging.setSink(sink)
   logging.sink = sink
   restampAll()
end

return logging
