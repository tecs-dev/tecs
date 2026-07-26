local tecs = require("tecs")
local ffi = require("ffi")
local components = require("tecs.internal.components")
local tecsInternal = require("tecs.internal.types")

local mathPi, mathSin, mathCos, mathPow = math.pi, math.sin, math.cos, math.pow

























































































ffi.cdef([[
    typedef struct {
        double init;
        double applied;
        double lastT;
        double s1;
        double s2;
        double s3;
        double s4;
        double d1;
        double d2;
        double d3;
        double d4;
    } TweenSlotState;
]])







































local TargetImpl = {}



























































































local TimelineImpl = {}




































local TweenPlaybackImpl = {}




local TrackingTarget = {}







local TweenEvent = {}













local TweenComplete = {}


























local TweenCancelled = {}














function TweenEvent.init(e, entity, name, channel, timelineId)
   e.entity = entity
   e.name = name
   e.channel = channel
   e.timelineId = timelineId
end

function TweenComplete.init(e, entity, channel, timelineId, playback)
   e.entity = entity
   e.channel = channel
   e.timelineId = timelineId
   e.playback = playback
end

function TweenCancelled.init(e, entity, channel, timelineId, playback, reason)
   e.entity = entity
   e.channel = channel
   e.timelineId = timelineId
   e.playback = playback
   e.reason = reason
end











local REGISTRY = tecs.newKey("tecs2d.tween.registry")
local SNAPSHOT_DATA_KEY = "tecs2d.tween.registry"

local tween = {}



































































































































































































function tween.linear(t) return t end

local EASING_NAMES = {}
local EASINGS = {}

local function registerEasing(name, fn)
   EASING_NAMES[fn] = name
   EASINGS[name] = fn
end

local function makeVariants(name, inFn)
   local tw = tween
   tw[name .. "In"] = inFn
   tw[name .. "Out"] = function(t) return 1 - inFn(1 - t) end
   tw[name .. "InOut"] = function(t)
      if t < 0.5 then return 0.5 * inFn(2 * t) end
      return 1 - 0.5 * inFn(2 - 2 * t)
   end
   tw[name .. "OutIn"] = function(t)
      if t < 0.5 then return 0.5 - 0.5 * inFn(1 - 2 * t) end
      return 0.5 + 0.5 * inFn(2 * t - 1)
   end
end

makeVariants("quad", function(t) return t * t end)
makeVariants("cubic", function(t) return t * t * t end)
makeVariants("quart", function(t) return t * t * t * t end)
makeVariants("quint", function(t) return t * t * t * t * t end)
makeVariants("sine", function(t) return 1 - mathCos(t * mathPi * 0.5) end)
makeVariants("expo", function(t)
   if t == 0 then return 0 end
   return mathPow(2, 10 * (t - 1))
end)
makeVariants("back", function(t)
   local s = 1.70158
   return t * t * ((s + 1) * t - s)
end)
makeVariants("elastic", function(t)
   if t == 0 then return 0 end
   if t == 1 then return 1 end
   local p = 0.3
   return -mathPow(2, 10 * (t - 1)) * mathSin((t - 1 - p / 4) * (2 * mathPi) / p)
end)

do
   local function bounceOut(t)
      if t < 1 / 2.75 then return 7.5625 * t * t
      elseif t < 2 / 2.75 then local u = t - 1.5 / 2.75; return 7.5625 * u * u + 0.75
      elseif t < 2.5 / 2.75 then local u = t - 2.25 / 2.75; return 7.5625 * u * u + 0.9375 end
      local u = t - 2.625 / 2.75; return 7.5625 * u * u + 0.984375
   end
   local function bounceIn(t) return 1 - bounceOut(1 - t) end
   tween.bounceIn = bounceIn
   tween.bounceOut = bounceOut
   tween.bounceInOut = function(t)
      if t < 0.5 then return 0.5 * bounceIn(2 * t) end
      return 0.5 * bounceOut(2 * t - 1) + 0.5
   end
   tween.bounceOutIn = function(t)
      if t < 0.5 then return 0.5 * bounceOut(2 * t) end
      return 0.5 * bounceIn(2 * t - 1) + 0.5
   end
end

do
   local names = {
      "linear",
      "quadIn", "quadOut", "quadInOut", "quadOutIn",
      "cubicIn", "cubicOut", "cubicInOut", "cubicOutIn",
      "quartIn", "quartOut", "quartInOut", "quartOutIn",
      "quintIn", "quintOut", "quintInOut", "quintOutIn",
      "sineIn", "sineOut", "sineInOut", "sineOutIn",
      "expoIn", "expoOut", "expoInOut", "expoOutIn",
      "backIn", "backOut", "backInOut", "backOutIn",
      "elasticIn", "elasticOut", "elasticInOut", "elasticOutIn",
      "bounceIn", "bounceOut", "bounceInOut", "bounceOutIn",
   }
   local tw = tween
   for i = 1, #names do
      registerEasing(names[i], tw[names[i]])
   end
end





local function serializeState(state, count)
   local out = {}
   for i = 0, count - 1 do
      local s = state[i]
      out[i + 1] = { s.init, s.applied, s.lastT, s.s1, s.s2, s.s3, s.s4, s.d1, s.d2, s.d3, s.d4 }
   end
   return out
end

local function deserializeState(rows)
   local count = rows and #rows or 0
   local state = ffi.new("TweenSlotState[?]", count)
   for i = 1, count do
      local row = rows[i]
      local s = state[i - 1]
      s.init = row[1] or 0
      s.applied = row[2] or 0
      s.lastT = row[3] or 0
      s.s1 = row[4] or 0
      s.s2 = row[5] or 0
      s.s3 = row[6] or 0
      s.s4 = row[7] or 0
      s.d1 = row[8] or 0
      s.d2 = row[9] or 0
      s.d3 = row[10] or 0
      s.d4 = row[11] or 0
   end
   return state
