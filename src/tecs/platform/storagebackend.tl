--[=[
The storage half of the platform seam: reaching a file, not finding one.

`adapter` names storage as a seam because a console's content is not a
directory tree. Half of that seam was already here, as `basePath` and
`prefPath`, which answer *where*. This is the other half, which answers
*how*, and without it the first half is a promise the engine cannot keep: a
platform can say its content lives at `/host0/title/` and every read of a
path under it still goes through `SDL_LoadFile`.

`filesystem` holds one of these and never reaches the FFI itself. A port
supplies one and touches nothing above it; the SDL implementation below is
the worked example, and the only thing in the storage layer that names an
SDL symbol.

## Path interface

SDL's own answer for a target whose content is not a filesystem is
`SDL_Storage`, and the objection to putting it behind a path-taking API is
that its paths are a different space: relative to a storage root, always
`/`-separated, never absolute. That objection dissolves once the roots are
the platform's, which they already are. Every path that reaches a backend
was built by resolving against `basePath` or `prefPath`, which the same
platform minted, so a port that answers `""` for its base and hands out
storage-relative paths receives exactly those paths back. The engine
concatenates and never interprets, which is why there is no virtual
filesystem here and no mount table.

A path the platform did not mint, one a user typed or one from an
absolute location, is passed through unchanged and the backend decides what
it means. On SDL that is the operating system's answer; on a port with no
filesystem it is a failure, which is the correct answer and not one this
layer should invent.

## SDL filesystem backend

The SDL backend below calls `SDL_LoadFile`, `SDL_GlobDirectory` and their
neighbors directly, not `SDL_OpenFileStorage`. Storage has a readiness
model a path call does not: it opens immediately and is unusable until
`SDL_StorageReady` says so, which on a console can be after a mount or a
download completes. On a machine where every backing it can have is the
plain filesystem, a spec would only ever exercise the ready-immediately path
and would prove nothing about the model that is the reason to have it.

So `SDL_Storage` belongs to whichever backend needs it, which is the point
of the seam. A port whose content is a title storage writes those calls, its
readiness wait included, in a module the engine never sees.

## Port contract

Eight functions that take a path, two that open one for streaming, and two
that ask about the host. The eight are required and are called without
checking. `currentDirectory` and `userFolder` are optional and answer nil
with a reason when the platform has no such notion, which is already what
SDL answers for a folder a desktop does not have, so a caller that handled
SDL's nil handles a port's. `openWrite` and `openRead` are optional in a
different sense: `filesystem` builds both out of `write` and `read` when a
backend leaves them out, so every caller has them and only the memory a
large file costs differs.

Nothing here validates its arguments. `filesystem` does that before it
delegates, so a port inherits it rather than repeating it.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local type iotypes = require("tecs.io.types")

local C <const> = sdl.C

local type Reader = iotypes.Reader
local type Writer = iotypes.Writer

--- What a path is. Symbolic links are followed where the platform has them, so
--- a link never reports as one: "other" is a socket, a fifo or a device.
local enum PathType
    "file"
    "directory"
    "other"
end

--- What a backend answered about one path.
local record Info
    kind: PathType
    --- Size in bytes. Zero for a directory.
    size: integer
    --- Nanoseconds since the epoch, as a double. Zero where the platform or
    --- the filesystem does not record a creation time.
    createdAt: number
    modifiedAt: number
    accessedAt: number
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

--- How a pattern is matched.
local record GlobOptions
    --- Match without regard to case. Defaults to false, which is a
    --- case-sensitive match on every platform including the ones whose
    --- filesystem is not.
    caseInsensitive: boolean
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
    --- Opens `path` for writing in pieces, replacing whatever was there.
    ---
    --- Optional. A platform that leaves it nil gets a writer `filesystem`
    --- builds out of `write`, which holds the pieces and writes once, so the
    --- interface is the same everywhere and only the memory differs.
    openWrite: function(path: string): Writer, string
    --- Opens `path` for reading in pieces.
    ---
    --- Optional, with the same fallback in terms of `read`.
    openRead: function(path: string): Reader, string
    --- What is at `path`, or nil and the reason there is nothing to describe.
    info: function(path: string): Info, string
    --- Entries under `path` matching `pattern`, as paths relative to `path`.
    --- A nil pattern walks the whole tree. `*` and `?` do not match a
    --- separator, so `"*"` is one level. Nil and a reason when `path` cannot
    --- be enumerated, which is not the same answer as an empty list.
    glob: function(path: string, pattern: string, options: GlobOptions): {string}, string
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
    --- one, so this is what `filesystem` checks a name against before it
    --- reaches a backend. Derived from the one table of them below, so there
    --- is no second list to drift.
    folders: {UserFolder: boolean}
    --- How `Backend.glob` matches.
    GlobOptions: GlobOptions
    --- A write taking its bytes in pieces. Kept as an alias of
    --- [`tecs.io.Writer`](tealdoc:tecs.io.Writer) for backend compatibility.
    Writer: Writer
    --- A read handing its bytes over in pieces. Kept as an alias of
    --- [`tecs.io.Reader`](tealdoc:tecs.io.Reader) for backend compatibility.
    Reader: Reader
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

local CASE_INSENSITIVE <const> = sdl.K.SDL_GLOB_CASEINSENSITIVE

local PATH_TYPES <const>: {integer: PathType} = {
    [tonumber(C.SDL_PATHTYPE_FILE) as integer] = "file",
    [tonumber(C.SDL_PATHTYPE_DIRECTORY) as integer] = "directory",
    [tonumber(C.SDL_PATHTYPE_OTHER) as integer] = "other",
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

--- Opens an `SDL_IOStream` and wraps it as a `Writer`.
---
--- The stream is a closed-over local rather than a field, so a closed writer
--- has nothing left to call SDL with and says so instead of handing a freed
--- pointer back to the library.
local function sdlWriter(path: string): Writer, string
    local stream = C.SDL_IOFromFile(path, "wb") as loader.CPtr
    if stream == nil then
        return nil, sdl.error()
    end

    local writer <const>: Writer = {}
    writer.write = function(_self: Writer, bytes: string): boolean, string
        if stream == nil then
            return false, "the writer is closed"
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
    writer.close = function(_self: Writer): boolean, string
        if stream == nil then
            return true
        end
        local held <const> = stream
        stream = nil
        -- SDL flushes here, so a full disk is reported by this call and by
        -- nothing before it.
        if not C.SDL_CloseIO(held) then
            return false, sdl.error()
        end
        return true
    end
    return writer
end

--- Opens an `SDL_IOStream` and wraps it as a `Reader`.
local function sdlReader(path: string): Reader, string
    local stream = C.SDL_IOFromFile(path, "rb") as loader.CPtr
    if stream == nil then
        return nil, sdl.error()
    end

    -- Grown to the largest read asked for and kept, so a reader driven in
    -- equal chunks allocates once rather than once a chunk.
    local buffer: loader.CArray = nil
    local capacity = 0

    local reader <const>: Reader = {}
    reader.read = function(_self: Reader, count: integer): string, string
        if stream == nil then
            return nil, "the reader is closed"
        end
        local wanted <const> = math.max(1, count)
        if wanted > capacity then
            buffer = loader.newArray("char[?]", wanted)
            capacity = wanted
        end
        local got <const> = tonumber(C.SDL_ReadIO(stream, buffer, wanted)) as integer
        if got <= 0 then
            -- Zero is the end of the file or a failure, and only the status
            -- tells them apart.
            if tonumber(C.SDL_GetIOStatus(stream)) == tonumber(C.SDL_IO_STATUS_ERROR) then
                return nil, sdl.error()
            end
            return ""
        end
        return loader.toBytes(buffer as loader.CValue, got)
    end
    reader.close = function(_self: Reader)
        if stream == nil then
            return
        end
        local held <const> = stream
        stream = nil
        C.SDL_CloseIO(held)
    end
    return reader
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

    openWrite = sdlWriter,
    openRead = sdlReader,

    info = function(path: string): Info, string
        if not C.SDL_GetPathInfo(path, INFO) then
            return nil, sdl.error()
        end
        return {
            kind = PATH_TYPES[tonumber(FIELDS.type) as integer],
            size = tonumber(FIELDS.size) as integer,
            createdAt = tonumber(FIELDS.create_time),
            modifiedAt = tonumber(FIELDS.modify_time),
            accessedAt = tonumber(FIELDS.access_time),
        }
    end,

    glob = function(path: string, pattern: string, options: GlobOptions): {string}, string
        local flags = 0
        if options ~= nil and options.caseInsensitive then
            flags = CASE_INSENSITIVE
        end

        local list = C.SDL_GlobDirectory(path, pattern, flags, countOut)
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
