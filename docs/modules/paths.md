---
description: "Where assets are read from and state is written to, asked of the platform rather than derived from the working directory"
outline: deep
---

# paths

`tecs.paths` answers _where_: the directory the executable was loaded from, the one writable directory this
application owns, and the root content is read from. [`filesystem`](/modules/filesystem) answers _what to do once
you have one_.

It is never the process working directory. On desktop that happens to work when a build is launched from a
project root and breaks the moment someone double-clicks it; on mobile there is no meaningful working directory
at all, and writing next to the executable is not permitted. So the platform is asked instead, through the
adapter seam a licensed port replaces. Assets sit beside the executable, or wherever the bundle put them;
writable state goes where the platform keeps it for this application and nowhere else.

Every root is cached, and the cache is keyed on the platform generation, so installing a platform drops it
without anyone calling `reset`.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.paths`. `tecs`
is also set as a global, which makes the require line optional, and engine modules are resolved lazily on first
field access.

## Naming the writable directory

| Field          | Type     | Default  | Description                                                               |
| -------------- | -------- | -------- | ------------------------------------------------------------------------- |
| `organisation` | `string` | `"tecs"` | Organisation name the platform uses to build the writable directory path. |
| `application`  | `string` | `"tecs"` | Application name, used the same way.                                      |

Set both before anything asks for `pref`, since the answer is cached from the first call.

```teal
tecs.paths.organisation = "Ex Nihilo"
tecs.paths.application = "Starfarer"
```

## The roots

### base

The directory the executable was loaded from, with a trailing separator.

```teal
function paths.base(): string
```

**Returns:** the directory, or an empty string when the platform declines to say. Empty is a real answer on some
targets rather than an error, and callers fall back to a relative path.

### pref

The writable directory for this application, created if absent.

```teal
function paths.pref(): string
```

**Returns:** the directory, with a trailing separator. Named from `organisation` and `application`.

::: warning The only place a build may write
Everything else is read-only on at least one target, and finding that out at run time on a device is expensive.
[`filesystem.userFolder`](/modules/filesystem#userfolder) answers where a platform's documents or screenshots
live, and none of those is a place a build may write.
:::

### assets

The root the engine reads content from.

```teal
function paths.assets(): string
```

**Returns:** the root, with a trailing separator.

Three sources, in order:

1. The `TECS_ASSETS` environment variable, when it is set and not empty. That is how a development run reads
   straight out of a build tree instead of a staged copy.
2. What the host was told at build time, since the build knows the layout it installed and this is not something
   to sniff for.
3. `paths.base()`, which is where a single-directory build puts everything.

## Resolving against a root

### asset

Resolves `relative` against the asset root.

```teal
function paths.asset(relative: string): string
```

**Parameters:**

- `relative`: a path below the content root.

**Returns:** `paths.assets() .. relative`. Plain concatenation: there is no virtual filesystem and no invented
scheme, which is what lets a port hand out roots of its own.

### writable

Resolves `relative` against the writable root.

```teal
function paths.writable(relative: string): string
```

**Example:**

```teal
local save <const> = tecs.paths.writable("slot1.json")
tecs.filesystem.write(save, tecs.json.encode(state))

local sheet <const> = tecs.paths.asset("sprites/hero.png")
```

## Cache control

### reset

Forgets the cached roots.

```teal
function paths.reset()
```

A platform change is noticed without this, so it is for a test or a tool that changed the environment underneath
a running process.

### setAssets

Overrides the asset root, for a test or a tool.

```teal
function paths.setAssets(root: string)
```

**Parameters:**

- `root`: the directory to read content from. A trailing separator is added when it is missing.

Synchronises with the platform generation first, so the override outlives a platform change that may have
preceded it rather than being dropped by the next read.

## Design record

- [The file watcher](https://github.com/tecs-dev/tecs/blob/main/README.md#the-file-watcher)
- [Touching the filesystem](https://github.com/tecs-dev/tecs/blob/main/README.md#touching-the-filesystem)
- [Porting to a platform SDL does not cover](https://github.com/tecs-dev/tecs/blob/main/README.md#porting-to-a-platform-sdl-does-not-cover)
