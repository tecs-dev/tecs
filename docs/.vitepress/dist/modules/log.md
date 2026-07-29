---
url: /modules/log.md
description: >-
  SDL's logging behind a Lua-side guard: named loggers mapped to SDL categories,
  priorities SDL owns, and a JSON Lines file
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

* `name`: the name the logger was registered under.
* `category`: its SDL category number. The level itself lives in SDL, not here.

### get

Returns the logger for `name`, creating it the first time.

```teal
function log.get(name: string): log.Logger
```

**Parameters:**

* `name`: the subsystem name to filter on. Asking twice returns the same object.

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
    LOGGER:debug("packet: %s", tecs.data.encodeJSON(packet))
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

* `path`: an absolute path. Put it under the writable root with [`writablePath`](/modules/filesystem/#writablepath).

**Returns:** whether the file was opened.

The sink holds one file. Calling this while another is open moves to `path`: the previous file is closed and
every later line goes to the new one, between lines rather than inside one. A path that cannot be opened
returns false and changes nothing, so the file already open keeps receiving lines.

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

[`Application`](/modules/application) opens a log file for you. `Application.Config.logFile` is a name under
the writable root and defaults to `log.jsonl`; set it to `""` to write only to the platform's own destination.

## Reference

Every function and type this module carries, rendered from `src/tecs/log.tl`.

### tecs.log.CRITICAL

See `TRACE`. The highest, so setting a level to this emits almost nothing.


### tecs.log.DEBUG

See `TRACE`.


### tecs.log.ERROR

See `TRACE`.


### tecs.log.INFO

See `TRACE`.


### tecs.log.Logger

A named category. Holds its SDL category number and nothing else; the
level lives in SDL.


### tecs.log.Logger.name

The name it was registered under. The native sink writes this rather than the
number, so it is what appears in the platform's log.


### tecs.log.Logger.category

Its SDL category, and the argument `SDL_SetLogPriority` takes. Handed out in
registration order from `SDL_LOG_CATEGORY_CUSTOM` upwards, so a number is
stable within a run and is not stable across runs that register in a different
order. Filter by name.


### tecs.log.Logger.setLevel

Sets the minimum priority this logger emits.

#### Parameters

| Type                                                     | Name                        | Description                                                                                      |
| -------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------ |
| Logger | self     |                                                                                                  |
| integer                               | priority | One of the constants on `log`. A message at this priority is emitted; anything lower is dropped. |

### tecs.log.Logger.level

The minimum priority this logger emits.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Logger | self |             |

#### Returns

| Type                       | Description                                                                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | SDL's current priority for this category, which is SDL's default until something sets one, so it is not necessarily a value any caller here chose. |

### tecs.log.Logger.enabled

Whether a message at `priority` would be emitted.

Call this directly to guard work that only exists to build a log message,
such as serializing a table. The level methods already guard themselves.

#### Parameters

| Type                                                     | Name                        | Description |
| -------------------------------------------------------- | --------------------------- | ----------- |
| Logger | self     |             |
| integer                               | priority |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.log.Logger.trace

Accepts `string.format` specifiers, applied only if the message is emitted.

The level is checked before the formatting, so a filtered call costs a load and a
compare and the arguments are never touched. Building those arguments is still the
caller's cost; guard that with `enabled`.

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                |
| -------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Logger | self    |                                                                                                                                            |
| string                                | message | A `string.format` template when arguments follow, and a literal otherwise, so a `%` in a plain message is safe.                            |
| any                                   | ...     | Formatted into `message`. A wrong count or a wrong specifier raises from `string.format`, and only on the calls that are actually emitted. |

### tecs.log.Logger.verbose

At `VERBOSE`. See `trace` for the formatting rules.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.Logger.debug

At `DEBUG`. See `trace` for the formatting rules.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.Logger.info

At `INFO`. See `trace` for the formatting rules.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.Logger.warn

At `WARN`. See `trace` for the formatting rules.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.Logger.error

At `ERROR`. See `trace` for the formatting rules. Logging is all this does; it neither
raises nor returns anything.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.Logger.critical

At `CRITICAL`. See `trace` for the formatting rules.

#### Parameters

| Type                                                     | Name                       | Description |
| -------------------------------------------------------- | -------------------------- | ----------- |
| Logger | self    |             |
| string                                | message |             |
| any                                   | ...     |             |

### tecs.log.TRACE

Priority values, as SDL numbers them.


### tecs.log.VERBOSE

See `TRACE`.


### tecs.log.WARN

See `TRACE`.


### tecs.log.categoryName

The name a category was registered under, for a sink that wants it.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| integer | category |             |

#### Returns

| Type                      | Description                                                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| string | Never nil. A category nothing registered, including SDL's own, comes back as `"category:<number>"` rather than as an error. |

### tecs.log.closeFile

Stops writing to the file and restores SDL's own output function.

Does nothing when no file is open, so it is safe to call on a shutdown path that does
not know whether one was ever asked for.


### tecs.log.filePath

Where the file is, or nil if none was opened. What `get_logs` hands back
to an agent that shares a filesystem with the game.

#### Returns

| Type                      | Description                                                                                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| string | The path as it was given, not resolved against the working directory, so a relative one is only meaningful to a reader in the same place the game ran. |

### tecs.log.get

Returns the logger for `name`, creating it the first time.

Names are the unit of filtering, so they are what a subsystem should use:
`tecs.gfx`, `tecs.debug.events`. Each maps to one SDL category, which
is what `SDL_SetLogPriority` takes.

#### Parameters

| Type                      | Name                    | Description                                                                  |
| ------------------------- | ----------------------- | ---------------------------------------------------------------------------- |
| string | name | Compared byte for byte, so two spellings are two categories with two levels. |

#### Returns

| Type                          | Description                                                                                                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| log.Logger | The same object on every call for a name, and it lives as long as the process. A new logger starts at whatever SDL's default priority is, not at a level of ours. |

### tecs.log.loggers

Every registered logger name, for tooling that enumerates them.

#### Returns

| Type                        | Description                                                                                                                            |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| {string} | A fresh array each call, sorted, holding only names something has already asked `get` for. A subsystem that has not run yet is absent. |

### tecs.log.openFile

Also writes every line to `path` as JSON Lines, truncating it.

The platform destination keeps receiving the human-readable form, so
`tail -f`, logcat and Console.app are unaffected. The file is what makes a
log queryable after the fact: seek to an offset, read to the end.

Lines are written from whichever thread logged, including threads the VM never created,
so ordering follows the calls and not any Lua-side sequence.

Called while another file is open, this moves to `path`: the previous file is closed and
every later line goes to the new one, so the path this accepts is the path being written
to and `filePath` never names a file the sink has left behind. The move happens between
lines rather than inside one.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                 |
| ------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| string | path | Truncated if it exists, created if it does not, including when it is the file already open, so this is not a way to check one is. Directories are not made. |

#### Returns

| Type                       | Description                                                                                                                |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| boolean | False when the file could not be opened, in which case nothing else changed and a file already open keeps receiving lines. |

### tecs.log.setLevel

Sets the minimum priority for every category, ours and SDL's.

#### Parameters

| Type                       | Name                        | Description                                                                       |
| -------------------------- | --------------------------- | --------------------------------------------------------------------------------- |
| integer | priority | Overrides every per-logger level already set, so this is a reset and not a floor. |
