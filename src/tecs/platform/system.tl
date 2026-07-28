--- Small operating-system services SDL presents consistently.
---
--- These are process-wide queries and requests rather than application
--- lifecycle. They therefore live together instead of being methods on a
--- window or on `Application`.

local Future <const> = require("tecs.Future")
local type Window = require("tecs.platform.Window")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

loader.declare("dialogs")

local C <const> = sdl.C
local K <const> = sdl.K
local D <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "dialogs")

local record Locale
    --- ISO 639 language code, such as `"en"`.
    language: string
    --- ISO 3166 country code, such as `"US"`, or an empty string when the
    --- platform names only a language.
    country: string
end

local record Power
    --- `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
    --- `"charged"` or `"error"`.
    state: string
    --- Seconds of battery life remaining, or -1 when unavailable.
    seconds: integer
    --- Charge percentage in 0..100, or -1 when unavailable.
    percent: integer
end

local record DialogFilter
    --- Label shown beside the filter, such as `"Images"`.
    name: string
    --- Semicolon-separated extensions, such as `"png;jpg;jpeg"`.
    pattern: string
end

local record DialogOptions
    window: Window
    filters: {DialogFilter}
    defaultLocation: string
    multiple: boolean
end

local record DialogResult
    --- Selected paths. Empty when the user cancelled.
    paths: {string}
    --- One-based selected filter, or zero when no filter applies.
    filter: integer
    cancelled: boolean
end

--- The operating-system half of `tecs.system`: URLs, locales, power, message
--- boxes and native file and folder dialogs.
local record system
    --- Anything carrying a native window handle, which is what a dialog or a
    --- message box sits over. A `Window` is one.
    type WindowLike = WindowLike

    --- One language the user prefers, in order of preference.
    type Locale = Locale

    --- What the machine is running on, and how much of it is left.
    type Power = Power

    --- One entry in a dialog's file-type filter.
    type DialogFilter = DialogFilter

    --- What a dialog is opened with.
    type DialogOptions = DialogOptions

    --- What the user chose, or that they chose nothing.
    type DialogResult = DialogResult
end

local countOut <const> = loader.newArray("int[1]")
local secondsOut <const> = loader.newArray("int[1]")
local percentOut <const> = loader.newArray("int[1]")

local POWER_STATES <const>: {integer: string} = {
    [tonumber(C.SDL_POWERSTATE_ERROR) as integer] = "error",
    [tonumber(C.SDL_POWERSTATE_UNKNOWN) as integer] = "unknown",
    [tonumber(C.SDL_POWERSTATE_ON_BATTERY) as integer] = "onBattery",
    [tonumber(C.SDL_POWERSTATE_NO_BATTERY) as integer] = "noBattery",
    [tonumber(C.SDL_POWERSTATE_CHARGING) as integer] = "charging",
    [tonumber(C.SDL_POWERSTATE_CHARGED) as integer] = "charged",
}

local MESSAGE_FLAGS <const>: {string: integer} = {
    error = K.SDL_MESSAGEBOX_ERROR,
    warning = K.SDL_MESSAGEBOX_WARNING,
    info = K.SDL_MESSAGEBOX_INFORMATION,
}

--- Opens a URL with the operating system's preferred handler.
function system.openURL(url: string): boolean, string
    if url == nil or url == "" then
        return false, "a URL is required"
    end
    if not C.SDL_OpenURL(url) then
        return false, sdl.error()
    end
    return true, nil
end

--- Preferred locales in the user's priority order.
function system.preferredLocales(): {Locale}
    local out: {Locale} = {}
    local locales = C.SDL_GetPreferredLocales(countOut)
    if locales == nil then
        return out
    end
    local list = locales as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local locale = list[index] as loader.CStruct
        if locale ~= nil then
            out[#out + 1] = {
                language = loader.toString(locale.language as loader.CValue),
                country = loader.toString(locale.country as loader.CValue),
            }
        end
    end
    C.SDL_free(locales)
    return out
end

--- Current battery or external-power state.
function system.power(): Power
    secondsOut[0], percentOut[0] = -1, -1
    local state = tonumber(C.SDL_GetPowerInfo(secondsOut, percentOut)) as integer
    return {
        state = POWER_STATES[state] or "unknown",
        seconds = secondsOut[0] as integer,
        percent = percentOut[0] as integer,
    }
end

--- Shows a native informational, warning or error dialog.
function system.messageBox(kind: string, title: string, message: string, window?: Window): boolean, string
    local flags = MESSAGE_FLAGS[kind]
    if flags == nil then
        return false, ("unknown message-box kind %q"):format(tostring(kind))
    end
    local handle = window ~= nil and window.handle or nil
    if not C.SDL_ShowSimpleMessageBox(flags, title or "", message or "", handle) then
        return false, sdl.error()
    end
    return true, nil
end

-------------------------------------------------------------------------------
-- Asynchronous file and folder dialogs
-------------------------------------------------------------------------------

--- SDL retains the file-dialog callback and may enter it from a thread LuaJIT
--- did not create. `native/dialogs.c` owns that callback and copies its answer;
--- this source polls the copied result and settles futures on the main thread.

local record DialogEntry
    handle: loader.CPtr
    future: Future<DialogResult>
end

local record DialogSource
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: DialogSource): integer
    advance: function(self: DialogSource, ms: number): integer
end

local DialogSourceMT <const>: metatable<DialogSource> = {__index = DialogSource}
local pendingDialogs: {DialogEntry} = {}

local function finishDialog(entry: DialogEntry)
    local handle = entry.handle
    local errorPointer = D.tecsDialogError(handle)
    if errorPointer ~= nil then
        entry.future:fail(loader.toString(errorPointer))
    else
        local paths: {string} = {}
        local count = tonumber(D.tecsDialogPathCount(handle)) as integer
        for index = 0, count - 1 do
            paths[index + 1] = loader.toString(D.tecsDialogPath(handle, index))
        end
        local selected = tonumber(D.tecsDialogFilter(handle)) as integer
        entry.future:complete({
            paths = paths,
            filter = selected >= 0 and selected + 1 or 0,
            cancelled = D.tecsDialogCancelled(handle) as boolean,
        })
    end
    D.tecsDialogDestroy(handle)
end

function DialogSource:poll(): integer
    local settled = 0
    for index = #pendingDialogs, 1, -1 do
        local entry = pendingDialogs[index]
        if D.tecsDialogReady(entry.handle) then
            finishDialog(entry)
            table.remove(pendingDialogs, index)
            settled = settled + 1
        end
    end
    return settled
end

function DialogSource:advance(ms: number): integer
    local settled = self:poll()
    if settled > 0 or ms <= 0 then
        return settled
    end
    C.SDL_Delay(math.floor(ms))
    return self:poll()
end

local dialogSource <const> = setmetatable({
    sliceMs = 16,
    defaultWaitMs = 300000,
} as DialogSource, DialogSourceMT)

local function filterArrays(options: DialogOptions): loader.CArray, loader.CArray, integer
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

local function trackDialog(handle: loader.CPtr): Future<DialogResult>
    if handle == nil then
        return Future.failed("cannot allocate file-dialog state") as Future<DialogResult>
    end
    local future = Future.pending(dialogSource as Future.Source) as Future<DialogResult>
    pendingDialogs[#pendingDialogs + 1] = {handle = handle, future = future}
    -- A setup allocation can fail before SDL opens anything.
    dialogSource:poll()
    return future
end

--- Opens a native file picker.
function system.openFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(
        D.tecsDialogOpenFile(window, names, patterns, count, given.defaultLocation, given.multiple == true)
    )
end

--- Opens a native save-file picker. At most one path is returned.
function system.saveFile(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogSaveFile(window, names, patterns, count, given.defaultLocation))
end

--- Opens a native folder picker.
function system.openFolder(options?: DialogOptions): Future<DialogResult>
    local given = options or {} as DialogOptions
    local window = given.window ~= nil and given.window.handle or nil
    return trackDialog(D.tecsDialogOpenFolder(window, given.defaultLocation, given.multiple == true))
end

--- Settles file and folder dialogs whose native callback has answered.
---
--- `Application` calls this every frame. It is public for a headless tool that
--- creates dialogs without an application.
function system.updateDialogs(): integer
    return dialogSource:poll()
end

return system
