--[=[
The storage half of the platform seam: reaching a file, not finding one.

`adapter` names storage as a seam because a console's content is not a
directory tree. `basePath`, `prefPath` and `cachePath` answer *where*, while
this backend answers *how*. A platform can therefore place content at
`/host0/title/`
without forcing every read through `SDL_LoadFile`.

`tecs.io.files` holds one of these and never reaches the FFI itself. A port
supplies one and touches nothing above it; the SDL implementation below is
the worked example, and the only thing in the storage layer that names an
SDL symbol.

## Path interface

SDL's own answer for a target whose content is not a filesystem is
`SDL_Storage`, and the objection to putting it behind a path-taking API is
that its paths are a different space: relative to a storage root, always
`/`-separated, never absolute. That objection dissolves once the roots are
the platform's, which they already are. Every path that reaches a backend
was built by resolving against `basePath`, `prefPath` or `cachePath`, which
the same platform minted, so a port that answers `""` for its base and hands
out storage-relative paths receives exactly those paths back. The engine
concatenates and never interprets, which is why there is no virtual filesystem
here and no mount table.

A path the platform did not mint, one a user typed or one from an
absolute location, is passed through unchanged and the backend decides what
it means. On SDL that is the operating system's answer; on a port with no
filesystem it is a failure, which is the correct answer and not one this
layer should invent.

## SDL filesystem backend

The SDL backend below calls `SDL_LoadFile`, `SDL_GlobDirectory` and their
neighbors directly, not `SDL_OpenFileStorage`. Rust's filesystem metadata
answers whether the final path itself is a symbolic link because SDL follows
it. Both stay inside this backend. Storage has a readiness model a path call
does not: it opens immediately and is unusable until `SDL_StorageReady` says
so, which on a console can be after a mount or a download completes. On a
machine where every backing it can have is the plain filesystem, a spec would
only ever exercise the ready-immediately path and would prove nothing about
the model that is the reason to have it.

So `SDL_Storage` belongs to whichever backend needs it, which is the point
of the seam. A port whose content is a title storage writes those calls, its
readiness wait included, in a module the engine never sees.

## Port contract

The core path operations are required and are called without checking.
`currentDirectory` and `userFolder` are optional and answer nil
with a reason when the platform has no such notion, which is already what
SDL answers for a folder a desktop does not have, so a caller that handled
SDL's nil handles a port's. `open` is optional in a different sense:
`tecs.io.files` builds a file cursor out of `write`, `append`, and `read` when
a backend leaves it out. Every caller has the same operation, and only the
memory a large file costs differs.

Symbolic-link creation and reading, portable read-only mutation, and temporary
resources are optional platform capabilities. The public module reports an
unsupported reason when a backend leaves one out. Enumeration streams need no
extra seam: they pull one level at a time through the required `list` operation.

`writeAtomic` is optional without a fallback. A title storage may have a
transaction or commit operation that provides the same guarantee, but
`write` followed by `rename` cannot synthesize durability or preserve the
destination through every failure. A backend that cannot provide the contract
leaves it nil and `tecs.io.files.writeAtomic` reports that it is unsupported.

Nothing here validates its arguments. `tecs.io.files` does that before it
delegates, so a port inherits it rather than repeating it.
]=]

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local buffer <const> = require("tecs.io.buffer")
local type types = require("tecs.io.types")

local DEFAULT_READ_BYTES <const> = 16 * 1024

local C <const> = sdl.C
local R <const> = rust.C
local floor <const> = math.floor
local max <const> = math.max

local type Reader = types.Reader
local type SeekOrigin = types.Seekable.Origin
local type Writer = types.Writer
local type SeekableWriter = types.SeekableWriter
local type IOBuffer = types.Buffer
local type ByteView = types.ByteView
-- Buffer structurally satisfies ByteView's read-only byte-range operations.
-- Naming one table side keeps Teal able to discriminate the union while both
-- public types pass it without a copy.
local type ByteInput = string | ByteView

--- An operating-system temporary path owned by the storage backend.
local record TemporaryPath
    path: string
    handle: loader.CPtr
    persist: function(self: TemporaryPath, destination: string): boolean, string
    close: function(self: TemporaryPath): boolean, string
