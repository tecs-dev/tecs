






















local tecs = require("tecs")
local logging = require("tecs.utils.logging")
local tween = require("tecs2d.tween")
local wakeheap = require("tecs2d.internal.wakeheap")



local LOGGER = logging.getLogger("tecs2d.sequence")

local floor = math.floor



local SLOT_LIMIT = 1048576

local DEFAULT_BUDGET = 512








local SNAPSHOT_VERSION = 4


local OP_WAIT = 1

local OP_CALL = 2

local OP_EMIT = 3

local OP_JUMP = 4

local OP_END = 5
local OP_WAIT_SIGNAL = 6
local OP_FORK = 7

local OP_JOIN = 8
local OP_WAIT_QUERY = 9

local OP_PLAY_TWEEN = 10

local OP_WAIT_TWEEN = 11

local STRIDE = 3














































local sequence = { EntityRef = {}, PlayOptions = {}, ActionContext = {}, Event = {}, Status = {} }














































































































































































































































































































































































function sequence.Event.init(
   e,
   name,
   args,
   handle)

   e.name = name
   e.args = args
   e.handle = handle
end

tecs.newEvent(sequence.Event)






local programsByName = {}
local programVersions = {}
local programRefs = {}

local function retainProgram(prog)
   programRefs[prog] = (programRefs[prog] or 0) + 1
end

local function releaseProgram(prog)
   if not prog then return end
   local remaining = (programRefs[prog] or 1) - 1
   if remaining > 0 then
      programRefs[prog] = remaining
      return
   end
   programRefs[prog] = nil
   if programsByName[prog.name] == prog then return end
   local versions = programVersions[prog.name]
   if not versions then return end
   versions[prog.version] = nil
   if next(versions) == nil then programVersions[prog.name] = nil end
end















function sequence.bind(name)
   if type(name) ~= "string" or name == "" then
      error("sequence.bind requires a non-empty binding name", 2)
   end
   return { bindName = name, isBinding = true }
end

local function isEntityRef(value)
   if type(value) ~= "table" then return false end
   local ref = value
   return ref.isBinding == true and type(ref.bindName) == "string"
end

function sequence.call(action, ...)
   if type(action) ~= "string" or action == "" then
      error("sequence.call requires a non-empty action name", 2)
   end
   return { kind = "call", text = action, args = { ... } }
end

function sequence.wait(seconds)
   if type(seconds) ~= "number" or seconds < 0 then
      error("sequence.wait requires a non-negative duration", 2)
   end
   return { kind = "wait", number = seconds }
end

function sequence.waitSteps(steps)
   if type(steps) ~= "number" or steps < 0 or steps % 1 ~= 0 then
      error("sequence.waitSteps requires a non-negative whole number", 2)
   end
   return { kind = "waitSteps", number = steps }
end

function sequence.waitSignal(name)
   if type(name) ~= "string" or name == "" then
      error("sequence.waitSignal requires a non-empty signal name", 2)
   end
   return { kind = "waitSignal", text = name }
end

function sequence.waitQuery(
   name,
   condition)

   if type(name) ~= "string" or name == "" then
      error("sequence.waitQuery requires a non-empty query name", 2)
   end
   if condition ~= "any" and condition ~= "empty" then
      error("sequence.waitQuery condition must be 'any' or 'empty'", 2)
   end
   return { kind = "waitQuery", text = name, count = condition == "any" and 1 or 0 }

end

function sequence.emit(event, ...)
   if type(event) ~= "string" or event == "" then
      error("sequence.emit requires a non-empty event name", 2)
   end
   return { kind = "emit", text = event, args = { ... } }
end

function sequence.loop(count, nodes)
   if count ~= nil and (type(count) ~= "number" or count < 1 or count % 1 ~= 0) then
      error("sequence.loop count must be a positive whole number or nil", 2)
   end
   if type(nodes) ~= "table" or #nodes == 0 then
      error("sequence.loop requires a non-empty block", 2)
   end
   return { kind = "loop", count = count, nodes = nodes }
end

function sequence.playTween(
   preset,
   target,
   options)

   if type(preset) ~= "string" or preset == "" then
      error("sequence.playTween requires a non-empty preset name", 2)
   end
   if not isEntityRef(target) then
      error("sequence.playTween requires a sequence.bind(name) target", 2)
   end
   return { kind = "playTween", text = preset, args = { target, options } }

end

function sequence.waitTween()
   return { kind = "waitTween" }
end

function sequence.fork(nodes)
   if type(nodes) ~= "table" or #nodes == 0 then
      error("sequence.fork requires a non-empty block", 2)
   end
   return { kind = "fork", nodes = nodes }
end

function sequence.join()
   return { kind = "join" }
end

function sequence.parallel(...)
   local blocks = { ... }
   if #blocks == 0 then
      error("sequence.parallel requires at least one block", 2)
   end
   for i = 1, #blocks do
      local block = blocks[i]
      if type(block) ~= "table" or #block == 0 then
         error("sequence.parallel block " .. tostring(i) .. " is empty", 2)
      end
   end
   return { kind = "parallel", blocks = blocks }
end













local function intern(c, value)

   if type(value) ~= "table" then
      local existing = c.constIndex[value]
      if existing then return existing end
   end
   local index = #c.consts + 1
   c.consts[index] = value
   if type(value) ~= "table" then
      c.constIndex[value] = index
   end
   return index
end

