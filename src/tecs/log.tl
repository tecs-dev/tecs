--[=[
Named, leveled logging.

Create one named logger per subsystem. Logger names form the stable filtering
surface:

```teal
local logger <const> = tecs.log.get("game.combat")

logger:info("wave %d spawned %d enemies", 3, 12)
logger:setLevel(tecs.log.DEBUG)
```

Messages go to the platform log destination, including logcat on Android and
Console on Apple platforms.

[`Logger`](tealdoc:tecs.log.Logger) methods check priority before formatting. Pass raw arguments rather
than formatting first. Guard work that exists only to build a message:

```teal
local snapshot <const> = {frame = 12, player = "Alice"}
if logger:enabled(tecs.log.DEBUG) then
    logger:debug("snapshot: %s", tecs.data.encodeJSON(snapshot))
end
```

## JSON Lines output

Add a queryable file beside the platform destination:

```teal
local path <const> = tecs.filesystem.writablePath("game.jsonl")
if not tecs.log.openFile(path) then
    logger:error("could not open %s", path)
end
```

Each line records time, level, logger, and message. `closeFile` stops file
output and leaves the platform destination active.
]=]

-- Implementation details:
-- Logger names map to SDL categories, and SDL owns process-wide priority
-- state. Direct SDL configuration and Tecs logger methods therefore affect the
-- same stream.
--
-- The native sink accepts messages from SDL and worker threads without
-- entering the Lua VM. Lua formats one safe `%s` argument only after SDL's
-- priority check because LuaJIT cannot safely pass arbitrary Lua values
-- through C varargs.

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

local record log
    --- Represents a named log category.
    record Logger
        --- Read-only. Contains the registered logger name written to the
        --- platform log.
        name: string

        --- Engine-owned. Contains the category allocated during this run.
        --- The number may change across runs, so game code should filter by
        --- `name`.
        category: integer
    end

    --- Read-only. Contains the trace priority.
    TRACE: integer
    --- Read-only. Contains the verbose priority.
    VERBOSE: integer
    --- Read-only. Contains the debug priority.
    DEBUG: integer
    --- Read-only. Contains the informational priority.
    INFO: integer
    --- Read-only. Contains the warning priority.
    WARN: integer
    --- Read-only. Contains the error priority.
    ERROR: integer
    --- Read-only. Contains the critical priority.
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
--- @return Returns the same object on every call for a name. A new logger
---     starts at the platform's default priority.
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

--- Returns the name registered for a category.
---
--- @return Never returns nil. An unregistered category comes back as
---     `"category:<number>"` rather than as an error.
function log.categoryName(category: integer): string
    return names[category] or ("category:%d"):format(category)
end

--- Returns every registered logger name.
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
--- @param priority One of the constants on `log`. The logger emits messages at
---     this priority and drops anything lower.
function log.Logger:setLevel(priority: integer)
    C.SDL_SetLogPriority(self.category, priority)
end

--- Returns the minimum priority this logger emits.
---
--- @return Returns the platform priority until something sets one.
function log.Logger:level(): integer
    return tonumber(C.SDL_GetLogPriority(self.category)) as integer
end

--- Reports whether the logger would emit a message at `priority`.
---
--- Call this directly to guard work that only exists to build a log message,
--- such as serializing a table. The level methods already guard themselves.
function log.Logger:enabled(priority: integer): boolean
    return tonumber(C.SDL_GetLogPriority(self.category)) <= priority
end

--- Sets the minimum priority for every category.
---
--- @param priority Overrides every per-logger level already set, so this is a reset and
---     not a floor.
function log.setLevel(priority: integer)
    C.SDL_SetLogPriorities(priority)
end

--- The path `openFile` last accepted, or nil until it accepts one.
local filePath: string = nil

--- Writes every accepted line to `path` as JSON Lines and truncates the file.
---
--- The platform destination keeps receiving the human-readable form, so
--- The platform still sends its human-readable stream to `tail -f`, logcat,
--- or Console.app. The file makes a
--- log queryable after the fact: seek to an offset, read to the end.
---
--- Calling this while another file is open closes the previous file and moves
--- subsequent lines to `path`.
---
--- @param path Truncated if it exists, created if it does not, including when it is the
---     file already open, so this is not a way to check one is. Directories are not made.
--- @return False when the file cannot open. In that case nothing else changes and
---     a file already open keeps receiving lines.
function log.openFile(path: string): boolean
    local ok = sink.tecsLogSinkOpen(path) as boolean
    if ok then
        filePath = path
    end
    return ok
end

--- Returns the open log file path, or nil when no file is open.
---
--- @return The path as it was given, not resolved against the working directory, so a
---     relative one is only meaningful to a reader in the same place the game ran.
function log.filePath(): string
    return filePath
end

--- Stops writing to the file.
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

--- Logs at `TRACE` and applies `string.format` specifiers only when emitted.
---
--- The method checks the level before formatting, so a filtered call costs a load and a
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

--- Logs at `VERBOSE`. See `trace` for the formatting rules.
function log.Logger:verbose(message: string, ...: any)
    emit(self, log.VERBOSE, message, ...)
end

--- Logs at `DEBUG`. See `trace` for the formatting rules.
function log.Logger:debug(message: string, ...: any)
    emit(self, log.DEBUG, message, ...)
end

--- Logs at `INFO`. See `trace` for the formatting rules.
function log.Logger:info(message: string, ...: any)
    emit(self, log.INFO, message, ...)
end

--- Logs at `WARN`. See `trace` for the formatting rules.
function log.Logger:warn(message: string, ...: any)
    emit(self, log.WARN, message, ...)
end

--- Logs at `ERROR`. See `trace` for the formatting rules. Logging is all this does; it neither
--- raises nor returns anything.
function log.Logger:error(message: string, ...: any)
    emit(self, log.ERROR, message, ...)
end

--- Logs at `CRITICAL`. See `trace` for the formatting rules.
function log.Logger:critical(message: string, ...: any)
    emit(self, log.CRITICAL, message, ...)
end

return log
