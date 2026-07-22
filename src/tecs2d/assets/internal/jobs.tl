-- Asset decoding functions executed inside a Tecs2D worker state. Inputs and
-- results must remain transferable through love.thread.Channel.
local modules = {"event", "data", "image", "audio", "sound", "font", "filesystem"}
for i = 1, #modules do require("love." .. modules[i]) end

local json <const> = require("tecs.utils.json")

local record Request
    path: string
    sourceType: love.audio.SourceType
    streamType: string
end

local record jobs
    loadFile: function(Request): string
    loadFileData: function(Request): love.filesystem.FileData
    loadImage: function(Request): love.image.ImageData
    loadImageFont: function(Request): love.image.ImageData
    loadFont: function(Request): string
    loadAudio: function(Request): love.audio.Source
    loadShader: function(Request): string
    loadVideo: function(Request): string
    loadCompressedImage: function(Request): love.image.CompressedImageData
    loadJson: function(Request): any
end

function jobs.loadFile(input: Request): string
    return assert(love.filesystem.read(input.path))
end

function jobs.loadFileData(input: Request): love.filesystem.FileData
    local data = love.filesystem.newFileData(input.path)
    return data
end

function jobs.loadImage(input: Request): love.image.ImageData
    return love.image.newImageData(input.path)
end

jobs.loadImageFont = jobs.loadImage

function jobs.loadFont(input: Request): string
    return assert(love.filesystem.read(input.path))
end

function jobs.loadAudio(input: Request): love.audio.Source
    local sourceType = input.sourceType or "static"
    if sourceType == "stream" and input.streamType then
        return love.audio.newSource(input.path, sourceType, input.streamType)
    end
    return love.audio.newSource(input.path, sourceType)
end

function jobs.loadShader(input: Request): string
    return assert(love.filesystem.read(input.path))
end

function jobs.loadVideo(input: Request): string
    return assert(love.filesystem.read(input.path))
end

function jobs.loadCompressedImage(input: Request): love.image.CompressedImageData
    return love.image.newCompressedData(input.path)
end

function jobs.loadJson(input: Request): any
    return json.parse(assert(love.filesystem.read(input.path)))
end

return jobs
