--[=[
The process-wide registry behind `tecs.runtime`.

Facilities register only while they have something a nonblocking process pump
can advance. This module requires none of them, which keeps every dependency
pointing down and lets the public pump stay independent of native services.
]=]

local type Shutdown = function()

local record Entry
    name: string
    order: integer
    poll: function(): integer
    shutdown: Shutdown
end

local record runtime
    register: function(name: string, order: integer, poll: function(): integer, shutdown: Shutdown)
    unregister: function(name: string)
    registered: function(name: string): boolean
    poll: function(): integer
    shutdown: function(): boolean, string
end

local entries <const>: {Entry} = {}
local byName <const>: {string: Entry} = {}
local turning <const>: {Entry} = {}

function runtime.register(name: string, order: integer, poll: function(): integer, shutdown: Shutdown)
    if byName[name] ~= nil then
        error("tecs: runtime source " .. name .. " is already registered", 2)
    end
    local entry: Entry = {name = name, order = order, poll = poll, shutdown = shutdown}
    byName[name] = entry
    entries[#entries + 1] = entry
    table.sort(
        entries,
        function(left: Entry, right: Entry): boolean
            return left.order < right.order or left.order == right.order and left.name < right.name
        end
    )
end

--- Shuts down a stable reverse-order view of every active source.
--- Sources remove themselves after releasing their work. Any source left in
--- the registry exposes a lifecycle bug instead of silently surviving SDL.
function runtime.shutdown(): boolean, string
    local turns <const> = #entries
    for index = 1, turns do
        turning[index] = entries[index]
    end

    local failures: {string} = {}
    for index = turns, 1, -1 do
        local entry <const> = turning[index]
        turning[index] = nil
        if byName[entry.name] == entry and entry.shutdown ~= nil then
            local ok <const>, failure = xpcall(entry.shutdown, debug.traceback) as (boolean, string)
            if not ok then
                failures[#failures + 1] = entry.name .. ": " .. failure
            end
        end
    end

    if #entries > 0 then
        local names: {string} = {}
        for index = 1, #entries do
            names[index] = entries[index].name
        end
        failures[#failures + 1] = "active sources remain: " .. table.concat(names, ", ")
    end
    if #failures > 0 then
        return false, table.concat(failures, "\n")
    end
    return true
end

--- Reports whether a source currently holds the registry under this name. A
--- facility that registers only while it has work uses it to prove it let go.
function runtime.registered(name: string): boolean
    return byName[name] ~= nil
end

function runtime.unregister(name: string)
    local entry = byName[name]
    if entry == nil then
        return
    end
    byName[name] = nil
    for index = 1, #entries do
        if entries[index] == entry then
            table.remove(entries, index)
            return
        end
    end
end

--- Pumps a stable view. A listener may activate or deactivate another source;
--- a newly active source waits for the next turn, and one deactivated before
--- its turn is skipped.
function runtime.poll(): integer
    local turns <const> = #entries
    for index = 1, turns do
        turning[index] = entries[index]
    end

    local settled = 0
    for index = 1, turns do
        local entry <const> = turning[index]
        turning[index] = nil
        if byName[entry.name] == entry then
            settled = settled + entry.poll()
        end
    end
    return settled
end

return runtime
