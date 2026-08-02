-- Private adapter from the native SDL AsyncIO queue to one-shot completions.
-- The native side owns the bounded open lane, byte limits, and buffers. This
-- module only publishes outcomes on the Lua thread.

local floor <const> = math.floor
local loader <const> = require("tecs.ffi.loader")
local rust <const> = require("tecs.ffi.rust")
local Completion <const> = require("tecs.internal.completion")
local runtime <const> = require("tecs.internal.runtime")

local R <const> = rust.C
local STATUS_PENDING <const> = 0
local STATUS_READY <const> = 1
local STATUS_FAILED <const> = 2
local STATUS_CANCELED <const> = 3
local SOURCE_NAME <const> = "file-async"

local record NativeRead
    handle: loader.CPtr
    pointer: loader.BytePointer
    length: integer
end

local record Entry
    handle: loader.CPtr
    completion: Completion<NativeRead>
    owner: any
    closeOwner: boolean
end

local record FileSource
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: FileSource): integer
    advance: function(self: FileSource, ms: number): integer
    cancel: function(self: FileSource, completion: Completion<any>)
end

local record fileasync
    type NativeRead = NativeRead
    read: function(path: string): Completion<NativeRead>
    write: function(
        path: string,
        pointer: loader.BytePointer,
        length: integer,
        owner: any,
        closeOwner?: boolean,
        flush?: boolean
    ): Completion<NativeRead>
    release: function(read: NativeRead)
    takeBytes: function(read: NativeRead): loader.CPtr
    shutdown: function()
end

local entries: {Entry} = {}
local registered = false
local source: FileSource

local function releaseOwner(entry: Entry)
    local owner <const> = entry.owner
    entry.owner = nil
    if entry.closeOwner and owner ~= nil then
        (owner as {string: function(any): boolean, string}).close(owner)
    end
end

local function unregisterIfIdle()
    if registered and #entries == 0 then
        registered = false
        runtime.unregister(SOURCE_NAME)
    end
end

local function remove(index: integer)
    entries[index] = entries[#entries]
    entries[#entries] = nil
end

local function settle(): integer
    local settled = 0
    local index = #entries
    while index > 0 do
        local entry <const> = entries[index]
        local status <const> = floor(tonumber(R.tecsAsyncFileStatus(entry.handle)) or STATUS_FAILED) as integer
        if status ~= STATUS_PENDING then
            remove(index)
            releaseOwner(entry)
            settled = settled + 1
            local completion <const> = entry.completion
            if completion == nil then
                -- Native kept the abandoned request alive until SDL stopped
                -- referencing its userdata.
                R.tecsAsyncFileDestroy(entry.handle)
            elseif status == STATUS_READY then
                completion:complete({
                    handle = entry.handle,
                    pointer = R.tecsAsyncFileData(entry.handle) as loader.BytePointer,
                    length = floor(tonumber(R.tecsAsyncFileLength(entry.handle)) or 0) as integer,
                })
            elseif status == STATUS_CANCELED then
                R.tecsAsyncFileDestroy(entry.handle)
                completion:abandon("file operation was canceled")
            else
                local reason <const> = loader.toString(R.tecsAsyncFileError(entry.handle))
                R.tecsAsyncFileDestroy(entry.handle)
                completion:fail(reason)
            end
        end
        index = index - 1
    end
    unregisterIfIdle()
    return settled
end

function FileSource:poll(): integer
    R.tecsAsyncFilePoll()
    return settle()
end

function FileSource:advance(ms: number): integer
    R.tecsAsyncFileWait(math.max(0, floor(ms)))
    return settle()
end

function FileSource:cancel(completion: Completion<any>)
    for index = 1, #entries do
        local entry <const> = entries[index]
        if (entry.completion as Completion<any>) == completion then
            entry.completion = nil
            -- Native retains an abandoned request until SDL and the open lane
            -- can no longer reference it.
            R.tecsAsyncFileDestroy(entry.handle)
            return
        end
    end
end

source = {
    -- The bounded open lane is not represented by the SDL completion queue,
    -- so a blocking caller may briefly sleep while the worker opens a path.
    -- Keep that fallback below a frame-scale wait; SDL itself still wakes the
    -- call immediately once an async transfer outcome is available.
    sliceMs = 1,
    defaultWaitMs = 30000,
    poll = FileSource.poll,
    advance = FileSource.advance,
    cancel = FileSource.cancel,
}

local function track(handle: loader.CPtr, owner?: any, closeOwner?: boolean): Completion<NativeRead>
    if handle == nil then
        if closeOwner and owner ~= nil then
            (owner as {string: function(any): boolean, string}).close(owner)
        end
        return Completion.failed(loader.toString(R.tecsRustError())) as Completion<NativeRead>
    end
    local completion <const> = Completion.pending(source as Completion.Source) as Completion<NativeRead>
    entries[#entries + 1] = {
        handle = handle,
        completion = completion,
        owner = owner,
        closeOwner = closeOwner == true,
    }
    if not registered then
        registered = true
        runtime.register(SOURCE_NAME, 25, function(): integer return source:poll() end)
    end
    return completion
end

function fileasync.read(path: string): Completion<NativeRead>
    return track(R.tecsAsyncFileRead(path, #path))
end

function fileasync.write(
    path: string,
    pointer: loader.BytePointer,
    length: integer,
    owner: any,
    closeOwner?: boolean,
    flush?: boolean
): Completion<NativeRead>
    return track(R.tecsAsyncFileWrite(path, #path, pointer, length, flush and 1 or 0), owner, closeOwner)
end

function fileasync.release(read: NativeRead)
    if read ~= nil and read.handle ~= nil then
        R.tecsAsyncFileDestroy(read.handle)
        read.handle = nil
        read.pointer = nil
        read.length = 0
    end
end

function fileasync.takeBytes(read: NativeRead): loader.CPtr
    if read == nil or read.handle == nil then
        error("tecs: native file read is released", 2)
    end
    local bytes <const> = R.tecsAsyncFileTakeBytes(read.handle)
    if bytes == nil then
        error("tecs: cannot take native file bytes: " .. loader.toString(R.tecsRustError()), 2)
    end
    read.handle = nil
    read.pointer = nil
    read.length = 0
    return bytes
end

function fileasync.shutdown()
    R.tecsAsyncFileShutdown()
    for index = 1, #entries do
        local entry <const> = entries[index]
        if entry.completion ~= nil and entry.completion.status == "pending" then
            entry.completion:abandon("application shutdown")
        end
        releaseOwner(entry)
        R.tecsAsyncFileDestroy(entry.handle)
        entries[index] = nil
    end
    unregisterIfIdle()
end

return fileasync
