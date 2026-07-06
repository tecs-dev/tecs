--[[
Bundle spawn codegen: generates specialized (spawn, drain) pairs for a
bundle's fixed component list.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")

local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type WorldImpl = internal.WorldImpl

local record BundleCodegen
    type SpawnFn = function(any, ...: Component): integer
    type DrainFn = function()

    codegenBundleSpawn: function(
        world: WorldImpl,
        typeArray: {Component},
        factoryArray: {function(): Component},
        requiredCount: integer
    ): SpawnFn
end

-- Build newline-joined repetitions of a template with %d replaced by
-- each index from `lo..hi`.
local function lines(template: string, lo: integer, hi: integer): string
    if hi < lo then return "" end
    local parts: {string} = {}
    for i = lo, hi do
        parts[#parts + 1] = (template:gsub("%%d", tostring(i)))
    end
    return table.concat(parts, "\n")
end

-- Build comma-separated "v1, v2, ..., vN" list from lo..hi.
local function seq(prefix: string, lo: integer, hi: integer, sep: string): string
    if hi < lo then return "" end
    local parts: {string} = {}
    for i = lo, hi do parts[#parts + 1] = prefix .. i end
    return table.concat(parts, sep)
end

local function codegenSrc(n: integer, requiredCount: integer, isSparse: {boolean}, isScalar: {boolean}): string
    -- Deferred path stores raw slots (NOT packed ids) + component values
    -- in a bundle-local queue. `queueSlot[i]` is the per-component offset
    -- within the queue's per-entity record; sparse components don't
    -- occupy a queue slot (they go to the per-world sparse store).
    local queueSlot: {integer} = {}
    local nonSparseCount = 0
    for i = 1, n do
        if not isSparse[i] then
            nonSparseCount = nonSparseCount + 1
            queueSlot[i] = nonSparseCount
        end
    end
    local stride = 1 + nonSparseCount  -- slot + non-sparse values

    -- Upvalues: world, allocSlot, plus component types (T1..Tn) and
    -- factories for the non-required suffix.
    local upvalueList: string do
        local parts: {string} = {"world", "allocSlot"}
        for i = 1, n do parts[#parts + 1] = "T" .. i end
        for i = requiredCount + 1, n do parts[#parts + 1] = "f" .. i end
        upvalueList = table.concat(parts, ", ")
    end

    local paramList = seq("r", 1, requiredCount, ", ")
    if paramList ~= "" then paramList = ", " .. paramList end

    local walkChain = lines("    a = a:withComponent(T%d, archIdx)", 1, n)

    local cachedColDecls: string do
        local parts: {string} = {}
        for i = 1, n do
            if not isSparse[i] then parts[#parts + 1] = "col" .. i end
        end
        cachedColDecls = #parts > 0 and ("local " .. table.concat(parts, ", ")) or ""
    end
    local fetchColsResolve: string do
        local parts: {string} = {}
        for i = 1, n do
            if not isSparse[i] then
                parts[#parts + 1] = "    col" .. i .. " = a.columns[T" .. i .. "]"
            end
        end
        fetchColsResolve = table.concat(parts, "\n")
    end
    local fetchColsGrow: string do
        local parts: {string} = {}
        for i = 1, n do
            if not isSparse[i] then
                parts[#parts + 1] = "            col" .. i .. " = a.columns[T" .. i .. "]"
            end
        end
        fetchColsGrow = table.concat(parts, "\n")
    end

    -- `valueExpr(i)` is the source expression for component i's value:
    -- `rN` for required params, `fN()` for factory-backed components.
    -- Scalar component args are wrapper tables (`{componentType, value}`);
    -- the column wants the raw scalar, so we extract `.value` here at
    -- the API boundary -- internals never see wrappers.
    local function valueExpr(i: integer): string
        local base = i <= requiredCount and ("r" .. i) or ("f" .. i .. "()")
        if isScalar[i] then return "(" .. base .. ").value" end
        return base
    end

    -- Immediate path column/sparse writes.
    local columnWritesImmediate: string do
        local parts: {string} = {}
        for i = 1, n do
            if isSparse[i] then
                parts[#parts + 1] = "    world:setSparseRaw(slot, " .. valueExpr(i) .. ")"
            else
                parts[#parts + 1] = "    col" .. i .. "[row] = " .. valueExpr(i)
            end
        end
        columnWritesImmediate = table.concat(parts, "\n")
    end

    -- Deferred path: push value into bundle's own queue at offset
    -- queueSlot[i]; sparse goes to world's per-entity store.
    local enqueuePushes: string do
        local parts: {string} = {}
        parts[#parts + 1] = "        spawnQueue[c + 1] = slot"
        for i = 1, n do
            if isSparse[i] then
                parts[#parts + 1] = "        world:setSparseRaw(slot, " .. valueExpr(i) .. ")"
            else
                parts[#parts + 1] = "        spawnQueue[c + " .. (queueSlot[i] + 1) .. "] = " .. valueExpr(i)
            end
        end
        enqueuePushes = table.concat(parts, "\n")
    end

    -- Deferred drain column writes: read value back from queue at the
    -- per-component offset and write into the dest column.
    local drainColumnWrites: string do
        local parts: {string} = {}
        for i = 1, n do
            if not isSparse[i] then
                parts[#parts + 1] = "        col" .. i .. "[row] = spawnQueue[i + " .. queueSlot[i] .. "]"
            end
        end
        drainColumnWrites = table.concat(parts, "\n")
    end

    local requiredChecks: string do
        local parts: {string} = {}
        for i = 1, requiredCount do
            parts[#parts + 1] = string.format(
                "    if r%d == nil then error('Required component missing: ' .. T%d.componentName, 2) end",
                i, i)
        end
        requiredChecks = table.concat(parts, "\n")
    end

    -- Two hot paths in the emitted spawn:
    --   1. `_scopeDepth == 0`: immediate placement -- the entity is
    --      placed directly into the cached target archetype and
    --      observer-notified inline.
    --   2. `_scopeDepth > 0`: enqueue into the bundle-local spawnQueue
    --      and register `drain` with the arch so `_drain` invokes it
    --      at commit. Amortizes the archetype walk vs naive
    --      `world:_deferSpawn(...)` which re-walks per entity.
    local src: string = [[
local __UPVALUES__ = ...

local cachedArch = nil
local cachedAutoState = nil
local cachedGen = -1
__CACHED_COL_DECLS__

local spawnQueue = {}
local spawnQueueCount = 0
local pendingDrain = false
local drain  -- forward ref

local function resolveArch()
    local archIdx = world.archetypeIndex
    local a = world.emptyArchetype
__WALK_CHAIN__
    local autoState = world.autoStateComponent
    if autoState then a = a:withComponent(autoState, archIdx) end
    cachedArch = a
    cachedAutoState = autoState
    cachedGen = a.generation
__FETCH_COLS_RESOLVE__
    return a
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

    if world._scopeDepth > 0 then
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

__COLUMN_WRITES_IMMEDIATE__

    a:onRowsAdded(row - 1, 1, nil)

    return id
end

drain = function()
    local a = cachedArch
    if a == nil or world.autoStateComponent ~= cachedAutoState then
        a = resolveArch()
    elseif a.generation ~= cachedGen then
        -- Another spawn path grew the archetype and swapped its columns.
        cachedGen = a.generation
__FETCH_COLS_RESOLVE__
    end

    local slots = world.allocator.slots
    local archId = a.id
    local GEN_STRIDE = __GEN_STRIDE__

    local i = 1
    while i <= spawnQueueCount do
        local slot = spawnQueue[i]

        local entities = a.entities
        local row = entities[0] + 1
        if row > a.capacity then
            a:reserveCapacity(row)
            entities = a.entities
            cachedGen = a.generation
__FETCH_COLS_GROW__
        end
        local es = slots[slot]
        es.archetypeId = archId
        es.row = row - 1
        local id = slot + es.generation * GEN_STRIDE
        entities[row] = id
        entities[0] = row

__DRAIN_COLUMN_WRITES__

        a:onRowsAdded(row - 1, 1, nil)

        i = i + __STRIDE__
    end

    spawnQueueCount = 0
    pendingDrain = false
end

return spawn, drain
]]
    -- Grow path for immediate: indentation differs (outer level).
    local fetchColsGrowImmediate: string do
        local parts: {string} = {}
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
    src = src:gsub("__WALK_CHAIN__", walkChain)
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
    world: WorldImpl,
    typeArray: {Component},
    factoryArray: {function(): Component},
    requiredCount: integer
): BundleCodegen.SpawnFn
    local n = #typeArray

    if n == 0 then
        return function(_self: any): integer
            return world:spawn()
        end
    end

    local isSparse: {boolean} = {}
    local isScalar: {boolean} = {}
    for i = 1, n do
        local ci = typeArray[i] as ComponentInternal
        isSparse[i] = ci.isSparse or false
        isScalar[i] = ci.storageType == "scalar"
    end

    local src = codegenSrc(n, requiredCount, isSparse, isScalar)
    local chunk, err = load(src, "=bundle_spawn", "t")
    if not chunk then error("bundle codegen failed: " .. tostring(err)) end

    -- Upvalue order must match the generated `local ... = ...` line:
    -- world, allocSlot, T1..Tn, f(requiredCount+1)..fn.
    local args: {any} = {
        world,
        IdAllocator.allocSlot,
    }
    for i = 1, n do args[#args + 1] = typeArray[i] end
    for i = requiredCount + 1, n do args[#args + 1] = factoryArray[i] end
    local packed = {(chunk as function(any...): any...)(table.unpack(args, 1, #args))}
    -- Generated chunk returns `spawn, drain`. `drain` is kept alive via
    -- the `drain = function() ... end` assignment inside the chunk's
    -- closure -- it's the upvalue that `pendingBundleDrains` points at
    -- during deferred bursts. We only need to hand the caller `spawn`.
    return packed[1] as BundleCodegen.SpawnFn
end

return BundleCodegen
