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
<!-- @generated by docs/scripts/reference.py from src/tecs/platform/filesystem.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/platform/filesystem.tl`.

<a id="tecs.filesystem.GlobOptions"></a>

### tecs.filesystem.GlobOptions

<pre><code v-pre>type <a href="#tecs.filesystem.GlobOptions">tecs.filesystem.GlobOptions</a> = storagebackend.GlobOptions
</code></pre>

How a pattern is matched.

<a id="tecs.filesystem.Info"></a>

### tecs.filesystem.Info

<pre><code v-pre>type <a href="#tecs.filesystem.Info">tecs.filesystem.Info</a> = storagebackend.Info
</code></pre>

What the backend answered about one path.

<a id="tecs.filesystem.PathType"></a>

### tecs.filesystem.PathType

<pre><code v-pre>type <a href="#tecs.filesystem.PathType">tecs.filesystem.PathType</a> = storagebackend.PathType
</code></pre>

What a path is. Symbolic links are followed, so a link never reports as
one: "other" is a socket, a fifo or a device.

<a id="tecs.filesystem.Reader"></a>

### tecs.filesystem.Reader

<pre><code v-pre>type <a href="#tecs.filesystem.Reader">tecs.filesystem.Reader</a> = storagebackend.Reader
</code></pre>

A read that hands its bytes over in pieces.

<a id="tecs.filesystem.UserFolder"></a>

### tecs.filesystem.UserFolder

<pre><code v-pre>type <a href="#tecs.filesystem.UserFolder">tecs.filesystem.UserFolder</a> = storagebackend.UserFolder
</code></pre>

Which of the platform's well-known folders to ask for.

<a id="tecs.filesystem.Writer"></a>

### tecs.filesystem.Writer

<pre><code v-pre>type <a href="#tecs.filesystem.Writer">tecs.filesystem.Writer</a> = storagebackend.Writer
</code></pre>

A write that takes its bytes in pieces.

<a id="tecs.filesystem.application"></a>

### tecs.filesystem.application

<pre><code v-pre><a href="#tecs.filesystem.application">tecs.filesystem.application</a>: string
</code></pre>

<a id="tecs.filesystem.assetPath"></a>

### tecs.filesystem.assetPath

<pre><code v-pre>function <a href="#tecs.filesystem.assetPath">tecs.filesystem.assetPath</a>(relative: string): string
</code></pre>

Resolves `relative` against the asset root.

#### Parameters

| Type                      | Name                        | Description                                                                                                             |
| ------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>relative</code> | A path under the content root, with `/` separators. Joined, not validated: nothing here asks whether the file is there. |

#### Returns

| Type                      | Description        |
| ------------------------- | ------------------ |
| <code v-pre>string</code> | The absolute path. |

<a id="tecs.filesystem.assetRoot"></a>

### tecs.filesystem.assetRoot

<pre><code v-pre>function <a href="#tecs.filesystem.assetRoot">tecs.filesystem.assetRoot</a>(): string
</code></pre>

Root the engine reads content from, with a trailing separator.

#### Returns

| Type                      | Description                                                                                                                |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | `TECS_ASSETS` if it is set, then what the host was told at build time, then `basePath`. Cached until the platform changes. |

<a id="tecs.filesystem.basePath"></a>

### tecs.filesystem.basePath

<pre><code v-pre>function <a href="#tecs.filesystem.basePath">tecs.filesystem.basePath</a>(): string
</code></pre>

Directory the executable was loaded from, with a trailing separator.

#### Returns

| Type                      | Description                                                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | The directory. Empty rather than nil when the platform declines to say, which is the case on some targets and is not an error: a caller falls back to a relative path. |

<a id="tecs.filesystem.copy"></a>

### tecs.filesystem.copy

<pre><code v-pre>function <a href="#tecs.filesystem.copy">tecs.filesystem.copy</a>(from: string, to: string): boolean, string
</code></pre>

Copies the file at `from` to `to`, replacing whatever was at `to`.

Files only: a directory is refused. The destination's parent must already
exist.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>from</code> |             |
| <code v-pre>string</code> | <code v-pre>to</code>   |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |

<a id="tecs.filesystem.createDirectory"></a>

### tecs.filesystem.createDirectory

<pre><code v-pre>function <a href="#tecs.filesystem.createDirectory">tecs.filesystem.createDirectory</a>(path: string): boolean, string
</code></pre>

Creates `path`, and any parents it needs.

Succeeds on a directory that already exists. SDL's backend also leaves an
SDL error string behind on success, having tried once before making the
parents; that string is not returned here and nothing clears it, so do not
read `SDL_GetError` after a call that reported success.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |

<a id="tecs.filesystem.currentDirectory"></a>

### tecs.filesystem.currentDirectory

<pre><code v-pre>function <a href="#tecs.filesystem.currentDirectory">tecs.filesystem.currentDirectory</a>(): string, string
</code></pre>

The process working directory, with a trailing separator.

Here because a command line tool is given relative paths by whoever ran it
and has to resolve them against something. It is emphatically not where a
game reads content from or writes state to: `assetRoot` and `preferencePath`
answer that, and say why. A platform with no working directory answers nil,
which is most of the ones that are not a desktop.

#### Returns

| Type                      | Description                           |
| ------------------------- | ------------------------------------- |
| <code v-pre>string</code> | The directory, or nil and the reason. |
| <code v-pre>string</code> |                                       |

<a id="tecs.filesystem.exists"></a>

### tecs.filesystem.exists

<pre><code v-pre>function <a href="#tecs.filesystem.exists">tecs.filesystem.exists</a>(path: string): boolean
</code></pre>

Whether anything is at `path`.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.filesystem.glob"></a>

### tecs.filesystem.glob

<pre><code v-pre>function <a href="#tecs.filesystem.glob">tecs.filesystem.glob</a>(path: string, pattern: string, options: <a href="#tecs.filesystem.GlobOptions">GlobOptions</a>): {string}, string
</code></pre>

Entries under `path` matching `pattern`, as paths relative to `path`.

**Recursive unless the pattern stops it**: with no pattern this walks the
whole tree below `path` and returns every descendant, joined with `/`
whatever the platform's separator is. `*` and `?` never match a separator,
so `"*"` is one level, `"*/*"` is exactly two, and `"*.png"` matches only
immediate children. Directories are returned alongside files and are not
distinguished; ask `info`.

The order is the platform's own and is not sorted.

#### Parameters

| Type                                                                      | Name                       | Description                                                |
| ------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------- |
| <code v-pre>string</code>                                                 | <code v-pre>path</code>    |                                                            |
| <code v-pre>string</code>                                                 | <code v-pre>pattern</code> | `*` and `?` wildcards, or nil for everything, recursively. |
| <code v-pre><a href="#tecs.filesystem.GlobOptions">GlobOptions</a></code> | <code v-pre>options</code> |                                                            |

#### Returns

| Type                        | Description                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>{string}</code> | The entries, or nil and the reason `path` could not be enumerated. An empty list means an empty directory, which nil does not. |
| <code v-pre>string</code>   |                                                                                                                                |

<a id="tecs.filesystem.info"></a>

### tecs.filesystem.info

<pre><code v-pre>function <a href="#tecs.filesystem.info">tecs.filesystem.info</a>(path: string): <a href="#tecs.filesystem.Info">Info</a>, string
</code></pre>

What is at `path`, or nil when there is nothing there.

Nil is the answer for a path that does not exist, for a broken symbolic
link, and for a directory that cannot be searched; the second return
separates them.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                                                        | Description                      |
| ----------------------------------------------------------- | -------------------------------- |
| <code v-pre><a href="#tecs.filesystem.Info">Info</a></code> | The info, or nil and the reason. |
| <code v-pre>string</code>                                   |                                  |

<a id="tecs.filesystem.isDirectory"></a>

### tecs.filesystem.isDirectory

<pre><code v-pre>function <a href="#tecs.filesystem.isDirectory">tecs.filesystem.isDirectory</a>(path: string): boolean
</code></pre>

Whether `path` is a directory, following symbolic links.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.filesystem.isFile"></a>

### tecs.filesystem.isFile

<pre><code v-pre>function <a href="#tecs.filesystem.isFile">tecs.filesystem.isFile</a>(path: string): boolean
</code></pre>

Whether `path` is a regular file, following symbolic links.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.filesystem.list"></a>

### tecs.filesystem.list

<pre><code v-pre>function <a href="#tecs.filesystem.list">tecs.filesystem.list</a>(path: string): {string}, string
</code></pre>

Names directly inside `path`, not recursively.

A glob with a `"*"` pattern, which is what confines it to one level. Names,
not paths: join them to `path` yourself, which is also what keeps this from
being a second path resolver.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                        | Description                       |
| --------------------------- | --------------------------------- |
| <code v-pre>{string}</code> | The names, or nil and the reason. |
| <code v-pre>string</code>   |                                   |

<a id="tecs.filesystem.loaded"></a>

### tecs.filesystem.loaded

<pre><code v-pre>function <a href="#tecs.filesystem.loaded">tecs.filesystem.loaded</a>(): {string : string}
</code></pre>

Every path this process has read or decoded, by the kind it was read as:
"image", "sound", "font", or "document" for bytes nothing named.

A path that failed to load is here too. Whatever asked for it named it, and
a file that would not decode is exactly the one worth noticing a change to.

#### Returns

| Type                                 | Description                                                                                                                                        |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string : string}</code> | The live table, so something consulting it periodically does not copy it. Shared, so a caller that means to keep it does not also mean to edit it. |

<a id="tecs.filesystem.note"></a>

### tecs.filesystem.note

<pre><code v-pre>function <a href="#tecs.filesystem.note">tecs.filesystem.note</a>(path: string, kind: string)
</code></pre>

Records a path under the kind it was first read as.

A named kind supersedes "document". `read` answers bytes and cannot know
what asked for them, so whatever did is the only thing that can say what the
file is, and it says so by naming a kind. The two can arrive in either
order, since a game is free to read a font's metrics as a document before
anything loads them as a font.

Decoding happens elsewhere, on a worker, so `assets` records what it opened
through here rather than keeping a second list nothing else can see.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |
| <code v-pre>string</code> | <code v-pre>kind</code> |             |

<a id="tecs.filesystem.openRead"></a>

### tecs.filesystem.openRead

<pre><code v-pre>function <a href="#tecs.filesystem.openRead">tecs.filesystem.openRead</a>(path: string): <a href="#tecs.filesystem.Reader">Reader</a>, string
</code></pre>

Opens `path` for reading in pieces. The mirror of `openWrite`.

`read` is the right call for a file a program wants whole. This is for one
it wants to hand over as it goes: an upload body is read through this, so
the file being sent is never also in memory.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                                                            | Description                                      |
| --------------------------------------------------------------- | ------------------------------------------------ |
| <code v-pre><a href="#tecs.filesystem.Reader">Reader</a></code> | The reader, or nil and the reason there is none. |
| <code v-pre>string</code>                                       |                                                  |

<a id="tecs.filesystem.openWrite"></a>

### tecs.filesystem.openWrite

<pre><code v-pre>function <a href="#tecs.filesystem.openWrite">tecs.filesystem.openWrite</a>(path: string): <a href="#tecs.filesystem.Writer">Writer</a>, string
</code></pre>

Opens `path` for writing in pieces, replacing whatever was there.

What `write` cannot do: a body that arrives over time never becomes one
string as large as itself. A download that ends in a file writes through
this, and so does anything else assembled from parts.

Close it. The bytes are not guaranteed to be on disk until `close` answers,
and it is the call a full disk is reported by.

```teal
local writer <const> = assert(tecs.filesystem.openWrite(path))
writer:write(chunk)
assert(writer:close())
```

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                                                            | Description                                      |
| --------------------------------------------------------------- | ------------------------------------------------ |
| <code v-pre><a href="#tecs.filesystem.Writer">Writer</a></code> | The writer, or nil and the reason there is none. |
| <code v-pre>string</code>                                       |                                                  |

<a id="tecs.filesystem.organization"></a>

### tecs.filesystem.organization

<pre><code v-pre><a href="#tecs.filesystem.organization">tecs.filesystem.organization</a>: string
</code></pre>

Organization and application names, used to name the writable
directory. Set before anything asks for `preferencePath`.

<a id="tecs.filesystem.preferencePath"></a>

### tecs.filesystem.preferencePath

<pre><code v-pre>function <a href="#tecs.filesystem.preferencePath">tecs.filesystem.preferencePath</a>(): string
</code></pre>

Writable directory for this application, created if absent.

#### Returns

| Type                      | Description                                                                                                                                                                                                                              |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | The directory, with a trailing separator, named from `organization` and `application`. The only place a build may write: everything else is read-only on at least one target, and finding that out at run time on a device is expensive. |

<a id="tecs.filesystem.read"></a>

### tecs.filesystem.read

<pre><code v-pre>function <a href="#tecs.filesystem.read">tecs.filesystem.read</a>(path: string, kind: string): string
</code></pre>

Reads a whole file and returns its bytes, or nil when there is none there.

Through the platform rather than stdio, because on Android content lives
inside the package and only SDL's IO reaches it, and on a target with no
filesystem nothing else reaches it at all. Binary: the result carries its
own length, so a NUL in the middle of it is a byte like any other.

Synchronous, which is what makes it usable while a world is being built.
This is for the documents a game or the engine reads once; a decode a frame
should not wait on goes through `assets.loadImage` or `assets.loadSound`.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                                                                                                              |
| ------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>path</code> | An absolute path, or one `assetPath` has resolved.                                                                                                                                                                                                       |
| <code v-pre>string</code> | <code v-pre>kind</code> | What the bytes were read as, for anything watching what this process has opened. Bytes are bytes, so nothing here can tell a font's metrics from a level; whatever asked can, and this is where it says so. Omitted, the path is recorded as a document. |

#### Returns

| Type                      | Description                                        |
| ------------------------- | -------------------------------------------------- |
| <code v-pre>string</code> | The bytes, or nil when the file could not be read. |

<a id="tecs.filesystem.remove"></a>

### tecs.filesystem.remove

<pre><code v-pre>function <a href="#tecs.filesystem.remove">tecs.filesystem.remove</a>(path: string): boolean, string
</code></pre>

Removes a file, or an empty directory.

It does not recurse and fails on a directory with anything in it. It
**succeeds when there is nothing at `path`**: the result says the path is
gone, not that this call is what removed it.

Emptying a tree is a glob and a loop, deepest first, and is left to the
caller because SDL does not offer it and a recursive delete nobody asked
for is the wrong thing to find in a library:

local entries = filesystem.glob(root)
table.sort(entries, function(a, b) return #a > #b end)
for _, entry in ipairs(entries) do
filesystem.remove(root .. "/" .. entry)
end
filesystem.remove(root)

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |

<a id="tecs.filesystem.rename"></a>

### tecs.filesystem.rename

<pre><code v-pre>function <a href="#tecs.filesystem.rename">tecs.filesystem.rename</a>(from: string, to: string): boolean, string
</code></pre>

Moves `from` to `to`, replacing whatever was at `to`.

Directories move as well as files, and an existing destination is
overwritten with no warning and nothing to undo it. Whether this works
across filesystems is the platform's business.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>string</code> | <code v-pre>from</code> |             |
| <code v-pre>string</code> | <code v-pre>to</code>   |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |

<a id="tecs.filesystem.resetPaths"></a>

### tecs.filesystem.resetPaths

<pre><code v-pre>function <a href="#tecs.filesystem.resetPaths">tecs.filesystem.resetPaths</a>()
</code></pre>

Forgets the cached roots.

A platform change is noticed without this, so this is for a test that moved
something under the process. Named for what it forgets rather than as a bare
`reset`, which on this module would read as resetting the filesystem.

<a id="tecs.filesystem.setAssetRoot"></a>

### tecs.filesystem.setAssetRoot

<pre><code v-pre>function <a href="#tecs.filesystem.setAssetRoot">tecs.filesystem.setAssetRoot</a>(root: string)
</code></pre>

Overrides the asset root, for a test or a tool.

#### Parameters

| Type                      | Name                    | Description                                                                                                              |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code> | <code v-pre>root</code> | The directory to read content from. A trailing separator is added when it is missing rather than doubled when it is not. |

<a id="tecs.filesystem.userFolder"></a>

### tecs.filesystem.userFolder

<pre><code v-pre>function <a href="#tecs.filesystem.userFolder">tecs.filesystem.userFolder</a>(which: <a href="#tecs.filesystem.UserFolder">UserFolder</a>): string, string
</code></pre>

One of the platform's well-known folders, with a trailing separator.

**Often nil, and legitimately so.** A platform that has no such concept says
so rather than inventing a path: macOS has no saved-games, screenshots or
templates folder and answers nil for all three, and a platform that is not a
desktop may have none of them. Treat every one of these as absent until it
is not, and never as a place a build may write; `preferencePath` is the only
such place.

#### Parameters

| Type                                                                    | Name                     | Description |
| ----------------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre><a href="#tecs.filesystem.UserFolder">UserFolder</a></code> | <code v-pre>which</code> |             |

#### Returns

| Type                      | Description                        |
| ------------------------- | ---------------------------------- |
| <code v-pre>string</code> | The folder, or nil and the reason. |
| <code v-pre>string</code> |                                    |

<a id="tecs.filesystem.watch"></a>

### tecs.filesystem.watch

<pre><code v-pre><a href="#tecs.filesystem.watch">tecs.filesystem.watch</a>: watch
</code></pre>

Polling for changed files, and dispatching what changed.

<a id="tecs.filesystem.writablePath"></a>

### tecs.filesystem.writablePath

<pre><code v-pre>function <a href="#tecs.filesystem.writablePath">tecs.filesystem.writablePath</a>(relative: string): string
</code></pre>

Resolves `relative` against the writable root.

#### Parameters

| Type                      | Name                        | Description                            |
| ------------------------- | --------------------------- | -------------------------------------- |
| <code v-pre>string</code> | <code v-pre>relative</code> | A path under the preference directory. |

#### Returns

| Type                      | Description        |
| ------------------------- | ------------------ |
| <code v-pre>string</code> | The absolute path. |

<a id="tecs.filesystem.write"></a>

### tecs.filesystem.write

<pre><code v-pre>function <a href="#tecs.filesystem.write">tecs.filesystem.write</a>(path: string, bytes: string): boolean, string
</code></pre>

Writes `bytes` to `path`, replacing whatever was there.

Binary: the string's own length is what is written, so a NUL in the middle
of it is a byte like any other and an empty string makes an empty file. The
parent directory must already exist.

The other half of this is `read`, just above.

#### Parameters

| Type                      | Name                     | Description |
| ------------------------- | ------------------------ | ----------- |
| <code v-pre>string</code> | <code v-pre>path</code>  |             |
| <code v-pre>string</code> | <code v-pre>bytes</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |
