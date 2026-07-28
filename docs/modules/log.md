---
description: "SDL's logging behind a Lua-side guard: named loggers mapped to SDL categories, priorities SDL owns, and a JSON Lines file"
outline: deep
---

# tecs.log

`tecs.log` is SDL's logging with a guard in front of it. There is deliberately nothing here to maintain: no
sinks, no prefixes, no timestamp cache, no ring buffer, and no level configuration of its own. SDL already
dispatches a message to the destination that platform actually reads, which is the whole argument, because
writing to stderr from Lua reaches nobody on a phone.

| Platform | Destination                                                 |
| -------- | ----------------------------------------------------------- |
| Windows  | `OutputDebugString`, plus the console where one is attached |
| Android  | `__android_log_write`, so logcat with a tag                 |
| Apple    | `NSLog`                                                     |
| other    | stderr                                                      |

The guard is on this side because `SDL_LogMessage` is variadic and LuaJIT cannot pass Lua values through C
varargs safely: a `%d` handed a double is undefined, not an error. So a message is formatted in Lua and passed
to SDL as one `%s`. The priority is checked before anything is formatted, so a filtered call costs a load and a
compare and never builds the string it would have thrown away.

Because SDL owns the priorities, `SDL_SetLogPriority` works with nothing here mirroring it, and SDL's own
diagnostics land in the same stream with no tee.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.log`. `tecs`
is also set as a global, which makes the require line optional, and engine modules such as this one are
resolved lazily on first field access.

## Loggers

A logger is a name and the SDL category it was given. Names are the unit of filtering, so they are what a
subsystem should use: `tecs.gfx`, `tecs.debug.events`. Each name maps to one SDL category number, allocated
upward from `SDL_LOG_CATEGORY_CUSTOM`, and that number is what `SDL_SetLogPriority` takes.

### Logger

```teal
record Logger
    name: string
    category: integer
end
```

**Fields:**

- `name`: the name the logger was registered under.
- `category`: its SDL category number. The level itself lives in SDL, not here.

### get

Returns the logger for `name`, creating it the first time.

```teal
function log.get(name: string): log.Logger
```

**Parameters:**

- `name`: the subsystem name to filter on. Asking twice returns the same object.

**Returns:** the `Logger` for that name.

Creating a logger also tells the native sink what the category is called, because the sink writes names rather
than numbers and it runs on threads the VM has never seen.

**Example:**

```teal
local LOGGER <const> = tecs.log.get("game.combat")

LOGGER:info("wave %d started", wave)
```

### categoryName

The name a category was registered under.

```teal
function log.categoryName(category: integer): string
```

**Returns:** the registered name, or `category:<n>` for a number nothing registered.

### loggers

Every registered logger name, for tooling that enumerates them.

```teal
function log.loggers(): {string}
```

**Returns:** the names, sorted. The [`context`](/modules/mcp#context) tool reports this list.

## Priorities

Priorities are SDL's numbers, exposed as integer fields so a call site does not have to reach into the
bindings.

| Field          | Value |
| -------------- | ----- |
| `log.TRACE`    | `1`   |
| `log.VERBOSE`  | `2`   |
| `log.DEBUG`    | `3`   |
| `log.INFO`     | `4`   |
| `log.WARN`     | `5`   |
| `log.ERROR`    | `6`   |
| `log.CRITICAL` | `7`   |

### Logger:setLevel

Sets the minimum priority this logger emits.

```teal
function log.Logger:setLevel(priority: integer)
```

### Logger:level

The minimum priority this logger emits.

```teal
function log.Logger:level(): integer
```

Nothing here caches it, so a priority set through SDL directly is seen immediately.

### Logger:enabled

Whether a message at `priority` would be emitted.

```teal
function log.Logger:enabled(priority: integer): boolean
```

Call this directly to guard work that only exists to build a log message, such as serializing a table. The
level methods already guard themselves, so wrapping an ordinary call in it buys nothing.

**Example:**

```teal
if LOGGER:enabled(tecs.log.DEBUG) then
    LOGGER:debug("packet: %s", tecs.json.encode(packet))
end
```

### setLevel

Sets the minimum priority for every category, this module's and SDL's.

```teal
function log.setLevel(priority: integer)
```

## Writing messages

Every level is a method on `Logger` taking a message and zero or more `string.format` arguments. The format is
applied only if the message is emitted, so passing raw values keeps a filtered call free.

```teal
function log.Logger:trace(message: string, ...: any)
function log.Logger:verbose(message: string, ...: any)
function log.Logger:debug(message: string, ...: any)
function log.Logger:info(message: string, ...: any)
function log.Logger:warn(message: string, ...: any)
function log.Logger:error(message: string, ...: any)
function log.Logger:critical(message: string, ...: any)
```

**Example:**

```teal
local LOGGER <const> = tecs.log.get("game.assets")

LOGGER:info("loaded %d sprites from %s", count, path)
LOGGER:warn("%.1f%% of the atlas is unused", waste)
LOGGER:error("could not read %s: %s", path, reason)
```

::: tip Pass raw values
Do not pre-format arguments. Formatting only runs when the level is enabled, so passing the values themselves
is what makes a disabled level cost nothing. Use `%s` for anything that needs `tostring`.
:::

## The log file

The platform destination is human-readable and is what `tail -f`, logcat and Console.app show. A file is what
makes a log queryable after the fact: seek to an offset, read to the end. Opening one adds the file; it does
not replace the platform destination.

Each record is one JSON object on its own line:

```json
{"time":12.345,"level":"INFO","logger":"tecs.gfx","message":"device created"}
```

`time` is seconds since SDL started, `level` is the priority's name, and `logger` is the registered category
name, falling back to an `sdl.*` name for SDL's own categories. The line is written by the native sink rather
than from Lua, because SDL logs from threads it created, such as the audio device thread and the async IO
pool, and entering the VM from a thread it has never seen is the unsafe case. A record is built in a fixed
2 KB buffer, so an unusually long message is truncated at that bound.

### openFile

Also writes every line to `path` as JSON Lines, truncating the file.

```teal
function log.openFile(path: string): boolean
```

**Parameters:**

- `path`: an absolute path. Put it under the writable root with [`paths.writable`](/modules/paths).

**Returns:** whether the file was opened.

The sink holds one file. Calling this while a file is already open leaves the first one in place, so close
before opening another.

### filePath

Where the file is.

```teal
function log.filePath(): string
```

**Returns:** the path passed to `openFile`, or `nil` if none was opened. This is what the
[`get_logs`](/modules/mcp#get_logs) tool hands back to an agent that shares a filesystem with the game.

### closeFile

Stops writing to the file and restores SDL's own output function.

```teal
function log.closeFile()
```

## Under an application

[`Application`](/modules/Application) opens a log file for you. `Application.Config.logFile` is a name under
the writable root and defaults to `log.jsonl`; set it to `""` to write only to the platform's own destination.

## Design record

- [The surface is a global](https://github.com/tecs-dev/tecs/blob/main/README.md#the-surface-is-a-global)
