---
description: "The operating system asked directly: what this build can do here, the clipboard, running another program, URLs, locales, power and native dialogs"
outline: deep
---

# tecs.system

`tecs.system` is the operating system, asked directly. What this build can do on this machine, the clipboard,
running another program, and the services a desktop offers: opening a URL, listing the user's languages,
reading the battery, showing a message box, and asking the user to pick a file.

One module rather than four, because none of these is a subsystem a game builds on. Each is a handful of calls
a game makes when a player asks for something, and each was too small to be a name of its own: a game copying a
path to the clipboard and then opening the containing folder was naming three modules to do one thing.

There is deliberately no `tecs.platform`. That is where this tree keeps an implementation category, and a
public name should say what a game is doing rather than which directory the code sits in.

Names are qualified by what they act on. On a module that also runs programs and reads capabilities, a bare
`text`, `data`, `clear`, `run`, `result` or `update` means nothing on its own, so the clipboard's calls carry
`Clipboard` and the process calls carry `Process`.

## What this build can do

`capabilities` reports what this build of the engine can do on the machine it is running on: whether machine
code is being generated, whether shaders can be compiled at run time, whether a touch device is attached, and
how many cores a worker pool has to size itself against.

It is read rather than inferred. Selecting behavior from `ffi.os` guesses: it cannot tell a build that linked a
shader compiler from one that did not, or an interpreter-only LuaJIT from a jitting one, and both distinctions
change what the engine is allowed to attempt.

### capabilities

Reads the capabilities of the running build.

```teal
function tecs.system.capabilities(): capabilities
```

**Returns:** the same table on every call until the platform changes. It is shared, so a caller that means to
keep it does not also mean to edit it.

The answer is cached, since none of it changes while a platform is installed. The cache is keyed on the platform
generation, so installing a platform drops it without anybody calling `reset`.

**Example:**

```teal
local caps <const> = tecs.system.capabilities()
local decoders <const> = caps.workers and math.max(1, caps.cores - 1) or 0
print(("%s on %s, %d decode workers"):format(caps.target, caps.architecture, decoders))
```

### What it answers

