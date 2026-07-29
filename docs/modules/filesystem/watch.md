---
description: "Polling the files this process loaded so an edit drives a reload, with settle rules for half-written saves"
outline: deep
---

# tecs.filesystem.watch

`tecs.filesystem.watch` notices that a content file changed, so a reload can be driven by the edit rather than by an agent
that remembers to ask.

SDL has no change notification, so a portable watcher is a poll, and going native for one would mean three
implementations plus a fourth for every platform whose SDK is licensed, to save work measured below in
microseconds. What it polls is not the content tree but what was loaded:
[`filesystem.loaded`](/modules/filesystem/#loaded) records every path this process has read or decoded, which is a
far smaller set and is exactly the set where a change has something to act on, since a file nothing opened has no
reloader to route to.

The poll runs between frames, on the main thread, synchronously. One path query per watched path per interval,
measured at 0.86 microseconds a path: a hundred files at two polls a second is 172 microseconds a second, and a
frame the interval has not elapsed on costs a clock read and a compare.

::: warning Development only
`install` refuses on a build that links no shader compiler, which is what tells a release apart from a
development build. A release polls nothing.
:::

[`Application`](/modules/Application) starts the watcher when its config asks for one, and registers the
reloaders for `"shader"`, `"image"`, `"sound"` and `"font"` before it does, so a game that only wants the stock
behavior writes no code here at all. Each of those four ends by asking the application to pick the loop back up
after a crash, which is most of what the watcher is for: a file that broke the game is a file someone is about to
fix, and a loop that stays stopped after the fix has landed makes the watcher a notification rather than a tool. A
handler that raised never gets that far, because the reload refused and nothing changed.

Everything below is for a game or a tool that drives the watcher itself or adds a kind of its own.

## Starting and stopping

### available

Whether the watcher can run on this build.

```teal
function watch.available(): boolean
```

**Returns:** [`capabilities.get().runtimeShaders`](/modules/system#the-two-shader-bits). A release links no
shader compiler, which is the same bit the shader reload tool refuses on and means the same thing.

### install

Starts watching, and refuses on a build that should not.

```teal
function watch.install(config?: watch.Config)
```

**`Config` fields:**

| Field      | Type      | Default          | Description                                                                                                                                                                                                                                                                    |
| ---------- | --------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `interval` | `number`  | `0.5`            | Seconds between polls.                                                                                                                                                                                                                                                         |
| `settle`   | `integer` | `1`              | Polls a change must repeat before it is dispatched, so the default sees a change twice. Zero dispatches the first time a file reads differently, which is what a test that writes whole files wants and what an editor that truncates will trip over. A negative value raises. |
| `root`     | `string`  | `paths.assets()` | Only paths under this prefix are watched, so a file the engine read from somewhere else is not content and is left alone.                                                                                                                                                      |

Every path already loaded is taken as it reads now, so nothing is dispatched for a file that has not changed
since the process opened it. Raises when `available` is false.

**Example:**

```teal
if tecs.filesystem.watch.available() then
    tecs.filesystem.watch.install({ interval = 0.25 })
end
```

### installed

Whether the watcher is running.

```teal
function watch.installed(): boolean
```

### uninstall

Stops watching and forgets every path's state.

```teal
function watch.uninstall()
```

The handlers stay registered. What a kind reloads is a property of the build rather than of whether anything is
watching right now, and a game that turns the watcher off and on again means the second thing.

## Reloaders

Mechanism and policy are split on purpose. Nothing in this module knows what an image or a clip is; the
application registers the reloader that owns each kind.

### on

Registers what reloads a kind.

```teal
function watch.on(kind: string, handler: watch.Handler)
```

**Parameters:**

- `kind`: the kind this handler owns. A nil or empty kind raises.
- `handler`: `function(change: watch.Change)`. Re-registering a kind replaces it, and nil removes it.

**`Change` fields:**

| Field  | Type     | Description                                                 |
| ------ | -------- | ----------------------------------------------------------- |
| `path` | `string` | The file that changed.                                      |
| `kind` | `string` | `"image"`, `"sound"`, `"font"`, `"shader"` or `"document"`. |

The kind comes from how the file was loaded rather than from its name: something asked for a path as an image,
which is what makes it one. A suffix decides in one place only, because a read answers bytes and cannot know what
wanted them, so a `.glsl` document is a `"shader"` and every other unnamed document stays a `"document"`.

A font is its metrics and not the atlas beside them. The atlas is an image, was loaded as one, and reloads as
one: its texels are replaced under the rect they already occupy and no glyph has to be told. The metrics are the
half that decides what a glyph is, so they are the half with a font's rules over them.

A handler runs guarded: a raise is logged rather than propagated, on the grounds that a handler which raised has
said the file is not usable, which is the same answer as waiting for the next save.

It logs under `tecs.watch`, not `tecs.filesystem.watch`. A logger name is what `SDL_SetLogPriority` filters on,
so it is configuration a developer typed into a shell rather than a name this tree can rename in a commit, and
it did not follow the module when the module moved.

**Example:**

```teal
tecs.filesystem.watch.on("document", function(change: tecs.filesystem.watch.Change)
    if change.path:match("%.json$") ~= nil then reloadLevel(change.path) end
end)
```

### kinds

Kinds something is registered to reload, sorted.

```teal
function watch.kinds(): {string}
```

## Polling

### poll

Scans if the interval has elapsed. Call once per iteration.

```teal
function watch.poll(): integer
```

**Returns:** how many changes were dispatched. A frame that is not due costs one clock read and a compare, which
is why this can sit in the loop unconditionally. Zero when the watcher is not running.

### scan

Looks at every watched path once, whatever the interval says.

```teal
function watch.scan(): integer
```

**Returns:** how many changes were dispatched.

What `poll` calls when the interval has elapsed, and what a test drives directly: settling is counted in polls,
so stepping it by hand is how a half-written file is asserted on without sleeping.

Each scan first takes up whatever has been loaded since the last look. A path is accepted as it reads the first
time it is seen, so a run that loads an image on frame ten does not reload it on frame eleven.

## Half-written files

An editor saving commonly truncates and rewrites, so a poll can land on a file of zero length or of half its
eventual size. Two rules cover it:

- A file must report the same size and modification time on `settle` consecutive polls before it is dispatched,
  so a rewrite in progress is seen changing and is not acted on until it stops changing.
- A file of zero length is never dispatched at all, since that is a truncation whatever else it is. A path that
  has gone missing, or that has become a directory, reads the same way, because some editors save by writing a
  temporary file and renaming it over the target and a poll can land in the gap.

A file that changed and changed back inside the settle window is forgotten rather than dispatched, which is a
save that produced the bytes that were already there.

### unsettled

Paths that have changed and have not settled yet, sorted.

```teal
function watch.unsettled(): {string}
```

What a file mid-save looks like from here, and what a test asserts on to show that a truncated write was seen and
not acted on.

### watching

Every path being watched, sorted.

```teal
function watch.watching(): {string}
```

### dispatched

Changes dispatched since `install`.

```teal
function watch.dispatched(): integer
```