local function emitOp(c, op, a, b)
   local pc = floor(#c.code / STRIDE)
   c.code[#c.code + 1] = op
   c.code[#c.code + 1] = a
   c.code[#c.code + 1] = b
   return pc
end

local compileBlock





local function compileFork(c, nodes, depth)
   local forkPc = emitOp(c, OP_FORK, 0, 0)
   c.code[forkPc * STRIDE + 2] = forkPc + 1
   compileBlock(c, nodes, depth)
   emitOp(c, OP_END, -1, -1)
   c.code[forkPc * STRIDE + 3] = floor(#c.code / STRIDE)
end

local function compileNode(c, node, depth)
   local kind = node.kind
   if kind == "call" then
      emitOp(c, OP_CALL, intern(c, node.text), intern(c, node.args))
   elseif kind == "emit" then
      emitOp(c, OP_EMIT, intern(c, node.text), intern(c, node.args))
   elseif kind == "wait" then
      emitOp(c, OP_WAIT, intern(c, node.number), -1)
   elseif kind == "waitSignal" then
      emitOp(c, OP_WAIT_SIGNAL, intern(c, node.text), -1)
   elseif kind == "waitQuery" then
      emitOp(c, OP_WAIT_QUERY, intern(c, node.text), node.count)
   elseif kind == "waitSteps" then
      emitOp(c, OP_WAIT, -1, node.number)
   elseif kind == "loop" then
      local slot = depth + 1
      if slot > c.loopSlots then c.loopSlots = slot end
      local top = floor(#c.code / STRIDE)
      compileBlock(c, node.nodes, slot)

      local jumpPc = emitOp(c, OP_JUMP, top, node.count and slot or -1)


      if node.count then c.loopCounts[jumpPc] = node.count end
   elseif kind == "fork" then
      compileFork(c, node.nodes, depth)
   elseif kind == "playTween" then
      emitOp(c, OP_PLAY_TWEEN, intern(c, node.text), intern(c, node.args))
   elseif kind == "waitTween" then
      emitOp(c, OP_WAIT_TWEEN, -1, -1)
   elseif kind == "join" then
      emitOp(c, OP_JOIN, -1, -1)
   elseif kind == "parallel" then
      local blocks = node.blocks
      for i = 1, #blocks do
         compileFork(c, blocks[i], depth)
      end
      emitOp(c, OP_JOIN, -1, -1)
   else
      error("sequence: unknown node kind '" .. tostring(kind) .. "'")
   end
end

compileBlock = function(c, nodes, depth)
   for i = 1, #nodes do
      local node = nodes[i]
      if type(node) ~= "table" or node.kind == nil then
         error("sequence: entry " .. tostring(i) .. " is not a sequence node")
      end
      compileNode(c, node, depth)
   end
end



local function indexBindingArgs(prog)
   local flags = {}
   local consts = prog.consts
   for i = 1, #consts do
      local value = consts[i]
      if type(value) == "table" then
         local list = value
         for j = 1, #list do
            if isEntityRef(list[j]) then
               flags[i] = true
               break
            end
         end
      end
   end
   prog.bindingArgs = flags
end

function sequence.define(name, nodes)
   if type(name) ~= "string" or name == "" then
      error("sequence.define requires a non-empty program name", 2)
   end
   if type(nodes) ~= "table" then
      error("sequence.define requires an array of nodes", 2)
   end

   local c = {
      code = {},
      consts = {},
      constIndex = {},
      loopSlots = 0,
      loopCounts = {},
   }
   compileBlock(c, nodes, 0)
   emitOp(c, OP_END, -1, -1)

   local previous = programsByName[name]
   local prog = {
      name = name,
      version = previous and previous.version + 1 or 1,
      code = c.code,
      consts = c.consts,
      loopSlots = c.loopSlots,
      loopCounts = c.loopCounts,
      bindingArgs = {},
   }
   indexBindingArgs(prog)

   programsByName[name] = prog
   local versions = programVersions[name]
   if not versions then
      versions = {}
      programVersions[name] = versions
   end
   versions[prog.version] = prog
   return prog
end

function sequence.program(name, version)
   if version then
      local versions = programVersions[name]
      return versions and versions[version]
   end
   return programsByName[name]
end

function sequence.programNames()
   local names = {}
   for name in pairs(programsByName) do names[#names + 1] = name end
   table.sort(names)
   return names
end


























































































local states =
setmetatable({}, { __mode = "k" })

local function stateFor(world)
   local state = states[world]
   if state then return state end
   state = {
      cursors = {},
      freeSlots = {},
      nextSlot = 1,
      generations = {},
      actions = {},
      step = 0,
      seq = 0,
      budget = DEFAULT_BUDGET,
      heap = wakeheap.new(),
      channels = {},
      pendingSignals = {},
      queries = {},
      queryWaiters = {},
      dirtyQueries = {},
      tweenOwners = {},
      tweenWaiters = {},
      argScratch = {},
      ownerIndex = {},
   }
   states[world] = state
   return state
end

local function packHandle(slot, generation)
   return slot + generation * SLOT_LIMIT
end





local function schedule(state, cursor, wakeAt)
   state.seq = state.seq + 1
   cursor.wakeAt = wakeAt
   cursor.seq = state.seq
   wakeheap.push(state.heap, wakeAt, cursor.seq,
   packHandle(cursor.slot, cursor.generation))
end





local function resolve(state, handle)
   if type(handle) ~= "number" then return nil end
   local slot = handle % SLOT_LIMIT
   local generation = (handle - slot) / SLOT_LIMIT
   local cursor = state.cursors[slot]
   if not cursor or cursor.generation ~= generation then return nil end
   return cursor
end

local function allocCursor(state)
   local slot
   local freeCount = #state.freeSlots
   if freeCount > 0 then
      slot = state.freeSlots[freeCount]
      state.freeSlots[freeCount] = nil
   else
      slot = state.nextSlot
      state.nextSlot = slot + 1
      if slot >= SLOT_LIMIT then
         error("sequence: cursor arena exhausted")
      end
   end
   local generation = (state.generations[slot] or 0) + 1
   state.generations[slot] = generation
   local cursor = {
      slot = slot,
      generation = generation,
      alive = true,
      pc = 0,
      state = "running",
      owner = 0,
      budget = state.budget,
      wakeAt = 0,
      seq = 0,
      loopRegs = nil,
   }
   state.cursors[slot] = cursor
   return cursor
end

local function park(
   index,
   key,
   slot)

   local blocked = index[key]
   if not blocked then
      blocked = {}
      index[key] = blocked
   end
   blocked[slot] = true
end

local function unpark(
   index,
   key,
   slot)

   local blocked = index[key]
   if not blocked then return end
   blocked[slot] = nil
   if next(blocked) == nil then index[key] = nil end
end



local function unlinkWaits(state, cursor)
   local channel = cursor.waitChannel
   if channel then
      cursor.waitChannel = nil
      unpark(state.channels, channel, cursor.slot)
   end
   local queryName = cursor.waitQuery
   if queryName then
      cursor.waitQuery = nil
      cursor.waitCondition = nil
      unpark(state.queryWaiters, queryName, cursor.slot)
   end
   if cursor.waitingTween then
      cursor.waitingTween = false
      state.tweenWaiters[cursor.slot] = nil
   end
end



local function releaseTween(state, cursor)
   local token = cursor.tweenPlayback
   if not token then return end
   if state.tweenOwners[token] == cursor.slot then
      state.tweenOwners[token] = nil
   end
   cursor.tweenPlayback = nil
   cursor.tweenEntity = nil
end

local function linkOwner(state, cursor)
   if cursor.owner == 0 then return end
   local owned = state.ownerIndex[cursor.owner]
   if not owned then
      owned = {}
      state.ownerIndex[cursor.owner] = owned
   end
   owned[cursor.slot] = true
end

local function unlinkOwner(state, cursor)
   if cursor.owner == 0 then return end
   local owned = state.ownerIndex[cursor.owner]
   if owned then
      owned[cursor.slot] = nil
      if next(owned) == nil then state.ownerIndex[cursor.owner] = nil end
   end
end



local function childSlots(cursor)
   local slots = {}
   local children = cursor.children
   if not children then return slots end
   for slot in pairs(children) do slots[#slots + 1] = slot end
   table.sort(slots)
   return slots
end



local faultCursor






local function detachFromParent(
   state,
   cursor,
   finalState)

   local slot = cursor.parentSlot
   if not slot then return end
   cursor.parentSlot = nil
   local parent = state.cursors[slot]
   if not parent or parent.generation ~= cursor.parentGeneration then return end

   local children = parent.children
   if children then children[cursor.slot] = nil end
   if not parent.alive then return end




   if finalState == "faulted" then
      faultCursor(state, parent, "branchFaulted",
      "branch at pc=" .. tostring(cursor.pc) .. " faulted: " ..
      tostring(cursor.faultMessage))
      return
   end

   if parent.joining and (not children or next(children) == nil) then
      parent.joining = false
      schedule(state, parent, state.step)
   end
end






local function retire(state, cursor, finalState)
   if not cursor.alive then return end
   cursor.state = finalState
   cursor.alive = false
   cursor.joining = false
   unlinkWaits(state, cursor)
   releaseTween(state, cursor)
   unlinkOwner(state, cursor)
   releaseProgram(cursor.program)



   local children = cursor.children
   if children and next(children) ~= nil then
      local slots = childSlots(cursor)
      for i = 1, #slots do
         local child = state.cursors[slots[i]]
         if child and child.alive then retire(state, child, "cancelled") end
      end
   end
   cursor.children = nil

   detachFromParent(state, cursor, finalState)
   state.freeSlots[#state.freeSlots + 1] = cursor.slot
end





function sequence.registerAction(world, name, action)
   if type(name) ~= "string" or name == "" then
      error("sequence.registerAction requires a non-empty action name", 2)
   end
   if type(action) ~= "function" then
      error("sequence.registerAction requires a function", 2)
   end
   stateFor(world).actions[name] = action
end

function sequence.hasAction(world, name)
   return stateFor(world).actions[name] ~= nil
end

function sequence.registerQuery(
   world,
   name,
   descriptor)

   if type(name) ~= "string" or name == "" then
      error("sequence.registerQuery requires a non-empty query name", 2)
   end
   if type(descriptor) ~= "table" then
      error("sequence.registerQuery requires a query descriptor", 2)
   end
   local state = stateFor(world)



   local userAdded = descriptor.onEntitiesAdded
   local userRemoved = descriptor.onEntitiesRemoved
   local spec = {}
   for key, value in pairs(descriptor) do
      (spec)[key] = value
   end
   spec.onEntitiesAdded = function(
      archetype,
      firstRow,
      lastRow,
      count)

      state.dirtyQueries[name] = true
      if userAdded then userAdded(archetype, firstRow, lastRow, count) end
   end
   spec.onEntitiesRemoved = function(
      archetype,
      firstRow,
      lastRow,
      count)

      state.dirtyQueries[name] = true
      if userRemoved then userRemoved(archetype, firstRow, lastRow, count) end
   end

   state.queries[name] = world:query(spec)

   state.dirtyQueries[name] = true
end

function sequence.hasQuery(world, name)
   return stateFor(world).queries[name] ~= nil
end

function sequence.signalOnEvent(world, name, event)
   if type(name) ~= "string" or name == "" then
      error("sequence.signalOnEvent requires a non-empty signal name", 2)
   end
   world:observe(0, event, function()
      sequence.signal(world, name)
   end)
end





local function contextEntity(self, name)
   local cursor = self._cursor
   local bindings = cursor.bindings
   if not bindings then return nil end
   local id = bindings[name]
   if not id then return nil end
   if not self.world:isAlive(id) then return nil end
   return id
end





local function resolveArgs(
   world,
   state,
   cursor,
   index)

   local raw = cursor.program.consts[index]
   if not cursor.program.bindingArgs[index] then return raw end

   local out = state.argScratch
   local count = #raw
   for i = 1, count do
      local value = raw[i]
      if isEntityRef(value) then
         local name = (value).bindName
         local id = cursor.bindings and cursor.bindings[name]
         out[i] = (id and world:isAlive(id)) and id or nil
      else
         out[i] = value
      end
   end
   for i = #out, count + 1, -1 do out[i] = nil end
   return out
end

faultCursor = function(
   state,
   cursor,
   reason,
   message)

   cursor.fault = reason
   cursor.faultMessage = message
   LOGGER:error("%s v%d pc=%d: %s (%s)",
   cursor.program.name, cursor.program.version, cursor.pc, message, reason)
   retire(state, cursor, "faulted")
end

local function secondsToSteps(world, seconds)
   if seconds <= 0 then return 0 end
   local timestep = world:getFixedTiming()
   if not timestep or timestep <= 0 then return 1 end
   local steps = math.floor(seconds / timestep + 0.5)
   if steps < 1 then steps = 1 end
   return steps
end



local function run(
   world,
   state,
   cursor,
   budget)

   local prog = cursor.program
   local code = prog.code
   local consts = prog.consts

   while true do
      budget = budget - 1
      if budget < 0 then
         faultCursor(state, cursor, "budgetExceeded",
         "exceeded " .. tostring(cursor.budget) ..
         " instructions in one step without waiting")
         return budget
      end

      local base = cursor.pc * STRIDE
      local op = code[base + 1]
      local a = code[base + 2]
      local b = code[base + 3]

      if op == OP_END then
         retire(state, cursor, "completed")
         return budget

      elseif op == OP_WAIT then
         local steps = a >= 0 and secondsToSteps(world, consts[a]) or b
         cursor.pc = cursor.pc + 1
         schedule(state, cursor, state.step + (steps > 0 and steps or 1))
         return budget

      elseif op == OP_WAIT_SIGNAL then
         local channel = consts[a]
         cursor.pc = cursor.pc + 1
         cursor.waitChannel = channel
         cursor.wakeAt = nil
         park(state.channels, channel, cursor.slot)
         return budget

      elseif op == OP_WAIT_QUERY then
         local name = consts[a]
         if not state.queries[name] then
            faultCursor(state, cursor, "unregisteredQuery",
            "query '" .. name .. "' is not registered on this world")
            return budget
         end
         cursor.pc = cursor.pc + 1
         cursor.waitQuery = name
         cursor.waitCondition = b
         cursor.wakeAt = nil
         park(state.queryWaiters, name, cursor.slot)



         state.dirtyQueries[name] = true
         return budget

      elseif op == OP_PLAY_TWEEN then
         local preset = consts[a]
         local spec = consts[b]
         local ref = spec[1]
         local id = cursor.bindings and cursor.bindings[ref.bindName]
         releaseTween(state, cursor)
         cursor.tweenOutcome = nil
         if not id or not world:isAlive(id) then



            cursor.tweenOutcome = "targetLost"
         else
            local ok, result = pcall(tween.play, world, id, preset,
            spec[2])
            if not ok then
               faultCursor(state, cursor, "unregisteredTween",
               "tween preset '" .. preset .. "': " .. tostring(result))
               return budget
            end
            cursor.tweenEntity = id
            cursor.tweenPlayback = result
            state.tweenOwners[cursor.tweenPlayback] = cursor.slot
         end
         cursor.pc = cursor.pc + 1

      elseif op == OP_WAIT_TWEEN then
         cursor.pc = cursor.pc + 1
         if cursor.tweenPlayback then
            cursor.waitingTween = true
            cursor.wakeAt = nil
            state.tweenWaiters[cursor.slot] = true
            return budget
         end



      elseif op == OP_CALL then
         local name = consts[a]
         local action = state.actions[name]
         if not action then
            faultCursor(state, cursor, "unregisteredAction",
            "action '" .. name .. "' is not registered on this world")
            return budget
         end
         local ctx = state.context
         if not ctx then
            ctx = { world = world, entity = contextEntity }
            state.context = ctx
         end
         ctx.handle = packHandle(cursor.slot, cursor.generation)
         ctx.owner = cursor.owner
         ctx.args = resolveArgs(world, state, cursor, b)
         ctx._cursor = cursor

         local ok, err = pcall(action, world, ctx)
         if not ok then
            faultCursor(state, cursor, "actionError", tostring(err))
            return budget
         end

         if not cursor.alive then return budget end
         cursor.pc = cursor.pc + 1

      elseif op == OP_EMIT then


         local resolved = resolveArgs(world, state, cursor, b)
         local args = {}
         for i = 1, #resolved do args[i] = resolved[i] end
         world:emit(0, sequence.Event,
         consts[a], args,
         packHandle(cursor.slot, cursor.generation))
         cursor.pc = cursor.pc + 1

      elseif op == OP_JUMP then
         if b < 0 then
            cursor.pc = a
         else
            local regs = cursor.loopRegs
            if not regs then
               regs = {}
               cursor.loopRegs = regs
            end
            local remaining = regs[cursor.pc]
            if remaining == nil then
               remaining = (prog.loopCounts and prog.loopCounts[cursor.pc]) or 1
            end
            remaining = remaining - 1
            if remaining > 0 then
               regs[cursor.pc] = remaining
               cursor.pc = a
            else
               regs[cursor.pc] = nil
               cursor.pc = cursor.pc + 1
            end
         end

      elseif op == OP_FORK then




         local child = allocCursor(state)
         child.program = prog
         retainProgram(prog)
         child.pc = a
         child.owner = cursor.owner
         child.bindings = cursor.bindings
         child.budget = cursor.budget
         child.parentSlot = cursor.slot
         child.parentGeneration = cursor.generation

         local children = cursor.children
         if not children then
            children = {}
            cursor.children = children
         end
         children[child.slot] = true

         linkOwner(state, child)
         schedule(state, child, state.step)
         cursor.pc = b

      elseif op == OP_JOIN then
         cursor.pc = cursor.pc + 1
         local children = cursor.children
         if children and next(children) ~= nil then

            cursor.joining = true
            cursor.wakeAt = nil
            return budget
         end

      else
         faultCursor(state, cursor, "actionError",
         "unknown opcode " .. tostring(op))
         return budget
      end
   end
end


local function advance(world, state, cursor)
   if cursor.budgetStep ~= state.step then
      cursor.budgetStep = state.step
      cursor.budgetLeft = cursor.budget
   end
   cursor.budgetLeft = run(world, state, cursor, cursor.budgetLeft)
end





function sequence.signal(world, name)
   if type(name) ~= "string" or name == "" then
      error("sequence.signal requires a non-empty signal name", 2)
   end
   local state = stateFor(world)
   local blocked = state.channels[name]
   if not blocked then return 0 end
   local count = 0
   for _ in pairs(blocked) do count = count + 1 end


   state.pendingSignals[#state.pendingSignals + 1] = name
   return count
end

function sequence.waitingOn(world, name)
   local blocked = stateFor(world).channels[name]
   if not blocked then return 0 end
   local count = 0
   for _ in pairs(blocked) do count = count + 1 end
   return count
end

function sequence.play(
   world,
   program,
   options)

   if type(program) ~= "table" or (program).code == nil then
      error("sequence.play requires a program from sequence.define", 2)
   end
   local state = stateFor(world)
   local cursor = allocCursor(state)
   cursor.program = program
   cursor.pc = 0
   cursor.state = "running"
   retainProgram(cursor.program)

   if options then
      cursor.owner = options.owner or 0
      cursor.bindings = options.bindings
      if options.budget then cursor.budget = options.budget end
   end

   linkOwner(state, cursor)


   schedule(state, cursor, state.step + 1)
   return packHandle(cursor.slot, cursor.generation)
end

function sequence.cancel(world, handle)
   local state = stateFor(world)
   local cursor = resolve(state, handle)
   if not cursor or not cursor.alive then return false end
   retire(state, cursor, "cancelled")
   return true
end



local function pauseTree(state, cursor)
   local slots = childSlots(cursor)
   for i = 1, #slots do
      local child = state.cursors[slots[i]]
      if child and child.alive then pauseTree(state, child) end
   end
   if cursor.state ~= "running" then return false end
   cursor.state = "paused"
   return true
end

local function resumeTree(state, cursor)
   local slots = childSlots(cursor)
   for i = 1, #slots do
      local child = state.cursors[slots[i]]
      if child and child.alive then resumeTree(state, child) end
   end
   if cursor.state ~= "paused" then return false end
   cursor.state = "running"




   if cursor.wakeAt and cursor.wakeAt <= state.step then
      schedule(state, cursor, state.step + 1)
   end
   return true
end

function sequence.pause(world, handle)
   local state = stateFor(world)
   local cursor = resolve(state, handle)
   if not cursor or not cursor.alive then return false end
   return pauseTree(state, cursor)
end

function sequence.resume(world, handle)
   local state = stateFor(world)
   local cursor = resolve(state, handle)
   if not cursor or not cursor.alive then return false end
   return resumeTree(state, cursor)
end

function sequence.status(world, handle)
   local state = stateFor(world)
   local cursor = resolve(state, handle)
   if not cursor then return nil end
   local branches = 0
   local children = cursor.children
   if children then
      for _ in pairs(children) do branches = branches + 1 end
   end

   local status = {
      state = cursor.state,
      program = cursor.program.name,
      version = cursor.program.version,
      pc = cursor.pc,
      wakeAt = cursor.alive and cursor.wakeAt or nil,
      waitingFor = cursor.alive and cursor.waitChannel or nil,
      waitingQuery = cursor.alive and cursor.waitQuery or nil,
      waitingTween = cursor.waitingTween and cursor.tweenPlayback or nil,
      tweenOutcome = cursor.tweenOutcome,
      waitingCondition = cursor.alive and cursor.waitQuery and
      (cursor.waitCondition == 1 and "any" or "empty") or nil,
      branches = branches,
      joining = cursor.joining or false,
      fault = cursor.fault,
      faultMessage = cursor.faultMessage,
   }
   return status
end

function sequence.cancelOwnedBy(world, owner)
   local state = stateFor(world)
   local owned = state.ownerIndex[owner]
   if not owned then return 0 end
   local slots = {}
   for slot in pairs(owned) do slots[#slots + 1] = slot end
   table.sort(slots)
   local cancelled = 0
   for i = 1, #slots do
      local cursor = state.cursors[slots[i]]
      if cursor and cursor.alive then
         retire(state, cursor, "cancelled")
         cancelled = cancelled + 1
      end
   end
   return cancelled
end

function sequence.activeCount(world)
   local state = stateFor(world)
   local count = 0
   for _, cursor in pairs(state.cursors) do
      if cursor.alive then count = count + 1 end
   end
   return count
end

function sequence.playbacks(world)
   local state = stateFor(world)
   local slots = {}
   for slot, cursor in pairs(state.cursors) do
      if cursor.alive then slots[#slots + 1] = slot end
   end
   table.sort(slots)
   local handles = {}
   for i = 1, #slots do
      local cursor = state.cursors[slots[i]]
      handles[i] = packHandle(cursor.slot, cursor.generation)
   end
   return handles
end

function sequence.setInstructionBudget(world, instructions)
   if type(instructions) ~= "number" or instructions < 1 then
      error("sequence.setInstructionBudget requires a positive count", 2)
   end
   stateFor(world).budget = instructions
end

function sequence.currentStep(world)
   return stateFor(world).step
end





local function describeArgs(args)
   if not args or #args == 0 then return "" end
   local parts = {}
   for i = 1, #args do
      local value = args[i]
      if isEntityRef(value) then
         parts[#parts + 1] = "bind(" .. (value).bindName .. ")"
      elseif type(value) == "string" then
         parts[#parts + 1] = string.format("%q", value)
      else
         parts[#parts + 1] = tostring(value)
      end
   end
   return ", " .. table.concat(parts, ", ")
end

function sequence.disassemble(program, pc)
   local prog = program
   if type(prog) ~= "table" or prog.code == nil then
      error("sequence.disassemble requires a program from sequence.define", 2)
   end
   local out = {
      string.format("%s v%d  (%d instructions)",
      prog.name, prog.version, floor(#prog.code / STRIDE)),
   }
   local counts = prog.loopCounts
   local marked = pc
   for at = 0, floor(#prog.code / STRIDE) - 1 do
      local base = at * STRIDE
      local op = prog.code[base + 1]
      local a = prog.code[base + 2]
      local b = prog.code[base + 3]
      local text
      if op == OP_WAIT then
         text = a >= 0 and
         string.format("WAIT      %ss", tostring(prog.consts[a])) or
         string.format("WAIT      %d step(s)", b)
      elseif op == OP_WAIT_SIGNAL then
         text = string.format("WAITSIG   %q", prog.consts[a])
      elseif op == OP_WAIT_QUERY then
         text = string.format("WAITQUERY %q %s",
         prog.consts[a], b == 1 and "any" or "empty")
      elseif op == OP_CALL then
         text = string.format("CALL      %q%s",
         prog.consts[a], describeArgs(prog.consts[b]))
      elseif op == OP_EMIT then
         text = string.format("EMIT      %q%s",
         prog.consts[a], describeArgs(prog.consts[b]))
      elseif op == OP_JUMP then
         local count = counts and counts[at]
         text = string.format("JUMP      -> %d  (%s)", a,
         b < 0 and "forever" or ("x" .. tostring(count or 1)))
      elseif op == OP_FORK then
         text = string.format("FORK      branch %d..%d, continue -> %d", a, b - 1, b)
      elseif op == OP_PLAY_TWEEN then
         local spec = prog.consts[b]
         local ref = spec[1]
         text = string.format("PLAYTWEEN %q, bind(%s)",
         prog.consts[a], ref.bindName)
      elseif op == OP_WAIT_TWEEN then
         text = "WAITTWEEN"
      elseif op == OP_JOIN then
         text = "JOIN"
      elseif op == OP_END then
         text = "END"
      else
         text = "?? " .. tostring(op)
      end
      out[#out + 1] = string.format("%s %4d  %s",
      at == marked and "->" or "  ", at, text)
   end
   return table.concat(out, "\n")
end












local function serializeProgram(prog)
   return {
      name = prog.name,
      version = prog.version,
      code = prog.code,
      consts = prog.consts,
      loopSlots = prog.loopSlots,
      loopCounts = prog.loopCounts,
   }
end

local function restoreProgram(data)
   local name = data.name
   local version = data.version
   local versions = programVersions[name]
   if versions and versions[version] then
      return versions[version]
   end

   local prog = {
      name = name,
      version = version,
      code = data.code,
      consts = data.consts,
      loopSlots = data.loopSlots,
      loopCounts = (data.loopCounts) or {},
      bindingArgs = {},
   }
   indexBindingArgs(prog)
   if not versions then
      versions = {}
      programVersions[name] = versions
   end
   versions[version] = prog

   local newest = programsByName[name]
   if not newest or newest.version < version then
      programsByName[name] = prog
   end
   return prog
end

local function saveState(world)
   local state = states[world]
   if not state then return nil end

   local programs = {}
   local seenPrograms = {}
   local cursors = {}

   local slots = {}
   for slot in pairs(state.cursors) do slots[#slots + 1] = slot end
   table.sort(slots)

   for i = 1, #slots do
      local cursor = state.cursors[slots[i]]
      if cursor.alive then
         local prog = cursor.program
         local key = prog.name .. "@" .. tostring(prog.version)
         if not seenPrograms[key] then
            seenPrograms[key] = true
            programs[#programs + 1] = serializeProgram(prog)
         end
         cursors[#cursors + 1] = {
            slot = cursor.slot,
            generation = cursor.generation,
            program = prog.name,
            version = prog.version,
            pc = cursor.pc,
            state = cursor.state,
            owner = cursor.owner,
            bindings = cursor.bindings,
            budget = cursor.budget,
            wakeAt = cursor.wakeAt,
            seq = cursor.seq,
            loopRegs = cursor.loopRegs,
            waitChannel = cursor.waitChannel,
            waitQuery = cursor.waitQuery,
            waitCondition = cursor.waitCondition,
            tweenEntity = cursor.tweenEntity,
            tweenPlayback = cursor.tweenPlayback,
            tweenOutcome = cursor.tweenOutcome,
            waitingTween = cursor.waitingTween,
            parentSlot = cursor.parentSlot,
            parentGeneration = cursor.parentGeneration,
            joining = cursor.joining,
         }
      end
   end

   return {
      version = SNAPSHOT_VERSION,
      step = state.step,
      seq = state.seq,
      budget = state.budget,
      nextSlot = state.nextSlot,
      generations = state.generations,
      programs = programs,
      cursors = cursors,
      pendingSignals = state.pendingSignals,
   }
end

local function loadState(world, value)


   if value ~= nil then
      if type(value) ~= "table" then
         error("tecs2d.sequence snapshot data must be a table", 2)
      end
      local header = value
      if header.version ~= SNAPSHOT_VERSION then
         error("unsupported tecs2d.sequence snapshot version: " ..
         tostring(header.version), 2)
      end
   end

   local state = stateFor(world)



   for _, cursor in pairs(state.cursors) do
      if cursor.alive then releaseProgram(cursor.program) end
   end


   state.cursors = {}
   state.freeSlots = {}
   state.ownerIndex = {}
   wakeheap.clear(state.heap)
   state.channels = {}
   state.pendingSignals = {}


   state.queryWaiters = {}
   state.dirtyQueries = {}
   state.tweenOwners = {}
   state.tweenWaiters = {}

   state.context = nil
   state.argScratch = {}
   state.nextSlot = 1
   state.generations = {}
   state.step = 0
   state.seq = 0

   local data = value
   if not data then return end

   state.step = (data.step) or 0
   state.seq = (data.seq) or 0
   state.budget = (data.budget) or DEFAULT_BUDGET
   state.nextSlot = (data.nextSlot) or 1
   state.generations = (data.generations) or {}
   state.pendingSignals = (data.pendingSignals) or {}

   local restored = {}
   local programs = (data.programs) or {}
   for i = 1, #programs do
      local prog = restoreProgram(programs[i])
      restored[prog.name .. "@" .. tostring(prog.version)] = prog
   end

   local cursors = (data.cursors) or {}
   for i = 1, #cursors do
      local row = cursors[i]
      local key = (row.program) .. "@" .. tostring(row.version)
      local prog = restored[key]
      if prog then
         local cursor = {
            slot = row.slot,
            generation = row.generation,
            alive = true,
            program = prog,
            pc = row.pc,
            state = row.state,
            owner = (row.owner) or 0,
            bindings = row.bindings,
            budget = (row.budget) or state.budget,
            wakeAt = row.wakeAt,
            seq = row.seq,
            loopRegs = row.loopRegs,
            waitChannel = row.waitChannel,
            waitQuery = row.waitQuery,
            waitCondition = row.waitCondition,
            tweenEntity = row.tweenEntity,
            tweenPlayback = row.tweenPlayback,
            tweenOutcome = row.tweenOutcome,
            waitingTween = row.waitingTween,
            parentSlot = row.parentSlot,
            parentGeneration = row.parentGeneration,
            joining = row.joining,
         }
         retainProgram(prog)
         state.cursors[cursor.slot] = cursor
         linkOwner(state, cursor)
         if cursor.tweenPlayback then
            state.tweenOwners[cursor.tweenPlayback] = cursor.slot
         end




         if cursor.waitChannel then
            park(state.channels, cursor.waitChannel, cursor.slot)
         elseif cursor.waitQuery then
            park(state.queryWaiters, cursor.waitQuery, cursor.slot)


            state.dirtyQueries[cursor.waitQuery] = true
         elseif cursor.waitingTween then
            state.tweenWaiters[cursor.slot] = true
         elseif not cursor.joining then
            wakeheap.push(state.heap, cursor.wakeAt, cursor.seq,
            packHandle(cursor.slot, cursor.generation))
         end
      else
         LOGGER:warn("dropping cursor for missing program %s", key)
      end
   end



   local liveSlots = {}
   for slot in pairs(state.cursors) do liveSlots[#liveSlots + 1] = slot end
   table.sort(liveSlots)


   for i = 1, #liveSlots do
      local cursor = state.cursors[liveSlots[i]]
      local parentSlot = cursor.parentSlot
      if parentSlot then
         local parent = state.cursors[parentSlot]
         if parent and parent.generation == cursor.parentGeneration then
            local children = parent.children
            if not children then
               children = {}
               parent.children = children
            end
            children[cursor.slot] = true
         else
            cursor.parentSlot = nil
            cursor.parentGeneration = nil
         end
      end
   end



   for i = 1, #liveSlots do
      local cursor = state.cursors[liveSlots[i]]
      if cursor.joining and (not cursor.children or next(cursor.children) == nil) then
         LOGGER:warn("%s v%d: join at pc=%d lost its branches; resuming",
         cursor.program.name, cursor.program.version, cursor.pc)
         cursor.joining = false
         schedule(state, cursor, state.step + 1)
      end
   end


   for slot = 1, state.nextSlot - 1 do
      if not state.cursors[slot] then
         state.freeSlots[#state.freeSlots + 1] = slot
      end
   end
end





local function deliverSignals(state)
   local signals = state.pendingSignals
   local count = #signals
   if count == 0 then return end
   state.pendingSignals = {}

   for i = 1, count do
      local blocked = state.channels[signals[i]]
      if blocked then


         local slots = {}
         for slot in pairs(blocked) do slots[#slots + 1] = slot end
         table.sort(slots)
         for j = 1, #slots do
            local cursor = state.cursors[slots[j]]
            if cursor and cursor.alive then
               unlinkWaits(state, cursor)
               schedule(state, cursor, state.step)
            end
         end
      end
   end
end





local function deliverQueryWaits(state)
   local dirty = state.dirtyQueries
   if next(dirty) == nil then return end
   state.dirtyQueries = {}

   local names = {}
   for name in pairs(dirty) do names[#names + 1] = name end
   table.sort(names)

   for i = 1, #names do
      local name = names[i]
      local waiting = state.queryWaiters[name]
      local query = state.queries[name]
      if waiting and query then
         local matched = query:count() > 0 and 1 or 0
         local slots = {}
         for slot in pairs(waiting) do slots[#slots + 1] = slot end
         table.sort(slots)
         for j = 1, #slots do
            local cursor = state.cursors[slots[j]]
            if cursor and cursor.alive and cursor.waitCondition == matched then
               unlinkWaits(state, cursor)
               schedule(state, cursor, state.step)
            end
         end
      end
   end
end





local function deliverTweenWaits(world, state)
   local waiting = state.tweenWaiters
   if next(waiting) == nil then return end

   local slots = {}
   for slot in pairs(waiting) do slots[#slots + 1] = slot end
   table.sort(slots)

   for i = 1, #slots do
      local cursor = state.cursors[slots[i]]
      if not cursor or not cursor.alive then
         waiting[slots[i]] = nil
      elseif cursor.state == "running" then
         local outcome = cursor.tweenOutcome
         if not outcome and
            not tween.isPlaying(world, cursor.tweenEntity, cursor.tweenPlayback) then

            LOGGER:warn("%s v%d: tween %d ended without an event",
            cursor.program.name, cursor.program.version, cursor.tweenPlayback)
            outcome = "targetLost"
            cursor.tweenOutcome = outcome
         end
         if outcome then
            unlinkWaits(state, cursor)
            releaseTween(state, cursor)
            schedule(state, cursor, state.step)
         end
      end
   end
end

local function tick(world, state)
   state.step = state.step + 1
   local step = state.step

   deliverSignals(state)
   deliverQueryWaits(state)
   deliverTweenWaits(world, state)

   local heap = state.heap
   while true do
      local due = wakeheap.peek(heap)
      if not due or due > step then break end
      local _, seq, handle = wakeheap.pop(heap)
      local packed = handle
      local slot = packed % SLOT_LIMIT
      local generation = (packed - slot) / SLOT_LIMIT
      local cursor = state.cursors[slot]

      if cursor and
         cursor.generation == generation and
         cursor.alive and
         cursor.seq == seq then

         if cursor.state == "paused" then

            cursor.wakeAt = step
         else
            advance(world, state, cursor)
         end
      end
   end
end

function sequence.plugin(world)
   local state = stateFor(world)

   world:addSystem({
      name = "sequence.Advance",
      phase = tecs.phases.FixedFirst,
      run = function()
         tick(world, state)
      end,
   })

   world:addSnapshotHandler({
      name = "tecs2d.sequence",
      save = function(w)
         return saveState(w)
      end,
      load = function(w, value)
         loadState(w, value)
      end,
   })


   world:observe(0, tecs.builtins.OnDespawn, function(event)
      if state.ownerIndex[event.entity] then
         sequence.cancelOwnedBy(world, event.entity)
      end
   end)




   local function endTween(slotOwner, playback, outcome)
      local cursor = state.cursors[slotOwner]
      if not cursor or not cursor.alive then return end
      if cursor.tweenPlayback ~= playback then return end
      cursor.tweenOutcome = outcome
   end

   world:observe(0, tween.TweenComplete, function(event)
      local owner = state.tweenOwners[event.playback]
      if owner then endTween(owner, event.playback, "completed") end
   end)

   world:observe(0, tween.TweenCancelled, function(event)
      local owner = state.tweenOwners[event.playback]
      if owner then endTween(owner, event.playback, event.reason) end
   end)
end

return sequence
