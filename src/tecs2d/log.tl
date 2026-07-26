--- Logging, which is SDL's with a guard in front of it.
---
--- There is deliberately nothing here to maintain: no sinks, no prefixes, no
--- timestamp cache, no ring buffer, no level configuration of our own. SDL
--- already dispatches to the right destination per platform, which is the
--- whole argument. Writing to stderr from Lua reaches nobody on a phone:
---
---   Windows   OutputDebugString, plus the console where one is attached
---   Android   __android_log_write, so logcat with a tag
---   Apple     NSLog
---   other     stderr
---
--- The guard is on this side because `SDL_LogMessage` is variadic and LuaJIT
--- cannot pass Lua values through C varargs safely: a `%d` handed a double is
--- undefined, not an error. So the message is formatted here and passed as one
--- `%s`. That would throw away SDL's own economy, which checks the priority
--- before it formats and renders into a stack buffer without allocating, so
--- the check happens first and a filtered call costs a load and a compare.
--- `SDL_GetLogPriority` bypasses SDL's mutex for known categories, and the
--- lock guards only the output dispatch, after the filter.
---
--- Because SDL owns the priorities, `SDL_SetLogPriority` works with nothing
--- here mirroring it, and SDL's own diagnostics land in the same stream with
--- no tee.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

loader.declare("logsink")

--- The native sink, which shares the worker library.
local sink <const> = loader.library("tecs2dworker", "tecs2d",
    "TECS2D_WORKER_PATH", "logsink")

--- Where our categories begin. SDL's own occupy everything below, and the
--- boundary is read from SDL rather than counted here, since the enum has
--- grown reserved slots before.
local CUSTOM <const> = tonumber(C.SDL_LOG_CATEGORY_CUSTOM) as integer

local record log
    --- A named category. Holds its SDL category number and nothing else; the
    --- level lives in SDL.
    record Logger
        name: string
        category: integer
    end

    --- Priority values, as SDL numbers them.
    TRACE: integer
    VERBOSE: integer
    DEBUG: integer
    INFO: integer
    WARN: integer
    ERROR: integer
    CRITICAL: integer
end

log.TRACE = 1
log.VERBOSE = 2
log.DEBUG = 3
log.INFO = 4
log.WARN = 5
log.ERROR = 6
log.CRITICAL = 7

local LoggerMT <const>: metatable<log.Logger> = { __index = log.Logger }

local byName <const>: {string: log.Logger} = {}
local names <const>: {integer: string} = {}
local nextCategory = CUSTOM

--- Returns the logger for `name`, creating it the first time.
---
--- Names are the unit of filtering, so they are what a subsystem should use:
--- `tecs2d.gfx`, `tecs2d.debug.events`. Each maps to one SDL category, which
--- is what `SDL_SetLogPriority` takes.
function log.get(name: string): log.Logger
    local existing = byName[name]
    if existing ~= nil then return existing end

    local self = setmetatable({} as log.Logger, LoggerMT)
    self.name = name
    self.category = nextCategory
    nextCategory = nextCategory + 1
    byName[name] = self
    names[self.category] = name
    -- The sink writes names rather than numbers, and it cannot ask Lua for
    -- them because it runs on threads the VM has never seen.
    sink.tecs2dLogSinkCategory(CUSTOM, self.category, name)
    return self
end

--- The name a category was registered under, for a sink that wants it.
function log.categoryName(category: integer): string
    return names[category] or ("category:%d"):format(category)
end

--- Every registered logger name, for tooling that enumerates them.
function log.loggers(): {string}
    local list: {string} = {}
    for name in pairs(byName) do list[#list + 1] = name end
    table.sort(list)
    return list
end

--- Sets the minimum priority this logger emits.
function log.Logger:setLevel(priority: integer)
    C.SDL_SetLogPriority(self.category, priority)
end

--- The minimum priority this logger emits.
function log.Logger:level(): integer
    return tonumber(C.SDL_GetLogPriority(self.category)) as integer
end

--- Whether a message at `priority` would be emitted.
---
--- Call this directly to guard work that only exists to build a log message,
--- such as serializing a table. The level methods already guard themselves.
function log.Logger:enabled(priority: integer): boolean
    return tonumber(C.SDL_GetLogPriority(self.category)) <= priority
end

--- Sets the minimum priority for every category, ours and SDL's.
function log.setLevel(priority: integer)
    C.SDL_SetLogPriorities(priority)
end

--- Also writes every line to `path` as JSON Lines, truncating it.
---
--- The platform destination keeps receiving the human-readable form, so
--- `tail -f`, logcat and Console.app are unaffected. The file is what makes a
--- log queryable after the fact: seek to an offset, read to the end.
function log.openFile(path: string): boolean
    return sink.tecs2dLogSinkOpen(path) as boolean
end

--- Stops writing to the file and restores SDL's own output function.
function log.closeFile()
    sink.tecs2dLogSinkClose()
end

local function emit(self: log.Logger, priority: integer, message: string,
                    ...: any)
    if tonumber(C.SDL_GetLogPriority(self.category)) > priority then return end
    if select("#", ...) > 0 then
        message = message:format(...)
    end
    -- One `%s`, because the arguments were resolved above. See the note at the
    -- top for why they are not passed through to SDL's own formatting.
    C.SDL_LogMessage(self.category, priority, "%s", message)
end

--- Accepts `string.format` specifiers, applied only if the message is emitted.
function log.Logger:trace(message: string, ...: any)
    emit(self, log.TRACE, message, ...)
end

function log.Logger:verbose(message: string, ...: any)
    emit(self, log.VERBOSE, message, ...)
end

function log.Logger:debug(message: string, ...: any)
    emit(self, log.DEBUG, message, ...)
end

function log.Logger:info(message: string, ...: any)
    emit(self, log.INFO, message, ...)
end

function log.Logger:warn(message: string, ...: any)
    emit(self, log.WARN, message, ...)
end

function log.Logger:error(message: string, ...: any)
    emit(self, log.ERROR, message, ...)
end

function log.Logger:critical(message: string, ...: any)
    emit(self, log.CRITICAL, message, ...)
end

return log