| Field              | Type       | Description                                                                                                                                                                                                       |
| ------------------ | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `target`           | `string`   | Platform name as SDL reports it, such as `"macOS"` or `"Android"`. A licensed port answers with its own name instead, since everything here describes the platform actually installed.                            |
| `architecture`     | `string`   | CPU architecture LuaJIT was built for.                                                                                                                                                                            |
| `jit`              | `boolean`  | Whether machine code is being generated. False on a target that forbids it, where the interpreter runs instead. Independent of `ffi`.                                                                             |
| `ffi`              | `boolean`  | Always true. The engine has no path that does not use the FFI, so a build without it does not run at all rather than running degraded.                                                                            |
| `dynamicLibraries` | `boolean`  | Whether a library can be loaded by name at run time. False where every library is linked into the executable.                                                                                                     |
| `runtimeShaders`   | `boolean`  | Whether shaders can be compiled from source at run time.                                                                                                                                                          |
| `packagedShaders`  | `boolean`  | Whether shaders are being read from a packaged artifact. Independent of `runtimeShaders`: a development build may have both, and a release has only this.                                                         |
| `shaderFormats`    | `{string}` | Shader formats this target consumes. One entry, since a build supplies one format.                                                                                                                                |
| `touch`            | `boolean`  | Whether a touch device is attached right now. A property of the machine rather than of the target: a desktop with a touchscreen has one.                                                                          |
| `gamepad`          | `boolean`  | Always true. Every target reaches gamepads through the same subsystem, so what varies is whether one is plugged in.                                                                                               |
| `sensors`          | `boolean`  | Whether the device itself carries a gyroscope or an accelerometer. True on iOS and Android. Says nothing about a gamepad's sensors.                                                                               |
| `workers`          | `boolean`  | Whether work can be run off the main thread.                                                                                                                                                                      |
| `cores`            | `integer`  | Logical cores, for sizing a worker pool.                                                                                                                                                                          |
| `writableStorage`  | `boolean`  | Always true. Every target has somewhere to write, and [`preferencePath`](/modules/filesystem/#preferencepath) is where. The field exists so a caller can ask rather than assume, not because a target answers no. |

#### Fields whose answer is about a device, not the target

`gamepad` says the subsystem exists, not that a pad is plugged in; ask [`Input`](/modules/input) which gamepads
are connected. `sensors` says the device itself carries a gyroscope or an accelerometer, which is a different
question from whether a particular pad has one; [`Gamepad`](/modules/input#gamepad) answers that per device. `touch`
is the one hardware answer here that is asked of the platform each time the capabilities are resolved, because
neither a desktop with a touchscreen nor a simulator without one follows from the OS name.

#### The two shader bits

`runtimeShaders` is whether a shader compiler was linked into this build, and it is what separates a development
build from a release. [`watch`](/modules/filesystem/watch) refuses to install without it, on the grounds that a release has
no business polling the filesystem for reloads it could not complete. `packagedShaders` is whether a prebuilt
pack was loaded, which a release always has and a development build may have as well.

### resetCapabilities

Forgets the cached answer.

```teal
function tecs.system.resetCapabilities()
```

A platform change is noticed without this, so it is for a test that changed something the resolution reads.

## The clipboard

Text in, text out, the mime types on offer, the bytes behind one of them, and the primary selection beside
it.

It is the other half of the [`clipboardUpdate` event](/modules/events#kind-reference), which reports that the clipboard
changed and lists the mime types now on offer. Being told and having no way to look is the worse of the two
halves to ship alone.

Nothing here is cached. The clipboard belongs to the desktop rather than to this process, so a value read a
frame ago may already be wrong, and `clipboardUpdate` is the only invalidation there is.

### With no video

The clipboard is part of SDL's video subsystem, so a headless tool has none. Every function here answers the
same shape without calling SDL at all: `available` is false, reads are empty, writes fail. That way a headless
tool gets an answer rather than a crash, and SDL's error string is left holding whatever last set it instead of
being overwritten by a question that was never going to be answered.

#### clipboardAvailable

Whether there is a clipboard to read at all.

```teal
function clipboardAvailable(): boolean
```

**Returns:** whether the video subsystem is up. This is the only answer that separates no clipboard from an
empty one, since no other return value can.

### Text

#### clipboardText

The clipboard's text.

```teal
function clipboardText(): string
```

**Returns:** the text, or an empty string when the clipboard holds none. Empty is also the answer when the
clipboard holds something that is not text, and when there is no video. Ask `hasText` to tell those apart from
text that is genuinely empty.

#### setClipboardText

Puts `text` on the clipboard, replacing whatever was there.

```teal
function setClipboardText(text: string): boolean
```

**Parameters:**

- `text`: the text to offer. SDL copies it, so the string is not retained here.

**Returns:** false when the platform refused, which includes having no video. A missing argument raises, because
SDL reads a null `const char *` as an empty string and a nil slipping through would clear the clipboard rather
than fail.

#### hasClipboardText

Whether the clipboard holds text.

```teal
function hasClipboardText(): boolean
```

Cheaper than reading it: no allocation crosses the boundary, and on a platform where a read negotiates with the
owning application, no negotiation happens.

#### clearClipboard

Withdraws what this application put on the clipboard.

```teal
function clearClipboard(): boolean
```

The clipboard is left empty rather than restored to what preceded the write, because nothing anywhere remembers
what that was.

**Example:**

```teal
world:observe(0, tecs.events.on.clipboardUpdate, function(event: tecs.events.Event)
    if not event.owner and tecs.system.hasClipboardText() then
        pasteBuffer = tecs.system.clipboardText()
    end
end)
```

### Arbitrary mime types

Reading a mime type is here; offering one is not. `SDL_SetClipboardData` takes no copy: it retains a callback and
calls it when some other application asks for the bytes, which may be long after the call returned and is a
moment this process does not choose. In Lua that is an FFI callback pinned for the lifetime of the offer and
entered from wherever SDL fulfils the request, and this engine keeps its callbacks native. Reading carries none
of that, so `mimeTypes`, `hasData` and `data` are here and the offer side is not. `setText` is the only way to
write.

#### clipboardMimeTypes

Mime types the clipboard currently offers, in the order SDL reports them.

```teal
function clipboardMimeTypes(): {string}
```

**Returns:** the list, empty when the clipboard is empty. The same list a `clipboardUpdate` event carries, for a
caller that wants to ask rather than wait to be told.

#### hasClipboardData

Whether the clipboard offers `mimeType`.

```teal
function hasClipboardData(mimeType: string): boolean
```

#### clipboardData

The clipboard's bytes for `mimeType`.

```teal
function clipboardData(mimeType: string): string
```

**Returns:** the bytes, or nil when the clipboard offers none. Nil rather than an empty string, because a mime
type can be offered with no bytes behind it and that is not the same as not being offered.

**Example:**

```teal
for _, mime in ipairs(tecs.system.clipboardMimeTypes()) do
    if mime == "image/png" then
        local bytes <const> = tecs.system.clipboardData(mime)
        if bytes ~= nil then importScreenshot(bytes) end
    end
end
```

### The primary selection

A second, independent clipboard: X11 and Wayland fill it with whatever was last selected and paste it on a
middle click, with no copy step at all. It is not a flavour of the clipboard and does not track it.

Elsewhere there is no such concept. SDL does not fail there; it keeps the value in the video device, so
`setPrimary` succeeds, `primary` reads back what this process wrote, and nothing outside the process ever sees
it. Read it as a hint that may be answered locally rather than as a shared clipboard.

#### primarySelection

```teal
function primarySelection(): string
```

**Returns:** the primary selection's text, or an empty string when it holds none.

#### setPrimarySelection

```teal
function setPrimarySelection(text: string): boolean
```

Succeeds on a platform that has no primary selection, where SDL keeps the value for this process alone.

#### hasPrimarySelection

```teal
function hasPrimarySelection(): boolean
```

### Encoding

Clipboard text is UTF-8 and passes through byte for byte. Line endings are not normalized, so text copied on
Windows arrives as CRLF and stays CRLF, and nothing is trimmed from either end. Text stops at the first NUL,
because that is what terminates the C string SDL returns and what every producer of clipboard text intends;
`data` uses the length SDL reports instead, so a blob keeps its NULs.

## Running another program

`runProcess` runs another program. A command line tool, a resource pipeline or an asset build wants to shell
out, and a game wants to do it between two frames rather than instead of them.

Reading a child's output and waiting for it to exit both hold the calling thread for as long as the child runs,
so neither happens on the main thread. A run goes out to a worker, the loop pumps, and a
[`Future`](/modules/Future) settles; that is the same shape [`assets`](/modules/assets) uses for a decode, for
the same reason.

It is one of the few subsystems more useful without a window than with one. No SDL subsystem is initialized and
no process call is made on this side at all, so it works under a plain interpreter with no video, no device and
no host.

```teal
local run <const> = tecs.system.runProcess({ args = { "git", "rev-parse", "HEAD" } })
-- ... frames pass, the loop pumps ...
if run.status == "ready" and run.value:succeeded() then
    print(run.value.output)
end
```

A run is a `Future`, so the words for how it ended are the ones every asynchronous thing in the tree uses, and a
caller who wants the answer rather than the polling writes:

```teal
local head <const> = tecs.system.runProcess({ args = { "git", "rev-parse", "HEAD" } })
    :map(function(result: tecs.system.ProcessResult): string return result.output end)
    :recover(function(): string return "unknown" end)
    :wait()
print(head.value)
```

A `wait` on a run spends up to 30 seconds by default, which is longer than an asset decode's default because a
child process is a different order of work.

### One shape: run to completion

`runProcess` serves the child whose output you want when it finishes: a version query, an image conversion, a
shader translator, a packer. The result arrives whole, once, with the exit status beside it.

It deliberately does not serve the long-running child whose output you want as it appears. That is a different
API, not a flag on this one: it has to answer what a chunk is, what happens when a chatty child outruns its
reader, and how two streams interleave once they are delivered separately over time, and every one of those is a
guess here and a requirement there.

::: warning Bound what you run
Output is accumulated whole, so a child that prints forever is a child that allocates forever, and `timeoutMs`
is the answer.
:::

### runProcess

Runs a program and answers a future for it, immediately.

```teal
function runProcess(options: Options): Future<Result>
```

**Returns:** a future that reads `"pending"` until [`updateProcesses`](#updateprocesses), or a `wait` on it, takes the
worker's answer. Nothing here blocks. The first `run` installs the worker, so a process that never shells out
never starts a thread.

**`Options` fields:**

| Field         | Type               | Default   | Description                                                                                                                                                                                                                                                  |
| ------------- | ------------------ | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `args`        | `{string}`         | required  | The program and its arguments; `args[1]` is the program. A name without a separator is resolved against `PATH`. A missing, empty or non-string-carrying list raises.                                                                                         |
| `cwd`         | `string`           | inherited | Working directory for the child.                                                                                                                                                                                                                             |
| `env`         | `{string: string}` | inherited | Environment variables to set. Applied over this process's environment, or over an empty one when `clearEnv` is true.                                                                                                                                         |
| `clearEnv`    | `boolean`          | `false`   | Start the child's environment empty rather than inherited, so `env` is the whole of what it sees.                                                                                                                                                            |
| `mergeStderr` | `boolean`          | `false`   | Fold the child's error output into `output` instead of keeping it in `errorOutput`. Separate by default, because a tool's diagnostics interleaved into its output corrupt anything parsing that output, and the diagnostics are what you want when it fails. |
| `input`       | `string`           | none      | Bytes written to the child's standard input, which is closed once they are through. Omitted closes it immediately, so a child reading to end of input sees one rather than waiting.                                                                          |
| `timeoutMs`   | `integer`          | none      | Kill the child forcibly after this many milliseconds. Omitted lets it run as long as it likes.                                                                                                                                                               |

**Example:**

```teal
local formatted <const> = tecs.system.runProcess({
    args = { "clang-format", "-" },
    input = source,
    timeoutMs = 5000,
})
```

### ProcessResult

What a child that ran leaves behind. It is the value a `"ready"` future carries.

| Field         | Type       | Description                                                                                  |
| ------------- | ---------- | -------------------------------------------------------------------------------------------- |
| `args`        | `{string}` | The program and its arguments, as given.                                                     |
| `pid`         | `integer`  | The child's process id.                                                                      |
| `exitCode`    | `integer`  | The child's exit code, or the negated signal that ended it.                                  |
| `output`      | `string`   | Everything the child wrote to standard output.                                               |
| `errorOutput` | `string`   | Everything it wrote to standard error, or `""` when `mergeStderr` folded that into `output`. |

#### ProcessResult:succeeded

Whether the child reported success.

```teal
function Result:succeeded(): boolean
```

**Returns:** whether `exitCode` is zero. A question about the answer rather than about whether there is one,
which is why it is a method and not a status: a result exists exactly when a child ran to completion, whatever it
then reported.

#### processResult

The record a run fills in, whatever became of it.

```teal
function processResult(run: Future<Result>): Result
```

**Returns:** the same object the future carries on `"ready"`, or nil for a run that never started and for
anything that is not a run from here.

It is reachable in the two cases where the future does not carry it. Before the child ends, so `pid` can be read
as soon as it has started, which is the one thing about a run that means anything before there is an answer. And
after a child was killed, which settles `"canceled"` with no value but does not throw away what the child
managed to say first.

### How a run ends

`"failed"` means the child never started. A program that cannot be started settles there with `error` set,
rather than raising: a caller that shells out is already branching on the exit code, and a spawn that failed is
one more branch on the same value.

An exit code is not a failure. A child that ran and exited 1 settles `"ready"`, because the run did what it was
asked to and the code is the answer; reading it the other way would make every non-zero exit propagate as a
failure through `map`, which is wrong for everything that shells out to a tool whose exit code is data.

`"canceled"` means this process ended the child, through `kill`, a `timeoutMs` deadline, or `shutdown`.

### Pumping

#### updateProcesses

Takes whatever the worker has answered. Call once per frame.

```teal
function updateProcesses(): integer
```

**Returns:** how many runs finished. [`Application`](/modules/Application) calls this for you each iteration.

#### pendingProcesses

Runs that have not answered yet.

```teal
function pendingProcesses(): integer
```

### Ending a child

#### killProcess

Asks the worker to end a child.

```teal
function killProcess(run: Future<Result>, force?: boolean)
```

**Parameters:**

- `run`: the future `runProcess` answered.
- `force`: whether the kill is unrefusable. Defaults to false, which is gentle and may be ignored by the child;
  a forced kill cannot be refused but leaves whatever the child was writing half written.

Queued rather than immediate: every process call belongs to the worker, so this is picked up on its next pass.
The future settles `"canceled"` when the child goes.

`run:cancel()` is the other spelling, and it counts holders: it ends the child only when the last consumer of the
future has given it up, and it forces the kill, because the last consumer of the output has just gone and there
is nothing left to be gentle on behalf of. `killProcess` ends the child whoever else is watching.

#### shutdownProcesses

Ends every child still running and stops the worker.

```teal
function shutdownProcesses(graceMs?: number)
```

**Parameters:**

- `graceMs`: how long a child gets to end gently before it is forced. Defaults to 250.

Gentle first, then forced, because a child that is mid-write deserves the chance to finish the line and a
teardown that waits forever deserves nothing. What it does not do is walk away: a detached child outlives the
process that started it, and the worker still blocked on it would be a thread running inside a library about to
be unmapped.

Every future still in flight ends at `"canceled"`, including one whose child the kernel never reaped. Leaving
those pending would be a handle that reads "still running" for the rest of the process against a runner that no
longer exists.

The application runs this at teardown.

### The worker

Nothing but the request and the answer crosses the worker boundary. The child is created, fed, polled, read,
killed and destroyed entirely on the worker; what comes back is bytes, an exit code and a pid. The process handle
itself never moves, because it is a pid that may be reaped exactly once plus a set of pipe descriptors, and two
states holding it means two states able to reap it.

The worker polls rather than blocking, which is what makes it interruptible: a kill is a message it picks up on
its next pass, one worker holds any number of children at once, and a child that writes past the pipe buffer
keeps going because something is draining it.

#### installProcessRunner

Starts the runner worker.

```teal
function installProcessRunner(luaPath?: string)
```

**Parameters:**

- `luaPath`: module path to give the worker. Defaults to this state's `package.path`.

Called for you by the first `run`. Call it directly to pay that cost up front, or to give the worker a module
path other than this state's.

#### processRunnerInstalled

Whether the runner worker is running.

```teal
function processRunnerInstalled(): boolean
```

## What the desktop offers

`tecs.system` groups small process-wide services SDL presents consistently. They are not window state. A window
is optional when a message box or file picker should be parented to one, and an `Application` is only needed to
pump asynchronous dialog results automatically.

### openURL

```teal
function system.openURL(url: string): boolean, string
```

Asks the operating system to open `url` with its preferred handler. Returns `(true, nil)` when the request was
accepted and `(false, error)` otherwise. An empty URL is refused without invoking the platform.

### preferredLocales

```teal
function system.preferredLocales(): {system.Locale}
```

Returns the user's preferred locales in priority order. Each has `language`, an ISO 639 code, and `country`, an
ISO 3166 code or `""` when the platform names only a language. The list and strings are owned Lua values.

### power

```teal
function system.power(): system.Power
```

Returns `state`, `seconds`, and `percent`. State is `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
`"charged"` or `"error"`. Either number is `-1` when the platform cannot supply it.

### messageBox

```teal
function system.messageBox(
    kind: string, title: string, message: string, window?: Window
): boolean, string
```

Shows a simple blocking native message box. `kind` is `"info"`, `"warning"` or `"error"`. Pass a window to make
the box modal to it.

### File and folder dialogs

```teal
function system.openFile(
    options?: system.DialogOptions
): Future<system.DialogResult>

function system.saveFile(
    options?: system.DialogOptions
): Future<system.DialogResult>

function system.openFolder(
    options?: system.DialogOptions
): Future<system.DialogResult>
```

These open native platform pickers and return [`Future`](/modules/Future) values. `saveFile` returns at most one
path. `openFile` and `openFolder` return one unless `multiple` is true.

```teal
local choice <const> = tecs.system.openFile({
    window = app.window,
    filters = {
        { name = "Images", pattern = "png;jpg;jpeg" },
    },
    defaultLocation = tecs.filesystem.assetRoot(),
    multiple = true,
})
```

`DialogOptions` has these fields:

| Field             | Type                    | Meaning                                                  |
| ----------------- | ----------------------- | -------------------------------------------------------- |
| `window`          | `Window`                | Optional parent window                                   |
| `filters`         | `{system.DialogFilter}` | Display names and semicolon-separated extension patterns |
| `defaultLocation` | `string`                | Initial directory or file                                |
| `multiple`        | `boolean`               | Allows several selections on open-file and open-folder   |

Every filter needs a non-empty `name` and `pattern`; invalid filters raise before a dialog opens.

A ready future carries `paths`, `filter`, and `canceled`. `filter` is one-based, or zero when no filter applies.
Closing the picker without choosing is a successful result with `canceled = true` and an empty path list;
failure means the platform could not complete the dialog.

SDL retains a callback for these pickers and may invoke it from a thread LuaJIT did not create. The Rust dialog
bridge therefore copies its answer behind a mutex, and `Application` settles the future on the main thread.

### updateDialogs

```teal
function system.updateDialogs(): integer
```

Settles completed file and folder dialogs and returns how many completed. `Application` calls this each frame. A
tool that uses dialogs without an application can call it itself or use `future:wait()`, whose source polls the
native state.