end

local function serializeCursor(c)
   local children = nil
   if c.children then
      children = {}
      for i = 1, #c.children do
         children[i] = serializeCursor(c.children[i])
      end
   end
   local data = {
      playbackId = c.playbackId,
      timelineId = c.timelineId,
      elapsed = c.elapsed,
      direction = c.direction,
      mode = c.mode,
      remainingPasses = c.remainingPasses,
      nextEmit = c.nextEmit,
      rate = c.rate,
      paused = c.paused,
      delay = c.delay,
      completed = c.completed,
      cancelled = c.cancelled,
      lastCycleIndex = c._lastCycleIndex,
      stateSize = c.stateSize,
      state = serializeState(c.state, c.stateSize),
      children = children,
   }
   return data
end

local function deserializeCursor(data)
   local children = nil
   local savedChildren = data.children
   if savedChildren then
      children = {}
      for i = 1, #savedChildren do
         children[i] = deserializeCursor(savedChildren[i])
      end
   end
   return {
      playbackId = data.playbackId,
      timelineId = data.timelineId,
      stateSize = (data.stateSize) or #(data.state or {}),
      state = deserializeState(data.state),
      children = children,
      elapsed = (data.elapsed) or 0,
      direction = (data.direction) or 1,
      mode = assert(data.mode, "Tween snapshot cursor mode is required"),
      remainingPasses = assert(data.remainingPasses,
      "Tween snapshot cursor remainingPasses is required"),
      nextEmit = (data.nextEmit) or 1,
      rate = (data.rate) or 1,
      paused = data.paused == true,
      delay = (data.delay) or 0,
      completed = data.completed == true,
      cancelled = data.cancelled == true,
      _lastCycleIndex = (data.lastCycleIndex) or 0,
   }
end

tween.TweenPlayback = tecs.newComponent({
   name = "TweenPlayback",
   container = TweenPlaybackImpl,
   new = function(data)
      local cursors = {}
      local saved = data and (data.cursors)
      if saved then
         for i = 1, #saved do
            cursors[i] = deserializeCursor(saved[i])
         end
      end
      return { cursors = cursors }
   end,
   serialize = function(instance)
      local cursors = {}
      for i = 1, #(instance.cursors or {}) do
         cursors[i] = serializeCursor(instance.cursors[i])
      end
      return { cursors = cursors }
   end,
})

tween.TrackingTarget = tecs.newComponent({
   name = "TweenTrackingTarget",
   container = TrackingTarget,
   fields = { "entity", "key" },
   defaults = { 0, "" },
})

tween.TweenEvent = TweenEvent
tween.TweenComplete = TweenComplete
tween.TweenCancelled = TweenCancelled
tecs.newEvent(TweenEvent)
tecs.newEvent(TweenComplete)
tecs.newEvent(TweenCancelled)





local TARGET_MT = { __index = TargetImpl }
local targetInit


local targetApply



local function fieldsFrom(field)
   if type(field) == "string" then
      return { field }
   end
   return field
end

local function componentByName(name)
   local component = components.registeredComponents[name]
   if not component then error("Unknown tween component " .. name) end
   return component
end

local function resolveTarget(t)
   if not t.component and t.componentName then
      t.component = componentByName(t.componentName)
   end
   return t
end

