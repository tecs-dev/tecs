# Logging module

The Tecs logging module provides a flexible, hierarchical logging system for your Tecs applications.
It follows common logging patterns found in libraries like Log4j and SLF4J, with support for named
loggers, multiple output destinations, and customizable formatting.

## Overview

The logging system is built around these key concepts:

- **Loggers**: Hierarchical named entities that you use to log messages
- **Log Levels**: Different severity levels for messages (DEBUG, INFO, WARN, ERROR)
- **Sinks**: Destinations where log messages are written (stderr, files, etc.)
- **Formatters**: Functions that convert log messages into formatted strings

## Getting Started

### Basic Usage

```lua
local tecs = require("tecs")
local logging = tecs.logging

-- Get a logger for your component
local logger = logging.getLogger("MySystem")

-- Log messages at different levels
logger:debug("Initializing system with %d components", 5)
logger:info("System started")
logger:warn("Resource usage is high: %d%", 85)
logger:error("Failed to load asset: %s", "player.png")
```

### Configuring Log Levels

You can set the logging level for any logger:

```lua
-- Set the root logger to only show warnings and errors
logging.rootLogger:setLevel(logging.WARN)

-- But make a specific child logger more verbose
local networkLogger = logging.getLogger("Network")
networkLogger:setLevel(logging.DEBUG)
```

You can also set the default level using the `TECS_LOG_LEVEL` environment variable
using "debug", "info", "warn", or "error".

```bash
export Tecs_LOG_LEVEL="debug"
```

## Core API

### Root Logger

A default logger is automatically created and accessible via:

```lua
logging.rootLogger
```

This logger writes to stderr by default, with a level determined by the `Tecs_LOG_LEVEL` environment variable
(defaulting to `INFO` if not set).

### Getting Loggers

```lua
-- Get or create a named logger (child of the root logger)
function logging.getLogger(name: string): Logger

-- Get a child of an existing logger
function logger:getChild(name: string): Logger
```

When you request a logger with the same name multiple times, you'll get the same logger instance.

Child loggers have fully qualified names that include their parent's name. For example, if you get
a child "Renderer" from a logger named "Graphics", the child's full name will be "Graphics.Renderer".

## Logger Interface

Each logger has the following methods:

### Logging Methods

```lua
-- Log a debug message
function logger:debug(message: string, ...: any)

-- Log an info message
function logger:info(message: string, ...: any)

-- Log a warning message
function logger:warn(message: string, ...: any)

-- Log an error message
function logger:error(message: string, ...: any)
```

All logging methods support printf-style formatting with additional arguments. Using these placeholder is preferred
over formatting and concatenating the messages yourself, because the logger is able to skip formatting messages
that don't get logged.

### Configuration Methods

```lua
-- Get the logger's name
function logger:getName(): string

-- Check if messages at the given level will be logged
function logger:isLoggable(level: integer): boolean

-- Set the minimum level to log
function logger:setLevel(level: integer)

-- Get the current logging level
function logger:getLevel(): integer

-- Set where log messages are written
function logger:setSink(sink: LogSink)

-- Get the current log sink
function logger:getSink(): LogSink

-- Flush any buffered log messages
function logger:flush()

-- Close the logger and any open files
function logger:close()
```

## Log Sinks

Log sinks determine where log messages are written. The module provides two built-in sinks:

### Stderr Sink

```lua
-- Create a sink that writes to stderr
function logging.newStderrSink(formatter?: Formatter): LogSink
```

### File Sink

```lua
-- Create a sink that writes to a file
function logging.newFileSink(file: FILE, formatter?: Formatter): LogSink
```

Example usage:

```lua
-- Log to a file instead of stderr
local logFile = io.open("application.log", "a")
local fileSink = logging.newFileSink(logFile)
logging.rootLogger:setSink(fileSink)

-- Or just for a specific subsystem
local audioLogger = logging.getLogger("Audio")
local audioLogFile = io.open("audio.log", "a")
audioLogger:setSink(logging.newFileSink(audioLogFile))

-- Important: Close file handles when done to avoid resource leaks
-- logging.rootLogger:close()  -- When shutting down
```

## Custom Formatters

You can customize how log messages are formatted by providing a formatter function:

```lua
-- A formatter converts log data into a string
type Formatter = function(level: integer, name: string, message: string, ...: any): string

-- The default formatter produces: [level] timestamp [name]: message
logging.DEFAULT_FORMATTER
```

Example custom formatter:

```lua
-- Create a simple formatter without timestamps
local function simpleFormatter(level: integer, name: string, message: string, ...: any): string
    local levelNames = {[1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR"}
    local levelName = levelNames[level] or "UNKNOWN"
    local formatted = string.format(message, ...)
    return string.format("[%s] %s: %s\n", levelName, name, formatted)
end

-- Use it with a sink
local customSink = logging.newStderrSink(simpleFormatter)
logging.rootLogger:setSink(customSink)
```

## Advanced Usage

### Hierarchical Loggers

Loggers are hierarchical. Child loggers inherit settings from their parents unless explicitly overridden:

```lua
-- Create a hierarchy of loggers
local graphicsLogger = logging.getLogger("Graphics")
graphicsLogger:setLevel(logging.INFO)

-- These inherit the INFO level from the parent
local rendererLogger = graphicsLogger:getChild("Renderer")
local textureLogger = graphicsLogger:getChild("Textures")

-- But this one is more verbose
textureLogger:setLevel(logging.DEBUG)
```

## LogSink Interface

If you need to create a custom sink, implement the `LogSink` interface:

```lua
interface LogSink
    -- Log a message
    log: function(self, level: integer, name: string, message: string, ...: any)

    -- Flush any buffered messages
    flush: function(self)

    -- Close the sink and any resources
    close: function(self)
end
```

Example custom sink that collects messages in memory:

```lua
local record MemorySink is LogSink
    messages: {string}
end

function MemorySink:log(level: integer, name: string, message: string, ...: any)
    local formatted = logging.DEFAULT_FORMATTER(level, name, message, ...)
    table.insert(self.messages, formatted)
end

function MemorySink:flush()
    -- No buffering, so nothing to flush
end

function MemorySink:close()
    -- Clear messages on close
    self.messages = {}
end

-- Use the custom sink
local memorySink = setmetatable({messages = {}}, {__index = MemorySink})
logging.rootLogger:setSink(memorySink)
```

## Performance Considerations

- Rely on `%s` placeholders and variadic arguments when logging to efficiently ignore messages without allocations.
- Guard complex formatting with `logger:isLoggable(level: integer)` to avoid unnecessary work.
- Messages below the current log level are skipped without formatting or sink processing.
- Warning and error messages are automatically flushed to ensure they appear immediately.
- Consider setting appropriate log levels for production use to minimize overhead.