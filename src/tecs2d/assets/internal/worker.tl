local modules = {"event", "data", "image", "audio", "sound", "font", "filesystem"}
for i = 1, #modules do
    require("love." .. modules[i])
end

-- Polyfill table.unpack for Lua 5.1/LuaJIT
if not table.unpack then
    ((_G as table)["table"] as table).unpack = (_G as table)["unpack"]
end

local json = require("tecs.utils.json")
local unpack <const> = table.unpack

local taskChannelName, resultChannelName: string = ...
assert(taskChannelName, "Expected a push channel name")
assert(resultChannelName, "Expected a pull channel name")

local taskChannel: love.thread.Channel = love.thread.getChannel(taskChannelName)
local resultChannel: love.thread.Channel = love.thread.getChannel(resultChannelName)

local functions: {string:function(path: string, ...: any): boolean, any, number | string} = {
    loadFile = function(path: string): boolean, any, number | string
        return pcall(love.filesystem.read, path)
    end,
    loadFileData = function(path: string): boolean, any, number | string
        return pcall(love.filesystem.newFileData, path)
    end,
    loadImage = function(path: string): boolean, any, number | string
        return pcall(love.image.newImageData, path)
    end,
    loadImageFont = function(path: string): boolean, any, number | string
        return pcall(love.image.newImageData, path)
    end,
    loadFont = function(path: string): boolean, any, number | string
        -- Font creation must happen on the main thread, so just verify the file exists
        return pcall(love.filesystem.read, path)
    end,
    loadAudio = function(path: string, sourceType: love.audio.SourceType, streamType: string): boolean, any, number | string
        sourceType = sourceType or "static"
        if sourceType == "stream" and streamType then
            return pcall(love.audio.newSource, path, sourceType, streamType)
        else
            return pcall(love.audio.newSource, path, sourceType)
        end
    end,
    loadShader = function(path: string): boolean, any, number | string
        return pcall(love.filesystem.read, path)
    end,
    loadVideo = function(path: string): boolean, any, number | string
        -- Video creation must happen on the main thread, so just verify the file exists
        return pcall(love.filesystem.read, path)
    end,
    loadCompressedImage = function(path: string): boolean, any, number | string
        return pcall(love.image.newCompressedData, path)
    end,
    loadJson = function(path: string): boolean, any, number | string
        return pcall(function(): any
            local content = love.filesystem.read(path)
            if not content then
                error("Could not read file: " .. path)
            end
            return json.parse(content)
        end)
    end
}

while true do
    local taskData: {any} = taskChannel:demand() as {any}

    -- If `nil` is received, terminate the worker thread
    if not taskData then
        break
    end

    if type(taskData) ~= "table" then
        error("Expected a table from the thread channel, but got: " .. type(taskData))
    end

    local id: integer = assert(taskData[1] as integer, "Missing ID for task")
    local action: string = assert(taskData[2] as string, "Missing action for task")
    local path: string = assert(taskData[3] as string, "Missing path for task")

    local fn = functions[action]
    if not fn then
        resultChannel:push({id, nil, "Unsupported action: " .. action})
    else
        local success, result = fn(path, unpack(taskData, 4))
        if success then
            resultChannel:push({id, result, nil})
        else
            resultChannel:push({id, nil, tostring(result)})
        end
    end
end
