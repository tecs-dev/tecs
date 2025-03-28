local os_date <const> = os.date
local string_format <const> = string.format
local assert <const> = assert
local setmetatable <const> = setmetatable

--- Environment variable for setting the logging level.
local TECS_LOG_LEVEL <const> = "TECS_LOG_LEVEL"

local DEBUG <const> = 1
local INFO <const> = 2
local WARN <const> = 3
local ERROR <const> = 4
local NAMES <const> = {
    [DEBUG] = "debug",
    [INFO] = "info",
    [WARN] = "warn",
    [ERROR] = "error"
}
local VALUES <const>: {string: integer} = {
    ["debug"] = DEBUG,
    ["info"] = INFO,
    ["warn"] = WARN,
    ["error"] = ERROR
}

--- Logging module for Tecs.
local record logging

    --- Logging levels.
    DEBUG: integer
    INFO: integer
    WARN: integer
    ERROR: integer

    --- The root logger.
    rootLogger: Logger

    --- Gets or creates a named child of the root logger.
    ---
    --- Changes made to child loggers only affect the child and do not affect the root logger.
    ---
    --- @param name string The name of the logger.
    --- @return the logger.
    getLogger: function(name: string): Logger

    --- The logging interface.
    interface Logger
        --- The name of the logger.
        --- @return string The name of the logger.
        getName: function(self): string

        --- Log a debug message.
        --- @param message string The message to log.
        --- @param ... any Additional arguments to format the message with.
        debug: function(self, message: string, ...: any)

        --- Log an info message.
        --- @param message string The message to log.
        --- @param ... any Additional arguments to format the message with.
        info: function(self, message: string, ...: any)

        --- Log a warning message.
        --- @param message string The message to log.
        --- @param ... any Additional arguments to format the message with.
        warn: function(self, message: string, ...: any)

        --- Log an error message.
        --- @param message string The message to log.
        --- @param ... any Additional arguments to format the message with.
        error: function(self, message: string, ...: any)

        --- Check if the logger is loggable at the given level.
        --- @param level The logging level.
        --- @return boolean True if the logger is loggable at the given level.
        isLoggable: function(self, level: integer): boolean

        --- Set the logging level.
        --- @param level The new logging level.
        setLevel: function(self, level: integer)

        --- Get the logging level.
        --- @return The logging level.
        getLevel: function(self): integer

        --- Set where to log.
        --- @param sink The log sink to log to.
        setSink: function(self, sink: LogSink)

        --- Get the log sink.
        --- @return LogSink The log sink.
        getSink: function(self): LogSink

        --- Flush the logger of any buffered messages.
        flush: function(self)

        --- Close the logger and any open files.
        close: function(self)

        --- Get a child logger of the current logger.
        ---
        --- This method allows for nested loggers of any depth. Most use cases would simply
        --- use `logging.getLogger(name)` to get a logger that is a direct child of the root logger.
        ---
        --- @param name string The name of the child logger.
        --- @return Logger The child logger.
        getChild: function(self, name: string): Logger
    end

    --- A pre-defined sink for logging to stderr.
    ---
    --- @param formatter? The optional custom formatter to use when writing messages.
    --- @return The log sink.
    newStderrSink: function(formatter?: Formatter): LogSink

    --- A sink used to log to a file.
    ---
    --- @param file FILE The file to log to.
    --- @param formatter? The optional custom formatter to use when writing messages.
    --- @return The log sink.
    newFileSink: function(file: FILE, formatter?: Formatter): LogSink

    --- A formatter is used to convert log messages into a string.
    ---
    --- Formatters aren't stricly required for implementing a log sink, but they are
    --- used to make the built-in file sink and stderr sink easier to customize.
    type Formatter = function(level: integer, name: string, message: string, ...: any): string

    --- A pre-defined formatter used to format log messages into a string.
    DEFAULT_FORMATTER: Formatter

    --- Where to write log messages.
    interface LogSink
        --- Log a message.
        ---
        --- @param level The logging level.
        --- @param name The name of the logger.
        --- @param message string The message to log.
        --- @param ... any Additional arguments to format the message with.
        log: function(self, level: integer, name: string, message: string, ...: any)

        --- Flush the sink of any buffered messages.
        flush: function(self)

        --- Close the log sink and any open files.
        close: function(self)
    end
end

local type Logger = logging.Logger

logging.DEBUG = DEBUG
logging.INFO = INFO
logging.WARN = WARN
logging.ERROR = ERROR

-------------------------------------------------------------------------------
-- Default formatter
-------------------------------------------------------------------------------

function logging.DEFAULT_FORMATTER(level: integer, name: string, message: string, ...: any): string
    local levelName = NAMES[level]
    local timestamp = os_date("%Y-%m-%d %H:%M:%S")
    local formatted = string_format(message, ...)
    return string_format("[%s] %s [%s]: %s\n", levelName, timestamp, name, formatted)
end

-------------------------------------------------------------------------------
-- File sink implementation
-------------------------------------------------------------------------------