end

--- What a path is. Symbolic links are followed where the platform has them, so
--- a link never reports as one: "other" is a socket, a fifo or a device.
local enum PathType
    "file"
    "directory"
    "other"
end

--- What a backend answered about one path.
local record Info
    --- Read-only. Identifies the resolved platform object's kind.
    kind: PathType
    --- Read-only. Reports size in bytes. Zero for a directory.
    size: integer
    --- Read-only. Reports nanoseconds since the epoch as a double. Zero means
    --- the platform or filesystem does not record a creation time.
    createdAt: number
    --- Read-only. Reports modification time in nanoseconds since the epoch.
    modifiedAt: number
    --- Read-only. Reports access time in nanoseconds since the epoch.
    accessedAt: number
    --- Read-only. Reports the portable read-only state of the resolved path.
    readOnly: boolean
end

--- Which of the platform's well-known folders to ask for.
local enum UserFolder
    "home"
    "desktop"
    "documents"
    "downloads"
    "music"
    "pictures"
    "publicShare"
    "savedGames"
    "screenshots"
    "templates"
    "videos"
end

--- How a file cursor opens its destination.
local enum FileMode
    "r"
    "w"
    "a"
    "r+"
    "w+"
    "a+"
end

--- A seekable file cursor shared by the public files module and its backend.
local interface File is types.SeekableReader, types.SeekableWriter
end

local record Backend
    --- Name this backend reports as. For diagnostics; it is not matched
    --- against.
    name: string

    --- Whole contents of a file, or nil when there is nothing readable there.
    --- Bytes rather than text: the result carries its own length, so a NUL in
    --- the middle of it is a byte like any other.
    read: function(path: string): string
    --- Writes `bytes` to `path`, replacing whatever was there. The parent is
    --- not created.
    write: function(path: string, bytes: string): boolean, string
    --- Durably writes `bytes` and atomically replaces `path`.
    ---
    --- Optional. There is deliberately no fallback in terms of `write` and
    --- `rename`, because those operations cannot provide this contract.
    writeAtomic: function(path: string, bytes: ByteInput): boolean, string
    --- Appends `bytes` to `path`, creating the file when absent. The parent is
    --- not created.
    append: function(path: string, bytes: string): boolean, string
    --- Opens `path` with one standard read, write, append, or update mode.
    ---
    --- Optional. `tecs.io.files` supplies an in-memory cursor built from the
    --- required whole-file operations when a backend leaves it nil.
    open: function(path: string, mode: FileMode): File, string
    --- What is at `path`, or nil and the reason there is nothing to describe.
    info: function(path: string): Info, string
    --- Whether the final path itself is a symbolic link. Parent links are
    --- followed.
    isSymlink: function(path: string): boolean
    --- Returns the target spelling stored in a symbolic link. Optional.
    readLink: function(path: string): string, string
    --- Creates a file or directory symbolic link. Optional.
    createSymlink: function(target: string, link: string, directory: boolean): boolean, string
    --- Changes the portable read-only state. Optional.
    setReadOnly: function(path: string, readOnly: boolean): boolean, string
    --- Names directly under `path`. Nil and a reason when `path` cannot be
    --- enumerated, which is not the same answer as an empty list.
    list: function(path: string): {string}, string
    --- Creates `path` and any parents it needs. Succeeds on one that is
    --- already there.
    createDirectory: function(path: string): boolean, string
    --- Removes a file or an empty directory. Succeeds when there is nothing
    --- there, since the result says the path is gone rather than that this
    --- call is what removed it.
    remove: function(path: string): boolean, string
    --- Moves `from` to `to`, replacing whatever was at `to`.
    rename: function(from: string, to: string): boolean, string
    --- Copies the file at `from` to `to`, replacing whatever was at `to`.
    --- Files only.
    copy: function(from: string, to: string): boolean, string

    --- Creates an exclusively owned temporary file. Optional.
    createTemporaryFile: function(directory: string, prefix: string, suffix: string): TemporaryPath, string
    --- Creates an exclusively owned temporary directory. Optional.
    createTemporaryDirectory: function(directory: string, prefix: string, suffix: string): TemporaryPath, string

    --- The process working directory, with a trailing separator. Optional: a
    --- platform with no such notion leaves it nil and callers get nil and a
    --- reason.
    currentDirectory: function(): string, string
    --- One of the platform's well-known folders, with a trailing separator.
    --- Optional, and nil for an individual folder is a correct answer even
    --- when it is supplied.
    userFolder: function(which: UserFolder): string, string
