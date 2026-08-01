--[=[
Resolves game paths and performs complete filesystem operations.

Use `assetPath` for shipped content, `writablePath` for persistent mutable
state, and `cachePath` for data the application can reconstruct.
Set the publisher and game names before resolving the first writable path:

```teal
local files <const> = tecs.io.files
files.setPreferenceIdentity("Ex Nihilo", "Starfarer")

local directory <const> = files.writablePath("saves")
local ok, reason = files.createDirectory(directory)
if not ok then
    error(reason)
end

local path <const> =
    files.writablePath("saves/slot1.json")
local bytes <const> = tecs.data.encodeJSON({ level = 3, hp = 100 })
ok, reason = files.writeAtomic(path, bytes)
if not ok then
    error(reason)
end
```

Filesystem outcomes return a status and a platform reason. Invalid arguments
raise because they indicate a defect in the calling program. Operations are
synchronous except `writeAtomicAsync`, whose worker-backed future is advanced
by `tecs.runtime.poll`. `glob` exposes a caller-owned pull stream so recursive
enumeration does not retain a complete tree. Temporary files,
temporary directories, and streams are [`Closeable`](tealdoc:tecs.Closeable)
and fit directly in `tecs.scoped`.

Every operation that accepts a filesystem location accepts either a string or
an immutable [`Path`](tealdoc:tecs.io.Path). String results remain useful
at Lua and platform boundaries; wrap one with `tecs.io.Path.new` when the next
operation benefits from component-aware manipulation.

`tecs.io.watcher` polls paths recorded by `read` and the built-in asset
loaders. It does not walk the whole asset tree.

`open` uses the standard Lua modes and returns one seekable file cursor. The
SDL backend operates on the file directly. A storage backend without random
access falls back to its required whole-file operations and retains the bytes
until the file closes.
]=]

local ffi <const> = require("ffi")
local adapter <const> = require("tecs.platform.adapter")
local buffer <const> = require("tecs.io.buffer")
local loader <const> = require("tecs.ffi.loader")
local storagebackend <const> = require("tecs.platform.storagebackend")
local content <const> = require("tecs.platform.content")
local workers <const> = require("tecs.workers")
local Future <const> = require("tecs.Future")
local runtime <const> = require("tecs.internal.runtime")
local type types = require("tecs.io.types")
local type Closeable = require("tecs.types").Closeable
local type Path = require("tecs.io.Path")

--- A caller-owned, seekable file cursor.
---
--- The mode passed to `open` controls which inherited read and write
--- operations succeed. Files implement [`Closeable`](tealdoc:tecs.Closeable),
--- [`SeekableReader`](tealdoc:tecs.io.SeekableReader), and
--- [`SeekableWriter`](tealdoc:tecs.io.SeekableWriter).
local interface File is storagebackend.File
end

--- One entry yielded by a [`DirectoryStream`](tealdoc:tecs.io.files.DirectoryStream).
local record DirectoryEntry
    --- Read-only. Contains the complete immutable path to this entry.
    path: Path
    --- Read-only. Contains the entry name relative to its immediate parent.
    name: string
    --- Read-only. Identifies the resolved object's kind.
    kind: storagebackend.PathType
    --- Read-only. Reports one for an immediate child and increases during a recursive glob.
    depth: integer
    --- Read-only. Reports whether the final path itself is a symbolic link.
    symlink: boolean
end

--- Controls pattern matching and traversal depth in a streamed glob.
local record FileGlobOptions
    --- Caller-writable. Matches ASCII letters without regard to case when
    --- true. Defaults to false, which compares every UTF-8 codepoint exactly
    --- on every platform including the ones whose filesystem is not.
    caseInsensitive: boolean
    --- Caller-writable. Limits traversal to this many levels below the root.
    --- Zero yields no entries, one yields immediate children, and nil permits
    --- unlimited traversal. Defaults to nil.
    maxDepth: integer
end

--- Pulls matching directory entries without retaining the complete tree.
local record DirectoryStream is Closeable
    --- Returns the next entry.
    ---
    --- @param self The open stream to advance.
    --- @return Returns the next entry, or nil at the end or after close.
    --- @return Returns a platform reason when traversal fails. Nil means end of stream.
    next: function(self: DirectoryStream): DirectoryEntry, string
    --- Prevents descent into the directory returned by the preceding `next` call.
    ---
    --- The method returns false when the preceding entry was not a directory,
    --- was a symbolic link, had no deeper pattern component, or has already
    --- been skipped. Calling `next` first makes an earlier directory no longer
    --- eligible for pruning.
    ---
    --- @param self The open stream whose pending descent the caller controls.
    --- @return Returns whether a pending directory descent was removed.
    skipDirectory: function(self: DirectoryStream): boolean
    --- Consumes the remaining entries into an array and closes the stream.
    ---
    --- Entries returned by earlier `next` calls are not repeated. A traversal
    --- failure discards the partial array and closes the stream.
    ---
    --- @param self The open stream to consume.
    --- @return Returns every remaining entry, or nil when traversal fails.
    --- @return Returns the platform reason when the first return is nil.
    toArray: function(self: DirectoryStream): {DirectoryEntry}, string
end

--- Controls creation of a temporary file or directory.
local record TemporaryOptions
    --- Caller-writable. Selects the parent directory. Nil uses the operating
    --- system's temporary directory.
    directory: string | Path
    --- Caller-writable. Prefixes the generated name. Defaults to `"tecs-"`.
    prefix: string
    --- Caller-writable. Suffixes the generated name. Defaults to an empty string.
    suffix: string
end

--- Identifies the target kind required when creating a symbolic link.
local enum SymlinkKind
    "file"
    "directory"
end

--- Owns a temporary file or directory until close or persistence.
local record TemporaryPath is Closeable
    --- Read-only. Contains the exclusively created path.
    path: Path
    --- Moves the resource to a permanent, absent destination and relinquishes cleanup.
    ---
    --- @param self The open temporary resource.
    --- @param destination The caller supplies a destination which must not exist.
    --- @return Returns whether the resource became permanent.
    --- @return Returns the platform reason when the first return is false.
    persist: function(self: TemporaryPath, destination: string | Path): boolean, string
end

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local DEFAULT_READ_BYTES <const> = 16 * 1024
local G <const> = _G as {string: any}
local loadstring <const> = G["loadstring"] as function(string, string): function(...: any): any..., string
local setfenv <const> = G["setfenv"] as function(any, {string: any})

