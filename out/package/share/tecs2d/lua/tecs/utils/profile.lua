



















local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local table_remove = table.remove

local logging = require("tecs.utils.logging")
local log = logging.getLogger("tecs.profile")

local profile = { SampleOptions = {}, TraceOptions = {}, AbortSite = {}, TraceReport = {}, SampleSession = {}, TraceSession = {} }



































































































local function loadUntyped(modName)
   return require(modName)
end

local zone = loadUntyped("jit.zone")
local zoneMeta = getmetatable(zone)

local function noopCall(_t, _name) end



local zoneVersion = 0





local function realCall(t, name)
   local arr = t
   zoneVersion = zoneVersion + 1
   if name then
      arr[#arr + 1] = name
   else
      return table_remove(arr)
   end
end

local zoneRefs = 0

local function acquireZones()
   zoneRefs = zoneRefs + 1
   if zoneRefs == 1 then
      zoneMeta.__call = realCall
   end
end

local function releaseZones()
   zoneRefs = zoneRefs - 1
   if zoneRefs <= 0 then
      zoneRefs = 0
      local arr = zone
      for i = #arr, 1, -1 do arr[i] = nil end
      zoneMeta.__call = noopCall
   end
end

local function activeZpath()
   local d = #zone
   if d == 0 then return "" end
   local buf = {}
   for i = 1, d do buf[i] = zone[i] end
   return table_concat(buf, "/", 1, d)
end





local jitProfile = loadUntyped("jit.profile")
local dumpstack = jitProfile.dumpstack
local profileStart = jitProfile.start
local profileStop = jitProfile.stop

local ROOT = "<root>"












local function sanitize(s)
   return (s:gsub("[;\n\r]", "_"))
end

local function dominantVm(r)
   local best = "N"
   local bestCount = r.N
   if r.I > bestCount then best, bestCount = "I", r.I end
   if r.C > bestCount then best, bestCount = "C", r.C end
   if r.G > bestCount then best, bestCount = "G", r.G end
   if r.J > bestCount then best, bestCount = "J", r.J end
   return best
end

local function splitInto(s, sep, out, offset)
   local n = offset
   if s == "" or s == ROOT then return n end
   local start = 1
   local len = #s
   for i = 1, len do
      if s:sub(i, i) == sep then
         if i > start then
            n = n + 1
            out[n] = sanitize(s:sub(start, i - 1))
         end
         start = i + 1
      end
   end
   if start <= len then
      n = n + 1
      out[n] = sanitize(s:sub(start))
   end
   return n
end







local function encodeCollapsed(agg)
   local entries = {}
   local count = 0
   for _, inner in pairs(agg) do
      for _, rec in pairs(inner) do
         count = count + 1
         entries[count] = rec
      end
   end
   if count == 0 then return "" end

   table_sort(entries, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      if a.zpath ~= b.zpath then return a.zpath < b.zpath end
      return a.stack < b.stack
   end)

   local lines = {}
   local frames = {}
   for i = 1, count do
      local rec = entries[i]
      for k = #frames, 1, -1 do frames[k] = nil end
      local n = splitInto(rec.zpath, "/", frames, 0)
      n = splitInto(rec.stack, ";", frames, n)
      if n == 0 then
         n = 1
         frames[1] = ROOT
      end
      frames[n] = frames[n] .. "_[" .. dominantVm(rec) .. "]"
      lines[i] = table_concat(frames, ";", 1, n) .. " " .. string_format("%d", rec.n)
   end
   return table_concat(lines, "\n")
end

local function filterByZone(agg, prefix)
   if not prefix or prefix == "" then return agg end
   local out = {}
   local plen = #prefix
   for zpath, inner in pairs(agg) do
      if zpath:sub(1, plen) == prefix then
         out[zpath] = inner
      end
   end
   return out
end

local sampleActive = false

local SAMPLE_MT = {
   __index = profile.SampleSession,
}

function profile.sample(opts)
   if sampleActive then
      error("profile.sample: a sample session is already active; call :stop() first", 2)
   end
   opts = opts or {}
   local intervalMs = opts.intervalMs or 10
   local stackDepth = -(opts.stackDepth or 16)
   local zoneFilter = opts.zone

   local agg = {}
   local zbuf = {}
   local paused = false






   local cachedVersion = -1
   local cachedZpath = ROOT
   local cachedInner = nil

   local function callback(th, n, vmstate)
      if paused then return end
      local zpath
      local inner
      if zoneVersion == cachedVersion then
         zpath = cachedZpath
         inner = cachedInner
      else
         local d = #zone
         if d == 0 then
            zpath = ROOT
         else
            for i = 1, d do zbuf[i] = zone[i] end
            zpath = table_concat(zbuf, "/", 1, d)
         end
         inner = agg[zpath]
         if not inner then
            inner = {}
            agg[zpath] = inner
         end
         cachedVersion = zoneVersion
         cachedZpath = zpath
         cachedInner = inner
      end
      local stack
      if th then
         stack = dumpstack(th, "lZ;", stackDepth)
      else
         stack = ""
      end
      local r = inner[stack]
      if not r then
         r = { n = 0, N = 0, I = 0, C = 0, G = 0, J = 0, zpath = zpath, stack = stack }
         inner[stack] = r
      end
      r.n = r.n + n
      if vmstate == "N" then r.N = r.N + n
      elseif vmstate == "I" then r.I = r.I + n
      elseif vmstate == "C" then r.C = r.C + n
      elseif vmstate == "G" then r.G = r.G + n
      elseif vmstate == "J" then r.J = r.J + n
      end
   end

   acquireZones()
   profileStart("li" .. string_format("%d", intervalMs), callback)
   sampleActive = true

   log:info("sample session started (intervalMs=%d, zone=%s)",
   intervalMs, zoneFilter or "*")

   local session = setmetatable({
      _agg = agg,
      _zoneFilter = zoneFilter,
      _stopped = false,
      _setPaused = function(v) paused = v end,
   }, SAMPLE_MT)
   return session
end

function profile.SampleSession:pause()
   local s = self
   if s._stopped then
      error("SampleSession:pause: session already stopped", 2)
   end
   (s._setPaused)(true)
end

function profile.SampleSession:resume()
   local s = self
   if s._stopped then
      error("SampleSession:resume: session already stopped", 2)
   end
   (s._setPaused)(false)
end

local function writeToFile(path, text)
   local f, err = io.open(path, "w")
   if not f then
      error("profile: cannot write '" .. path .. "': " .. (err or "unknown"), 3)
   end
   local ok, writeErr = f:write(text)
   if not ok then
      f:close()
      error("profile: cannot write '" .. path .. "': " .. (writeErr or "unknown"), 3)
   end
   local closeOk, closeErr = f:close()
   if not closeOk then
      error("profile: cannot close '" .. path .. "': " .. (closeErr or "unknown"), 3)
   end
end

function profile.SampleSession:stop(filename)
   local s = self
   if s._stopped then
      error("SampleSession:stop: session already stopped", 2)
   end
   s._stopped = true
   profileStop()
   sampleActive = false
   releaseZones()
   local filtered = filterByZone(s._agg, s._zoneFilter)
   local text = encodeCollapsed(filtered)
   if filename then
      writeToFile(filename, text)
      log:info("sample session stopped, %d bytes written to %s", #text, filename)
   else
      log:info("sample session stopped, %d bytes of collapsed-stack text", #text)
   end
   return text
end





local jitAttach = ((_G).jit).attach



local vmdef = loadUntyped("jit.vmdef")
local traceerr = vmdef.traceerr
local bcnames = vmdef.bcnames

local funcinfo
do
   local ok, util = pcall(loadUntyped, "jit.util")
   if ok and util then
      funcinfo = (util).funcinfo
   end
end

local function bcName(opcode)
   if not bcnames then return string_format("op%d", opcode) end
   local idx = opcode * 6 + 1
   local s = bcnames:sub(idx, idx + 5)
   return (s:gsub("%s+$", ""))
end

local function reasonText(otr, oex)
   if not otr then return "abort" end
   local fmt = traceerr[otr]
   if not fmt then return string_format("error %d", otr) end
   if fmt:find("NYI: bytecode", 1, true) and type(oex) == "number" then
      return "NYI: bytecode " .. bcName(oex)
   end
   if oex == nil then return fmt end
   local ok, s = pcall(string_format, fmt, oex)
   if ok then return s end
   return fmt
end

local function classify(reason)
   if reason:find("blacklist", 1, true) then return "blacklist" end
   if reason:find("leaving loop", 1, true) then return "info" end
   if reason:find("inner loop", 1, true) then return "info" end
   if reason:find("down%-recursion") then return "info" end
   if reason:find("up%-recursion") then return "info" end
   return "warn"
end

local function severityRank(s)
   if s == "blacklist" then return 0 end
   if s == "warn" then return 1 end
   return 2
end





local function trimAt(src)
   if src:sub(1, 1) == "@" then return src:sub(2) end
   return src
end

local function describeLocation(func, pc)
   if funcinfo and func then
      local ok, fi = pcall(funcinfo, func, pc)
      if ok and fi then
         local src = (fi).short_src or (fi).source or "?"
         local line = (fi).currentline or (fi).linedefined or 0
         return string_format("%s:%d", trimAt(src), line)
      end
   end
   if type(func) == "function" then
      local info = debug.getinfo(func, "S")
      local src = (info and info.short_src) or "?"
      local line = (info and info.linedefined) or 0
      return string_format("%s:%d", trimAt(src), line)
   end
   return "?:0"
end



local function csvField(s)
   if s:find("[,\"\n\r]") then
      return "\"" .. s:gsub("\"", "\"\"") .. "\""
   end
   return s
end

local function serializeTraceReport(r)
   local lines = { "severity,count,reason,location,zone" }
   for i = 1, #r.sites do
      local s = r.sites[i]
      lines[#lines + 1] = table_concat({
         s.severity,
         string_format("%d", s.count),
         csvField(s.reason),
         csvField(s.location),
         csvField(s.zone),
      }, ",")
   end
   return table_concat(lines, "\n")
end

local TRACE_REPORT_MT = {
   __tostring = function(self)
      return serializeTraceReport(self)
   end,
}

local TRACE_MT = {
   __index = profile.TraceSession,
}

local traceActive = false

function profile.trace(opts)
   if traceActive then
      error("profile.trace: a trace session is already active; call :stop() first", 2)
   end
   opts = opts or {}
   local includeBenign = opts.includeBenign or false

   local sites = {}
   local counters = { total = 0, black = 0 }
   local startTime = os.time()
   local paused = false

   local function callback(what, _tr, func, pc, otr, oex)
      if what ~= "abort" or paused then return end
      local reason = reasonText(otr, oex)
      local sev = classify(reason)
      if not includeBenign and sev == "info" then return end

      counters.total = counters.total + 1
      if sev == "blacklist" then counters.black = counters.black + 1 end

      local location = describeLocation(func, pc)
      local zpath = activeZpath()
      local key = sev .. "|" .. reason .. "|" .. location .. "|" .. zpath
      local site = sites[key]
      if site then
         site.count = site.count + 1
      else
         sites[key] = {
            severity = sev,
            count = 1,
            reason = reason,
            location = location,
            zone = zpath,
         }
      end
   end

   acquireZones()
   jitAttach(callback, "trace")
   traceActive = true

   log:info("trace session started (includeBenign=%s)", tostring(includeBenign))

   local session = setmetatable({
      _callback = callback,
      _sites = sites,
      _counters = counters,
      _startTime = startTime,
      _stopped = false,
      _setPaused = function(v) paused = v end,
   }, TRACE_MT)
   return session
end

function profile.TraceSession:pause()
   local s = self
   if s._stopped then
      error("TraceSession:pause: session already stopped", 2)
   end
   (s._setPaused)(true)
end

function profile.TraceSession:resume()
   local s = self
   if s._stopped then
      error("TraceSession:resume: session already stopped", 2)
   end
   (s._setPaused)(false)
end

function profile.TraceSession:stop(filename)
   local s = self
   if s._stopped then
      error("TraceSession:stop: session already stopped", 2)
   end
   s._stopped = true
   jitAttach(s._callback)
   traceActive = false
   releaseZones()

   local sites = {}
   for _, site in pairs(s._sites) do
      sites[#sites + 1] = site
   end
   table_sort(sites, function(a, b)
      local ra, rb = severityRank(a.severity), severityRank(b.severity)
      if ra ~= rb then return ra < rb end
      if a.count ~= b.count then return a.count > b.count end
      if a.reason ~= b.reason then return a.reason < b.reason end
      return a.location < b.location
   end)

   local counters = s._counters
   local report = setmetatable({
      durationSec = os.time() - (s._startTime),
      totalAborts = counters.total,
      blacklisted = counters.black,
      sites = sites,
   }, TRACE_REPORT_MT)
   if filename then
      writeToFile(filename, tostring(report))
      log:info("trace session stopped (%.2fs, %d aborts, %d blacklisted), report written to %s",
      report.durationSec, report.totalAborts, report.blacklisted, filename)
   else
      log:info("trace session stopped (%.2fs, %d aborts, %d blacklisted)",
      report.durationSec, report.totalAborts, report.blacklisted)
   end
   return report
end

return profile