end

local record storagebackend
    --- What a path is.
    PathType: PathType
    --- What `Backend.info` answers.
    Info: Info
    --- Which well-known folder `Backend.userFolder` is asked for.
    UserFolder: UserFolder
    --- Every folder name there is. An enum is gone by the time a caller names
    --- one, so this is what `tecs.io.files` checks a name against before it
    --- reaches a backend. Derived from the one table of them below, so there
    --- is no second list to drift.
    folders: {UserFolder: boolean}
    --- How `Backend.open` opens its file cursor.
    FileMode: FileMode
    --- The internal cursor contract returned by `Backend.open`.
    File: File
    --- Complete bytes accepted by an atomic write without an intermediate copy.
    ByteInput: ByteInput
    --- An internal temporary resource returned by a backend.
    TemporaryPath: TemporaryPath
    --- The seam a port implements.
    Backend: Backend
    --- The SDL backend, and the default everywhere.
    sdl: Backend
end

--- One scratch struct and one scratch cell. Every reader below fills one and
--- reads it before the next call, and none of them calls another, so there is
--- nothing here for a second use to overlap with.
local INFO <const> = loader.newStruct("SDL_PathInfo")
local FIELDS <const> = INFO as {string: any}
local countOut <const> = loader.newArray("int[1]")

local PATH_TYPES <const>: {integer: PathType} = {
    [tonumber(C.SDL_PATHTYPE_FILE) as integer] = "file",
    [tonumber(C.SDL_PATHTYPE_DIRECTORY) as integer] = "directory",
    [tonumber(C.SDL_PATHTYPE_OTHER) as integer] = "other",
}

local SEEK_ORIGINS <const>: {SeekOrigin: loader.CValue} = {
    start = C.SDL_IO_SEEK_SET,
    current = C.SDL_IO_SEEK_CUR,
    ["end"] = C.SDL_IO_SEEK_END,
}

local SDL_FILE_MODES <const>: {FileMode: string} = {
    r = "rb",
    w = "wb",
    a = "ab",
    ["r+"] = "r+b",
    ["w+"] = "w+b",
    ["a+"] = "a+b",
}

local FOLDERS <const>: {UserFolder: loader.CValue} = {
    home = C.SDL_FOLDER_HOME,
    desktop = C.SDL_FOLDER_DESKTOP,
    documents = C.SDL_FOLDER_DOCUMENTS,
    downloads = C.SDL_FOLDER_DOWNLOADS,
    music = C.SDL_FOLDER_MUSIC,
    pictures = C.SDL_FOLDER_PICTURES,
    publicShare = C.SDL_FOLDER_PUBLICSHARE,
    savedGames = C.SDL_FOLDER_SAVEDGAMES,
    screenshots = C.SDL_FOLDER_SCREENSHOTS,
    templates = C.SDL_FOLDER_TEMPLATES,
    videos = C.SDL_FOLDER_VIDEOS,
}

storagebackend.folders = {}
for name in pairs(FOLDERS) do
    storagebackend.folders[name] = true
end

--- Converts a string SDL allocated and frees it.
---
--- The generated cdef says which returns are owed this: `SDL_GetCurrentDirectory`
--- hands back `char *` and the caller frees it, while `SDL_GetUserFolder` hands
--- back `const char *` that belongs to SDL and must not be freed. The
--- constness in the binding is the ownership, and `adapter` reads
--- `SDL_GetBasePath` and `SDL_GetPrefPath` under the same rule.
local function take(pointer: loader.CValue): string
    if pointer == nil then
        return nil
    end
    local text = loader.toString(pointer)
    C.SDL_free(pointer)
    return text
end

