local taskChannelName, resultChannelName: string = ...
assert(taskChannelName, "Expected a worker task channel")
assert(resultChannelName, "Expected a worker result channel")

local taskChannel <const> = love.thread.getChannel(taskChannelName)
local resultChannel <const> = love.thread.getChannel(resultChannelName)

while true do
    local task = taskChannel:demand() as any
    if task == false then break end

    local data = task as {any}
    local id = assert(data[1] as integer, "Worker task is missing its ID")
    local moduleName = assert(data[2] as string, "Worker task is missing its module")
    local functionName = (data[3] as string) or "run"
    local input = data[4]

    local okModule, loaded = pcall(require, moduleName) as (boolean, any)
    if not okModule then
        resultChannel:push({id, nil, "Could not load worker job '" .. moduleName .. "': " .. tostring(loaded)})
    else
        local fn: function(any): any
        if type(loaded) == "function" and functionName == "run" then
            fn = loaded as function(any): any
        elseif type(loaded) == "table" then
            fn = (loaded as {string: function(any): any})[functionName]
        end
        if not fn then
            resultChannel:push({id, nil, "Worker job '" .. moduleName .. "' has no function '" .. functionName .. "'"})
        else
            local ok, value = pcall(fn, input) as (boolean, any)
            if ok then
                resultChannel:push({id, value, nil})
            else
                resultChannel:push({id, nil, tostring(value)})
            end
        end
    end
end
