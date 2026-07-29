--- Logging, which is SDL's with a guard in front of it.
---
--- A logger is a name, and the name is what a developer filters on:
---
--- ```teal
--- local logger <const> = tecs.log.get("game.combat")
---
--- logger:info("wave %d spawned %d enemies", 3, 12)
--- logger:setLevel(tecs.log.DEBUG)
---
--- -- A queryable copy beside the platform destination, not instead of it.
--- tecs.log.openFile(tecs.filesystem.writablePath("game.log"))
--- tecs.log.closeFile()
--- ```
---
--- Arguments are formatted only once the priority has passed, so a filtered
--- call costs a load and a compare rather than a string.
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

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

loader.declare("logsink")

--- The native sink, which shares the worker library.
local sink <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "logsink")

--- Where our categories begin. SDL's own occupy everything below, and the
--- boundary is read from SDL rather than counted here, since the enum has
--- grown reserved slots before.
local CUSTOM <const> = tonumber(C.SDL_LOG_CATEGORY_CUSTOM) as integer

--- Logging, which is SDL's with a guard in front of it.
---
--- Loggers are process-wide and named, and a name is the unit of filtering: `log.get`
--- resolves it to the SDL category number that `SDL_SetLogPriority` takes, and the level
--- itself is held by SDL rather than mirrored here. Nothing in this module has a level of
--- its own, so changing one through SDL changes what these methods emit.
local record log
    --- A named category. Holds its SDL category number and nothing else; the
    --- level lives in SDL.
    record Logger
        --- The name it was registered under. The native sink writes this rather than the
        --- number, so it is what appears in the platform's log.
        name: string

        --- Its SDL category, and the argument `SDL_SetLogPriority` takes. Handed out in
        --- registration order from `SDL_LOG_CATEGORY_CUSTOM` upwards, so a number is
        --- stable within a run and is not stable across runs that register in a different
        --- order. Filter by name.
        category: integer
    end

    --- Priority values, as SDL numbers them.
    TRACE: integer
    --- See `TRACE`.
    VERBOSE: integer
    --- See `TRACE`.
    DEBUG: integer
    --- See `TRACE`.
    INFO: integer
    --- See `TRACE`.
    WARN: integer
    --- See `TRACE`.
    ERROR: integer
    --- See `TRACE`. The highest, so setting a level to this emits almost nothing.
    CRITICAL: integer
end

log.TRACE = 1
log.VERBOSE = 2
log.DEBUG = 3
log.INFO = 4
log.WARN = 5
log.ERROR = 6
log.CRITICAL = 7

local LoggerMT <const>: metatable<log.Logger> = {__index = log.Logger}

local byName <const>: {string: log.Logger} = {}
local names <const>: {integer: string} = {}
local nextCategory = CUSTOM

--- Returns the logger for `name`, creating it the first time.
---
--- Names are the unit of filtering, so they are what a subsystem should use:
--- `tecs.gfx`, `tecs.debug.events`. Each maps to one SDL category, which
--- is what `SDL_SetLogPriority` takes.
---
--- @param name Compared byte for byte, so two spellings are two categories with two levels.
--- @return The same object on every call for a name, and it lives as long as the process.
---     A new logger starts at whatever SDL's default priority is, not at a level of ours.
function log.get(name: string): log.Logger
    local existing = byName[name]
    if existing ~= nil then
        return existing
    end

    local self = setmetatable({} as log.Logger, LoggerMT)
    self.name = name
    self.category = nextCategory
    nextCategory = nextCategory + 1
    byName[name] = self
    names[self.category] = name
    -- The sink writes names rather than numbers, and it cannot ask Lua for
    -- them because it runs on threads the VM has never seen.
    sink.tecsLogSinkCategory(CUSTOM, self.category, name)
    return self
end

--- The name a category was registered under, for a sink that wants it.
---
--- @return Never nil. A category nothing registered, including SDL's own, comes back as
---     `"category:<number>"` rather than as an error.
function log.categoryName(category: integer): string
    return names[category] or ("category:%d"):format(category)
end

--- Every registered logger name, for tooling that enumerates them.
---
--- @return A fresh array each call, sorted, holding only names something has already asked
---     `get` for. A subsystem that has not run yet is absent.
function log.loggers(): {string}
    local list: {string} = {}
    for name in pairs(byName) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

