---
description: "Where a game may read and write, what to do with a path once you have one, and the watcher that reports when a file changed"
outline: deep
---

# tecs.filesystem

`tecs.filesystem` answers both halves of touching a file: where it is, and what to do with it once you have
the path. `assetPath` and `writablePath` resolve against the two roots a build is allowed to use; `read`,
`write`, `glob`, `copy` and the rest act on whatever path they are handed.

They were two modules and are one, because they were never two questions. Every path a game touches is
resolved and then acted on in the same breath, and a caller holding one half had to name the other module to
do anything with it.

There is still deliberately no second way to resolve a path. Every operation takes the string the platform
takes, so a path from `assetPath`, a path a user typed and an absolute path from somewhere else all work, and
none of them is rewritten on the way through. No virtual filesystem, no mount table, no invented scheme.

## What is under it

| Module                                               | What it is                                      |
| ---------------------------------------------------- | ----------------------------------------------- |
| [`tecs.filesystem.watch`](/modules/filesystem/watch) | polling for changed files, and dispatching them |

Watching is below rather than beside because it is a running poller with a lifecycle of its own rather than a
call that answers, and its vocabulary, an interval, a settle count and a set of kinds, means nothing to the
rest of this. It resolves the first time it is read, so a program that never watches never loads it.

## Where a path comes from

Two roots, and a build may use exactly them. Content is read from one and state is written to the other, and
neither is the process working directory: on desktop that happens to work when launched from a project root and
breaks the moment someone double-clicks, on mobile there is no meaningful working directory at all, and writing
next to the executable is not permitted. So the platform is asked instead, through the adapter seam a licensed
port replaces. Assets sit beside the executable, or wherever the bundle put them; writable state goes where the
platform keeps it for this application and nowhere else.

Every root is cached, and the cache is keyed on the platform generation, so installing a platform drops it
without anyone calling `resetPaths`.

### Naming the writable directory

| Field          | Type     | Default  | Description                                                               |
| -------------- | -------- | -------- | ------------------------------------------------------------------------- |
| `organization` | `string` | `"tecs"` | Organization name the platform uses to build the writable directory path. |
| `application`  | `string` | `"tecs"` | Application name, used the same way.                                      |

Set both before anything asks for `preferencePath`, since the answer is cached from the first call.

```teal
tecs.filesystem.organization = "Ex Nihilo"
tecs.filesystem.application = "Starfarer"
```

### The roots a path is resolved against

#### basePath

The directory the executable was loaded from, with a trailing separator.

```teal
function filesystem.basePath(): string
```

**Returns:** the directory, or an empty string when the platform declines to say. Empty is a real answer on some
targets rather than an error, and callers fall back to a relative path.

#### preferencePath

The writable directory for this application, created if absent.

```teal
function filesystem.preferencePath(): string
```

**Returns:** the directory, with a trailing separator. Named from `organization` and `application`.