local function newTarget(component, fields, mode, id)
   local parts = component.componentName
   for i = 1, #fields do
      parts = parts .. "." .. fields[i]
   end
   local t = setmetatable({
      id = id or parts,
      component = component,
      componentName = component.componentName,
      fields = fields,
      mode = mode or (#fields == 2 and "field2" or "field"),
   }, TARGET_MT)
   t.init = function(
      world, entity, relative,
      t1, t2, t3, t4)

      return targetInit(t, world, entity, relative, t1, t2, t3, t4)
   end
   t.apply = function(
      world, entity, tv,
      s1, s2, s3, s4,
      d1, d2, d3, d4)

      targetApply(t, world, entity, tv, s1, s2, s3, s4, d1, d2, d3, d4)
   end
   return t
end

targetInit = function(self,
   world, entity, relative,
   t1, t2, t3, t4)

   resolveTarget(self)
   local c = world:get(entity, self.component)
   if not c then
      return 0, 0, 0, 0, 0, 0, 0, 0
   end
   local cany = c
   local f = self.fields
   local mode = self.mode
   if mode == "color" then
      local r, g, b, a = cany[f[1]], cany[f[2]], cany[f[3]], cany[f[4]]
      if relative then return r, g, b, a, t1, t2, t3, t4 end
      return r, g, b, a, t1 - r, t2 - g, t3 - b, t4 - a
   elseif mode == "field2" then
      local a, b = cany[f[1]], cany[f[2]]
      if relative then return a, b, 0, 0, t1, t2, 0, 0 end
      return a, b, 0, 0, t1 - a, t2 - b, 0, 0
   elseif mode == "angle" then
      local startVal = cany[f[1]]
      local delta
      if relative then
         delta = t1
      else
         local twoPi = mathPi * 2
         local diff = (t1 - startVal) % twoPi
         delta = 2 * diff % twoPi - diff
      end
      return startVal, 0, 0, 0, delta, 0, 0, 0
   end
   local startVal = cany[f[1]]
   local delta = relative and t1 or (t1 - startVal)
   return startVal, 0, 0, 0, delta, 0, 0, 0
end

targetApply = function(self,
   world, entity, t,
   s1, s2, s3, s4,
   d1, d2, d3, d4)

   resolveTarget(self)
   local c = world:getMut(entity, self.component)
   if not c then return end
   local cany = c
   local f = self.fields
   local mode = self.mode
   cany[f[1]] = s1 + d1 * t
   if mode == "field2" or mode == "color" then
      cany[f[2]] = s2 + d2 * t
   end
   if mode == "color" then
      cany[f[3]] = s3 + d3 * t
      cany[f[4]] = s4 + d4 * t
   end
end

function tween.field(component, fieldName)
   return newTarget(component, { fieldName }, "field")
end

function tween.field2(component, fieldA, fieldB)
   return newTarget(component, { fieldA, fieldB }, "field2")
end

function tween.angle(component, fieldName)
   return newTarget(component, { fieldName }, "angle")
end

function tween.target(component, field)
   local fields = fieldsFrom(field)
   assert(#fields >= 1 and #fields <= 2, "tween.target supports one or two fields")
   return newTarget(component, fields)
end

local function source(
   kind, component, field,
   key, relationship)

   return {
      kind = kind,
      key = key,
      relationship = relationship,
      relationshipName = relationship and relationship.componentName or nil,
      component = component,
      componentName = component.componentName,
      fields = fieldsFrom(field),
   }
end

function tween.sourceSelf(component, field)
   return source("self", component, field)
end

function tween.sourceKey(key, component, field)
   return source("key", component, field, key)
end

function tween.sourceTrackingTarget(component, field)
   return source("trackingTarget", component, field)
end

function tween.sourceRelationship(relationship, component, field)
   return source("relationship", component, field, nil, relationship)
end

local Transform = tecs.builtins.Transform
tween.translateX = newTarget(Transform, { "x" }, "field", "transform.x")
tween.translateY = newTarget(Transform, { "y" }, "field", "transform.y")
tween.translateXY = newTarget(Transform, { "x", "y" }, "field2", "transform.xy")
tween.rotation = newTarget(Transform, { "rotation" }, "field", "transform.rotation")
tween.rotationShortest = newTarget(Transform, { "rotation" }, "angle", "transform.rotationShortest")
tween.scaleX = newTarget(Transform, { "scaleX" }, "field", "transform.scaleX")
tween.scaleY = newTarget(Transform, { "scaleY" }, "field", "transform.scaleY")
tween.scaleXY = newTarget(Transform, { "scaleX", "scaleY" }, "field2", "transform.scaleXY")



do
   local Tint = require("tecs2d.components").Tint
   tween.alpha = newTarget(Tint, { "a" }, "field", "color.a")
   tween.color = newTarget(Tint, { "r", "g", "b", "a" }, "color", "color.rgba")
end

local BUILTIN_TARGETS = {
   ["transform.x"] = tween.translateX,
   ["transform.y"] = tween.translateY,
   ["transform.xy"] = tween.translateXY,
   ["transform.rotation"] = tween.rotation,
   ["transform.rotationShortest"] = tween.rotationShortest,
   ["transform.scaleX"] = tween.scaleX,
   ["transform.scaleY"] = tween.scaleY,
   ["transform.scaleXY"] = tween.scaleXY,
   ["color.a"] = tween.alpha,
   ["color.rgba"] = tween.color,
}





local function serializeTarget(t)
   local impl = t
   return {
      id = impl.id,
      component = impl.componentName or (impl.component and impl.component.componentName),
      fields = impl.fields,
      mode = impl.mode,
   }
end

local function deserializeTarget(data)
   local id = data.id
   local builtin = id and BUILTIN_TARGETS[id]
   if builtin then return builtin end
   return newTarget(
   componentByName(data.component),
   data.fields,
   (data.mode) or "field",
   id)

end

local function serializeSource(s)
   if not s then return nil end
   local impl = s
   return {
      kind = impl.kind,
      key = impl.key,
      relationship = impl.relationshipName or (impl.relationship and impl.relationship.componentName),
      component = impl.componentName or (impl.component and impl.component.componentName),
      fields = impl.fields,
   }
end

local function deserializeSource(data)
   if not data then return nil end
   local relName = data.relationship
   return {
      kind = data.kind,
      key = data.key,
      relationshipName = relName,
      relationship = relName and componentByName(relName) or nil,
      componentName = data.component,
      component = componentByName(data.component),
      fields = data.fields,
   }
end

local function serializeTimeline(tl)
   local impl = tl
   local slots = {}
   for i = 1, #(impl.slots or {}) do
      local s = impl.slots[i]
      slots[i] = {
         kind = s.kind,
         target = serializeTarget(s.target),
         source = serializeSource(s.source),
         easing = s.easingName,
         t1 = s.t1, t2 = s.t2, t3 = s.t3, t4 = s.t4,
         relative = s.relative,
         startTime = s.startTime,
         endTime = s.endTime,
         duration = s.duration,
         stateIndex = s.stateIndex,
      }
   end
   local runs = nil
   if impl.runs then
      runs = {}
      for i = 1, #impl.runs do
         local r = impl.runs[i]
         runs[i] = {
            timelineId = r.timelineId,
            timeline = r.timeline and serializeTimeline(r.timeline) or nil,
            startTime = r.startTime,
            effectiveDuration = r.effectiveDuration,
            mode = r.mode,
            passCount = r.passCount,
         }
      end
   end
   return {
      slots = slots,
      runs = runs,
      emits = impl.emits,
      totalDuration = impl.totalDuration,
      stateSize = impl.stateSize,
      channel = impl.channel,
      presetName = impl.presetName,
      pinned = impl.pinned,
   }
end

local TIMELINE_MT = { __index = TimelineImpl }

local function deserializeTimeline(data)
   local slots = {}
   local savedSlots = data.slots
   for i = 1, #(savedSlots or {}) do
      local s = savedSlots[i]
      local easingName = s.easing
      slots[i] = {
         kind = (s.kind) or "to",
         target = deserializeTarget(s.target),
         source = deserializeSource(s.source),
         easingName = easingName,
         easing = assert(EASINGS[easingName], "Unknown tween easing " .. tostring(easingName)),
         t1 = (s.t1) or 0,
         t2 = (s.t2) or 0,
         t3 = (s.t3) or 0,
         t4 = (s.t4) or 0,
         relative = s.relative == true,
         startTime = (s.startTime) or 0,
         endTime = (s.endTime) or 0,
         duration = (s.duration) or 0,
         stateIndex = (s.stateIndex) or (i - 1),
      }
   end
   local runs = nil
   local savedRuns = data.runs
   if savedRuns then
      runs = {}
      for i = 1, #savedRuns do
         local r = savedRuns[i]
         runs[i] = {
            timeline = r.timeline and deserializeTimeline(r.timeline) or nil,
            timelineId = (r.timelineId) or 0,
            startTime = (r.startTime) or 0,
            effectiveDuration = (r.effectiveDuration) or 0,
            mode = assert(r.mode, "Tween snapshot run mode is required"),
            passCount = assert(r.passCount, "Tween snapshot run passCount is required"),
         }
      end
   end
   return setmetatable({
      slots = slots,
      runs = runs,
      emits = data.emits,
      totalDuration = (data.totalDuration) or 0,
      stateSize = (data.stateSize) or #slots,
      channel = data.channel,
      presetName = data.presetName,
      pinned = data.pinned == true,
   }, TIMELINE_MT)
end





local function newRegistry()
   return {
      nextId = 1,
      nextPlaybackId = 1,
      byId = {},
      refcounts = {},
      objectIds = setmetatable({}, { __mode = "k" }),
      named = {},
   }
end

local function registry(world)
   local r = world.resources[REGISTRY]
   if not r then
      r = newRegistry()
      world.resources[REGISTRY] = r
   end
   return r
end

local function internTimeline(world, tl)
   local reg = registry(world)
   local existing = reg.objectIds[tl]
   if existing then return existing end
   if tl.presetName then
      local named = reg.named[tl.presetName]
      if named then
         reg.objectIds[tl] = named
         return named
      end
   end
   local id = reg.nextId
   reg.nextId = id + 1
   reg.byId[id] = tl
   reg.objectIds[tl] = id
   reg.refcounts[id] = 0
   if tl.presetName then
      reg.named[tl.presetName] = id
      tl.pinned = true
   end
   if tl.runs then
      for i = 1, #tl.runs do
         tl.runs[i].timelineId = internTimeline(world, tl.runs[i].timeline)
      end
   end
   return id
end

local function incRef(reg, id)
   reg.refcounts[id] = (reg.refcounts[id] or 0) + 1
end

local function decRef(reg, id)
   local tl = reg.byId[id]
   if not tl then return end
   local n = (reg.refcounts[id] or 0) - 1
   if n > 0 then
      reg.refcounts[id] = n
      return
   end
   reg.refcounts[id] = 0
   if tl.pinned then return end
   reg.byId[id] = nil
   reg.objectIds[tl] = nil
   reg.refcounts[id] = nil
end

local function restoreRegistry(world, data)
   local reg = newRegistry()
   local maxId = 0
   local templates = data and (data.templates)
   if templates then
      for i = 1, #templates do
         local item = templates[i]
         local id = item.id
         local tl = deserializeTimeline(item.timeline)
         reg.byId[id] = tl



         reg.objectIds[tl] = id
         reg.refcounts[id] = 0
         if tl.presetName then reg.named[tl.presetName] = id end
         if id > maxId then maxId = id end
      end
   end



   for _, tl in pairs(reg.byId) do
      if tl.runs then
         for i = 1, #tl.runs do
            local run = tl.runs[i]
            if run.timelineId and reg.byId[run.timelineId] then
               run.timeline = reg.byId[run.timelineId]
            end
         end
      end
   end
   reg.nextId = maxId + 1


   reg.nextPlaybackId = (data and (data.nextPlaybackId)) or 1
   world.resources[REGISTRY] = reg
end





local function playbackMode(mode, count, finite)
   local resolved = mode or "once"
   assert(resolved == "once" or resolved == "loop" or resolved == "pingPong",
   "Tween mode must be once, loop, or pingPong")
   if resolved == "once" then
      assert(count == nil, "Tween count is only valid with loop or pingPong mode")
      return resolved, 1
   end
   if count ~= nil then
      assert(count > 0, "Tween count must be greater than 0")
      return resolved, count
   end
   assert(not finite, "Nested loop and pingPong runs require a finite count")
   return resolved, -1
end

local function createCursor(
   world,
   tl,
   target,
   mode,
   passCount,
   rate,
   delay)

   local id = internTimeline(world, tl)
   local state = ffi.new("TweenSlotState[?]", tl.stateSize)
   local children = nil
   if tl.runs then
      children = {}
      for i = 1, #tl.runs do
         local run = tl.runs[i]
         children[i] = createCursor(world, run.timeline, target, run.mode, run.passCount, 1, 0)
      end
   end
   incRef(registry(world), id)
   return {
      timelineId = id,
      stateSize = tl.stateSize,
      state = state,
      children = children,
      elapsed = 0,
      direction = 1,
      mode = mode,
      remainingPasses = passCount,
      nextEmit = 1,
      rate = rate,
      delay = delay or 0,
      _lastCycleIndex = 0,
   }
end

local function playbackFor(world, entity)
   local pb = world:getMut(entity, TweenPlaybackImpl)
   if pb then return pb end


   pb = (world):oldValueOf(entity, TweenPlaybackImpl)
   if pb then return pb end
   local created = TweenPlaybackImpl.new({})
   world:set(entity, created)
   return created
end

local function cursorTimeline(world, c)
   return registry(world).byId[c.timelineId]
end




local function endCursor(world, entity, c, reason)
   if c.cancelled then return end
   c.cancelled = true
   local tl = cursorTimeline(world, c)
   world:emit(0, TweenCancelled, entity, tl and tl.channel or nil,
   c.timelineId, c.playbackId, reason)
end

local function addCursor(world, entity, tl, options)
   local pb = playbackFor(world, entity)
   if tl.channel then
      for i = 1, #(pb.cursors or {}) do
         local existing = pb.cursors[i]
         local etl = cursorTimeline(world, existing)
         if etl and etl.channel == tl.channel then
            endCursor(world, entity, existing, "replaced")
         end
      end
   end
   local mode, passCount = playbackMode(options and options.mode, options and options.count)
   local speed = options and options.speed or 1
   local delay = options and options.delay or 0
   assert(speed > 0, "Tween speed must be greater than 0")
   assert(delay >= 0, "Tween delay must be at least 0")
   assert(passCount == 1 or tl.totalDuration > 0, "Repeating tween timelines must have a duration")
   local c = createCursor(
   world, tl, entity, mode, passCount,
   speed, delay)

   local reg = registry(world)
   c.playbackId = reg.nextPlaybackId
   reg.nextPlaybackId = c.playbackId + 1
   pb.cursors[#pb.cursors + 1] = c
   return c
end

function TimelineImpl:play(world, entity, options)
   return addCursor(world, entity, self, options).playbackId
end

function tween.play(
   world,
   entity,
   timelineOrName,
   options)

   if type(timelineOrName) == "string" then
      local id = registry(world).named[timelineOrName]
      if not id then error("Unknown tween preset " .. timelineOrName) end
      return addCursor(world, entity, registry(world).byId[id], options).playbackId
   end
   return addCursor(world, entity, timelineOrName, options).playbackId
end

local function selectorTimelineId(world, selector)
   local impl = selector
   local reg = registry(world)
   local id = reg.objectIds[impl]
   if id then return id end
   if impl.presetName then return reg.named[impl.presetName] end
   return nil
end

local function matchesCursor(world, c, selector)
   if not selector then return true end
   local tl = cursorTimeline(world, c)
   if not tl then return false end
   if type(selector) == "string" then
      return tl.channel == selector or tl.presetName == selector
   end
   local id = selectorTimelineId(world, selector)
   return id ~= nil and c.timelineId == id
end

function tween.cancel(world, entity, selector)
   local pb = world:get(entity, TweenPlaybackImpl)
   if not pb then return end
   local mutable = nil
   for i = 1, #(pb.cursors or {}) do
      if matchesCursor(world, pb.cursors[i], selector) then
         if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
         endCursor(world, entity, mutable.cursors[i], "cancelled")
      end
   end
end

function tween.isPlaying(world, entity, playback)
   if not world:isAlive(entity) then return false end
   local pb = world:get(entity, TweenPlaybackImpl)
   if not pb then return false end
   for i = 1, #(pb.cursors or {}) do
      local c = pb.cursors[i]
      if c.playbackId == playback then return not c.cancelled end
   end
   return false
end

function tween.pause(world, entity, selector)
   local pb = world:get(entity, TweenPlaybackImpl)
   if not pb then return end
   local mutable = nil
   for i = 1, #(pb.cursors or {}) do
      if not pb.cursors[i].paused and matchesCursor(world, pb.cursors[i], selector) then
         if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
         mutable.cursors[i].paused = true
      end
   end
end

function tween.resume(world, entity, selector)
   local pb = world:get(entity, TweenPlaybackImpl)
   if not pb then return end
   local mutable = nil
   for i = 1, #(pb.cursors or {}) do
      if pb.cursors[i].paused and matchesCursor(world, pb.cursors[i], selector) then
         if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
         mutable.cursors[i].paused = false
      end
   end
end





local function resolveEasing(value)
   if type(value) == "string" then
      local name = value
      return name, assert(EASINGS[name], "Unknown tween easing " .. value)
   end
   local easingFn = value
   return assert(EASING_NAMES[easingFn],
   "Tween easing must be a built-in easing name or value"), easingFn
end

local function resolveTargetValue(value)
   if type(value) == "string" then
      return assert(BUILTIN_TARGETS[value], "Unknown tween target " .. value)
   end
   return value
end

local function numericValue(value, position)
   if value == nil then return 0 end
   assert(type(value) == "number", "Tween value at position " .. tostring(position) .. " must be a number")
   return value
end

function tween.to(
   duration, easing, target,
   t1, t2, t3, t4)

   return { "to", duration, easing, target, t1, t2, t3, t4 }
end

function tween.adjust(
   duration, easing, target,
   t1, t2, t3, t4)

   return { "adjust", duration, easing, target, t1, t2, t3, t4 }
end

function tween.track(
   duration, easing,
   target, trackingSource)

   return { "track", duration, easing, target, trackingSource }
end

function tween.wait(duration)
   return { "wait", duration }
end

function tween.emit(name)
   return { "emit", name }
end

function tween.run(timeline, options)
   return { "run", timeline, options }
end

function tween.parallel(...)
   local node = { "parallel" }
   for i = 1, select("#", ...) do
      node[i + 1] = select(i, ...)
   end
   return node
end

local compileNode

local function compileBlock(block, startTime, tl)
   local time = startTime
   for i = 1, #block do
      time = compileNode(block[i], time, tl)
   end
   return time
end

local function compileSlot(node, startTime, tl)
   local compiled = (node)
   local authoredKind = compiled[1]
   local duration = compiled[2]
   assert(duration and duration > 0, "Tween duration must be greater than 0")
   local easingName, easingFn = resolveEasing(compiled[3])
   local target = resolveTargetValue(compiled[4])
   assert(target, "Tween target is required")

   compiled.kind = authoredKind == "track" and "track" or "to"
   compiled.target = target
   compiled.source = authoredKind == "track" and (compiled[5]) or nil
   compiled.easingName = easingName
   compiled.easing = easingFn
   compiled.t1 = authoredKind == "track" and 0 or numericValue(compiled[5], 5)
   compiled.t2 = authoredKind == "track" and 0 or numericValue(compiled[6], 6)
   compiled.t3 = authoredKind == "track" and 0 or numericValue(compiled[7], 7)
   compiled.t4 = authoredKind == "track" and 0 or numericValue(compiled[8], 8)
   compiled.relative = authoredKind == "adjust"
   compiled.startTime = startTime
   compiled.endTime = startTime + duration
   compiled.duration = duration
   compiled.stateIndex = #tl.slots

   tl.slots[#tl.slots + 1] = node
   return compiled.endTime
end

compileNode = function(node, startTime, tl)
   local data = (node)
   assert(data, "Tween timeline entry is required")
   local kind = data[1]
   if type(kind) == "table" then
      return compileBlock(data, startTime, tl)
   end
   assert(type(kind) == "string", "Tween operation name must be a string")

   if kind == "to" or kind == "adjust" or kind == "track" then
      return compileSlot(node, startTime, tl)
   elseif kind == "wait" then
      local duration = data[2]
      assert(duration and duration >= 0, "Tween wait duration must be at least 0")
      return startTime + duration
   elseif kind == "emit" then
      local name = data[2]
      assert(name, "Tween emit name is required")
      data.time = startTime
      data.name = name
      data.order = #tl.emits + 1
      tl.emits[#tl.emits + 1] = node
      return startTime
   elseif kind == "run" then
      local child = data[2]
      assert(child and child.totalDuration, "Tween run requires a compiled timeline")
      local options = data[3]
      local mode, passCount = playbackMode(options and options.mode, options and options.count, true)
      local duration = child.totalDuration * passCount
      data.timeline = child
      data.startTime = startTime
      data.effectiveDuration = duration
      data.mode = mode
      data.passCount = passCount
      tl.runs[#tl.runs + 1] = node
      return startTime + duration
   elseif kind == "parallel" then
      local endTime = startTime
      local children = data
      for i = 2, #children do
         local childEnd = compileNode(children[i], startTime, tl)
         if childEnd > endTime then endTime = childEnd end
      end
      return endTime
   end
   error("Unknown tween operation " .. kind)
end

function tween.timeline(spec)
   local authored = spec
   assert(authored.sequence == nil, "Tween timelines use an implicit sequence")
   local tl = spec
   tl.slots = {}
   tl.runs = {}
   tl.emits = {}
   tl.totalDuration = compileBlock(spec, 0, tl)
   tl.stateSize = #tl.slots
   if #tl.runs == 0 then tl.runs = nil end
   if #tl.emits == 0 then
      tl.emits = nil
   else
      table.sort(tl.emits, function(a, b)
         return a.time < b.time or (a.time == b.time and a.order < b.order)
      end)
   end
   return setmetatable(tl, TIMELINE_MT)
end

function tween.registerPreset(world, name, timeline)
   local impl = timeline
   assert(name ~= "", "Tween preset name must not be empty")
   local reg = registry(world)
   local existingId = reg.named[name]
   if existingId then
      assert(reg.byId[existingId] == impl, "Tween preset " .. name .. " is already registered")
      return timeline
   end
   assert(not impl.presetName or impl.presetName == name,
   "Tween timeline is already registered as " .. tostring(impl.presetName))
   impl.presetName = name
   impl.pinned = true
   local id = internTimeline(world, impl)
   reg.named[name] = id
   return timeline
end





local function targetValuesFromSource(
   world, entity, src)

   if not src then return 0, 0, 0, 0 end
   if not src.component and src.componentName then
      src.component = componentByName(src.componentName)
   end
   local sourceEntity = entity
   if src.kind == "key" then
      sourceEntity = world:requireKey(src.key)
   elseif src.kind == "trackingTarget" then
      local tt = world:get(entity, TrackingTarget)
      if not tt then return 0, 0, 0, 0 end
      if tt.entity and tt.entity ~= 0 then
         sourceEntity = tt.entity
      elseif tt.key and tt.key ~= "" then
         sourceEntity = world:requireKey(tt.key)
      else
         return 0, 0, 0, 0
      end
   elseif src.kind == "relationship" then
      if not src.relationship and src.relationshipName then
         src.relationship = componentByName(src.relationshipName)
      end
      local rel = world:get(entity, src.relationship)
      if not rel then return 0, 0, 0, 0 end
      sourceEntity = (rel).target
   end
   local c = world:get(sourceEntity, src.component)
   if not c then return 0, 0, 0, 0 end
   local cany = c
   local f = src.fields
   return cany[f[1]] or 0, cany[f[2]] or 0, cany[f[3]] or 0, cany[f[4]] or 0
end

local function evaluateSlots(slots, state, world, target, elapsed)
   for i = 1, #(slots or {}) do
      local slot = slots[i]
      local ss = state[slot.stateIndex]
      local shouldEvaluate = false
      local active = false
      local localT = 0
      if elapsed >= slot.startTime and elapsed <= slot.endTime then
         shouldEvaluate = true
         active = true
         localT = (elapsed - slot.startTime) / slot.duration
      elseif elapsed > slot.endTime then
         shouldEvaluate = true
         localT = 1
      elseif ss.init ~= 0 then
         shouldEvaluate = true
         localT = 0
      end

      if shouldEvaluate then
         if ss.init == 0 then
            local t1, t2, t3, t4 = slot.t1, slot.t2, slot.t3, slot.t4
            if slot.kind == "track" then
               t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
            end
            ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
            slot.target.init(world, target, slot.relative, t1, t2, t3, t4)
            ss.init = 1
         end
         if localT < 0 then localT = 0 end
         if localT > 1 then localT = 1 end
         if slot.kind == "track" and active then
            local t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
            ss.d1 = t1 - ss.s1
            ss.d2 = t2 - ss.s2
            ss.d3 = t3 - ss.s3
            ss.d4 = t4 - ss.s4
         end
         if ss.applied == 0 or ss.lastT ~= localT or (slot.kind == "track" and active) then
            slot.target.apply(
            world, target, slot.easing(localT),
            ss.s1, ss.s2, ss.s3, ss.s4,
            ss.d1, ss.d2, ss.d3, ss.d4)

            ss.applied = 1
            ss.lastT = localT
         end
      end
   end
end

local function fireEmits(c, tl, world, target, elapsed)
   local emits = tl.emits
   if not emits then return end
   while c.nextEmit <= #emits do
      local evDef = emits[c.nextEmit]
      if elapsed >= evDef.time then
         c.nextEmit = c.nextEmit + 1
         world:emit(0, TweenEvent, target, evDef.name, tl.channel, c.timelineId)
      else
         break
      end
   end
end

local evaluateCursor
local resetCursorCycle

local function beginRunCycle(
   child, childTl, runSlot, cycleIndex, world)

   if runSlot.mode == "loop" or cycleIndex % 2 == 0 then
      resetCursorCycle(child, world)
   end
   child.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
   if child.direction == -1 then
      child.nextEmit = (childTl.emits and #childTl.emits or 0) + 1
   else
      child.nextEmit = 1
   end
   child._lastCycleIndex = cycleIndex
   child.remainingPasses = runSlot.passCount - cycleIndex
end

local function evaluateRun(
   child, childTl, runSlot,
   localElapsed, world, target)

   local cycleDuration = childTl.totalDuration
   if cycleDuration <= 0 then return end

   local atEnd = localElapsed >= runSlot.effectiveDuration
   local cycleIndex = atEnd and (runSlot.passCount - 1) or math.floor(localElapsed / cycleDuration)
   local cyclePos = atEnd and cycleDuration or (localElapsed % cycleDuration)

   if cycleIndex > child._lastCycleIndex then
      for completedCycle = child._lastCycleIndex, cycleIndex - 1 do
         child.elapsed = runSlot.mode == "pingPong" and completedCycle % 2 == 1 and 0 or cycleDuration
         evaluateCursor(child, world, target)
         beginRunCycle(child, childTl, runSlot, completedCycle + 1, world)
      end
   elseif cycleIndex < child._lastCycleIndex then
      child._lastCycleIndex = cycleIndex
      child.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
   end

   if runSlot.mode == "pingPong" and cycleIndex % 2 == 1 then
      cyclePos = cycleDuration - cyclePos
   end
   child.elapsed = cyclePos
   child.remainingPasses = runSlot.passCount - cycleIndex
   evaluateCursor(child, world, target)
   child.completed = atEnd
end

evaluateCursor = function(c, world, target)
   local tl = cursorTimeline(world, c)
   if not tl then return end
   evaluateSlots(tl.slots, c.state, world, target, c.elapsed)
   fireEmits(c, tl, world, target, c.elapsed)
   if tl.runs and c.children then
      for i = 1, #tl.runs do
         local runSlot = tl.runs[i]
         local child = c.children[i]
         local runStart = runSlot.startTime
         local runEnd = runStart + runSlot.effectiveDuration
         local childTl = cursorTimeline(world, child)
         if childTl and c.elapsed >= runStart and c.elapsed <= runEnd then
            evaluateRun(child, childTl, runSlot, c.elapsed - runStart, world, target)
         elseif childTl and c.elapsed > runEnd and not child.completed then
            evaluateRun(child, childTl, runSlot, runSlot.effectiveDuration, world, target)
         end
      end
   end
end

resetCursorCycle = function(c, world)
   local tl = cursorTimeline(world, c)
   if not tl then return end
   ffi.fill(c.state, ffi.sizeof("TweenSlotState") * tl.stateSize, 0)
   c.elapsed = 0
   c.direction = 1
   c.nextEmit = 1
   c.completed = false
   c._lastCycleIndex = 0
   if c.children then
      for i = 1, #c.children do
         resetCursorCycle(c.children[i], world)
      end
   end
end

local function advanceCursor(c, dt, world, target)
   if c.paused then return false end
   local tl = cursorTimeline(world, c)
   if not tl then return true end
   if c.delay > 0 then
      c.delay = c.delay - dt
      if c.delay > 0 then return false end
      dt = -c.delay
      c.delay = 0
   end
   local totalDuration = tl.totalDuration
   if totalDuration <= 0 then
      evaluateCursor(c, world, target)
      world:emit(0, TweenComplete, target, tl.channel, c.timelineId, c.playbackId)
      return true
   end

   local remainingTime = dt * c.rate
   if remainingTime <= 0 then
      evaluateCursor(c, world, target)
      return false
   end

   while remainingTime > 0 do
      local distance = c.direction == 1 and (totalDuration - c.elapsed) or c.elapsed
      if remainingTime < distance then
         c.elapsed = c.elapsed + remainingTime * c.direction
         evaluateCursor(c, world, target)
         return false
      end

      c.elapsed = c.direction == 1 and totalDuration or 0
      evaluateCursor(c, world, target)
      remainingTime = remainingTime - distance

      if c.remainingPasses == -1 or c.remainingPasses > 1 then
         if c.remainingPasses > 1 then c.remainingPasses = c.remainingPasses - 1 end
         if c.mode == "pingPong" then
            c.direction = -c.direction
            if c.direction == 1 then
               resetCursorCycle(c, world)
            end
         else
            resetCursorCycle(c, world)
         end
      else
         world:emit(0, TweenComplete, target, tl.channel, c.timelineId, c.playbackId)
         return true
      end
   end

   return false
end

local function releaseCursor(reg, c)
   if c.children then
      for i = 1, #c.children do
         releaseCursor(reg, c.children[i])
      end
   end
   decRef(reg, c.timelineId)
end





local function collectLiveTemplateIds(world, playbackQuery)
   local live = {}
   local reg = registry(world)
   local function markTemplate(id)
      if live[id] then return end
      local tl = reg.byId[id]
      if not tl then return end
      live[id] = true
      if tl.runs then
         for i = 1, #tl.runs do
            markTemplate(tl.runs[i].timelineId)
         end
      end
   end
   for archetype, len in playbackQuery:iter() do
      local playbacks = archetype:get(TweenPlaybackImpl)
      for i = 1, len do
         local pb = playbacks[i]
         for j = 1, #(pb.cursors or {}) do
            local function mark(c)
               markTemplate(c.timelineId)
               if c.children then
                  for k = 1, #c.children do mark(c.children[k]) end
               end
            end
            mark(pb.cursors[j])
         end
      end
   end
   for id, tl in pairs(reg.byId) do
      if tl.pinned then markTemplate(id) end
   end
   return live
end

function tween.plugin(world)
   if world.resources[REGISTRY] then return end
   world.resources[REGISTRY] = newRegistry()

   local playbackQuery = world:query({
      name = "tween.Playbacks",
      include = { TweenPlaybackImpl },
      onEntitiesRemoved = function(archetype, firstRow, lastRow, _count)
         local reg = registry(world)
         local playbacks = archetype:get(TweenPlaybackImpl)
         local entities = archetype.entities
         for row = firstRow, lastRow do
            local pb = playbacks[row]
            if pb then
               for i = 1, #(pb.cursors or {}) do


                  endCursor(world, entities[row], pb.cursors[i], "targetLost")
                  releaseCursor(reg, pb.cursors[i])
               end
            end
         end
      end,
   })

   world:observe(0, tecs.builtins.OnSnapshotSave, function(ev)
      local reg = registry(world)
      local live = collectLiveTemplateIds(world, playbackQuery)
      local templates = {}
      for id, _ in pairs(live) do
         local tl = reg.byId[id]
         if tl then
            templates[#templates + 1] = { id = id, timeline = serializeTimeline(tl) }
         end
      end
      ev:addData(SNAPSHOT_DATA_KEY, {
         nextId = reg.nextId,
         nextPlaybackId = reg.nextPlaybackId,
         templates = templates,
      })
   end)

   world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev)
      ev:onData(SNAPSHOT_DATA_KEY, function(value)
         restoreRegistry(world, value)
      end)
   end)

   world:observe(0, tecs.builtins.FinishSnapshotLoad, function()
      local reg = registry(world)
      reg.refcounts = {}
      for archetype, len in playbackQuery:iter() do


         local playbacks = archetype:get(TweenPlaybackImpl)
         for i = 1, len do
            local pb = playbacks[i]
            for j = 1, #(pb.cursors or {}) do
               local function rebuild(c)
                  incRef(reg, c.timelineId)
                  if c.children then
                     for k = 1, #c.children do rebuild(c.children[k]) end
                  end
               end
               rebuild(pb.cursors[j])
            end
         end
      end
   end)



   local emptyEntities = {}
   world:addSystem({
      name = "tween.Update",
      phase = tecs.phases.Update,
      run = function(dt)
         local reg = registry(world)
         local emptyCount = 0
         for archetype, len, entities in playbackQuery:iter() do
            local playbacks = archetype:getMut(TweenPlaybackImpl)
            for i = 1, len do
               local entity = entities[i]
               local pb = playbacks[i]
               local cursors = pb.cursors
               for cidx = #cursors, 1, -1 do
                  local c = cursors[cidx]
                  if not c.cancelled and not world:isAlive(entity) then
                     endCursor(world, entity, c, "targetLost")
                  end
                  local remove = c.cancelled
                  if not remove then
                     remove = advanceCursor(c, dt, world, entity)
                  end
                  if remove then
                     releaseCursor(reg, c)
                     table.remove(cursors, cidx)
                  end
               end
               if #cursors == 0 then
                  emptyCount = emptyCount + 1
                  emptyEntities[emptyCount] = entity
               end
            end
         end
         for i = 1, emptyCount do
            if world:isAlive(emptyEntities[i]) then
               world:remove(emptyEntities[i], TweenPlaybackImpl)
            end
            emptyEntities[i] = nil
         end
      end,
   })
end

return tween
