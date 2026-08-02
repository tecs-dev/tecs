-- Shared, allocation-free control for the LuaJIT profiler zone stack.
--
-- LuaJIT's stock `jit.zone` callable pushes into a table even when no profiler
-- is listening. Tecs keeps it disabled by default and lets the profiling
-- module acquire it only for the lifetime of a sampling or trace session.

local table_remove <const> = table.remove

local function loadUntyped(name: string): any
    return require(name)
end

local stack = loadUntyped("jit.zone") as {string}
local stackMeta <const> = getmetatable(stack) as {any: any}

local record zones
    active: boolean
    version: integer
    stack: {string}
    acquire: function()
    release: function()
    push: function(?string): string
end

zones.active = false
zones.version = 0
zones.stack = stack

local references = 0

local function noopCall(_stack: {any}, _name: any): any
end

-- This pop tolerates an empty stack. A profile can start or stop while a
-- system is running, leaving one side of a push/pop pair intentionally absent.
local function realCall(target: {any}, name: any): any
    zones.version = zones.version + 1
    if name ~= nil then
        target[#target + 1] = name
        return
    end
    return table_remove(target)
end

stackMeta.__call = noopCall
for index = #stack, 1, -1 do
    stack[index] = nil
end

function zones.acquire()
    references = references + 1
    if references == 1 then
        zones.active = true
        stackMeta.__call = realCall
    end
end

function zones.release()
    references = references - 1
    if references > 0 then
        return
    end

    references = 0
    zones.active = false
    for index = #stack, 1, -1 do
        stack[index] = nil
    end
    stackMeta.__call = noopCall
end

function zones.push(name?: string): string
    return realCall(stack as {any}, name) as string
end

return zones