--- Borrows complete bytes for the duration of one synchronous native call.
local function byteRange(bytes: ByteInput): loader.BytePointer, integer
    if type(bytes) == "string" then
        local text <const> = bytes as string
        return ffi.cast("uint8_t *", text) as loader.BytePointer, #text
    end
    local input <const> = bytes as ByteView
    return input:getFFIPointer(), input:length()
end

--- Copies a Rust-owned byte result and releases it.
local function takeRustBytes(handle: loader.CPtr): string
    if handle == nil then
        return nil
    end
    local length <const> = tonumber(R.tecsBytesLength(handle)) as integer
    local value <const> = loader.toBytes(R.tecsBytesData(handle), length)
    R.tecsBytesDestroy(handle)
    return value
end

local TEMPORARY_MT <const>: metatable<TemporaryPath> = {__index = TemporaryPath}

function TemporaryPath:persist(destination: string): boolean, string
    if self.handle == nil then
        return false, "the temporary path is closed"
    end
    if not R.tecsTemporaryPathPersist(self.handle, destination, #destination) then
        return false, loader.toString(R.tecsRustError())
    end
    local held <const> = self.handle
    self.handle = nil
    ffi.gc(held as ffi.CData, nil)
    R.tecsTemporaryPathDestroy(held)
    return true
end

function TemporaryPath:close(): boolean, string
    if self.handle == nil then
        return true
    end
    if not R.tecsTemporaryPathClose(self.handle) then
        return false, loader.toString(R.tecsRustError())
    end
    local held <const> = self.handle
    self.handle = nil
    ffi.gc(held as ffi.CData, nil)
    R.tecsTemporaryPathDestroy(held)
    return true
end

local function sdlTemporary(
    directory: string, prefix: string, suffix: string, isDirectory: boolean
): TemporaryPath, string
    local handle: loader.CPtr
    if isDirectory then
        handle = R.tecsTemporaryDirectoryCreate(directory, #directory, prefix, #prefix, suffix, #suffix)
    else
        handle = R.tecsTemporaryFileCreate(directory, #directory, prefix, #prefix, suffix, #suffix)
    end
    if handle == nil then
        return nil, loader.toString(R.tecsRustError())
    end
    handle = ffi.gc(handle as ffi.CData, R.tecsTemporaryPathDestroy as function(ffi.CData)) as loader.CPtr
    local pathHandle <const> = R.tecsTemporaryPathGet(handle)
    if pathHandle == nil then
        ffi.gc(handle as ffi.CData, nil)
        R.tecsTemporaryPathDestroy(handle)
        return nil, loader.toString(R.tecsRustError())
    end
    return setmetatable({path = takeRustBytes(pathHandle), handle = handle} as TemporaryPath, TEMPORARY_MT)
end

--- Opens an `SDL_IOStream` and wraps it as a file cursor.
---
--- The stream is a closed-over local rather than a field, so a closed writer
--- has nothing left to call SDL with and says so instead of handing a freed
--- pointer back to the library.
local function sdlFile(path: string, mode: FileMode): File, string
    local stream = C.SDL_IOFromFile(path, SDL_FILE_MODES[mode]) as loader.CPtr
    if stream == nil then
        return nil, sdl.error()
    end
    stream = ffi.gc(stream as ffi.CData, C.SDL_CloseIO as function(ffi.CData)) as loader.CPtr
    if mode == "a+" and tonumber(C.SDL_SeekIO(stream, 0, SEEK_ORIGINS.start)) < 0 then
        local reason <const> = sdl.error()
        ffi.gc(stream as ffi.CData, nil)
        C.SDL_CloseIO(stream)
        return nil, reason
    end

    local readable <const> = mode == "r" or mode == "r+" or mode == "w+" or mode == "a+"
    local writable <const> = mode ~= "r"
    local scratch: loader.CArray = nil
    local capacity = 0
    local lastDirection: string = nil

    local function prepareDirection(direction: string): boolean, string
        if lastDirection ~= nil and lastDirection ~= direction then
            if lastDirection == "write" and not C.SDL_FlushIO(stream) then
                return false, sdl.error()
            end
            local position <const> = tonumber(C.SDL_TellIO(stream)) as integer
            if position < 0 or tonumber(C.SDL_SeekIO(stream, position, SEEK_ORIGINS.start)) < 0 then
                return false, sdl.error()
            end
        end
        lastDirection = direction
        return true
    end

    local writer <const> = {} as {string: any}
    writer.read = function(_self: Reader, count: integer): string, string
        if stream == nil then
            return nil, "the file is closed"
        end
        if not readable then
            return nil, "the file is not open for reading"
        end
        local ready <const>, reason = prepareDirection("read")
        if not ready then
            return nil, reason
        end
        local wanted <const> = max(1, count)
        if wanted > capacity then
            scratch = loader.newArray("char[?]", wanted)
            capacity = wanted
        end
        local got <const> = tonumber(C.SDL_ReadIO(stream, scratch, wanted)) as integer
        if got <= 0 then
            if tonumber(C.SDL_GetIOStatus(stream)) == tonumber(C.SDL_IO_STATUS_ERROR) then
                return nil, sdl.error()
            end
            return ""
        end
        return loader.toBytes(scratch as loader.CValue, got)
    end

    writer.readInto = function(_self: Reader, destination: IOBuffer, offset?: integer, count?: integer): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        if not readable then
            return nil, "the file is not open for reading"
        end
        local ready <const>, reason = prepareDirection("read")
        if not ready then
            return nil, reason
        end
        offset = offset or 0
        count = count or DEFAULT_READ_BYTES
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 then
            error("tecs: Reader:readInto offset must be a non-negative integer", 2)
        end
        if type(count) ~= "number" or count ~= floor(count) or count < 0 then
            error("tecs: Reader:readInto count must be a non-negative integer", 2)
        end
        if count == 0 then
            return 0
        end
        local output <const>, previousLength = buffer.prepareWrite(destination, offset, count)
        local got <const> = tonumber(C.SDL_ReadIO(stream, output, count)) as integer
        if got <= 0 then
            buffer.commitWrite(destination, offset, 0, previousLength)
            if tonumber(C.SDL_GetIOStatus(stream)) == tonumber(C.SDL_IO_STATUS_ERROR) then
                return nil, sdl.error()
            end
            return 0
        end
        buffer.commitWrite(destination, offset, got, previousLength)
        return got
    end

    writer.write = function(_self: Writer, bytes: string): boolean, string
        if stream == nil then
            return false, "the file is closed"
        end
        if not writable then
            return false, "the file is not open for writing"
        end
        local ready <const>, reason = prepareDirection("write")
        if not ready then
            return false, reason
        end
        local length <const> = #bytes
        if length == 0 then
            return true
        end
        local written <const> = tonumber(C.SDL_WriteIO(stream, bytes, length)) as integer
        if written < length then
            return false, sdl.error()
        end
        return true
    end

    writer.writeFrom = function(
        _self: Writer, sourceBuffer: IOBuffer, offset?: integer, count?: integer
    ): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        if not writable then
            return nil, "the file is not open for writing"
        end
        local ready <const>, reason = prepareDirection("write")
        if not ready then
            return nil, reason
        end
        offset = offset or 0
        local length <const> = sourceBuffer:length()
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > length then
            error("tecs: Writer:writeFrom offset is outside the buffer", 2)
        end
        if count == nil then
            count = length - offset
        elseif type(count) ~= "number" or count ~= floor(count) or count < 0 or count > length - offset then
            error("tecs: Writer:writeFrom count is outside the buffer", 2)
        end
        if count == 0 then
            return 0
        end
        local pointer <const> = sourceBuffer:getFFIPointer() + offset
        local written <const> = tonumber(C.SDL_WriteIO(stream, pointer, count)) as integer
        if written == 0 and tonumber(C.SDL_GetIOStatus(stream)) == tonumber(C.SDL_IO_STATUS_ERROR) then
            return nil, sdl.error()
        end
        return written
    end

    writer.writeView = function(_self: Writer, sourceView: ByteView, offset?: integer, count?: integer): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        if not writable then
            return nil, "the file is not open for writing"
        end
        local ready <const>, reason = prepareDirection("write")
        if not ready then
            return nil, reason
        end
        if sourceView == nil or sourceView:isReleased() then
            error("tecs: Writer:writeView needs an open io.ByteView", 2)
        end
        offset = offset or 0
        local length <const> = sourceView:length()
        if type(offset) ~= "number" or offset ~= floor(offset) or offset < 0 or offset > length then
            error("tecs: Writer:writeView offset is outside the view", 2)
        end
        if count == nil then
            count = length - offset
        elseif type(count) ~= "number" or count ~= floor(count) or count < 0 or count > length - offset then
            error("tecs: Writer:writeView count is outside the view", 2)
        end
        if count == 0 then
            return 0
        end
        local pointer <const> = sourceView:getFFIPointer() + offset
        local written <const> = tonumber(C.SDL_WriteIO(stream, pointer, count)) as integer
        if written == 0 and tonumber(C.SDL_GetIOStatus(stream)) == tonumber(C.SDL_IO_STATUS_ERROR) then
            return nil, sdl.error()
        end
        return written
    end

    writer.size = function(_self: SeekableWriter): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        local length <const> = tonumber(C.SDL_GetIOSize(stream)) as integer
        if length < 0 then
            return nil, sdl.error()
        end
        return length
    end

    writer.tell = function(_self: SeekableWriter): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        local position <const> = tonumber(C.SDL_TellIO(stream)) as integer
        if position < 0 then
            return nil, sdl.error()
        end
        return position
    end

    writer.seek = function(_self: SeekableWriter, origin: SeekOrigin, offset?: integer): integer, string
        if stream == nil then
            return nil, "the file is closed"
        end
        local whence <const> = SEEK_ORIGINS[origin]
        if whence == nil then
            error("tecs: File:seek origin must be 'start', 'current', or 'end'", 2)
        end
        offset = offset or 0
        if type(offset) ~= "number" or offset ~= floor(offset) then
            error("tecs: File:seek offset must be an integer", 2)
        end
        local length <const> = tonumber(C.SDL_GetIOSize(stream)) as integer
        if length < 0 then
            return nil, sdl.error()
        end
        local base = 0
        if origin == "current" then
            base = tonumber(C.SDL_TellIO(stream)) as integer
            if base < 0 then
                return nil, sdl.error()
            end
        elseif origin == "end" then
            base = length
        end
        local target <const> = base + offset
        if target < 0 or target > length then
            return nil, "seek position is outside the file"
        end
        local position <const> = tonumber(C.SDL_SeekIO(stream, target, SEEK_ORIGINS.start)) as integer
        if position < 0 then
            return nil, sdl.error()
        end
        lastDirection = nil
        return position
    end

    writer.flush = function(_self: Writer): boolean, string
        if stream == nil then
            return false, "the file is closed"
        end
        if not writable then
            return true
        end
        if not C.SDL_FlushIO(stream) then
            return false, sdl.error()
        end
        return true
    end

    writer.close = function(_self: Writer): boolean, string
        if stream == nil then
            return true
        end
        local held <const> = stream
        stream = nil
        ffi.gc(held as ffi.CData, nil)
        -- SDL flushes here, so a full disk is reported by this call and by
        -- nothing before it.
        if not C.SDL_CloseIO(held) then
            return false, sdl.error()
        end
        return true
    end
    return writer as File
end

--- One SDL call each, and nothing composed out of several.
---
--- A failure is SDL's failure, so the name of the call is what to read the
--- documentation for and the message beside a false is the operating system's
--- own. Nothing here raises for a filesystem outcome.
local sdlBackend <const>: Backend = {
    name = "sdl",

    read = function(path: string): string
        local size <const> = loader.newArray("size_t[1]")
        local data <const> = C.SDL_LoadFile(path, size)
        if data == nil then
            return nil
        end
        local bytes <const> = loader.toBytes(data, tonumber(size[0]) as integer)
        C.SDL_free(data)
        return bytes
    end,

    write = function(path: string, bytes: string): boolean, string
        if C.SDL_SaveFile(path, bytes, #bytes) then
            return true
        end
        return false, sdl.error()
    end,

    writeAtomic = function(path: string, bytes: ByteInput): boolean, string
        local pointer <const>, length = byteRange(bytes)
        if R.tecsFileWriteAtomic(path, #path, pointer, length) then
            return true
        end
        return false, loader.toString(R.tecsRustError())
    end,

    append = function(path: string, bytes: string): boolean, string
        local writer <const>, openReason = sdlFile(path, "a")
        if writer == nil then
            return false, openReason
        end
        local wrote <const>, writeReason = writer:write(bytes)
        local closed <const>, closeReason = writer:close()
        if not wrote then
            return false, writeReason
        end
        return closed, closeReason
    end,

    open = sdlFile,

    info = function(path: string): Info, string
        if not C.SDL_GetPathInfo(path, INFO) then
            return nil, sdl.error()
        end
        local readOnly <const> = tonumber(R.tecsPathIsReadOnly(path, #path)) as integer
        if readOnly < 0 then
            return nil, loader.toString(R.tecsRustError())
        end
        return {
            kind = PATH_TYPES[tonumber(FIELDS.type) as integer],
            size = tonumber(FIELDS.size) as integer,
            createdAt = tonumber(FIELDS.create_time),
            modifiedAt = tonumber(FIELDS.modify_time),
            accessedAt = tonumber(FIELDS.access_time),
            readOnly = readOnly == 1,
        }
    end,

    isSymlink = function(path: string): boolean return tonumber(R.tecsPathIsSymlink(path, #path)) == 1 end,

    readLink = function(path: string): string, string
        local handle <const> = R.tecsPathReadLink(path, #path)
        if handle == nil then
            return nil, loader.toString(R.tecsRustError())
        end
        return takeRustBytes(handle)
    end,

    createSymlink = function(target: string, link: string, directory: boolean): boolean, string
        if R.tecsPathCreateSymlink(target, #target, link, #link, directory) then
            return true
        end
        return false, loader.toString(R.tecsRustError())
    end,

    setReadOnly = function(path: string, readOnly: boolean): boolean, string
        if R.tecsPathSetReadOnly(path, #path, readOnly) then
            return true
        end
        return false, loader.toString(R.tecsRustError())
    end,

    list = function(path: string): {string}, string
        local list = C.SDL_GlobDirectory(path, "*", 0, countOut)
        if list == nil then
            return nil, sdl.error()
        end

        local found: {string} = {}
        local items = loader.castPointer("char **", list)
        local count = tonumber(countOut[0]) as integer
        for index = 0, count - 1 do
            found[index + 1] = loader.toString(items[index] as loader.CValue)
        end
        -- One allocation holds the array and every string it points at,
        -- exactly as the clipboard's mime list does, so one free releases all
        -- of it and freeing an entry would be a double free.
        C.SDL_free(list)
        return found
    end,

    createDirectory = function(path: string): boolean, string
        if C.SDL_CreateDirectory(path) then
            return true
        end
        return false, sdl.error()
    end,

    remove = function(path: string): boolean, string
        if C.SDL_RemovePath(path) then
            return true
        end
        return false, sdl.error()
    end,

    rename = function(from: string, to: string): boolean, string
        if C.SDL_RenamePath(from, to) then
            return true
        end
        return false, sdl.error()
    end,

    copy = function(from: string, to: string): boolean, string
        if C.SDL_CopyFile(from, to) then
            return true
        end
        return false, sdl.error()
    end,

    createTemporaryFile = function(directory: string, prefix: string, suffix: string): TemporaryPath, string
        return sdlTemporary(directory, prefix, suffix, false)
    end,

    createTemporaryDirectory = function(directory: string, prefix: string, suffix: string): TemporaryPath, string
        return sdlTemporary(directory, prefix, suffix, true)
    end,

    currentDirectory = function(): string, string
        local directory = take(C.SDL_GetCurrentDirectory())
        if directory == nil then
            return nil, sdl.error()
        end
        return directory
    end,

    userFolder = function(which: UserFolder): string, string
        local path = C.SDL_GetUserFolder(FOLDERS[which])
        if path == nil then
            return nil, sdl.error()
        end
        return loader.toString(path)
    end,
}

storagebackend.sdl = sdlBackend

return storagebackend
