--[=[
Runtime capabilities, clipboard access, and desktop services.

## Capabilities

Ask the installed build instead of inferring support from a target name.
`capabilities` distinguishes targets that share an operating system but differ
in JIT, worker, shader, storage, or device support. It reports the process
sandbox separately because that environment can restrict filesystem and child
process access without changing the target.

## Clipboard

The clipboard belongs to the desktop and can change between frames.
`events.clipboardUpdate` reports a change; read the current value when the
event arrives or when the user requests paste. Text stays UTF-8, keeps its line
endings, and stops at the first NUL. `clipboardData` preserves NULs.

Headless builds report the clipboard as unavailable. Primary selection remains
independent of the clipboard. On platforms without a shared primary selection,
reads may return only the value this process wrote.

## Process signals

SDL applications already receive `SIGINT` and `SIGTERM` as the public
`tecs.platform.events.on.quit` event and then run their normal shutdown
lifecycle. A headless loop can retain a [`SignalListener`](tealdoc:tecs.platform.os.SignalListener)
instead. `next` transfers native signal flags and drains one without waiting:

```teal
tecs.scoped("listen for signals", function(scope: tecs.Scope)
    local signals <const> = scope:own(tecs.platform.os.newSignalListener())

    local running = true
    while running do
        local signal <const> = signals:next()
        if signal == "interrupt" or signal == "terminate" then
            running = false
        end
    end
end)
```

The native handler only sets atomic flags. It never calls Lua, allocates, or
locks. Repeated instances of one signal may coalesce before the next listener
read, as operating-system signals ordinarily may. When different signals are
pending in one read, `next` returns them in enum order rather than claiming
an arrival order the operating system did not preserve. Closing the last
listener stops interception, so a later signal follows the platform's
termination behavior again.

## Native dialogs

File and folder dialogs return their result directly. Inside a system they
suspend the logical world update while the operating system owns the dialog;
outside an update they block while pumping the native bridge. The Rust bridge
copies the platform callback result into a queue, and Lua observes it only from
the Application or the blocking call.

]=]
-- Implementation details:
-- Clipboard reads copy SDL allocations before freeing them. Arbitrary MIME
-- writes stay out of the public surface because SDL retains a producer
-- callback and may invoke it from a thread LuaJIT did not create. Headless
-- checks avoid calling clipboard entry points before SDL video starts.

local bit <const> = require("bit")
local ffi <const> = require("ffi")
local rust <const> = require("tecs.ffi.rust")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local adapter <const> = require("tecs.platform.adapter")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local Completion <const> = require("tecs.internal.completion")
local task <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")
local buffer <const> = require("tecs.io.buffer")
local type coretypes = require("tecs.types")
local type iotypes = require("tecs.io.types")
local type Window = require("tecs.platform.window").Window
local type IOBuffer = iotypes.Buffer
local type Closeable = coretypes.Closeable

local dialogRuntimePoll: function(): integer
local function pollDialogs(): integer
    return dialogRuntimePoll()
end

local shutdownDialogs: function()
local function stopDialogs()
    shutdownDialogs()
end

loader.declare("dialogs")

local C <const> = sdl.C
local R <const> = rust.C
local K <const> = sdl.K
local D <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "dialogs")
local VIDEO <const> = sdl.K.SDL_INIT_VIDEO

local signalRuntimePoll: function(): integer
local function pollSignals(): integer
    return signalRuntimePoll()
end

local shutdownSignals: function()

--- Describes one preferred language and country.
local record Locale
    --- Read-only. Contains an ISO 639 language code, such as `"en"`.
    language: string
    --- Read-only. Contains an ISO 3166 country code, such as `"US"`, or an empty string when the
    --- platform names only a language.
    country: string
end

