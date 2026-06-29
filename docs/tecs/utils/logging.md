---
outline: deep
---

# Logging module

Tecs provides a lightweight and fast logging module with a no-op disabled path. Disabled log levels are
replaced with an empty function at runtime, avoiding branching, formatting, or allocation. Enabled levels
write formatted messages to a configurable sink (defaults to stderr). Timestamps are second-resolution.

## Basic usage

First, require the logging module:

```lua
local logging <const> = require("tecs.utils.logging")
```

Next, create a logger by providing a name. This is typically the name of the module.

```lua
local LOGGER <const> = logging.getLogger("mySystem")
```

Now you can log using `debug`, `info`, `warn`, and `error` methods. The first argument is the message, in
`string.format` syntax, followed by zero or more `string.format` arguments.

```lua
LOGGER:info("system started")
LOGGER:debug("loaded %d assets from %s", count, path)
LOGGER:warn("%.1f%% memory used", 85.3)
LOGGER:error("failed to load: %s", filename)
```

::: tip Pass raw values
Don't pre-format values yourself. Formatting only runs if the level is enabled, so passing raw values keeps
disabled logs free. (Use `%s` for values that need `tostring`; numeric specifiers like `%d` and `%f` expect
numbers and may error if given other types.)
:::

## Log levels

Levels from most to least verbose:

| Level   | Description                              |
| ------- | ---------------------------------------- |
| `DEBUG` | Verbose diagnostic info                  |
| `INFO`  | General operational messages             |
| `WARN`  | Potential issues that aren't fatal       |
| `ERROR` | Failures that need attention             |
| `OFF`   | Suppresses all output                    |

Setting a level enables that level and all less verbose levels below it. For example, `WARN` enables `WARN`
and `ERROR`, but disables `DEBUG` and `INFO`.

::: tip Just log, don't check
Don't worry about ever checking if a log level is enabled because:
1. Logging uses Lua varargs, so the logger itself does not allocate transient tables in the common case
2. Disabled levels are an empty function call: no branching, formatting, or argument inspection
3. Formatting on enabled levels only runs after the level check passes
:::

## Changing the log level

```lua
logging.setLevel("DEBUG")   -- enable all levels
logging.setLevel("WARN")    -- only warnings and errors
logging.setLevel("OFF")     -- silence everything
```

`setLevel` updates all existing loggers immediately, in place, so code holding a reference to a logger
sees the change.

## Changing the output sink

By default, log messages are written to `io.stderr`. You can redirect to any file handle:

```lua
local logFile = io.open("game.log", "a")
logging.setSink(logFile)
```

Like `setLevel`, this updates all existing loggers. The module does not close or flush sinks for you; the
caller owns the file handle lifecycle.

## Output format

Each log line is written as:

```
YYYY-MM-DD HH:MM:SS name LEVEL: message
```

For example:

```
2026-04-12 14:30:00 tecs2d.gfx.mesh ERROR: No render pipeline found in world resources
2026-04-12 14:30:00 mySystem INFO: entity 42 spawned at (100, 200)
```

## Logger caching

`getLogger` returns the same logger instance for a given name. Names are used verbatim and are
case-sensitive. Calling it repeatedly is essentially free (a table lookup), though best practice is to
create a variable for a logger in each module that needs logging.

You can do this:

```lua
-- These return the same object:
local a = logging.getLogger("physics")
local b = logging.getLogger("physics")
assert(a == b)
```

But you _should_ do this:

```lua
local LOGGER <const> = logging.getLogger("physics")
```

## Module properties

| Property     | Default                 | Description                                |
| ------------ | ----------------------- | ------------------------------------------ |
| `level`      | `"INFO"`                | The active log level (read only)           |
| `sink`       | `io.stderr`             | The output file handle (read only)         |
| `dateFormat` | `"%Y-%m-%d %H:%M:%S "`  | The strftime format passed to `os.date`    |

## Performance

An enabled log call measures at **~29 ns/call** on LuaJIT 2.1 with a null sink on an Apple M1
(`logger:info("loaded %d entities", n)`). Real I/O adds its own cost on top; in practice `io.stderr` writes
will dominate. Disabled levels have effectively no overhead: the method slot is replaced with a no-op function,
avoiding branching, formatting, and timestamp lookup.

::: details What makes it fast
1. **Shared writers, per-logger state.** All loggers of a given level point at the same function object,
   and all per-logger state (sink, format, prefix) lives on the logger table. Call sites stay monomorphic
   no matter how many loggers rotate through them, so LuaJIT specializes a single trace.
2. **Per-second date cache.** The default `dateFormat` is seconds-resolution, so a naive `os.date` call
   per log would allocate a fresh string every time (~500 ns, dominating the cost). The module caches the
   formatted timestamp once per wall-clock second, keyed on `ffi.C.time` (JIT-traceable; `os.time` is not).
   Effectively all enabled logs within a given second share one allocation.
:::