local record files
    --- `PathType` identifies a file, directory or other
    --- platform object after following symbolic links.
    type PathType = storagebackend.PathType

    --- `Info` describes one resolved path.
    type Info = storagebackend.Info

    --- `UserFolder` identifies a well-known platform
    --- folder.
    type UserFolder = storagebackend.UserFolder

    --- `GlobOptions` controls pattern matching and traversal depth.
    type GlobOptions = FileGlobOptions

    --- `PathInput` accepts either a platform path string or an immutable path object.
    type PathInput = string | Path

    --- `FileMode` selects standard read, write, append, or update behavior.
    type FileMode = storagebackend.FileMode

    --- `File` is the seekable cursor returned by `open`.
    type File = File

    --- `LineIterator` yields each line in a file and returns nil at the end.
    type LineIterator = function(): string

    --- `DirectoryEntry` describes one streamed child.
    type DirectoryEntry = DirectoryEntry

    --- `DirectoryStream` is a caller-owned pull cursor over directory entries.
    type DirectoryStream = DirectoryStream

    --- `TemporaryOptions` selects generated-name details.
    type TemporaryOptions = TemporaryOptions

    --- `TemporaryPath` owns an automatically removed file or directory.
    type TemporaryPath = TemporaryPath

    --- `SymlinkKind` selects a file or directory symbolic link.
    type SymlinkKind = SymlinkKind
end

local type Info = files.Info
local type UserFolder = files.UserFolder
local type GlobOptions = files.GlobOptions
local type PathInput = files.PathInput
local type FileMode = files.FileMode
local type ByteInput = storagebackend.ByteInput
local type LineIterator = files.LineIterator
local type Writer = types.Writer
local type Reader = types.Reader
local type SeekOrigin = types.Seekable.Origin
local type IOBuffer = types.Buffer
local type ByteView = types.ByteView

local ATOMIC_WRITER <const> = [[
local tecs = require("tecs")
local self = tecs.workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    local ok, reason = tecs.io.files.writeAtomic(task.path, task.bytes)
    self:send({id = task.id, ok = ok, reason = reason})
end
]]

local record AtomicEntry
    future: Future<boolean>
end

local record AtomicSource
    sliceMs: number
    defaultWaitMs: number
end

local ATOMIC_SOURCE_MT <const>: metatable<AtomicSource> = {__index = AtomicSource}
local atomicEntries: {integer: AtomicEntry} = {}
local atomicWorker: workers.Worker = nil
local atomicPending = 0
local nextAtomicId = 1

local record DirectoryFrame
    path: Path
    depth: integer
    names: {string}
    at: integer
end

local record DirectoryStreamState
    frames: {DirectoryFrame}
    pattern: {string}
    caseInsensitive: boolean
    maxDepth: integer
    pendingDirectory: DirectoryFrame
    closed: boolean
end

local DIRECTORY_STREAM_MT <const>: metatable<DirectoryStream> = {__index = DirectoryStream}
local directoryStates <const>: {DirectoryStream: DirectoryStreamState} = setmetatable(
    {}, {__mode = "k"} as metatable<{DirectoryStream: DirectoryStreamState}>
)
local TEMPORARY_PATH_MT <const>: metatable<TemporaryPath> = {__index = TemporaryPath}
local temporaryBackings <const>: {TemporaryPath: storagebackend.TemporaryPath} = setmetatable(
    {}, {__mode = "k"} as metatable<{TemporaryPath: storagebackend.TemporaryPath}>
)

--- Raises when a required string argument is missing.
---
--- LuaJIT passes a Lua nil to a `const char *` parameter as a null pointer, so
--- a nil that reached SDL would be a call against an empty or invalid path
--- rather than an error anyone could trace back here. A path is the one thing
--- every function below needs, and a missing one is a defect in the caller.
--- Checked once, here, so a port's backend inherits it rather than repeating
--- it in ten functions.
local function required(value: PathInput, what: string): string
    if type(value) == "string" then
        return value as string
    end
    if type(value) ~= "table" or type((value as {string: any}).toString) ~= "function" then
        error(("tecs: io.files.%s needs a path"):format(what), 3)
    end
    local rendered <const> = (value as Path):toString()
    if type(rendered) ~= "string" then
        error(("tecs: io.files.%s received an invalid io.Path"):format(what), 3)
    end
    return rendered
end

local function stopAtomicWorker()
    if atomicWorker == nil or atomicPending ~= 0 then
        return
    end
    runtime.unregister("file-writes")
    local held <const> = atomicWorker
    atomicWorker = nil
    held:stop()
end

local function settleAtomic(result: {string: any}): boolean
    local id <const> = result.id as integer
    local entry <const> = atomicEntries[id]
    if entry == nil then
        return false
    end
    atomicEntries[id] = nil
    atomicPending = atomicPending - 1
    if result.ok then
        entry.future:complete(true)
    else
        entry.future:fail(tostring(result.reason or "atomic write failed"))
    end
    stopAtomicWorker()
    return true
end

function AtomicSource:poll(): integer
    local settled = 0
    while atomicWorker ~= nil do
        local result <const> = atomicWorker:receive()
        if result == nil then
            break
        end
        if settleAtomic(result as {string: any}) then
            settled = settled + 1
        end
    end
    return settled
end

function AtomicSource:advance(ms: number): integer
    if atomicWorker == nil then
        return 0
    end
    local result <const> = atomicWorker:receive(ms)
    if result == nil then
        return 0
    end
    return settleAtomic(result as {string: any}) and 1 or 0
end

function AtomicSource:cancel(_future: Future<any>)
    -- An operating-system write cannot be interrupted safely. Its result is
    -- still drained so the worker and copied task bytes can be released.
end

local atomicSource <const> = setmetatable({sliceMs = 16, defaultWaitMs = 5000} as AtomicSource, ATOMIC_SOURCE_MT)

local function ensureAtomicWorker(): boolean, string
    if atomicWorker ~= nil then
        return true
    end
    local ok <const>, made = pcall(function(): workers.Worker
        return workers.spawn({source = ATOMIC_WRITER, luaPath = package.path})
    end) as (boolean, workers.Worker)
    if not ok then
        return false, tostring(made)
    end
    atomicWorker = made
    runtime.register("file-writes", 40, function(): integer return atomicSource:poll() end)
    return true
end