--- Sets the minimum priority this logger emits.
---
--- @param priority One of the constants on `log`. A message at this priority is emitted;
---     anything lower is dropped.
function log.Logger:setLevel(priority: integer)
    C.SDL_SetLogPriority(self.category, priority)
end

--- The minimum priority this logger emits.
---
--- @return SDL's current priority for this category, which is SDL's default until
---     something sets one, so it is not necessarily a value any caller here chose.
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
---
--- @param priority Overrides every per-logger level already set, so this is a reset and
---     not a floor.
function log.setLevel(priority: integer)
    C.SDL_SetLogPriorities(priority)
end

--- The path `openFile` last accepted, or nil while no file has been opened.
local filePath: string = nil

--- Also writes every line to `path` as JSON Lines, truncating it.
---
--- The platform destination keeps receiving the human-readable form, so
--- `tail -f`, logcat and Console.app are unaffected. The file is what makes a
--- log queryable after the fact: seek to an offset, read to the end.
---
--- Lines are written from whichever thread logged, including threads the VM never created,
--- so ordering follows the calls and not any Lua-side sequence.
---
--- Called while another file is open, this moves to `path`: the previous file is closed and
--- every later line goes to the new one, so the path this accepts is the path being written
--- to and `filePath` never names a file the sink has left behind. The move happens between
--- lines rather than inside one.
---
--- @param path Truncated if it exists, created if it does not, including when it is the
---     file already open, so this is not a way to check one is. Directories are not made.
--- @return False when the file could not be opened, in which case nothing else changed and
---     a file already open keeps receiving lines.
function log.openFile(path: string): boolean
    local ok = sink.tecsLogSinkOpen(path) as boolean
    if ok then
        filePath = path
    end
    return ok
end

--- Where the file is, or nil if none was opened. What `get_logs` hands back
--- to an agent that shares a filesystem with the game.
---
--- @return The path as it was given, not resolved against the working directory, so a
---     relative one is only meaningful to a reader in the same place the game ran.
function log.filePath(): string
    return filePath
end

--- Stops writing to the file and restores SDL's own output function.
---
--- Does nothing when no file is open, so it is safe to call on a shutdown path that does
--- not know whether one was ever asked for.
function log.closeFile()
    sink.tecsLogSinkClose()
    filePath = nil
end

local function emit(self: log.Logger, priority: integer, message: string, ...: any)
    if tonumber(C.SDL_GetLogPriority(self.category)) > priority then
        return
    end
    if select("#", ...) > 0 then
        message = message:format(...)
    end
    -- One `%s`, because the arguments were resolved above. See the note at the
    -- top for why they are not passed through to SDL's own formatting.
    C.SDL_LogMessage(self.category, priority, "%s", message)
end

--- Accepts `string.format` specifiers, applied only if the message is emitted.
---
--- The level is checked before the formatting, so a filtered call costs a load and a
--- compare and the arguments are never touched. Building those arguments is still the
--- caller's cost; guard that with `enabled`.
---
--- @param message A `string.format` template when arguments follow, and a literal
---     otherwise, so a `%` in a plain message is safe.
--- @param ... Formatted into `message`. A wrong count or a wrong specifier raises from
---     `string.format`, and only on the calls that are actually emitted.
function log.Logger:trace(message: string, ...: any)
    emit(self, log.TRACE, message, ...)
end

--- At `VERBOSE`. See `trace` for the formatting rules.
function log.Logger:verbose(message: string, ...: any)
    emit(self, log.VERBOSE, message, ...)
end

--- At `DEBUG`. See `trace` for the formatting rules.
function log.Logger:debug(message: string, ...: any)
    emit(self, log.DEBUG, message, ...)
end

--- At `INFO`. See `trace` for the formatting rules.
function log.Logger:info(message: string, ...: any)
    emit(self, log.INFO, message, ...)
end

--- At `WARN`. See `trace` for the formatting rules.
function log.Logger:warn(message: string, ...: any)
    emit(self, log.WARN, message, ...)
end

--- At `ERROR`. See `trace` for the formatting rules. Logging is all this does; it neither
--- raises nor returns anything.
function log.Logger:error(message: string, ...: any)
    emit(self, log.ERROR, message, ...)
end

--- At `CRITICAL`. See `trace` for the formatting rules.
function log.Logger:critical(message: string, ...: any)
    emit(self, log.CRITICAL, message, ...)
end

return log
