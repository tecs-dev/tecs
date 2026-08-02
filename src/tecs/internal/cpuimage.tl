-- Private adapter for the bounded native CPU image-decode lane.

local floor <const> = math.floor
local loader <const> = require("tecs.ffi.loader")
local rust <const> = require("tecs.ffi.rust")
local Completion <const> = require("tecs.internal.completion")
local runtime <const> = require("tecs.internal.runtime")

local R <const> = rust.C
local STATUS_PENDING <const> = 0
local STATUS_READY <const> = 1
local STATUS_FAILED <const> = 2
local SOURCE_NAME <const> = "cpu-images"

local record Entry
    handle: loader.CPtr
    completion: Completion<loader.CPtr>
end

local record Source
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: Source): integer
    advance: function(self: Source, ms: number): integer
    cancel: function(self: Source, completion: Completion<any>)
end

local record cpuimage
    decode: function(bytes: loader.CPtr): Completion<loader.CPtr>
    take: function(request: loader.CPtr): loader.CPtr
end

local entries: {Entry} = {}
local registered = false
local source: Source

local function unregisterIfIdle()
    if registered and #entries == 0 then
        registered = false
        runtime.unregister(SOURCE_NAME)
    end
end

local function settle(): integer
    local completed = 0
    local index = #entries
    while index > 0 do
        local entry <const> = entries[index]
        local status <const> = floor(tonumber(R.tecsImageDecodeStatus(entry.handle)) or STATUS_FAILED) as integer
        if status ~= STATUS_PENDING then
            entries[index] = entries[#entries]
            entries[#entries] = nil
            completed = completed + 1
            if entry.completion == nil then
                R.tecsImageDecodeRequestDestroy(entry.handle)
            elseif status == STATUS_READY then
                entry.completion:complete(entry.handle)
            else
                local reason <const> = loader.toString(R.tecsImageDecodeError(entry.handle))
                R.tecsImageDecodeRequestDestroy(entry.handle)
                entry.completion:fail(reason)
            end
        end
        index = index - 1
    end
    unregisterIfIdle()
    return completed
end

function Source:poll(): integer
    return settle()
end

function Source:advance(ms: number): integer
    if #entries > 0 then
        R.tecsImageDecodeWait(entries[1].handle, math.max(0, floor(ms)))
    end
    return settle()
end

function Source:cancel(completion: Completion<any>)
    for index = 1, #entries do
        local entry <const> = entries[index]
        if (entry.completion as Completion<any>) == completion then
            entry.completion = nil
            R.tecsImageDecodeRequestDestroy(entry.handle)
            return
        end
    end
end

source = {
    sliceMs = 1,
    defaultWaitMs = 30000,
    poll = Source.poll,
    advance = Source.advance,
    cancel = Source.cancel,
}

function cpuimage.decode(bytes: loader.CPtr): Completion<loader.CPtr>
    local request <const> = R.tecsImageDecodeStart(bytes)
    if request == nil then
        return Completion.failed(loader.toString(R.tecsRustError())) as Completion<loader.CPtr>
    end
    local completion <const> = Completion.pending(source as Completion.Source) as Completion<loader.CPtr>
    entries[#entries + 1] = {handle = request, completion = completion}
    if not registered then
        registered = true
        runtime.register(SOURCE_NAME, 30, function(): integer return source:poll() end)
    end
    return completion
end

function cpuimage.take(request: loader.CPtr): loader.CPtr
    local image <const> = R.tecsImageDecodeTake(request)
    if image == nil then
        error("tecs: cannot take decoded image: " .. loader.toString(R.tecsRustError()), 2)
    end
    return image
end

return cpuimage