local preferenceOrganization = "tecs"
local preferenceApplication = "tecs"

--- Returns the directory that contains the executable.
---
--- @return Returns the directory with a trailing separator. It returns an empty
---     string rather than nil when the platform declines to
---     say, which is the case on some targets and is not an error: a caller
---     falls back to a relative path.
function files.basePath(): string
    return content.basePath()
end

--- Sets the publisher and game names used for writable user data.
---
--- SDL combines these values with the current user and platform conventions
--- to choose the directory returned by `preferencePath`. The defaults are
--- `"tecs"` and `"tecs"`. Later calls change which directory the next
--- `preferencePath`, `writablePath`, or `cachePath` resolves.
---
--- @param organization The caller supplies a non-empty publisher, studio, or
---     organization name.
--- @param application The caller supplies a non-empty game or application
---     name.
function files.setPreferenceIdentity(organization: string, application: string)
    if type(organization) ~= "string" or organization == "" then
        error("tecs: a preference organization is required", 2)
    end
    if type(application) ~= "string" or application == "" then
        error("tecs: a preference application is required", 2)
    end
    preferenceOrganization = organization
    preferenceApplication = application
end

--- Returns the publisher and game names used for writable user data.
---
--- The pair starts as `"tecs", "tecs"` and changes when
--- `setPreferenceIdentity` succeeds.
---
--- @return Returns the current publisher, studio, or organization name.
--- @return Returns the current game or application name.
function files.preferenceIdentity(): string, string
    return preferenceOrganization, preferenceApplication
end

--- Returns the writable directory for this application and creates it if
--- absent.
---
--- @return Returns the directory with a trailing separator, named from the
---     preference identity. This is where a build writes durable state;
---     `cachePath` is the other writable root and holds only reconstructable
---     data.
function files.preferencePath(): string
    return content.prefPath(preferenceOrganization, preferenceApplication)
end

--- Returns the system cache directory for this application and creates it if
--- absent.
---
--- The operating system may empty this directory between any two runs. Store
--- only reconstructable downloads, compiled artifacts, thumbnails and similar
--- derived data here. Saves, settings and other durable state belong under
--- `preferencePath`.
---
--- @return Returns the directory with a trailing platform separator, named
---     from the preference identity.
function files.cachePath(): string
    return content.cachePath(preferenceOrganization, preferenceApplication)
end

--- Returns the root from which the engine reads content.
---
--- @return Returns `TECS_ASSETS` when set, otherwise the host-configured root
---     or `basePath`. The value stays cached until the platform changes.
function files.assetRoot(): string
    return content.assetRoot()
end

--- Resolves `relative` against the asset root.
---
--- @param relative The caller supplies a path under the content root with `/`
---     separators. The function joins it without checking existence.
--- @return Returns the absolute path.
function files.assetPath(relative: PathInput): string
    return content.assetPath(required(relative, "assetPath"))
end

--- Resolves `relative` against the writable root.
---
--- @param relative The caller supplies a path under the preference directory.
--- @return Returns the absolute path.
function files.writablePath(relative: PathInput): string
    return files.preferencePath() .. required(relative, "writablePath")
end

--- Overrides the asset root, for a test or a tool.
---
--- @param root The caller supplies the new content directory. The function
---     adds a trailing separator only when needed.
function files.setAssetRoot(root: PathInput)
    content.setAssetRoot(required(root, "setAssetRoot"))
end

--- Returns information about `path`, or nil when nothing occupies it.
---
--- Nil is the answer for a path that does not exist, for a broken symbolic
--- link, and when the platform cannot search a directory; the second return
--- separates them.
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns the path information, or nil when unavailable.
--- @return Returns the platform reason when the first return is nil.
function files.info(path: PathInput): Info, string
    return adapter.storage().info(required(path, "info"))
end

--- Returns whether anything occupies `path`.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the platform finds any object.
function files.exists(path: PathInput): boolean
    return adapter.storage().info(required(path, "exists")) ~= nil
end

--- Returns whether `path` resolves to a regular file.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the resolved object is a regular file.
function files.isFile(path: PathInput): boolean
    local info <const> = adapter.storage().info(required(path, "isFile"))
    return info ~= nil and info.kind == "file"
end

--- Returns whether `path` resolves to a directory.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the resolved object is a directory.
function files.isDirectory(path: PathInput): boolean
    local info <const> = adapter.storage().info(required(path, "isDirectory"))
    return info ~= nil and info.kind == "directory"
end

--- Returns whether the final object named by `path` is a symbolic link.
---
--- Unlike `info`, this function does not follow the final link. It does follow
--- links in parent directories, so the result is path introspection and not a
--- security boundary. A path that is absent or cannot be inspected returns
--- false.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the final path itself is a symbolic link.
function files.isSymlink(path: PathInput): boolean
    return adapter.storage().isSymlink(required(path, "isSymlink"))
end

--- Returns the target spelling stored in a symbolic link.
---
--- A relative target remains relative. The function does not resolve it
--- against the link's parent and fails when `path` is not a symbolic link.
---
--- @param path The caller supplies the symbolic link to inspect.
--- @return Returns the stored target as an immutable [`Path`](tealdoc:tecs.io.Path).
--- @return Returns the platform or unsupported reason when the first return is nil.
function files.readLink(path: PathInput): Path, string
    local backend <const> = adapter.storage()
    if backend.readLink == nil then
        return nil, ("symbolic links are not supported by the %s storage backend"):format(backend.name)
    end
    local target <const>, reason = backend.readLink(required(path, "readLink"))
    if target == nil then
        return nil, reason
    end
    return Path.new(target)
end

--- Creates a symbolic link to a file or directory.
---
--- The target spelling is stored unchanged, so a relative target is resolved
--- from the link's parent when later opened. `kind` is required because
--- Windows must choose a file or directory link even for a dangling target.
---
--- @param target The caller supplies the target spelling to store.
--- @param link The caller supplies the new link path.
--- @param kind The caller supplies `"file"` or `"directory"`.
--- @return Returns whether the platform created the link.
--- @return Returns the platform or unsupported reason when the first return is false.
function files.createSymlink(target: PathInput, link: PathInput, kind: SymlinkKind): boolean, string
    local renderedTarget <const> = required(target, "createSymlink")
    local renderedLink <const> = required(link, "createSymlink")
    if kind ~= "file" and kind ~= "directory" then
        error("tecs: io.files.createSymlink kind must be 'file' or 'directory'", 2)
    end
    local backend <const> = adapter.storage()
    if backend.createSymlink == nil then
        return false, ("symbolic links are not supported by the %s storage backend"):format(backend.name)
    end
    return backend.createSymlink(renderedTarget, renderedLink, kind == "directory")