--- Describes the current power source and remaining battery.
local record Power
    --- Read-only. Reports `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
    --- `"charged"` or `"error"`.
    state: string
    --- Read-only. Reports seconds of battery life remaining, or -1 when
    --- unavailable.
    seconds: integer
    --- Read-only. Reports charge percentage in 0..100, or -1 when unavailable.
    percent: integer
end

--- Describes one file-type filter in a native dialog.
local record DialogFilter
    --- Caller-writable. Sets the label shown beside the filter, such as
    --- `"Images"`.
    name: string
    --- Caller-writable. Sets semicolon-separated extensions, such as
    --- `"png;jpg;jpeg"`.
    pattern: string
end

--- Configures a native file or folder dialog.
local record DialogOptions
    --- Caller-writable. Sets the window that owns the dialog.
    window: Window
    --- Caller-writable. Sets the available file-type filters.
    filters: {DialogFilter}
    --- Caller-writable. Sets the initial file or folder. Omit it to let the
    --- platform choose.
    defaultLocation: string
    --- Caller-writable. Allows the user to select more than one path.
    multiple: boolean
end

--- Contains the result of a completed native dialog.
local record DialogResult
    --- Read-only. Contains selected paths. It is empty when the user canceled.
    paths: {string}
    --- Read-only. Reports the one-based selected filter, or zero when no
    --- filter applies.
    filter: integer
    --- Read-only. Reports whether the user canceled the dialog.
    canceled: boolean
end

--- Names one process signal delivered outside a native handler.
local enum ProcessSignal
    "interrupt"
    "terminate"
    "hangup"
    "quit"
end

--- A caller-owned queue of process signals for a headless loop.
---
--- Reading the listener transfers pending native flags into its queue. The
--- listener owns no thread and invokes no callback. Close it to stop
--- interception after the last listener closes. Repeated closure remains
--- safe.
local interface SignalListener is Closeable
    --- Returns whether this listener has been closed.
    ---
    --- @param self The listener to inspect.
    --- @return Returns true after `close`.
    isClosed: function(self: SignalListener): boolean

    --- Returns the number of signals waiting to be read.
    ---
    --- Signals of the same kind may coalesce before a read. The count
    --- covers deliveries already transferred to this listener.
    --- @param self The open listener to inspect.
    --- @return Returns the queued delivery count.
    pending: function(self: SignalListener): integer

    --- Removes and returns one queued signal without waiting.
    ---
    --- The call returns nil when no selected signal has arrived since the
    --- listener was created or last drained. Signals transferred by the same
    --- runtime poll are returned in enum order, not arrival order.
    --- @param self The open listener whose queue advances.
    --- @return Returns one selected signal, or nil when none is pending.
    next: function(self: SignalListener): ProcessSignal
end

--- Describes what this build can do on the current target.
local record Capabilities
    --- Read-only. This is the platform name, such as "macOS" or "Android". A
    --- licensed port answers with its own name instead, since everything here
    --- describes the platform actually installed.
    target: string
    --- Read-only. This is the CPU architecture this build targets.
    architecture: string
    --- Read-only. Reports `"none"`, `"unknownContainer"`, `"flatpak"`,
    --- `"snap"` or `"macOS"` for the process environment SDL detects. A
    --- sandbox can restrict filesystem and child-process access independently
    --- of the target and the build's other capabilities.
    sandbox: string

    --- Read-only. This reports whether the runtime generates machine code.
    --- False on a target that requires interpretation.
    jit: boolean
    --- Read-only. This is always true because every supported build requires
    --- the FFI.
    ffi: boolean

    --- Read-only. Reports whether a library can load by name at run time. It is false where every
    --- build links every library into the executable.
    dynamicLibraries: boolean
    --- Read-only. Reports whether this build supports development-time content reload.
    --- Named independently of any one kind the watcher reloads.
    hotReload: boolean
    --- Read-only. Reports whether this build can compile shaders from source
    --- at run time.
    runtimeShaders: boolean
    --- Read-only. Reports whether the engine reads shaders from a packaged artifact. Independent of
    --- `runtimeShaders`: a development build may have both, and a release has
    --- only this.
    packagedShaders: boolean
    --- Read-only. Lists the shader formats this target consumes. It contains one entry, since a build supplies
    --- one format.
    shaderFormats: {string}

    --- Read-only. Reports whether the machine currently has a touch device. This describes the machine
    --- rather than of the target: a desktop with a touchscreen has one.
    touch: boolean
    --- Read-only. Reports true because every target reaches gamepads through the same subsystem,
    --- so only the connected devices vary, which the `gamepads`
    --- method on [`Input`](tealdoc:tecs.input.Input) answers.
    gamepad: boolean
    --- Read-only. Reports whether the device carries a gyroscope or an accelerometer. This says
    --- nothing about a gamepad's sensors, which `hasSensor` on
    --- [`Gamepad`](tealdoc:tecs.input.Gamepad) answers per device.
    sensors: boolean
    --- Read-only. Reports whether work can run off the main thread.
    workers: boolean
    --- Read-only. Reports the number of logical cores for sizing a worker pool.
    cores: integer

    --- Read-only. Reports true because every target has somewhere to write,
    --- and `tecs.io.files.preferencePath` and `tecs.io.files.cachePath` answer
    --- where: the field exists so a caller can ask rather than assume, not
    --- because a target answers no.
    writableStorage: boolean
end

local record platformOS
    --- Describes what this build can do on this target.
    type Capabilities = Capabilities

    --- Describes one language the user prefers.
    type Locale = Locale

    --- Describes the machine's power source and remaining charge.
    type Power = Power

    --- Describes one file-type filter.
    type DialogFilter = DialogFilter

    --- Describes dialog configuration.
    type DialogOptions = DialogOptions

    --- Describes a completed dialog.
    type DialogResult = DialogResult

    --- `ProcessSignal` identifies an interrupt, termination, hangup, or quit
    --- request sent to this process.
    type ProcessSignal = ProcessSignal

    --- A `SignalListener` receives process signals in a headless loop.
    type SignalListener = SignalListener
end

local countOut <const> = loader.newArray("int[1]")
local secondsOut <const> = loader.newArray("int[1]")
local percentOut <const> = loader.newArray("int[1]")

local POWER_STATES <const>: {integer: string} = {
    [tonumber(C.SDL_POWERSTATE_ERROR) as integer] = "error",
    [tonumber(C.SDL_POWERSTATE_UNKNOWN) as integer] = "unknown",
    [tonumber(C.SDL_POWERSTATE_ON_BATTERY) as integer] = "onBattery",
    [tonumber(C.SDL_POWERSTATE_NO_BATTERY) as integer] = "noBattery",
    [tonumber(C.SDL_POWERSTATE_CHARGING) as integer] = "charging",
    [tonumber(C.SDL_POWERSTATE_CHARGED) as integer] = "charged",
}

local SANDBOXES <const>: {integer: string} = {
    [tonumber(C.SDL_SANDBOX_NONE) as integer] = "none",
    [tonumber(C.SDL_SANDBOX_UNKNOWN_CONTAINER) as integer] = "unknownContainer",
    [tonumber(C.SDL_SANDBOX_FLATPAK) as integer] = "flatpak",
    [tonumber(C.SDL_SANDBOX_SNAP) as integer] = "snap",
    [tonumber(C.SDL_SANDBOX_MACOS) as integer] = "macOS",
}

local MESSAGE_FLAGS <const>: {string: integer} = {
    error = K.SDL_MESSAGEBOX_ERROR,
    warning = K.SDL_MESSAGEBOX_WARNING,
    info = K.SDL_MESSAGEBOX_INFORMATION,
}

--- Opens an absolute URI with the operating system's preferred application.
---
--- This is not limited to web URLs. The operating system may route `https:`
--- to a browser, `mailto:` to a mail client, and application-specific schemes
--- such as `steam:` to their registered handler. Tecs passes the string to SDL
--- without parsing it, so the platform decides which schemes it accepts and
--- which application handles them.
---
--- @param url The caller supplies a non-empty absolute URI. Embedded NUL bytes
---     are not supported by SDL's C-string boundary.
--- @return Returns true after the operating system accepts the launch request.
--- @return Returns SDL's reason when the URI is empty, unsupported, malformed,
---     or cannot be opened.
function platformOS.openURL(url: string): boolean, string
    if url == nil or url == "" then
        return false, "a URL is required"
    end
    if not C.SDL_OpenURL(url) then
        return false, sdl.error()
    end
    return true, nil
end

--- Returns the user's preferred locales in priority order.
function platformOS.preferredLocales(): {Locale}
    local out: {Locale} = {}
    local locales = C.SDL_GetPreferredLocales(countOut)
    if locales == nil then
        return out
    end
    local list = locales as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local locale = list[index] as loader.CStruct
        if locale ~= nil then
            out[#out + 1] = {
                language = loader.toString(locale.language as loader.CValue),
                country = loader.toString(locale.country as loader.CValue),
            }
        end
    end
    C.SDL_free(locales)
    return out
end

--- Returns the current battery or external-power state.
function platformOS.power(): Power
    secondsOut[0], percentOut[0] = -1, -1
    local state = tonumber(C.SDL_GetPowerInfo(secondsOut, percentOut)) as integer
    return {
        state = POWER_STATES[state] or "unknown",
        seconds = secondsOut[0] as integer,
        percent = percentOut[0] as integer,
    }
end

-------------------------------------------------------------------------------
-- Process signals
-------------------------------------------------------------------------------

local SIGNALS <const>: {ProcessSignal} = {"interrupt", "terminate", "hangup", "quit"}
local SIGNAL_INDEX <const>: {string: integer} = {
    interrupt = 1,
    terminate = 2,
    hangup = 3,
    quit = 4,
}
local SIGNAL_BITS <const>: {integer} = {1, 2, 4, 8}

local record SignalListenerImpl is SignalListener
    _closed: boolean
    _selected: {boolean}
    _pending: {integer}
end

local listeners <const>: {SignalListenerImpl: boolean} = {}
local listenerCount = 0
local updateSignals: function(): integer

function SignalListenerImpl:isClosed(): boolean
    return self._closed
end

local function openListener(self: SignalListenerImpl, method: string)
    if self._closed then
        error("tecs: SignalListener:" .. method .. " called after close", 3)
    end
end

function SignalListenerImpl:pending(): integer
    openListener(self, "pending")
    updateSignals()
    local count = 0
    for index = 1, #SIGNALS do
        count = count + self._pending[index]
    end
    return count
end

function SignalListenerImpl:next(): ProcessSignal
    openListener(self, "next")
    updateSignals()
    for index = 1, #SIGNALS do
        if self._pending[index] > 0 then
            self._pending[index] = self._pending[index] - 1
            return SIGNALS[index]
        end
    end
    return nil
end

function SignalListenerImpl:close(): boolean, string
    if self._closed then
        return true
    end
    self._closed = true
    listeners[self] = nil
    listenerCount = listenerCount - 1
    if listenerCount == 0 then
        runtime.unregister("signals")
        R.tecsSignalsUninstall()
    end
    return true
end

shutdownSignals = function()
    local active: {SignalListenerImpl} = {}
    for listener in pairs(listeners) do
        active[#active + 1] = listener
    end
    for index = 1, #active do
        active[index]:close()
    end
end

updateSignals = function(): integer
    local mask <const> = tonumber(R.tecsSignalsPoll()) as integer
    if mask == 0 then
        return 0
    end
    local delivered = 0
    for listener in pairs(listeners) do
        for index = 1, #SIGNALS do
            if listener._selected[index] and bit.band(mask, SIGNAL_BITS[index]) ~= 0 then
                listener._pending[index] = listener._pending[index] + 1
                delivered = delivered + 1
            end
        end
    end
    return delivered
end

signalRuntimePoll = updateSignals

--- Creates a listener for process signals in a headless loop.
---
--- The listener receives `"interrupt"` for `SIGINT`, `"terminate"` for
--- `SIGTERM`, `"hangup"` for `SIGHUP`, and `"quit"` for `SIGQUIT` on POSIX.
--- Windows maps Ctrl-C and Ctrl-Break to `"interrupt"`, and console close,
--- logoff, and shutdown to `"terminate"`. Unsupported signals simply never
--- arrive on that platform.
---
--- SDL applications normally observe `tecs.platform.events.on.quit` instead.
--- SDL converts SIGINT and SIGTERM to that event and the application performs
--- its normal shutdown lifecycle before the process-wide runtime pump.
---
--- @param selected The caller supplies the signal names to retain, or omits
---     the list to retain every supported name. An empty list and duplicate or
---     unknown names raise as programmer errors.
--- @return Returns a caller-owned listener.
--- @return Returns the platform reason when native signal handling cannot be
---     installed.
function platformOS.newSignalListener(selected?: {ProcessSignal}): SignalListener, string
    local retained <const>: {boolean} = {}
    if selected == nil then
        for index = 1, #SIGNALS do
            retained[index] = true
        end
    else
        if #selected == 0 then
            error("tecs: platform.os.newSignalListener needs at least one signal", 2)
        end
        for index = 1, #selected do
            local name <const> = selected[index]
            local signalIndex <const> = SIGNAL_INDEX[name]
            if signalIndex == nil then
                error(("tecs: unknown process signal %q"):format(tostring(name)), 2)
            end
            if retained[signalIndex] then
                error(("tecs: duplicate process signal %q"):format(name), 2)
            end
            retained[signalIndex] = true
        end
    end

    if listenerCount == 0 and not R.tecsSignalsInstall() then
        return nil, loader.toString(R.tecsRustError())
    end

    local pending: {integer} = {}
    for index = 1, #SIGNALS do
        pending[index] = 0
    end
    local listener <const> = setmetatable(
        {
            _closed = false,
            _selected = retained,
            _pending = pending,
        } as SignalListenerImpl,
        {__index = SignalListenerImpl}
    )
    listeners[listener] = true
    listenerCount = listenerCount + 1
    if listenerCount == 1 then
        runtime.register("signals", 5, pollSignals, shutdownSignals)
    end
    return listener as SignalListener
end

--- Shows a native informational, warning or error dialog.
function platformOS.messageBox(kind: string, title: string, message: string, window?: Window): boolean, string
    local flags = MESSAGE_FLAGS[kind]
    if flags == nil then
        return false, ("unknown message-box kind %q"):format(tostring(kind))
    end
    local handle = window ~= nil and window.handle or nil
    if not C.SDL_ShowSimpleMessageBox(flags, title or "", message or "", handle) then
        return false, sdl.error()
    end
    return true, nil
end

-------------------------------------------------------------------------------
-- Cooperative file and folder dialogs
-------------------------------------------------------------------------------

--- SDL retains the file-dialog callback and may enter it from a thread LuaJIT
--- did not create. The Rust dialog bridge owns that callback and copies its
--- answer; this source polls the copied result and settles private completion
--- state on the main thread.

local record DialogEntry
    handle: loader.CPtr
    completion: Completion<DialogResult>
end

local record DialogSource
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: DialogSource): integer
    advance: function(self: DialogSource, ms: number): integer
    cancel: function(self: DialogSource, completion: Completion<any>)
end

local DialogSourceMT <const>: metatable<DialogSource> = {__index = DialogSource}
local pendingDialogs: {DialogEntry} = {}

local function finishDialog(entry: DialogEntry)
    local handle = entry.handle
    local errorPointer = D.tecsDialogError(handle)
    if errorPointer ~= nil then
        entry.completion:fail(loader.toString(errorPointer))
    else
        local paths: {string} = {}
        local count = tonumber(D.tecsDialogPathCount(handle)) as integer
        for index = 0, count - 1 do
            paths[index + 1] = loader.toString(D.tecsDialogPath(handle, index))
        end
        local selected = tonumber(D.tecsDialogFilter(handle)) as integer
        entry.completion:complete({
            paths = paths,
            filter = selected >= 0 and selected + 1 or 0,
            canceled = D.tecsDialogCancelled(handle) as boolean,
        })
    end
    D.tecsDialogDestroy(handle)
end

function DialogSource:poll(): integer
    local settled = 0
    for index = #pendingDialogs, 1, -1 do
        local entry = pendingDialogs[index]
        if D.tecsDialogReady(entry.handle) then
            finishDialog(entry)
            table.remove(pendingDialogs, index)
            settled = settled + 1
        end
    end
    if #pendingDialogs == 0 then
        runtime.unregister("dialogs")
    end
    return settled
end

function DialogSource:advance(ms: number): integer
    local settled = self:poll()
    if settled > 0 or ms <= 0 then
        return settled
    end
    C.SDL_Delay(math.floor(ms))
    return self:poll()
end

function DialogSource:cancel(completion: Completion<any>)
    for index = #pendingDialogs, 1, -1 do
        local entry <const> = pendingDialogs[index]
        if entry.completion as Completion<any> == completion then
            table.remove(pendingDialogs, index)
            D.tecsDialogAbandon(entry.handle)
            if #pendingDialogs == 0 then
                runtime.unregister("dialogs")
            end
            return
        end
    end
end

shutdownDialogs = function()
    while #pendingDialogs > 0 do
        local entry <const> = pendingDialogs[#pendingDialogs]
        pendingDialogs[#pendingDialogs] = nil
        D.tecsDialogAbandon(entry.handle)
        entry.completion:abandon("application shutdown")
    end
    runtime.unregister("dialogs")
end

local dialogSource <const> = setmetatable(
    {
        sliceMs = 16,
        defaultWaitMs = 300000,
    } as DialogSource,
    DialogSourceMT
)

local function filterArrays(options: DialogOptions): loader.CArray, loader.CArray, integer
    local filters = options.filters
    if filters == nil or #filters == 0 then
        return nil, nil, 0
    end
    local names = loader.newArray("const char *[?]", #filters)
    local patterns = loader.newArray("const char *[?]", #filters)
    for index = 1, #filters do
        local filter = filters[index]
        if filter.name == nil or filter.name == "" then
            error(("tecs: dialog filter %d needs a name"):format(index), 3)
        end
        if filter.pattern == nil or filter.pattern == "" then
            error(("tecs: dialog filter %d needs a pattern"):format(index), 3)
        end
        names[index - 1] = filter.name
        patterns[index - 1] = filter.pattern
    end
    return names, patterns, #filters
end

local function trackDialog(handle: loader.CPtr): Completion<DialogResult>
    if handle == nil then
        return Completion.failed("cannot allocate file-dialog state") as Completion<DialogResult>
    end
    local completion = Completion.pending(dialogSource as Completion.Source) as Completion<DialogResult>
    pendingDialogs[#pendingDialogs + 1] = {handle = handle, completion = completion}
    if #pendingDialogs == 1 then
        runtime.register("dialogs", 30, pollDialogs, stopDialogs)
    end
    -- A setup allocation can fail before SDL opens anything.
    dialogSource:poll()
    return completion
end

local function awaitDialog(pending: Completion<DialogResult>): DialogResult
    return task.awaitCompletion(pending, "native dialog")
end

--- Opens a native file picker and returns its selection.
---
--- Inside a system, the call suspends until the dialog closes. Outside a world
--- update, it blocks while pumping the native bridge.
--- @param options The caller supplies the owner window, filters, starting
---     location, and multiple-selection flag, or omits every option.
--- @return Returns selected paths and filter state. Cancellation returns a
---     result with `canceled` true rather than failing.
function platformOS.openFile(options?: DialogOptions): DialogResult
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    task.checkWait("native dialog")
    return awaitDialog(
        trackDialog(D.tecsDialogOpenFile(window, names, patterns, count, given.defaultLocation, given.multiple == true))
    )
end

--- Opens a native save-file picker and returns at most one path.
---
--- Inside a system, the call suspends until the dialog closes. Outside a world
--- update, it blocks while pumping the native bridge.
--- @param options The caller supplies the owner window, filters, and starting
---     location, or omits every option. The `multiple` field is ignored.
--- @return Returns the selected path and filter state. Cancellation returns a
---     result with `canceled` true rather than failing.
function platformOS.saveFile(options?: DialogOptions): DialogResult
    local given = options or {} as DialogOptions
    local names, patterns, count = filterArrays(given)
    local window = given.window ~= nil and given.window.handle or nil
    task.checkWait("native dialog")
    return awaitDialog(trackDialog(D.tecsDialogSaveFile(window, names, patterns, count, given.defaultLocation)))
end

--- Opens a native folder picker and returns its selection.
---
--- Inside a system, the call suspends until the dialog closes. Outside a world
--- update, it blocks while pumping the native bridge.
--- @param options The caller supplies the owner window, starting location, and
---     multiple-selection flag, or omits every option. Filters are ignored.
--- @return Returns selected folders. Cancellation returns a result with
---     `canceled` true rather than failing.
function platformOS.openFolder(options?: DialogOptions): DialogResult
    local given = options or {} as DialogOptions
    local window = given.window ~= nil and given.window.handle or nil
    task.checkWait("native dialog")
    return awaitDialog(trackDialog(D.tecsDialogOpenFolder(window, given.defaultLocation, given.multiple == true)))
end

--- Settles file and folder dialogs that have answered.
local function updateDialogs(): integer
    return dialogSource:poll()
end

dialogRuntimePoll = updateDialogs

local resolved: Capabilities = nil
local cachedGeneration = -1

--- Whether the platform reports a touch device.
---
--- Asked rather than inferred from the platform: a desktop with a touchscreen
--- has one and a simulator may not, so neither answer follows from the OS.
local function hasTouch(): boolean
    local count = loader.newArray("int[1]")
    local devices = C.SDL_GetTouchDevices(count)
    if devices == nil then
        return false
    end
    C.SDL_free(devices)
    return tonumber(count[0]) > 0
end

-- Query the optional `jit` module dynamically so a stripped build reports
-- interpretation instead of failing to load.
local function jitEnabled(): boolean
    local ok, module = pcall(require, "jit")
    if not ok then
        return false
    end
    local status = (module as {string: any}).status
    if status == nil then
        return false
    end
    local running = (status as function(): boolean)()
    return running == true
end

--- Forgets the cached answer. Capability lookup notices a platform change without this.
function platformOS.resetCapabilities()
    resolved = nil
end

--- Reads the capabilities of the running build.
---
--- The function caches its answer because these values do not change while a
--- platform remains installed. The platform generation keys the cache, so
--- installing a platform drops the value without
--- anybody calling `resetCapabilities`.
--- @return The same table on every call until the platform changes. Shared,
---     so a caller that means to keep it does not also mean to edit it.
function platformOS.capabilities(): Capabilities
    local generation = adapter.generation()
    if generation ~= cachedGeneration then
        cachedGeneration = generation
        resolved = nil
    end
    if resolved ~= nil then
        return resolved
    end

    -- The platform in use, which is not always SDL: a licensed port installs
    -- its own and everything here has to describe that one.
    local platform = loader.toString(C.SDL_GetPlatform())
    local installed = adapter.current()
    if installed.name ~= "sdl" then
        platform = installed.name
    end

    -- The shader pipeline is asked rather than guessed at: whether a compiler
    -- was linked is a property of the build, and a loaded pack narrows the
    -- format to the one it holds.
    local pack = shadercompiler.pack()
    local formats: {string} = {shaderpack.formatName(shadercompiler.format())}

    local runtimeShaders <const> = shadercompiler.isSupported()
    local sandbox <const> = SANDBOXES[tonumber(C.SDL_GetSandbox()) as integer] or "unknownContainer"
    resolved = {
        target = platform,
        architecture = ffi.arch,
        sandbox = sandbox,
        -- Whether machine code is being generated. On a target that forbids
        -- writable executable memory it is not, and the interpreter runs.
        jit = jitEnabled(),
        ffi = true,
        -- A registry means the libraries were linked, which is the case
        -- precisely where loading one by name is not available.
        dynamicLibraries = installed.dynamicLibraries,
        -- Runtime shaders and hot reload are selected by the same development
        -- preset today. They remain separate capabilities so neither consumer
        -- has to infer itself from the other.
        hotReload = runtimeShaders,
        runtimeShaders = runtimeShaders,
        packagedShaders = pack ~= nil,
        shaderFormats = formats,
        touch = hasTouch(),
        gamepad = true,
        sensors = platform == "iOS" or platform == "Android",
        workers = pcall(require, "tecs.workers"),
        cores = tonumber(C.SDL_GetNumLogicalCPUCores()) as integer,
        writableStorage = true,
    }
    return resolved
end

-- One scratch cell for the size and count out-parameters. `mimeTypes` and
-- `data` are the only readers that take one, and neither calls the other, so
-- there is nothing here for a second use to overlap with.
local sizeOut <const> = loader.newArray("size_t[1]")

-- Copies and frees a platform string. The nil guard avoids turning an
-- unexpected null into a dereference.
local function take(pointer: loader.CValue): string
    if pointer == nil then
        return ""
    end
    local text = loader.toString(pointer)
    C.SDL_free(pointer)
    return text
end

--- Raises when a required string argument is missing.
---
--- SDL reads a null `const char *` as an empty string, so a nil slipping into
--- `setClipboardText` would clear the clipboard rather than fail, which is the one
--- outcome nobody meant.
local function required(value: string, what: string)
    if value == nil then
        error(("tecs: os.%s needs a string"):format(what), 3)
    end
end

--- Reports whether a clipboard is available.
---
--- False in a process that never brought up video, where every other function
--- here answers empty or false. Distinguishes that from a clipboard that is
--- simply empty, which no other return value can.
function platformOS.clipboardAvailable(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- Returns the clipboard text, or an empty string when it holds none.
---
--- Empty is also the answer when the clipboard holds something that is not
--- text, and when there is no video. Ask `hasClipboardText` to tell those from text
--- that is genuinely empty.
function platformOS.clipboardText(): string
    if not platformOS.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetClipboardText())
end

--- Puts `text` on the clipboard, replacing whatever was there.
---
--- The platform copies the string before this call returns. Returns false
--- when the platform refused, which includes having no video.
function platformOS.setClipboardText(text: string): boolean
    required(text, "setClipboardText")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_SetClipboardText(text) as boolean
end

--- Reports whether the clipboard holds text.
---
--- Cheaper than reading it: no allocation crosses the boundary, and on a
--- platform where a read negotiates with the owning application, no
--- negotiation happens.
function platformOS.hasClipboardText(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardText() as boolean
end

--- Withdraws what this application put on the system.
---
--- The clipboard is left empty rather than restored to what preceded the
--- write, because nothing anywhere remembers what that was.
function platformOS.clearClipboard(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_ClearClipboardData() as boolean
end

--- Returns the clipboard MIME types in platform order.
---
--- The same list `clipboardUpdate` carries, for a caller that wants to ask
--- rather than wait to be told. Empty when the clipboard is empty.
function platformOS.clipboardMimeTypes(): {string}
    local found: {string} = {}
    if not platformOS.clipboardAvailable() then
        return found
    end

    local list = C.SDL_GetClipboardMimeTypes(sizeOut)
    if list == nil then
        return found
    end
    local items = loader.castPointer("char **", list)
    local count = tonumber(sizeOut[0]) as integer
    for index = 0, count - 1 do
        found[index + 1] = loader.toString(items[index] as loader.CValue)
    end
    -- One allocation holds the array and the strings it points at, so one
    -- free releases all of it and freeing an entry would be a double free.
    C.SDL_free(list)
    return found
end

--- Reports whether the clipboard offers `mimeType`.
function platformOS.hasClipboardData(mimeType: string): boolean
    required(mimeType, "hasClipboardData")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasClipboardData(mimeType) as boolean
end

--- Returns the clipboard bytes for `mimeType`, or nil when it offers none.
---
--- The caller releases the returned
--- [`Buffer`](/modules/io/#tecs.io.Buffer).
--- Returns nil rather than an empty buffer because the clipboard can offer a
--- MIME type with no bytes, which differs from not offering that type.
function platformOS.clipboardData(mimeType: string): IOBuffer
    required(mimeType, "clipboardData")
    if not platformOS.clipboardAvailable() then
        return nil
    end

    local bytes = C.SDL_GetClipboardData(mimeType, sizeOut)
    if bytes == nil then
        return nil
    end
    local length <const> = tonumber(sizeOut[0]) as integer
    local blob <const> = buffer.new(length)
    if length > 0 then
        ffi.copy(blob:getFFIPointer() as ffi.CData, bytes as ffi.CData, length)
    end
    C.SDL_free(bytes)
    return blob
end

--- Returns text from the platform's primary selection.
---
--- On X11 and Wayland, selecting text places it in a clipboard separate from
--- the ordinary copy-and-paste clipboard, commonly pasted with the middle
--- mouse button. Platforms without that concept expose only the value this
--- process last supplied through `setPrimarySelection`; other applications do
--- not see it. This function does not read `clipboardText`.
---
--- @return Returns UTF-8 text, or an empty string when the selection is empty
---     or no video subsystem is available.
function platformOS.primarySelection(): string
    if not platformOS.clipboardAvailable() then
        return ""
    end
    return take(C.SDL_GetPrimarySelectionText())
end

--- Puts `text` in the primary selection.
---
--- Succeeds on a platform that has no shared primary selection, where the
--- value remains visible only to this process.
function platformOS.setPrimarySelection(text: string): boolean
    required(text, "setPrimarySelection")
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_SetPrimarySelectionText(text) as boolean
end

--- Reports whether the primary selection holds text.
function platformOS.hasPrimarySelection(): boolean
    if not platformOS.clipboardAvailable() then
        return false
    end
    return C.SDL_HasPrimarySelectionText() as boolean
end

return platformOS
