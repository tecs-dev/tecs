--[=[
The process-wide registry behind `tecs.runtime`.

Facilities register only while they have something a nonblocking process pump
can advance. This module requires none of them, which keeps every dependency
pointing down and lets the public pump stay independent of native services.
]=]

local record Entry
    name: string
    order: integer
    poll: function(): integer
end

local record runtime
    register: function(name: string, order: integer, poll: function(): integer)
    unregister: function(name: string)
    poll: function(): integer
end

local entries <const>: {Entry} = {}
local byName <const>: {string: Entry} = {}
local turning <const>: {Entry} = {}

function runtime.register(name: string, order: integer, poll: function(): integer)
    if byName[name] ~= nil then
        error("tecs: runtime source " .. name .. " is already registered", 2)
    end
    local entry: Entry = {name = name, order = order, poll = poll}
    byName[name] = entry
    entries[#entries + 1] = entry
    table.sort(entries, function(left: Entry, right: Entry): boolean
        return left.order < right.order or left.order == right.order and left.name < right.name
    end)
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