end

--- Changes the portable read-only state of a path.
---
--- On Unix, making a path read-only clears every write bit and making it
--- writable restores only the owner's write bit. The API deliberately does
--- not model platform ACLs, ownership, or executable bits.
---
--- @param path The caller supplies the existing path to change.
--- @param readOnly The caller supplies true to prevent ordinary writes.
--- @return Returns whether the platform changed the state.
--- @return Returns the platform or unsupported reason when the first return is false.
function files.setReadOnly(path: PathInput, readOnly: boolean): boolean, string
    local rendered <const> = required(path, "setReadOnly")
    if type(readOnly) ~= "boolean" then
        error("tecs: io.files.setReadOnly needs a boolean state", 2)
    end
    local backend <const> = adapter.storage()
    if backend.setReadOnly == nil then
        return false, ("read-only permissions are not supported by the %s storage backend"):format(backend.name)
    end
    return backend.setReadOnly(rendered, readOnly)
end

local function listDirectory(path: Path): {string}, string
    return adapter.storage().list(path:toString())
end

local function nextUTF8Byte(text: string, offset: integer): integer
    local first <const> = text:byte(offset)
    if first == nil or first < 0x80 then
        return offset + 1
    elseif first >= 0xc2 and first <= 0xdf then
        return offset + 2
    elseif first >= 0xe0 and first <= 0xef then
        return offset + 3
    elseif first >= 0xf0 and first <= 0xf4 then
        return offset + 4
    end
    return offset + 1
end

local function matchesGlob(name: string, pattern: string, caseInsensitive: boolean): boolean
    if caseInsensitive then
        name = name:lower()
        pattern = pattern:lower()
    end

    local nameAt = 1
    local patternAt = 1
    local starAt = 0
    local starNameAt = 0
    while nameAt <= #name do
        local token <const> = pattern:sub(patternAt, patternAt)
        local nextNameAt <const> = nextUTF8Byte(name, nameAt)
        local nextPatternAt <const> = nextUTF8Byte(pattern, patternAt)
        if token == "?" or name:sub(nameAt, nextNameAt - 1) == pattern:sub(patternAt, nextPatternAt - 1) then
            nameAt = nextNameAt
            patternAt = nextPatternAt
        elseif token == "*" then
            starAt = patternAt
            starNameAt = nameAt
            patternAt = patternAt + 1
        elseif starAt ~= 0 then
            starNameAt = nextUTF8Byte(name, starNameAt)
            nameAt = starNameAt
            patternAt = starAt + 1
        else
            return false
        end
    end
    while pattern:sub(patternAt, patternAt) == "*" do
        patternAt = patternAt + 1
    end
    return patternAt > #pattern
end