::: warning The only place a build may write
Everything else is read-only on at least one target, and finding that out at run time on a device is expensive.
[`filesystem.userFolder`](#userfolder) answers where a platform's documents or screenshots
live, and none of those is a place a build may write.
:::

#### assetRoot

The root the engine reads content from.

```teal
function filesystem.assetRoot(): string
```

**Returns:** the root, with a trailing separator.

Three sources, in order:

1. The `TECS_ASSETS` environment variable, when it is set and not empty. That is how a development run reads
   straight out of a build tree instead of a staged copy.
2. What the host was told at build time, since the build knows the layout it installed and this is not something
   to sniff for.
3. `filesystem.basePath()`, which is where a single-directory build puts everything.

### Resolving against a root

#### assetPath

Resolves `relative` against the asset root.

```teal
function filesystem.assetPath(relative: string): string
```

**Parameters:**

- `relative`: a path below the content root.

**Returns:** `filesystem.assetRoot() .. relative`. Plain concatenation: there is no virtual filesystem and no invented
scheme, which is what lets a port hand out roots of its own.

#### writablePath

Resolves `relative` against the writable root.

```teal
function filesystem.writablePath(relative: string): string
```

**Example:**

```teal
local save <const> = tecs.filesystem.writablePath("slot1.json")
tecs.filesystem.write(save, tecs.data.encodeJSON(state))

local sheet <const> = tecs.filesystem.assetPath("sprites/hero.png")
```

### Cache control

#### resetPaths

Forgets the cached roots.

```teal
function filesystem.resetPaths()
```

A platform change is noticed without this, so it is for a test or a tool that changed the environment underneath
a running process.

#### setAssetRoot

Overrides the asset root, for a test or a tool.

```teal
function filesystem.setAssetRoot(root: string)
```

**Parameters:**

- `root`: the directory to read content from. A trailing separator is added when it is missing.

Synchronizes with the platform generation first, so the override outlives a platform change that may have
preceded it rather than being dropped by the next read.

## Doing something with a path

The other half reads and writes whole files, asks what is at a path, walks a directory, and creates, removes,
renames and copies paths.

Nothing here reaches the operating system directly: every function delegates to the storage backend the installed
platform supplies, which is SDL's unless a port replaced it. What stays in this module is what a port should not
have to write again, which is the argument checks, the record of what has been opened, and the four questions
that are one backend call answered differently.

```teal
local save <const> = tecs.filesystem.writablePath("slot1.json")
tecs.filesystem.write(save, tecs.data.encodeJSON(state))
local bytes <const> = tecs.filesystem.read(save)
```

### Failure is a value

Nothing here raises for a filesystem outcome. Every function answers a status, and every failing one puts the
backend's reason beside it as its second return, so the message a caller shows is the operating system's own.
Only a missing or non-string path raises, because that is a defect in the calling program rather than something
the filesystem did.

A failed enumeration answers nil rather than an empty list, so "this directory is empty" and "this directory
could not be opened" stay apart.

### Blocking

Every function here is synchronous and blocks the calling thread. A path call is one syscall against a mounted
device, and [`watch`](/modules/filesystem/watch) measured a path query at 0.86 microseconds on the machine it was written
on, which is why it puts a hundred of them between frames twice a second and does not notice. That is a
different answer from [`proc`](/modules/system), which runs children on a worker because a child blocks for
another program's lifetime, and from [`assets`](/modules/assets), which decodes on a worker because a PNG is
milliseconds of pure CPU.

The one genuinely unbounded call is a recursive `glob` over a large tree, and it runs on a worker like anything
else: every function takes a path and returns a value, so nothing crosses a thread that must not. Walking a tree
off the main thread is [`workers.spawn`](/modules/workers) with a source that requires this module, and the
answer comes back as plain data.

### Headless

SDL's filesystem API needs no subsystem initialized, and neither this module nor its default backend initializes
one. There is no `available()` and no video gate, unlike [`clipboard`](/modules/system), because there is
nothing to gate on: with no window, no device and no `SDL_Init` at all, every function below answers for real.
This is one of the few subsystems that is more useful without a window than with one.

### Reading and writing

#### read

Reads a whole file and returns its bytes.

```teal
function filesystem.read(path: string, kind?: string): string
```

**Parameters:**

- `path`: an absolute path, or one [`filesystem.assetPath`](#assetpath) has resolved.
- `kind`: what the bytes were read as, for anything watching what this process has opened. Bytes are bytes, so
  nothing here can tell a font's metrics from a level; whatever asked can, and this is where it says so. Omitted,
  the path is recorded as `"document"`.

**Returns:** the bytes, or nil when the file could not be read.

Goes through the platform rather than stdio, because on Android content lives inside the package and only SDL's
IO reaches it, and on a target with no filesystem nothing else reaches it at all. Binary: the result carries its
own length, so a NUL in the middle of it is a byte like any other.

Synchronous, which is what makes it usable while a world is being built. This is for the documents a game or the
engine reads once; a decode a frame should not wait on goes through [`assets`](/modules/assets) instead.

#### write

Writes `bytes` to `path`, replacing whatever was there.

```teal
function filesystem.write(path: string, bytes: string): boolean, string
```

**Returns:** whether it was written, or false and the reason.

Binary: the string's own length is what is written, so a NUL in the middle of it is a byte like any other and an
empty string makes an empty file. The parent directory must already exist. A nil `bytes` raises.

#### note

Records a path under the kind it was first read as.

```teal
function filesystem.note(path: string, kind: string)
```

A named kind supersedes `"document"`. The two can arrive in either order, since a game is free to read a font's
metrics as a document before anything loads them as a font. Decoding happens elsewhere, on a worker, so `assets`
records what it opened through here rather than keeping a second list nothing else can see.

#### loaded

Every path this process has read or decoded, by the kind it was read as.

```teal
function filesystem.loaded(): {string: string}
```

**Returns:** the live table, so something consulting it periodically does not copy it. Shared, so a caller that
means to keep it does not also mean to edit it. Values are `"image"`, `"sound"`, `"font"`, or `"document"` for
bytes nothing named.

A path that failed to load is here too. Whatever asked for it named it, and a file that would not decode is
exactly the one worth noticing a change to. This is the set [`watch`](/modules/filesystem/watch) polls.

### Asking about a path

#### info

What is at `path`.

```teal
function filesystem.info(path: string): Info, string
```

**Returns:** the info, or nil and the reason. Nil is the answer for a path that does not exist, for a broken
symbolic link, and for a directory that cannot be searched; the second return separates them.

**`Info` fields:**

| Field        | Type       | Description                                                                                                          |
| ------------ | ---------- | -------------------------------------------------------------------------------------------------------------------- |
| `kind`       | `PathType` | `"file"`, `"directory"` or `"other"`.                                                                                |
| `size`       | `integer`  | Size in bytes. Zero for a directory.                                                                                 |
| `createdAt`  | `number`   | Nanoseconds since the epoch, as a double. Zero where the platform or the filesystem does not record a creation time. |
| `modifiedAt` | `number`   | Same units.                                                                                                          |
| `accessedAt` | `number`   | Same units.                                                                                                          |

The stamps round to the nearest 256 nanoseconds at present-day values, which no filesystem timestamp comes close
to needing and is worth having in exchange for a plain number rather than a boxed 64-bit integer.

Symbolic links are followed, so a link to a file reports `"file"` and a link to nothing reports nothing at all.
`"other"` is what is left: a socket, a fifo, a device node.

#### exists, isFile, isDirectory

```teal
function filesystem.exists(path: string): boolean
function filesystem.isFile(path: string): boolean
function filesystem.isDirectory(path: string): boolean
```

The same backend call as `info` with the answer thrown away, so asking two of them about one path is two
syscalls. Call `info` once when you want more than one bit of it. Both `isFile` and `isDirectory` follow
symbolic links.

### Enumeration

Enumeration is glob, and there is no callback: SDL's directory enumeration takes a function pointer it calls per
entry, and the seam is shaped around the allocating form instead so no FFI callback is ever installed for a
walk. What that costs is that the whole result exists before the first entry is seen, so a directory with a
million entries is a million Lua strings. That is the honest trade and there is no streaming form of it.

::: warning Glob recurses, and the pattern is what stops it

- `glob(dir)` with no pattern walks the **entire tree** and returns every descendant, as paths relative to `dir`
  joined with `/`.
- `glob(dir, "*")` returns only the immediate children, because `*` and `?` never match a path separator. That
  is what `list` is.
- `glob(dir, "*/*.png")` reaches exactly one level down.
  :::

#### glob

Entries under `path` matching `pattern`, as paths relative to `path`.

```teal
function filesystem.glob(path: string, pattern?: string,
                         options?: GlobOptions): {string}, string
```

**Parameters:**

- `pattern`: `*` and `?` wildcards, or nil for everything, recursively.
- `options`: `GlobOptions`, whose one field is `caseInsensitive`. It defaults to false, which is a
  case-sensitive match on every platform including the ones whose filesystem is not.

**Returns:** the entries, or nil and the reason `path` could not be enumerated. An empty list means an empty
directory, which nil does not.

Directories are returned alongside files and are not distinguished; ask `info` about the ones you care about.
The order is the platform's own, is not sorted, and is not stable across machines; sort it if you need it to be.

#### list

Names directly inside `path`, not recursively.

```teal
function filesystem.list(path: string): {string}, string
```

A glob with a `"*"` pattern, which is what confines it to one level. Names, not paths: join them to `path`
yourself, which is also what keeps this from being a second path resolver.

### Changing the tree

#### createDirectory

Creates `path`, and any parents it needs.

```teal
function filesystem.createDirectory(path: string): boolean, string
```

Succeeds on a directory that already exists. SDL's backend also leaves an SDL error string behind on success,
having tried once before making the parents; that string is not returned here and nothing clears it, so read the
second return value rather than SDL's error after a call that reported success.

#### remove

Removes a file, or an empty directory.

```teal
function filesystem.remove(path: string): boolean, string
```

It does not recurse and fails on a directory with anything in it. It **succeeds when there is nothing at
`path`**: the result says the path is gone, not that this call is what removed it. Ask `exists` first if the
difference matters.

Emptying a tree is a glob and a loop, deepest first, and is left to the caller, because a recursive delete
nobody asked for is the wrong thing to find in a library:

```teal
local entries <const> = tecs.filesystem.glob(root)
table.sort(entries, function(a: string, b: string): boolean return #a > #b end)
for _, entry in ipairs(entries) do
    tecs.filesystem.remove(root .. "/" .. entry)
end
tecs.filesystem.remove(root)
```

#### rename

Moves `from` to `to`, replacing whatever was at `to`.

```teal
function filesystem.rename(from: string, to: string): boolean, string
```

Directories move as well as files, and an existing destination is overwritten with no warning and nothing to
undo it. Whether this works across filesystems is the platform's business.

#### copy

Copies the file at `from` to `to`, replacing whatever was at `to`.

```teal
function filesystem.copy(from: string, to: string): boolean, string
```

Files only: a directory is refused. The destination's parent must already exist; neither `copy` nor `write`
creates it.

### Asking about the host

#### currentDirectory

The process working directory, with a trailing separator.

```teal
function filesystem.currentDirectory(): string, string
```

**Returns:** the directory, or nil and the reason. A platform with no working directory answers nil, which is
most of the ones that are not a desktop.

Here because a command line tool is given relative paths by whoever ran it and has to resolve them against
something. It is emphatically not where a game reads content from or writes state to;
[`filesystem.assetRoot`](#assetroot) and [`filesystem.preferencePath`](#preferencepath) answer that.

#### userFolder

One of the platform's well-known folders, with a trailing separator.

```teal
function filesystem.userFolder(which: UserFolder): string, string
```

**Parameters:**

- `which`: one of `"home"`, `"desktop"`, `"documents"`, `"downloads"`, `"music"`, `"pictures"`, `"publicShare"`,
  `"savedGames"`, `"screenshots"`, `"templates"`, `"videos"`. A name outside that set raises.

**Returns:** the folder, or nil and the reason.

::: warning Often nil, and legitimately so
A platform that has no such concept says so rather than inventing a path: macOS has no saved-games, screenshots
or templates folder and answers nil for all three, and a platform that is not a desktop may have none of them.
Treat every one of these as absent until it is not, and never as a place a build may write;
[`filesystem.preferencePath`](#preferencepath) is the only such place.
:::