local record FileSink is logging.LogSink
    file: FILE
    formatter: logging.Formatter
end

function FileSink.log(self: FileSink, level: integer, name: string, message: string, ...: any)
    local formatted = self.formatter(level, name, message, ...)
    self.file:write(formatted)
    if level >= WARN then
        self.file:flush()
    end
end

function FileSink.flush(self: FileSink)
    self.file:flush()
end

function FileSink.close(self: FileSink)
    if self.file then
        self.file:close()
        self.file = nil
    end
end

local FILESINK_MT <const>: metatable<FileSink> = {
    __index = FileSink
}

function FileSink.new(file: FILE, formatter?: logging.Formatter): FileSink
    assert(file, "Invalid log file: file cannot be nil")
    formatter = formatter or logging.DEFAULT_FORMATTER
    return setmetatable({
        file = file,
        formatter = formatter
    }, FILESINK_MT)
end

-------------------------------------------------------------------------------
-- File and stderr sink creation
-------------------------------------------------------------------------------

function logging.newFileSink(file: FILE, formatter?: logging.Formatter): logging.LogSink
    return FileSink.new(file, formatter)
end

function logging.newStderrSink(formatter?: logging.Formatter): logging.LogSink
    return logging.newFileSink(io.stderr, formatter)
end

-------------------------------------------------------------------------------
-- Logger implementation
-------------------------------------------------------------------------------

local record LoggerImpl is Logger
    level: integer
    name: string
    parent: Logger
    sink: logging.LogSink
    children: {string: Logger}
end

local LOGGER_MT <const>: metatable<LoggerImpl> = {
    __index = LoggerImpl
}

function LoggerImpl.new(name: string, level: integer, sink: logging.LogSink, parent?: Logger): LoggerImpl
    assert(name, "Invalid logger name: name cannot be nil")
    if not parent then
        assert(sink, "Invalid log sink: sink cannot be nil for root logger")
        assert(level, "Invalid logging level: level cannot be nil for root logger")
        assert(level >= DEBUG and level <= ERROR, "Invalid logging level: level must be between DEBUG and ERROR")
    end
    return setmetatable({
        name = name,
        level = level,
        sink = sink,
        parent = parent,
        children = {}
    }, LOGGER_MT)
end

function LoggerImpl:getName(): string
    return self.name
end

function LoggerImpl:debug(message: string, ...: any)
    if self:isLoggable(DEBUG) then
        self:getSink():log(DEBUG, self.name, message, ...)
    end
end

function LoggerImpl:info(message: string, ...: any)
    if self:isLoggable(INFO) then
        self:getSink():log(INFO, self.name, message, ...)
    end
end

function LoggerImpl:warn(message: string, ...: any)
    if self:isLoggable(WARN) then
        self:getSink():log(WARN, self.name, message, ...)
    end
end

function LoggerImpl:error(message: string, ...: any)
    if self:isLoggable(ERROR) then
        self:getSink():log(ERROR, self.name, message, ...)
    end
end

function LoggerImpl:isLoggable(level: integer): boolean
    return self:getLevel() <= level
end

function LoggerImpl:getLevel(): integer
    if self.level then
        return self.level
    elseif self.parent then
        return self.parent:getLevel()
    else
        return INFO -- Fallback to INFO if no level is set
    end
end

function LoggerImpl:setLevel(level: integer)
    assert(level >= DEBUG and level <= ERROR, "Invalid logging level: level must be between DEBUG and ERROR")
    self.level = level
end

function LoggerImpl:setSink(sink: logging.LogSink)
    assert(sink, "Invalid log sink: sink cannot be nil")
    self.sink = sink
end

function LoggerImpl:getSink(): logging.LogSink
    if self.sink then
        return self.sink
    elseif self.parent then
        return self.parent:getSink()
    else
        error("No log sink configured for logger: " .. self.name)
    end
end

function LoggerImpl:close()
    if self.sink then
        self.sink:close()
    end
end

function LoggerImpl:flush()
    if self.sink then
        self.sink:flush()
    end
end

function LoggerImpl:getChild(name: string): logging.Logger
    assert(name, "Invalid logger name: name cannot be nil")
    local child = self.children[name]
    if not child then
        -- Create fully qualified name for child logger
        local childName = self.name == "-" and name or (self.name .. "." .. name)
        child = LoggerImpl.new(childName, nil, nil, self)
        self.children[name] = child
    end
    return child
end

-- Create the root logger with the environment variable TECS_LOG_LEVEL if set.
local defaultLevel = INFO
local envLevel = os.getenv(TECS_LOG_LEVEL)
if envLevel then
    local level = VALUES[envLevel]
    if not level then
        error(string_format("Invalid logging level: %s", envLevel))
    end
    defaultLevel = level
end

logging.rootLogger = LoggerImpl.new("-", defaultLevel, logging.newStderrSink())

function logging.getLogger(name: string): logging.Logger
    return logging.rootLogger:getChild(name)
end

return logging