local function splitGlob(pattern: string): {string}
    local segments: {string} = {}
    local start = 1
    while true do
        local separator <const> = pattern:find("/", start, true)
        if separator == nil then
            segments[#segments + 1] = pattern:sub(start)
            return segments
        end
        segments[#segments + 1] = pattern:sub(start, separator - 1)
        start = separator + 1
    end
end

function DirectoryStream:next(): DirectoryEntry, string
    local state <const> = directoryStates[self]
    if state == nil or state.closed then
        return nil
    end
    state.pendingDirectory = nil
    while #state.frames > 0 do
        local frame <const> = state.frames[#state.frames]
        if frame.names == nil then
            local names <const>, reason = listDirectory(frame.path)
            if names == nil then
                self:close()
                return nil, reason
            end
            frame.names = names
        end
        if frame.at > #frame.names then
            state.frames[#state.frames] = nil
        else
            local name <const> = frame.names[frame.at]
            frame.at = frame.at + 1
            local path <const> = frame.path:join(name)
            local symlink <const> = files.isSymlink(path)
            local info <const>, reason = files.info(path)
            if info == nil and not symlink then
                self:close()
                return nil, reason
            end
            local kind <const>: files.PathType = info ~= nil and info.kind or "other"
            local depth <const> = frame.depth
            local matches <const> = state.pattern == nil
                or matchesGlob(name, state.pattern[depth], state.caseInsensitive)
            local descends <const> = kind == "directory"
                and not symlink
                and depth < state.maxDepth
                and (state.pattern == nil or (matches and depth < #state.pattern))
            local child: DirectoryFrame = nil
            if descends then
                child = {path = path, depth = depth + 1, at = 1}
                state.frames[#state.frames + 1] = child
            end
            if state.pattern == nil or (matches and depth == #state.pattern) then
                state.pendingDirectory = child
                return {path = path, name = name, kind = kind, depth = depth, symlink = symlink}
            end
        end
    end
    state.closed = true
    return nil
end

function DirectoryStream:skipDirectory(): boolean
    local state <const> = directoryStates[self]
    if state == nil or state.closed or state.pendingDirectory == nil then
        return false
    end
    if state.frames[#state.frames] ~= state.pendingDirectory then
        state.pendingDirectory = nil
        return false
    end
    state.frames[#state.frames] = nil
    state.pendingDirectory = nil
    return true
end

function DirectoryStream:toArray(): {DirectoryEntry}, string
    local entries: {DirectoryEntry} = {}
    while true do
        local entry <const>, reason = self:next()
        if entry == nil then
            self:close()
            if reason ~= nil then
                return nil, reason
            end
            return entries
        end
        entries[#entries + 1] = entry
    end
end

function DirectoryStream:close(): boolean, string
    local state <const> = directoryStates[self]
    if state == nil or state.closed then
        return true
    end
    state.closed = true
    state.frames = {}
    state.pendingDirectory = nil
    return true
end

--- Opens a pull stream over entries under `path` that match `pattern`.
---
--- **Recursive unless the pattern stops it**: with no pattern this walks the
--- whole tree below `path`. `*` and `?` never match a separator, and `?`
--- consumes one UTF-8 codepoint, so `"*"` is one level, `"*/*"` is exactly
--- two, and `"*.png"` matches only immediate children. Results include
--- directories alongside files. Symbolic links are yielded but never followed.
--- The order is the platform's own and is not sorted.
---
--- The stream retains only the unvisited names in each directory on its
--- current descent. Close it when leaving early. After receiving a directory,
--- call `skipDirectory` before `next` to prune that complete subtree. Call
--- `toArray` to consume and close the stream when every remaining entry should
--- be retained.
---
--- A fixed bound belongs in `maxDepth`; `skipDirectory` remains useful when
--- descent depends on the entry itself. The checked example combines both.
---
--- @param path The caller supplies the directory to enumerate.
--- @param pattern The caller supplies `/`-separated `*` and `?` wildcards, or
---     nil to include every descendant recursively.
--- @param options The caller supplies matching and depth options, or omits
---     them for case-sensitive, unlimited traversal.
--- @return Returns a caller-owned stream, or nil when enumeration cannot start.
--- @return Returns the platform reason when the first return is nil.
function files.glob(path: PathInput, pattern?: string, options?: GlobOptions): DirectoryStream, string
    local root <const> = Path.new(required(path, "glob"))
    local maxDepth = 2147483647
    if options ~= nil and options.maxDepth ~= nil then
        maxDepth = options.maxDepth
        if type(maxDepth) ~= "number" or maxDepth ~= floor(maxDepth) or maxDepth < 0 then
            error("tecs: io.files.glob maxDepth must be a non-negative integer", 2)
        end
    end
    local names <const>, reason = listDirectory(root)
    if names == nil then
        return nil, reason
    end
    local stream <const> = setmetatable({} as DirectoryStream, DIRECTORY_STREAM_MT)
    local segments: {string} = nil
    if pattern ~= nil then
        segments = splitGlob(pattern)
    end
    directoryStates[stream] = {
        frames = maxDepth == 0 and {} or {{path = root, depth = 1, names = names, at = 1}},
        pattern = segments,
        caseInsensitive = options ~= nil and options.caseInsensitive or false,
        maxDepth = maxDepth,
        closed = false,
    }
    return stream
end

--- Creates `path`, and any parents it needs.
---
--- It succeeds when the directory already exists.
---
--- @param path The caller supplies the directory to create.
--- @return Returns whether the platform created or found the directory.
--- @return Returns the platform reason when the first return is false.
function files.createDirectory(path: PathInput): boolean, string
    return adapter.storage().createDirectory(required(path, "createDirectory"))
end

--- Removes a file, or an empty directory.
---
--- It does not recurse and fails on a directory with anything in it. It
--- **succeeds when there is nothing at `path`**: the result says the path is
--- gone, not that this call is what removed it.
---
--- Emptying a tree requires a glob and a deepest-first loop:
---
---     local stream = assert(files.glob(root))
---     local paths = {}
---     while true do
---         local entry, reason = stream:next()
---         if entry == nil then
---             if reason ~= nil then error(reason) end
---             break
---         end
---         paths[#paths + 1] = entry.path
---     end
---     stream:close()
---     table.sort(paths, function(a, b)
---         return #(a:toString()) > #(b:toString())
---     end)
---     for _, path in ipairs(paths) do
---         files.remove(path)
---     end
---     files.remove(root)
---
--- @param path The caller supplies the file or empty directory to remove.
--- @return Returns true when nothing remains at `path`.
--- @return Returns the platform reason when the first return is false.
function files.remove(path: PathInput): boolean, string
    return adapter.storage().remove(required(path, "remove"))
end

--- Moves `from` to `to`, replacing whatever was at `to`.
---
--- Directories move as well as files, and an existing destination is
--- overwritten with no warning and nothing to undo it. Whether this works
--- across filesystems is the platform's business.
---
--- @param from The caller supplies the existing source path.
--- @param to The caller supplies the destination path to replace.
--- @return Returns whether the platform moved the path.
--- @return Returns the platform reason when the first return is false.
function files.rename(from: PathInput, to: PathInput): boolean, string
    return adapter.storage().rename(required(from, "rename"), required(to, "rename"))
end

--- Copies the file at `from` to `to`, replacing whatever was at `to`.
---
--- The function refuses directories and requires an existing destination
--- parent.
---
--- @param from The caller supplies the existing source file.
--- @param to The caller supplies the destination file to replace.
--- @return Returns whether the platform copied the file.
--- @return Returns the platform reason when the first return is false.
function files.copy(from: PathInput, to: PathInput): boolean, string
    return adapter.storage().copy(required(from, "copy"), required(to, "copy"))
end

function TemporaryPath:persist(destination: string | Path): boolean, string
    local backing <const> = temporaryBackings[self]
    if backing == nil then
        return false, "the temporary path is closed"
    end
    local ok <const>, reason = backing:persist(required(destination, "persist"))
    if ok then
        temporaryBackings[self] = nil
    end
    return ok, reason
end

function TemporaryPath:close(): boolean, string
    local backing <const> = temporaryBackings[self]
    if backing == nil then
        return true
    end
    local ok <const>, reason = backing:close()
    if ok then
        temporaryBackings[self] = nil
    end
    return ok, reason
end

local function temporaryNamePart(value: string, default: string, field: string): string
    value = value or default
    if
        type(value) ~= "string" or value:find("/", 1, true) or value:find("\\", 1, true) or value:find("\0", 1, true)
    then
        error(("tecs: io.files temporary %s must be a path-separator-free string"):format(field), 3)
    end
    return value
end

local function createTemporary(options: TemporaryOptions, directory: boolean): TemporaryPath, string
    options = options or {} as TemporaryOptions
    local parent = ""
    if options.directory ~= nil then
        parent = required(options.directory, directory and "createTemporaryDirectory" or "createTemporaryFile")
    end
    local prefix <const> = temporaryNamePart(options.prefix, "tecs-", "prefix")
    local suffix <const> = temporaryNamePart(options.suffix, "", "suffix")
    local backend <const> = adapter.storage()
    local create <const> = directory and backend.createTemporaryDirectory or backend.createTemporaryFile
    if create == nil then
        return nil, ("temporary paths are not supported by the %s storage backend"):format(backend.name)
    end
    local backing <const>, reason = create(parent, prefix, suffix)
    if backing == nil then
        return nil, reason
    end
    local temporary <const> = setmetatable({path = Path.new(backing.path)} as TemporaryPath, TEMPORARY_PATH_MT)
    temporaryBackings[temporary] = backing
    return temporary
end

--- Creates an empty temporary file owned by the returned resource.
---
--- Creation is exclusive. Closing removes the file; garbage collection is a
--- leak safety net, while [`tecs.scoped`](/modules/#tecs.scoped) provides
--- deterministic cleanup. Call `persist` to keep the file under an absent
--- permanent destination.
---
--- @param options The caller may select the parent, prefix, and suffix.
--- @return Returns the caller-owned temporary file.
--- @return Returns the platform or unsupported reason when creation fails.
function files.createTemporaryFile(options?: TemporaryOptions): TemporaryPath, string
    return createTemporary(options, false)
end

--- Creates an empty temporary directory owned by the returned resource.
---
--- Closing recursively removes its contents without following symbolic links.
--- Call `persist` to keep the complete tree under an absent destination.
---
--- @param options The caller may select the parent, prefix, and suffix.
--- @return Returns the caller-owned temporary directory.
--- @return Returns the platform or unsupported reason when creation fails.
function files.createTemporaryDirectory(options?: TemporaryOptions): TemporaryPath, string
    return createTemporary(options, true)
end

--- Reads a whole file and returns its bytes, or nil when there is none there.
---
--- The binary string retains embedded NUL bytes. The synchronous call suits
--- small documents; use `tecs.assets.loadString` when a whole-file read should
--- run off the main thread, or its image and sound loaders for decoding.
---
--- @param path The caller supplies an absolute path or one from `assetPath`.
--- @param kind The caller supplies the content kind for watching, or omits it
---     to record a document.
--- @return Returns the file bytes, or nil when the platform cannot read them.
function files.read(path: PathInput, kind?: string): string
    return content.read(required(path, "read"), kind)
end

--- Iterates over the lines in a whole file.
---
--- The function reads and closes the file before it returns the iterator, so
--- breaking the loop retains only the immutable bytes and no file descriptor.
--- It strips LF and CRLF terminators, returns empty lines between adjacent
--- terminators, and does not invent another empty line after a final
--- terminator. Use `open` when the input is too large to hold whole.
---
--- @param path The caller supplies the source file.
--- @return Returns a
---     [`LineIterator`](tealdoc:tecs.io.files.LineIterator) that yields each
---     line in order, or nil when the platform cannot read the file.
--- @return Returns the failure reason when the first return is nil.
function files.lines(path: PathInput): LineIterator, string
    local rendered <const> = required(path, "lines")
    local bytes <const> = files.read(rendered)
    if bytes == nil then
        return nil, ("cannot read %s"):format(rendered)
    end
    local at = 1
    local length <const> = #bytes
    return function(): string
        if at > length then
            return nil
        end
        local newline <const> = bytes:find("\n", at, true)
        if newline == nil then
            local line <const> = bytes:sub(at)
            at = length + 1
            return line
        end
        local last = newline - 1
        if last >= at and bytes:byte(last) == 13 then
            last = last - 1
        end
        local line <const> = bytes:sub(at, last)
        at = newline + 1
        return line
    end
end

--- Compiles a Lua file without running it.
---
--- The function reads through the installed storage backend rather than
--- `loadfile`, records the source for file watching, and uses `@path` as the
--- compiler's chunk name. The default environment is the caller's global
--- environment. A supplied environment is installed exactly as given and is
--- not a security boundary unless the caller makes it one.
---
--- @param path The caller supplies the Lua source file.
--- @param environment The caller supplies the globals visible when the chunk
---     runs, or omits them to use the process globals.
--- @return Returns the compiled chunk, or nil when reading or compilation
---     fails. Calling the returned function executes the file.
--- @return Returns the read or compiler reason when the first return is nil.
function files.load(path: PathInput, environment?: {string: any}): function(...: any): any..., string
    local rendered <const> = required(path, "load")
    local bytes <const> = files.read(rendered)
    if bytes == nil then
        return nil, ("cannot read %s"):format(rendered)
    end
    local chunk <const>, reason = loadstring(bytes, "@" .. rendered)
    if chunk ~= nil and environment ~= nil then
        setfenv(chunk, environment)
    end
    return chunk, reason
end

--- Builds a shared read/write cursor for a backend without direct file access.
local function bufferedFile(backend: storagebackend.Backend, path: string, mode: FileMode): File, string
    local readable <const> = mode == "r" or mode == "r+" or mode == "w+" or mode == "a+"
    local writable <const> = mode ~= "r"
    local appending <const> = mode == "a" or mode == "a+"
    local initial = ""

    if mode == "r" or mode == "r+" then
        initial = backend.read(path)
        if initial == nil then
            return nil, ("cannot read %s"):format(path)
        end
    elseif mode == "w" or mode == "w+" then
        local ok <const>, reason = backend.write(path, "")
        if not ok then
            return nil, reason
        end
    else
        initial = backend.read(path) or ""
        local ok <const>, reason = backend.append(path, "")
        if not ok then
            return nil, reason
        end
    end

    local bytes = buffer.new(initial)
    local at = mode == "a" and bytes:length() or 0
    local appendedThrough = bytes:length()
    local closed = false
    local file <const> = {} as {string: any}

    file.read = function(_self: Reader, count: integer): string, string
        if closed then
            return nil, "the file is closed"
        end
        if not readable then
            return nil, "the file is not open for reading"
        end
        if at >= bytes:length() then
            return ""
        end
        local taking <const> = min(max(1, count), bytes:length() - at)
        local piece <const> = bytes:getString(at, taking)
        at = at + taking
        return piece
    end

    file.readInto = function(_self: Reader, destination: IOBuffer, offset?: integer, count?: integer): integer, string
        if closed then
            return nil, "the file is closed"
        end
        if not readable then
            return nil, "the file is not open for reading"
        end
        offset = offset or 0
        count = count or DEFAULT_READ_BYTES
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 then
            error("tecs: Reader:readInto offset must be a non-negative integer", 2)
        end
        if type(count) ~= "number" or count ~= floor(count) or count < 0 then
            error("tecs: Reader:readInto count must be a non-negative integer", 2)
        end
        local taking <const> = min(count, bytes:length() - at)
        if taking == 0 then
            return 0
        end
        local output <const>, previousLength = buffer.prepareWrite(destination, offset, taking)
        ffi.copy(output as ffi.CData, (bytes:getFFIPointer() + at) as ffi.CData, taking)
        buffer.commitWrite(destination, offset, taking, previousLength)
        at = at + taking
        return taking
    end

    file.write = function(_self: Writer, piece: string): boolean, string
        if closed then
            return false, "the file is closed"
        end
        if not writable then
            return false, "the file is not open for writing"
        end
        if appending then
            at = bytes:length()
        end
        bytes:setString(piece, at)
        at = at + #piece
        return true
    end

    file.writeFrom = function(_self: Writer, source: IOBuffer, offset?: integer, count?: integer): integer, string
        if closed then
            return nil, "the file is closed"
        end
        if not writable then
            return nil, "the file is not open for writing"
        end
        offset = offset or 0
        local sourceLength <const> = source:length()
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > sourceLength then
            error("tecs: Writer:writeFrom offset is outside the buffer", 2)
        end
        if count == nil then
            count = sourceLength - offset
        elseif type(count) ~= "number" or count ~= floor(count) or count < 0 or count > sourceLength - offset then
            error("tecs: Writer:writeFrom count is outside the buffer", 2)
        end
        if appending then
            at = bytes:length()
        end
        if count == 0 then
            return 0
        end
        local output <const>, previousLength = buffer.prepareWrite(bytes, at, count)
        ffi.copy(output as ffi.CData, (source:getFFIPointer() + offset) as ffi.CData, count)
        buffer.commitWrite(bytes, at, count, previousLength)
        at = at + count
        return count
    end

    file.writeView = function(_self: Writer, source: ByteView, offset?: integer, count?: integer): integer, string
        if closed then
            return nil, "the file is closed"
        end
        if not writable then
            return nil, "the file is not open for writing"
        end
        if source == nil or source:isReleased() then
            error("tecs: Writer:writeView needs an open io.ByteView", 2)
        end
        offset = offset or 0
        local sourceLength <const> = source:length()
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > sourceLength then
            error("tecs: Writer:writeView offset is outside the view", 2)
        end
        if count == nil then
            count = sourceLength - offset
        elseif type(count) ~= "number" or count ~= floor(count) or count < 0 or count > sourceLength - offset then
            error("tecs: Writer:writeView count is outside the view", 2)
        end
        if appending then
            at = bytes:length()
        end
        if count == 0 then
            return 0
        end
        local output <const>, previousLength = buffer.prepareWrite(bytes, at, count)
        ffi.copy(output as ffi.CData, (source:getFFIPointer() + offset) as ffi.CData, count)
        buffer.commitWrite(bytes, at, count, previousLength)
        at = at + count
        return count
    end

    file.size = function(_self: File): integer, string
        if closed then
            return nil, "the file is closed"
        end
        return bytes:length()
    end

    file.tell = function(_self: File): integer, string
        if closed then
            return nil, "the file is closed"
        end
        return at
    end

    file.seek = function(_self: File, origin: SeekOrigin, offset?: integer): integer, string
        if closed then
            return nil, "the file is closed"
        end
        if origin ~= "start" and origin ~= "current" and origin ~= "end" then
            error("tecs: File:seek origin must be 'start', 'current', or 'end'", 2)
        end
        offset = offset or 0
        if type(offset) ~= "number" or offset ~= floor(offset) then
            error("tecs: File:seek offset must be an integer", 2)
        end
        local base = 0
        if origin == "current" then
            base = at
        elseif origin == "end" then
            base = bytes:length()
        end
        local target <const> = base + offset
        if target < 0 or target > bytes:length() then
            return nil, "seek position is outside the file"
        end
        at = target
        return at
    end

    file.flush = function(_self: Writer): boolean, string
        if closed then
            return false, "the file is closed"
        end
        if not writable then
            return true
        end
        if appending then
            if appendedThrough == bytes:length() then
                return true
            end
            local ok <const>, reason = backend.append(
                path, bytes:getString(appendedThrough, bytes:length() - appendedThrough)
            )
            if ok then
                appendedThrough = bytes:length()
            end
            return ok, reason
        end
        return backend.write(path, bytes:getString())
    end

    file.close = function(_self: Writer): boolean, string
        if closed then
            return true
        end
        local ok = true
        local reason: string = nil
        if writable then
            ok, reason = (file as Writer):flush()
        end
        closed = true
        bytes:close()
        return ok, reason
    end
    return file as File
end

--- Writes `bytes` to `path`, replacing whatever was there.
---
--- The string's length controls the binary write, so embedded NUL bytes remain
--- data and an empty string creates an empty file. The parent directory must
--- already exist.
---
--- @param path The caller supplies the destination file.
--- @param bytes The caller supplies the complete binary contents.
--- @return Returns whether the platform wrote the complete file.
--- @return Returns the platform reason when the first return is false.
function files.write(path: PathInput, bytes: string): boolean, string
    local rendered <const> = required(path, "write")
    if bytes == nil then
        error("tecs: io.files.write needs bytes to write", 2)
    end
    return adapter.storage().write(rendered, bytes)
end

--- Durably writes `bytes` and atomically replaces `path`.
---
--- The platform writes a uniquely named temporary file beside `path`, commits
--- its complete contents to durable storage, atomically replaces the
--- destination, and commits the containing directory where the operating
--- system provides that operation. An existing destination remains untouched
--- when anything fails before replacement, and no temporary file is retained.
---
--- A failure after replacement means the complete new file is visible but the
--- platform could not confirm that the directory update will survive a power
--- loss. The function returns false in that case rather than overstating
--- durability. Hardware can still violate an operating system's completed
--- flush request.
---
--- A storage backend without an atomic durable commit returns false and an
--- unsupported reason. The function never falls back to `write` plus `rename`.
--- The parent directory must already exist.
---
--- @param path The caller supplies the destination file.
--- @param bytes The caller supplies a string or open
---     [`Buffer`](/modules/io/#tecs.io.Buffer) or
---     [`ByteView`](/modules/io/#tecs.io.ByteView) containing the complete
---     binary contents. Buffers and views are borrowed only for this
---     synchronous call and are not copied or closed.
--- @return Returns whether the platform confirmed the atomic durable write.
--- @return Returns the platform or unsupported reason when the first return is false.
function files.writeAtomic(path: PathInput, bytes: ByteInput): boolean, string
    local rendered <const> = required(path, "writeAtomic")
    if bytes == nil then
        error("tecs: io.files.writeAtomic needs bytes to write", 2)
    end
    if type(bytes) ~= "string" then
        local dynamic <const> = bytes as {string: any}
        if
            type(bytes) ~= "table"
            or type(dynamic.length) ~= "function"
            or type(dynamic.getFFIPointer) ~= "function"
            or type(dynamic.isReleased) ~= "function"
            or (dynamic.isReleased as function(any): boolean)(bytes)
        then
            error("tecs: io.files.writeAtomic needs a byte string or open io.Buffer or io.ByteView", 2)
        end
    end
    local backend <const> = adapter.storage()
    if backend.writeAtomic == nil then
        return false, ("atomic durable writes are not supported by the %s storage backend"):format(backend.name)
    end
    return backend.writeAtomic(rendered, bytes)
end

--- Durably and atomically writes a complete file on a worker.
---
--- The returned [`Future`](tealdoc:tecs.Future) becomes ready with true after
--- the same commit performed by `writeAtomic`, or fails with its platform
--- reason. The call copies a buffer or byte view before returning, so the
--- caller may mutate or close it immediately. String bytes cross the worker
--- channel by value as well. `tecs.runtime.poll` advances the future each
--- frame; `Future:wait` advances it in headless code.
---
--- Canceling the future stops interest in its result but cannot safely
--- interrupt a filesystem commit already in progress. The shared worker exits
--- automatically after its last queued result is drained. A non-SDL storage
--- backend receives a failed future because a separate worker state cannot
--- inherit the main state's installed Lua backend.
---
--- @param path The caller supplies the destination file.
--- @param bytes The caller supplies the complete binary contents.
--- @return Returns a future which becomes ready with true or fails.
function files.writeAtomicAsync(path: PathInput, bytes: ByteInput): Future<boolean>
    local rendered <const> = required(path, "writeAtomicAsync")
    if bytes == nil then
        error("tecs: io.files.writeAtomicAsync needs bytes to write", 2)
    end
    local copied: string
    if type(bytes) == "string" then
        copied = bytes as string
    else
        local dynamic <const> = bytes as {string: any}
        if
            type(bytes) ~= "table"
            or type(dynamic.length) ~= "function"
            or type(dynamic.getFFIPointer) ~= "function"
            or type(dynamic.isReleased) ~= "function"
            or (dynamic.isReleased as function(any): boolean)(bytes)
        then
            error("tecs: io.files.writeAtomicAsync needs a byte string or open io.Buffer or io.ByteView", 2)
        end
        local input <const> = bytes as ByteView
        copied = loader.toBytes(input:getFFIPointer() as loader.CValue, input:length())
    end
    local backend <const> = adapter.storage()
    if backend.writeAtomic == nil or backend ~= storagebackend.sdl then
        return Future.failed(
            ("asynchronous atomic durable writes are not supported by the %s storage backend"):format(backend.name)
        ) as Future<boolean>
    end
    local started <const>, reason = ensureAtomicWorker()
    if not started then
        return Future.failed(reason) as Future<boolean>
    end
    local id <const> = nextAtomicId
    nextAtomicId = nextAtomicId + 1
    local future <const> = Future.pending(atomicSource as Future.Source) as Future<boolean>
    atomicEntries[id] = {future = future}
    atomicPending = atomicPending + 1
    atomicWorker:send({id = id, path = rendered, bytes = copied})
    return future
end

--- Opens a file through one seekable cursor.
---
--- The mode follows Lua's standard file modes. `"r"` opens an existing file
--- for reading and is the default. `"w"` creates or truncates for writing.
--- `"a"` creates or preserves for writes that always land at the end. Adding
--- `+` permits both reading and writing. The cursor starts at byte zero except
--- for `"a"`; `"a+"` starts at byte zero for reading while every write still
--- lands at the current end. Seeks may not move past the end.
---
--- Close the file even after its last write succeeds. `close` flushes buffered
--- bytes and can report a delayed storage failure. A backend without direct
--- random access retains the complete file until close.
---
--- @param path The caller supplies the file as a string or immutable
---     [`Path`](tealdoc:tecs.io.Path).
--- @param mode The caller selects `"r"`, `"w"`, `"a"`, `"r+"`, `"w+"`, or
---     `"a+"`, or omits it for `"r"`.
--- @return Returns a caller-owned [`File`](tealdoc:tecs.io.files.File), or nil
---     when the platform cannot open it.
--- @return Returns the platform reason when the first return is nil.
function files.open(path: PathInput, mode?: FileMode): File, string
    local rendered <const> = required(path, "open")
    mode = mode or "r"
    if mode ~= "r" and mode ~= "w" and mode ~= "a" and mode ~= "r+" and mode ~= "w+" and mode ~= "a+" then
        error("tecs: io.files.open mode must be 'r', 'w', 'a', 'r+', 'w+', or 'a+'", 2)
    end
    local backend <const> = adapter.storage()
    if backend.open ~= nil then
        local opened <const>, reason = backend.open(rendered, mode)
        return opened as File, reason
    end
    return bufferedFile(backend, rendered, mode)
end

--- Returns the process working directory.
---
--- Command-line tools receive relative paths and resolve them against this
--- directory. It is not where a
--- game reads content from or writes state to: `assetRoot`, `preferencePath`
--- and `cachePath` answer that, and say why. A platform with no working
--- directory answers nil, which is most of the ones that are not a desktop.
--- @return Returns the directory with a trailing separator, or nil when the
---     platform has no working directory.
--- @return Returns the platform reason when the first return is nil.
function files.currentDirectory(): string, string
    local storage <const> = adapter.storage()
    if storage.currentDirectory == nil then
        return nil, "this platform has no working directory"
    end
    return storage.currentDirectory()
end

--- Returns one of the platform's well-known folders.
---
--- **Often nil, and legitimately so.** A platform that has no such concept says
--- so rather than inventing a path: macOS has no saved-games, screenshots or
--- templates folder and answers nil for all three, and a platform that is not a
--- desktop may have none of them. Treat every one of these as absent until it
--- is not, and never as a place a build may write; `preferencePath` and
--- `cachePath` are the two writable roots, with different durability.
--- @param which The caller supplies the well-known folder to resolve.
--- @return Returns the folder with a trailing separator, or nil when the
---     platform has no matching folder.
--- @return Returns the platform reason when the first return is nil.
function files.userFolder(which: UserFolder): string, string
    if not storagebackend.folders[which] then
        error(("tecs: io.files.userFolder does not know '%s'"):format(tostring(which)), 2)
    end
    local storage <const> = adapter.storage()
    if storage.userFolder == nil then
        return nil, "this platform has no well-known folders"
    end
    return storage.userFolder(which)
end

return files
