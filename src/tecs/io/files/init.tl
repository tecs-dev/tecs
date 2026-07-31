--[=[
Resolves game paths and performs synchronous file operations.

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

Filesystem outcomes return a status and a platform reason. Invalid
arguments raise because they indicate a defect in the calling program.
Every operation runs synchronously. Send large tree walks to
`tecs.workers`, and decode images or sounds through `tecs.assets`.

`tecs.io.watcher` polls paths recorded by `read` and the built-in asset
loaders. It does not walk the whole asset tree.

`openRead` returns a seekable reader without adding cursor operations to the
basic `tecs.io.Reader` contract used by transforms, sockets, and pipes. The
SDL backend seeks the file directly. A storage backend without random access
falls back to its required whole-file read, retaining those bytes until the
reader closes.
]=]

local ffi <const> = require("ffi")
local adapter <const> = require("tecs.platform.adapter")
local buffer <const> = require("tecs.io.buffer")
local loader <const> = require("tecs.ffi.loader")
local storagebackend <const> = require("tecs.platform.storagebackend")
local content <const> = require("tecs.platform.content")
local type types = require("tecs.io.types")

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
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

    --- `GlobOptions` controls pattern matching.
    type GlobOptions = storagebackend.GlobOptions

    --- `WriteMode` selects replacement or append behavior.
    type WriteMode = storagebackend.WriteMode

    --- `SeekableWriteMode` selects replacement or in-place update behavior.
    type SeekableWriteMode = storagebackend.SeekableWriteMode

    --- `ByteInput` supplies a string or open
    --- [`Buffer`](/modules/io/#tecs.io.Buffer) or
    --- [`ByteView`](/modules/io/#tecs.io.ByteView).
    type ByteInput = storagebackend.ByteInput

    --- [`SeekOrigin`](tealdoc:tecs.io.SeekOrigin) selects the reference point
    --- for a seek.
    type SeekOrigin = types.SeekOrigin

    --- A [`SeekableReader`](tealdoc:tecs.io.SeekableReader) reads a file
    --- through a repositionable cursor.
    type SeekableReader = types.SeekableReader

    --- A [`SeekableWriter`](tealdoc:tecs.io.SeekableWriter) patches a file
    --- through a repositionable cursor.
    type SeekableWriter = types.SeekableWriter

    --- `LineIterator` yields each line in a file and returns nil at the end.
    type LineIterator = function(): string
end

local type Info = files.Info
local type UserFolder = files.UserFolder
local type GlobOptions = files.GlobOptions
local type WriteMode = files.WriteMode
local type SeekableWriteMode = files.SeekableWriteMode
local type ByteInput = files.ByteInput
local type LineIterator = files.LineIterator
local type Writer = types.Writer
local type SeekableWriter = types.SeekableWriter
local type Reader = types.Reader
local type SeekOrigin = types.SeekOrigin
local type SeekableReader = types.SeekableReader
local type IOBuffer = types.Buffer
local type ByteView = types.ByteView

--- Raises when a required string argument is missing.
---
--- LuaJIT passes a Lua nil to a `const char *` parameter as a null pointer, so
--- a nil that reached SDL would be a call against an empty or invalid path
--- rather than an error anyone could trace back here. A path is the one thing
--- every function below needs, and a missing one is a defect in the caller.
--- Checked once, here, so a port's backend inherits it rather than repeating
--- it in ten functions.
local function required(value: string, what: string)
    if value == nil then
        error(("tecs: io.files.%s needs a path"):format(what), 3)
    end
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
function files.assetPath(relative: string): string
    return content.assetPath(relative)
end

--- Resolves `relative` against the writable root.
---
--- @param relative The caller supplies a path under the preference directory.
--- @return Returns the absolute path.
function files.writablePath(relative: string): string
    return files.preferencePath() .. relative
end

--- Overrides the asset root, for a test or a tool.
---
--- @param root The caller supplies the new content directory. The function
---     adds a trailing separator only when needed.
function files.setAssetRoot(root: string)
    content.setAssetRoot(root)
end

--- Returns information about `path`, or nil when nothing occupies it.
---
--- Nil is the answer for a path that does not exist, for a broken symbolic
--- link, and when the platform cannot search a directory; the second return
--- separates them.
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns the path information, or nil when unavailable.
--- @return Returns the platform reason when the first return is nil.
function files.info(path: string): Info, string
    required(path, "info")
    return adapter.storage().info(path)
end

--- Returns whether anything occupies `path`.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the platform finds any object.
function files.exists(path: string): boolean
    required(path, "exists")
    return adapter.storage().info(path) ~= nil
end

--- Returns whether `path` resolves to a regular file.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the resolved object is a regular file.
function files.isFile(path: string): boolean
    required(path, "isFile")
    local info <const> = adapter.storage().info(path)
    return info ~= nil and info.kind == "file"
end

--- Returns whether `path` resolves to a directory.
---
--- @param path The caller supplies an absolute or platform-resolvable path.
--- @return Returns true when the resolved object is a directory.
function files.isDirectory(path: string): boolean
    required(path, "isDirectory")
    local info <const> = adapter.storage().info(path)
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
function files.isSymlink(path: string): boolean
    required(path, "isSymlink")
    return adapter.storage().isSymlink(path)
end

--- Returns entries under `path` that match `pattern`.
---
--- **Recursive unless the pattern stops it**: with no pattern this walks the
--- whole tree below `path` and returns every descendant, joined with `/`
--- whatever the platform's separator is. `*` and `?` never match a separator,
--- so `"*"` is one level, `"*/*"` is exactly two, and `"*.png"` matches only
--- immediate children. Results include directories alongside files; call
--- `info` to distinguish them.
---
--- The order is the platform's own and is not sorted.
--- @param path The caller supplies the directory to enumerate.
--- @param pattern The caller supplies `*` and `?` wildcards, or nil to include
---     every descendant recursively.
--- @param options The caller supplies matching options or omits them for a
---     case-sensitive match.
--- @return Returns matching paths relative to `path`, or nil when enumeration
---     fails.
--- @return Returns the platform reason when the first return is nil.
---     An empty list means an empty directory, which nil does not.
function files.glob(path: string, pattern?: string, options?: GlobOptions): {string}, string
    required(path, "glob")
    return adapter.storage().glob(path, pattern, options)
end

--- Returns names directly inside `path`.
---
--- The function uses a `"*"` glob to confine results to one level. It returns
--- names rather than joined paths.
--- @param path The caller supplies the directory to enumerate.
--- @return Returns immediate child names, or nil when enumeration fails.
--- @return Returns the platform reason when the first return is nil.
function files.list(path: string): {string}, string
    required(path, "list")
    return files.glob(path, "*")
end

--- Creates `path`, and any parents it needs.
---
--- It succeeds when the directory already exists.
---
--- @param path The caller supplies the directory to create.
--- @return Returns whether the platform created or found the directory.
--- @return Returns the platform reason when the first return is false.
function files.createDirectory(path: string): boolean, string
    required(path, "createDirectory")
    return adapter.storage().createDirectory(path)
end

--- Removes a file, or an empty directory.
---
--- It does not recurse and fails on a directory with anything in it. It
--- **succeeds when there is nothing at `path`**: the result says the path is
--- gone, not that this call is what removed it.
---
--- Emptying a tree requires a glob and a deepest-first loop:
---
---     local entries = files.glob(root)
---     table.sort(entries, function(a, b) return #a > #b end)
---     for _, entry in ipairs(entries) do
---         files.remove(root .. "/" .. entry)
---     end
---     files.remove(root)
---
--- @param path The caller supplies the file or empty directory to remove.
--- @return Returns true when nothing remains at `path`.
--- @return Returns the platform reason when the first return is false.
function files.remove(path: string): boolean, string
    required(path, "remove")
    return adapter.storage().remove(path)
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
function files.rename(from: string, to: string): boolean, string
    required(from, "rename")
    required(to, "rename")
    return adapter.storage().rename(from, to)
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
function files.copy(from: string, to: string): boolean, string
    required(from, "copy")
    required(to, "copy")
    return adapter.storage().copy(from, to)
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
function files.read(path: string, kind?: string): string
    required(path, "read")
    return content.read(path, kind)
end

--- Iterates over the lines in a whole file.
---
--- The function reads and closes the file before it returns the iterator, so
--- breaking the loop retains only the immutable bytes and no file descriptor.
--- It strips LF and CRLF terminators, returns empty lines between adjacent
--- terminators, and does not invent another empty line after a final
--- terminator. Use `openRead` when the input is too large to hold whole.
---
--- @param path The caller supplies the source file.
--- @return Returns a
---     [`LineIterator`](tealdoc:tecs.io.files.LineIterator) that yields each
---     line in order, or nil when the platform cannot read the file.
--- @return Returns the failure reason when the first return is nil.
function files.lines(path: string): LineIterator, string
    required(path, "lines")
    local bytes <const> = files.read(path)
    if bytes == nil then
        return nil, ("cannot read %s"):format(path)
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
function files.load(path: string, environment?: {string: any}): function(...: any): any..., string
    required(path, "load")
    local bytes <const> = files.read(path)
    if bytes == nil then
        return nil, ("cannot read %s"):format(path)
    end
    local chunk <const>, reason = loadstring(bytes, "@" .. path)
    if chunk ~= nil and environment ~= nil then
        setfenv(chunk, environment)
    end
    return chunk, reason
end

--- A `Writer` for a backend that has no streaming write.
---
--- Replacement mode holds the complete value for `write`. Append mode releases
--- each successfully flushed group after handing it to `append`. It exists so
--- a caller has one interface everywhere: a port that streams gets the memory
--- back without the caller knowing, and a port that does not retains only what
--- its whole-file operations require.
local function bufferedWriter(backend: storagebackend.Backend, path: string, mode: WriteMode): Writer, string
    local pieces: {string} = {}
    local count = 0
    local appended = false

    local writer <const> = {} as {string: any}
    local basicWriter <const> = writer as Writer
    writer.write = function(_self: Writer, bytes: string): boolean, string
        if pieces == nil then
            return false, "the writer is closed"
        end
        count = count + 1
        pieces[count] = bytes
        return true
    end
    writer.writeFrom = function(
        _self: Writer, sourceBuffer: IOBuffer, offset?: integer, length?: integer
    ): integer, string
        local bytes <const> = sourceBuffer:getString(offset, length)
        local ok <const>, reason = basicWriter:write(bytes)
        if not ok then
            return nil, reason
        end
        return #bytes
    end
    writer.writeView = function(
        _self: Writer, sourceView: ByteView, offset?: integer, length?: integer
    ): integer, string
        if sourceView == nil or sourceView:isReleased() then
            error("tecs: Writer:writeView needs an open io.ByteView", 2)
        end
        offset = offset or 0
        local viewLength <const> = sourceView:length()
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > viewLength then
            error("tecs: Writer:writeView offset is outside the view", 2)
        end
        if length == nil then
            length = viewLength - offset
        elseif type(length) ~= "number" or length ~= floor(length) or length < 0 or length > viewLength - offset then
            error("tecs: Writer:writeView count is outside the view", 2)
        end
        local bytes <const> = loader.toBytes((sourceView:getFFIPointer() + offset) as loader.CValue, length)
        local ok <const>, reason = basicWriter:write(bytes)
        if not ok then
            return nil, reason
        end
        return length
    end
    writer.flush = function(_self: Writer): boolean, string
        if pieces == nil then
            return false, "the writer is closed"
        end
        if mode == "replace" then
            return backend.write(path, table.concat(pieces, "", 1, count))
        end
        if count == 0 and appended then
            return true
        end
        local ok <const>, reason = backend.append(path, table.concat(pieces, "", 1, count))
        if ok then
            pieces = {}
            count = 0
            appended = true
        end
        return ok, reason
    end
    writer.close = function(_self: Writer): boolean, string
        if pieces == nil then
            return true
        end
        local ok <const>, reason = basicWriter:flush()
        pieces = nil
        return ok, reason
    end
    return basicWriter
end

--- Builds random-access output over memory for a backend without a cursor.
local function bufferedSeekableWriter(
    backend: storagebackend.Backend, path: string, mode: SeekableWriteMode
): SeekableWriter, string
    local initial = ""
    if mode == "update" then
        initial = backend.read(path)
        if initial == nil then
            return nil, ("cannot open %s for update"):format(path)
        end
    end
    local bytes = buffer.new(initial)
    local at = 0
    local closed = false

    local writer <const> = {} as {string: any}
    writer.write = function(_self: Writer, piece: string): boolean, string
        if closed then
            return false, "the writer is closed"
        end
        bytes:setString(piece, at)
        at = at + #piece
        return true
    end
    writer.flush = function(_self: Writer): boolean, string
        if closed then
            return false, "the writer is closed"
        end
        return backend.write(path, bytes:getString())
    end
    writer.size = function(_self: SeekableWriter): integer, string
        if closed then
            return nil, "the writer is closed"
        end
        return bytes:length()
    end
    writer.tell = function(_self: SeekableWriter): integer, string
        if closed then
            return nil, "the writer is closed"
        end
        return at
    end
    writer.seek = function(_self: SeekableWriter, origin: SeekOrigin, offset?: integer): integer, string
        if closed then
            return nil, "the writer is closed"
        end
        if origin ~= "start" and origin ~= "current" and origin ~= "end" then
            error("tecs: SeekableWriter:seek origin must be 'start', 'current', or 'end'", 2)
        end
        offset = offset or 0
        if type(offset) ~= "number" or offset ~= floor(offset) then
            error("tecs: SeekableWriter:seek offset must be an integer", 2)
        end
        local base = 0
        if origin == "current" then
            base = at
        elseif origin == "end" then
            base = bytes:length()
        end
        local target <const> = base + offset
        if target < 0 or target > bytes:length() then
            return nil, "seek position is outside the destination"
        end
        at = target
        return at
    end
    writer.close = function(_self: Writer): boolean, string
        if closed then
            return true
        end
        local ok <const>, reason = (writer as Writer):flush()
        closed = true
        bytes:close()
        return ok, reason
    end
    return writer as SeekableWriter
end

local record SlicingReaderState
    bytes: string | nil
    at: integer
    closed: boolean
end

--- A `Reader` over bytes already in memory, for the same reason.
local function slicingReader(bytes: string): SeekableReader
    local state <const>: SlicingReaderState = {bytes = bytes, at = 1, closed = false}
    local pointer <const> = ffi.cast("const uint8_t *", bytes) as loader.BytePointer

    local reader <const> = {} as {string: any}
    reader.read = function(_self: Reader, count: integer): string, string
        if state.closed then
            return nil, "the reader is closed"
        end
        local source <const> = state.bytes as string
        if state.at > #source then
            return ""
        end
        local last <const> = min(#source, state.at + max(1, count) - 1)
        local piece <const> = source:sub(state.at, last)
        state.at = last + 1
        return piece
    end
    reader.readInto = function(_self: Reader, destination: IOBuffer, count: integer, offset?: integer): integer, string
        if state.closed then
            return nil, "the reader is closed"
        end
        if type(count) ~= "number" or count ~= floor(count) or count < 0 then
            error("tecs: Reader:readInto count must be a non-negative integer", 2)
        end
        offset = offset or 0
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 then
            error("tecs: Reader:readInto offset must be a non-negative integer", 2)
        end
        local source <const> = state.bytes as string
        if count == 0 or state.at > #source then
            return 0
        end
        local taking <const> = min(count, #source - state.at + 1)
        local output <const>, previousLength = buffer.prepareWrite(destination, offset, taking)
        ffi.copy(output as ffi.CData, (pointer + (state.at - 1)) as ffi.CData, taking)
        buffer.commitWrite(destination, offset, taking, previousLength)
        state.at = state.at + taking
        return taking
    end
    reader.size = function(_self: SeekableReader): integer, string
        if state.closed then
            return nil, "the reader is closed"
        end
        return #(state.bytes as string)
    end
    reader.tell = function(_self: SeekableReader): integer, string
        if state.closed then
            return nil, "the reader is closed"
        end
        return state.at - 1
    end
    reader.seek = function(_self: SeekableReader, origin: SeekOrigin, offset?: integer): integer, string
        if state.closed then
            return nil, "the reader is closed"
        end
        if origin ~= "start" and origin ~= "current" and origin ~= "end" then
            error("tecs: SeekableReader:seek origin must be 'start', 'current', or 'end'", 2)
        end
        offset = offset or 0
        if type(offset) ~= "number" or offset ~= floor(offset) then
            error("tecs: SeekableReader:seek offset must be an integer", 2)
        end
        local base = 0
        if origin == "current" then
            base = state.at - 1
        elseif origin == "end" then
            base = #(state.bytes as string)
        end
        local position <const> = base + offset
        if position < 0 or position > #(state.bytes as string) then
            return nil, "seek position is outside the source"
        end
        state.at = position + 1
        return position
    end
    reader.close = function(_self: Reader) state.closed = true; state.bytes = nil end
    return reader as SeekableReader
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
function files.write(path: string, bytes: string): boolean, string
    required(path, "write")
    if bytes == nil then
        error("tecs: io.files.write needs bytes to write", 2)
    end
    return adapter.storage().write(path, bytes)
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
function files.writeAtomic(path: string, bytes: ByteInput): boolean, string
    required(path, "writeAtomic")
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
    return backend.writeAtomic(path, bytes)
end

--- Appends `bytes` to `path`, creating the file when absent.
---
--- The string's length controls the binary write, so embedded NUL bytes remain
--- data. The platform opens the destination in append mode instead of reading
--- and replacing it. The parent directory must already exist.
---
--- @param path The caller supplies the destination file.
--- @param bytes The caller supplies the binary contents to append.
--- @return Returns whether the platform appended every byte.
--- @return Returns the platform reason when the first return is false.
function files.append(path: string, bytes: string): boolean, string
    required(path, "append")
    if bytes == nil then
        error("tecs: io.files.append needs bytes to append", 2)
    end
    return adapter.storage().append(path, bytes)
end

--- Opens `path` for writing in pieces.
---
--- Use it when bytes arrive over time and should not become one large string.
--- The default `"replace"` mode replaces the destination. `"append"` keeps
--- its existing bytes and creates the file when it does not exist.
---
--- Close it. The bytes are not guaranteed to be on disk until `close` answers,
--- and this call reports a full disk.
---
--- @param path The caller supplies the destination file.
--- @param mode The caller selects `"replace"` or `"append"`, or omits it to
---     replace the destination.
--- @return Returns a caller-owned writer, or nil when it cannot open.
--- @return Returns the platform reason when the first return is nil.
function files.openWrite(path: string, mode?: WriteMode): Writer, string
    required(path, "openWrite")
    mode = mode or "replace"
    if mode ~= "replace" and mode ~= "append" then
        error("tecs: io.files.openWrite mode must be 'replace' or 'append'", 2)
    end
    local backend <const> = adapter.storage()
    if backend.openWrite ~= nil then
        return backend.openWrite(path, mode)
    end
    return bufferedWriter(backend, path, mode)
end

--- Opens `path` for writing through a repositionable cursor.
---
--- `"replace"` creates or truncates the file and starts at byte zero.
--- `"update"` requires an existing file, preserves its bytes, and also starts
--- at byte zero. Writes replace bytes at the cursor and extend the file when
--- they reach its end. Seek positions stay within the current file, so this
--- operation does not create sparse holes.
---
--- Close the writer even after the last write succeeds. The close flushes
--- buffered bytes and is where a delayed full-disk failure may be reported.
--- The SDL backend writes and seeks the file directly. A platform backend
--- without random-access output uses an in-memory fallback and writes the
--- complete result on `flush` or `close`.
---
--- @param path The caller supplies the destination file.
--- @param mode The caller selects `"replace"` or `"update"`, or omits it to
---     replace the destination.
--- @return Returns a caller-owned
---     [`SeekableWriter`](tealdoc:tecs.io.SeekableWriter), or nil when it
---     cannot open the file.
--- @return Returns the platform reason when the first return is nil.
function files.openSeekableWrite(path: string, mode?: SeekableWriteMode): SeekableWriter, string
    required(path, "openSeekableWrite")
    mode = mode or "replace"
    if mode ~= "replace" and mode ~= "update" then
        error("tecs: io.files.openSeekableWrite mode must be 'replace' or 'update'", 2)
    end
    local backend <const> = adapter.storage()
    if backend.openSeekableWrite ~= nil then
        return backend.openSeekableWrite(path, mode)
    end
    return bufferedSeekableWriter(backend, path, mode)
end

--- Opens `path` for reading in pieces through a repositionable cursor.
---
--- `read` is the right call for a file a program wants whole. This is for one
--- it wants to consume incrementally without first asking the filesystem for
--- one string containing the whole file. The SDL backend reads and seeks the
--- file directly. A platform backend without `openRead` falls back to its
--- whole-file `read` and retains that string until this reader closes.
---
--- @param path The caller supplies the source file.
--- @return Returns a caller-owned
---     [`SeekableReader`](tealdoc:tecs.io.SeekableReader) at byte zero, or nil
---     when the platform cannot open the file.
--- @return Returns the platform reason when the first return is nil.
function files.openRead(path: string): SeekableReader, string
    required(path, "openRead")
    local backend <const> = adapter.storage()
    if backend.openRead ~= nil then
        return backend.openRead(path)
    end
    local bytes <const> = backend.read(path)
    if bytes == nil then
        return nil, ("cannot read %s"):format(path)
    end
    return slicingReader(bytes)
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
