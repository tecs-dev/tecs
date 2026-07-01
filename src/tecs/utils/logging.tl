--- Lightweight logging with level-stamped no-op methods.
local ffi <const> = require("ffi")
local string_format <const> = string.format
local os_date <const> = os.date
local tonumber <const> = tonumber

-- Per-second date string cache. The default dateFormat is seconds-resolution, so within a given second every
-- logger wants the same timestamp string, and os.date allocates a fresh string for each call
-- (measured: ~500 ns/call). Caching collapses that to one allocation per wall-clock second across all
-- loggers, cutting a real enabled log from ~600 ns to ~25 ns on LuaJIT.
--
-- `os.time()` is NYI in LuaJIT's JIT compiler and aborts traces; `C.time()`
-- via FFI is trace-compilable and returns the same seconds-since-epoch.
ffi.cdef([[
    typedef int64_t time_t;
    time_t time(time_t *t);
]])
local TIME_NULL <const> = ffi.cast("time_t*", 0)

-- Prefer C.time (trace-compilable), falling back to os.time when the symbol is
-- unavailable: some Windows CRTs don't export a plain `time` (it inlines to
-- `_time64`) or use a 32-bit time_t that mismatches the int64_t cdef above.
local C_time: function(any): integer
do
    local osFallback = function(_: any): integer return os.time() end
    local ok, fn = pcall(function(): any return ffi.C.time end)
    if ok and fn then
        local candidate = fn as function(any): integer
        -- Validate against os.time: catches a resolved-but-wrong-width symbol.
        local valOk, cv = pcall(candidate, TIME_NULL)
        local diff = valOk and (tonumber(cv) - os.time()) or math.huge
        C_time = (diff > -2 and diff < 2) and candidate or osFallback
    else
        C_time = osFallback
    end
end

local record logging
    --- Log level severity, from most to least verbose. "OFF" disables all output.
    enum LogLevel
        "DEBUG"
        "INFO"
        "WARN"
        "ERROR"
        "OFF"
    end

    --- A logger instance with level-gated methods.
    --- Each method is either a real writer or a no-op, depending on the active level.
    record Logger
        --- Log a debug message. Accepts `string.format` specifiers.
        debug: function(self: Logger, msg: string, ...: any)
        --- Log an info message. Accepts `string.format` specifiers.
        info: function(self: Logger, msg: string, ...: any)
        --- Log a warning message. Accepts `string.format` specifiers.
        warn: function(self: Logger, msg: string, ...: any)
        --- Log an error message. Accepts `string.format` specifiers.
        error: function(self: Logger, msg: string, ...: any)

        sink: FILE
        dateFormat: string
        debugPrefix: string
        infoPrefix: string
        warnPrefix: string
        errorPrefix: string
    end

    --- The active log level. Messages below this level are no-ops.
    level: LogLevel

    --- The date format string passed to `os.date`. Non-strftime characters are
    --- copied verbatim, so the trailing space is intentional.
    dateFormat: string

    --- The output destination. Defaults to `io.stderr`.
    sink: FILE

    --- Get or create a named logger. Repeated calls with the same name return
    --- the same instance.
    --- @param name The logger name, included in every log line.
    --- @return A Logger whose methods reflect the current level and sink.
    getLogger: function(name: string): Logger

    --- Set the global log level and re-stamp all existing loggers.
    --- @param level The new log level.
    setLevel: function(level: LogLevel)

    --- Set the global output sink and re-stamp all existing loggers.
    --- @param sink The file handle to write to.
    setSink: function(sink: FILE)
end

logging.sink = io.stderr
logging.dateFormat = "%Y-%m-%d %H:%M:%S "
logging.level = "INFO"

local NO_OP: function(logging.Logger, string, any...) = function() end
local registry: {string: logging.Logger} = {}

-- Cache keyed on (os.time tick, dateFormat); mutating logging.dateFormat invalidates transparently.
-- The extra compares are cheap integer/pointer checks; the saved work is a full os.date allocation.
local cachedTick: number = -1
local cachedDateStr: string = ""
local cachedDateFormat: string = ""

local function getDateStr(dateFormat: string): string
    local tick = tonumber(C_time(TIME_NULL))
    if tick ~= cachedTick or dateFormat ~= cachedDateFormat then
        cachedTick = tick
        cachedDateFormat = dateFormat
        cachedDateStr = os_date(dateFormat)
    end
    return cachedDateStr
end

local function writeDebug(self: logging.Logger, msg: string, ...: any)
    self.sink:write(getDateStr(self.dateFormat), self.debugPrefix, string_format(msg, ...), "\n")
end

local function writeInfo(self: logging.Logger, msg: string, ...: any)
    self.sink:write(getDateStr(self.dateFormat), self.infoPrefix, string_format(msg, ...), "\n")
end

local function writeWarn(self: logging.Logger, msg: string, ...: any)
    self.sink:write(getDateStr(self.dateFormat), self.warnPrefix, string_format(msg, ...), "\n")
end

local function writeError(self: logging.Logger, msg: string, ...: any)
    self.sink:write(getDateStr(self.dateFormat), self.errorPrefix, string_format(msg, ...), "\n")
end

local function stampLogger(logger: logging.Logger)
    local level = logging.level
    logger.debug = (level == "DEBUG") and writeDebug or NO_OP
    logger.info = (level == "INFO" or level == "DEBUG") and writeInfo or NO_OP
    logger.warn = (level ~= "OFF" and level ~= "ERROR") and writeWarn or NO_OP
    logger.error = (level ~= "OFF") and writeError or NO_OP
    logger.sink = logging.sink
    logger.dateFormat = logging.dateFormat
end

function logging.getLogger(name: string): logging.Logger
    local logger = registry[name]
    if not logger then
        logger = {
            debugPrefix = name .. " DEBUG: ",
            infoPrefix = name .. " INFO: ",
            warnPrefix = name .. " WARN: ",
            errorPrefix = name .. " ERROR: ",
        }
        stampLogger(logger)
        registry[name] = logger
    end
    return logger
end

local function restampAll()
    for _, logger in pairs(registry) do
        stampLogger(logger)
    end
end

function logging.setLevel(level: logging.LogLevel)
    logging.level = level
    restampAll()
end

function logging.setSink(sink: FILE)
    logging.sink = sink
    restampAll()
end

return logging
