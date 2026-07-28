--- Native open, save and folder dialogs.
---
--- SDL's callback stays in `native/dialogs.c`, because it may run on a thread
--- LuaJIT did not create. This module polls the copied answer and settles an
--- ordinary `Future` on the main thread.

local Future <const> = require("tecs.Future")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")

loader.declare("dialogs")

local C <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "dialogs")
local SDL <const> = sdl.C

local record WindowLike
    handle: loader.CPtr
end

local record Filter
    --- Label shown beside the filter, such as `"Images"`.
    name: string
    --- Semicolon-separated wildcard patterns, such as `"png;jpg;jpeg"`.
    pattern: string
end

local record Options
    window: WindowLike
    filters: {Filter}
    defaultLocation: string
    multiple: boolean
end

local record Result
    --- Selected paths. Empty when the user cancelled.
    paths: {string}
    --- One-based selected filter, or zero when no filter applies.
    filter: integer
    cancelled: boolean
end

local record dialogs
    Filter: Filter
    Options: Options
    Result: Result
end

local record Entry
    handle: loader.CPtr
    future: Future<Result>
end

local record Source
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: Source): integer
    advance: function(self: Source, ms: number): integer
end

local SourceMT <const>: metatable<Source> = {__index = Source}
local pending: {Entry} = {}

local function finish(entry: Entry)
    local handle = entry.handle
    local errorPointer = C.tecsDialogError(handle)
    if errorPointer ~= nil then
        entry.future:fail(loader.toString(errorPointer))
    else
        local paths: {string} = {}
        local count = tonumber(C.tecsDialogPathCount(handle)) as integer
        for index = 0, count - 1 do
            paths[index + 1] = loader.toString(C.tecsDialogPath(handle, index))
        end
        local selected = tonumber(C.tecsDialogFilter(handle)) as integer
        entry.future:complete({
            paths = paths,
            filter = selected >= 0 and selected + 1 or 0,
            cancelled = C.tecsDialogCancelled(handle) as boolean,
        })
    end
    C.tecsDialogDestroy(handle)
end

function Source:poll(): integer
    local settled = 0
    for index = #pending, 1, -1 do
        local entry = pending[index]
        if C.tecsDialogReady(entry.handle) then
            finish(entry)
            table.remove(pending, index)
            settled = settled + 1
        end
    end
    return settled
end

function Source:advance(ms: number): integer
    local settled = self:poll()
    if settled > 0 or ms <= 0 then
        return settled
    end
    SDL.SDL_Delay(math.floor(ms))
    return self:poll()
end

local source <const> = setmetatable({
    sliceMs = 16,
    defaultWaitMs = 300000,
} as Source, SourceMT)

local function filterArrays(options: Options): loader.CArray, loader.CArray, integer
    local filters = options.filters
    if filters == nil or #filters == 0 then
        return nil, nil, 0
    end
    local names = loader.newArray("const char *[?]", #filters)
    local patterns = loader.newArray("const char *[?]", #filters)
    for index = 1, #filters do
        local filter = filters[index]
        if filter.name == nil or filter.name == "" then
            error(("tecs: dialog filter %d needs a name"):format(index), 3)
        end
        if filter.pattern == nil or filter.pattern == "" then
            error(("tecs: dialog filter %d needs a pattern"):format(index), 3)
        end
        names[index - 1] = filter.name
        patterns[index - 1] = filter.pattern
    end
    return names, patterns, #filters
end

local function track(handle: loader.CPtr): Future<Result>
    if handle == nil then
        return Future.failed("cannot allocate file-dialog state") as Future<Result>
    end
    local future = Future.pending(source as Future.Source) as Future<Result>
    pending[#pending + 1] = {handle = handle, future = future}
    -- A setup allocation can fail before SDL opens anything.
    source:poll()
    return future
end

--- Opens a native file picker.
function dialogs.openFile(options?: Options): Future<Result>
    local given = options or {} as Options
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return track(C.tecsDialogOpenFile(window, names, patterns, count, given.defaultLocation, given.multiple == true))
end

--- Opens a native save-file picker. At most one path is returned.
function dialogs.saveFile(options?: Options): Future<Result>
    local given = options or {} as Options
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return track(C.tecsDialogSaveFile(window, names, patterns, count, given.defaultLocation))
end

--- Opens a native folder picker.
function dialogs.openFolder(options?: Options): Future<Result>
    local given = options or {} as Options
    local window = given.window ~= nil and given.window.handle or nil
    return track(C.tecsDialogOpenFolder(window, given.defaultLocation, given.multiple == true))
end

--- Settles dialogs whose native callback has answered.
---
--- `Application` calls this every frame. It is public for a headless tool that
--- creates dialogs without an application.
function dialogs.update(): integer
    return source:poll()
end

return dialogs
