--- Doing things to paths: listing, creating, removing, renaming, copying,
--- saving, and asking what is there.
---
--- `tecs.paths` answers *where*, and this answers *what to do once you have
--- one*. There is deliberately no second way to resolve a path here: every
--- function takes the string SDL takes, so `paths.writable("saves/slot1")`, a
--- path a user typed and an absolute path from somewhere else all work and none
--- of them is rewritten on the way through. No virtual filesystem, no mount
--- table, no invented scheme.
---
--- ## One SDL call each
---
--- ```
---  This module          SDL
---  ───────────────────  ─────────────────────
---  info                 SDL_GetPathInfo
---  exists               SDL_GetPathInfo
---  isFile               SDL_GetPathInfo
---  isDirectory          SDL_GetPathInfo
---  list                 SDL_GlobDirectory
---  glob                 SDL_GlobDirectory
---  createDirectory      SDL_CreateDirectory
---  remove               SDL_RemovePath
---  rename               SDL_RenamePath
---  copy                 SDL_CopyFile
---  write                SDL_SaveFile
---  currentDirectory     SDL_GetCurrentDirectory
---  userFolder           SDL_GetUserFolder
--- ```
---
--- Nothing is composed out of several calls and nothing is emulated, so a
--- failure is SDL's failure and the name in this table is what to read the
--- documentation for.
---
--- ## Reading is `assets.read`
---
--- There is no `read` here, and that is not an omission. `SDL_LoadFile` already
--- has a home in `assets.read`, which does one thing this module cannot: it
--- records the path under the kind it was read as, and `assets.loaded()` is the
--- set `watch` polls. A second reader would mean a file opened through the
--- wrong one is never reloaded, and nothing would point at which reader was
--- used as the reason.
---
--- Routing a `read` here through `assets.read` would fix that and cost more
--- than it is worth: `tecs.assets` loads SDL3_mixer at require time, so listing
--- a directory would drag the audio decoders in behind it and would fail
--- outright on a machine that has no mixer installed. So `write` is here,
--- `read` is one module along, and they are a pair across two files on purpose:
---
---     local tecs <const> = require("tecs")
---     local save <const> = tecs.paths.writable("slot1.json")
---     tecs.filesystem.write(save, tecs.json.encode(state))
---     local bytes <const> = tecs.assets.read(save)
---
--- ## Path info is the same answer `watch` gets
---
--- `info` fills the same `SDL_PathInfo` from the same `SDL_GetPathInfo` that
--- `watch` polls with, and reports the same numbers: a size in bytes and three
--- stamps in nanoseconds since the epoch, carried as doubles. That rounds to
--- the nearest 256 nanoseconds at present-day values, which no filesystem
--- timestamp comes close to needing and is worth having in exchange for a plain
--- number rather than a boxed 64-bit integer.
---
--- `SDL_GetPathInfo` follows symbolic links, so a link to a file reports "file"
--- and a link to nothing reports nothing at all. "other" is what is left: a
--- socket, a fifo, a device node.
---
--- ## Enumeration is glob, and there is no callback
---
--- SDL offers two ways to walk a directory. `SDL_EnumerateDirectory` takes a
--- function pointer it calls per entry; `SDL_GlobDirectory` allocates a list
--- and returns it. This module uses glob exclusively and never installs an FFI
--- callback.
---
--- The callback would in fact be the safe kind: it fires synchronously inside
--- the call and is not retained past it, unlike the clipboard's data offer,
--- which SDL keeps and enters at a moment this process does not choose. But it
--- buys nothing here. A LuaJIT FFI callback is a trampoline allocated from a
--- small, process-wide pool, entering Lua from C aborts the enclosing trace,
--- and an error raised inside one cannot unwind through the C frame that called
--- it, so a handler that raises has to be wrapped anyway. Against that, glob
--- answers the same entries in one allocation this module already knows how to
--- free. `physics.TaskPool` keeps its callbacks native for the harder version
--- of the same reason; the cheap version applies here.
---
--- What that costs is that the whole result exists before the first entry is
--- seen, so a directory with a million entries is a million Lua strings. That
--- is the honest trade and there is no streaming form of it.
---
--- **`SDL_GlobDirectory` recurses, and the pattern is what stops it.** This is
--- the surprise worth knowing before anything else here:
---
--- * `glob(dir)` with no pattern walks the *entire tree* and returns every
---   descendant, as paths relative to `dir` joined with `/`.
--- * `glob(dir, "*")` returns only the immediate children, because `*` and `?`
---   never match a path separator. That is what `list` is.
--- * `glob(dir, "*/*.png")` reaches exactly one level down.
---
--- Directories are included alongside files and are not marked; ask `info`
--- about the ones you care about. The order is the directory's own, as the
--- platform reports it, and is not sorted and not stable across machines; sort
--- it if you need it to be.
---
--- ## SDL's semantics, documented rather than smoothed over
---
--- * `createDirectory` creates missing parents, and succeeds on a directory
---   that already exists. It also **leaves an SDL error string set even when it
---   succeeds**, because it tries, fails, makes the parents and tries again.
---   Nothing here clears it, since clearing SDL's error is as global a side
---   effect as setting it; read the second return value of these functions
---   rather than `SDL_GetError` after them.
--- * `remove` takes a file or an **empty** directory and does not recurse.
--- * `remove` **succeeds when there is nothing there**. It reports that the
---   path is gone, not that it did something. Ask `exists` first if the
---   difference matters.
--- * `rename` and `copy` **overwrite an existing destination** without asking.
---   `rename` moves directories; `copy` refuses one.
--- * `copy` and `write` do **not** create the destination's parent directory.
---   `createDirectory` first.
--- * `userFolder` genuinely has no answer for some folders on some platforms;
---   macOS has no saved-games, screenshots or templates folder, and says so.
---   Handle nil.
---
--- ## Failure is a value
---
--- Nothing here raises for a filesystem outcome. Every function answers a
--- status, and every failing one puts `SDL_GetError` beside it as its second
--- return, so the message a caller shows is the operating system's own. Only a
--- missing or non-string path raises, because that is a defect in the calling
--- program rather than something the filesystem did.
---
--- A failed enumeration answers nil rather than an empty list, so "this
--- directory is empty" and "this directory could not be opened" stay apart.
---
--- ## Blocking, and what to do about it
---
--- **Every function here is synchronous and blocks the calling thread.** That
--- is the whole story for stage one, and it is a different answer from the two
--- neighbours that went the other way, so here is why.
---
--- `proc` runs children on a worker because a child blocks for another
--- program's lifetime, which is unbounded and is exactly what a frame must not
--- wait for. `assets` decodes on a worker because a PNG is milliseconds of
--- pure CPU. A path call is neither: it is one syscall against a mounted
--- device, and `watch` already measured `SDL_GetPathInfo` at 0.86 microseconds
--- on this machine, which is why it puts a hundred of them between frames twice
--- a second and does not notice.
---
--- The one call that is genuinely unbounded is a recursive `glob` over a large
--- tree, and `SDL_LoadFileAsync` is not the answer to it: that reads a file,
--- there is no asynchronous form of stat, enumerate, mkdir, remove, rename or
--- copy, and adding it would make one of eleven entry points non-blocking while
--- leaving the slow one exactly as it was, in exchange for a third asynchronous
--- lifecycle to pump beside `assets` and `proc`.
---
--- What does answer it is a worker, and this module needs no support for that.
--- Every function takes a path and returns a value, so nothing crosses a thread
--- that must not: there is no handle here of the kind that keeps `SDL_Process`
--- pinned to `proc`'s worker. Walking a tree off the main thread is
--- `workers.spawn` with a source that requires this module, and the answer
--- comes back as plain data.
---
--- ## `SDL_Storage` is not this, and is not here yet
---
--- `SDL_Storage` is SDL's abstraction for targets where content is not a
--- filesystem: a console's title storage, a bundle, a read-only mount. It is
--- not covered by stage one, for two reasons that are about it rather than
--- about effort.
---
--- It has a readiness model that a path call does not. A storage opens
--- immediately and is not usable until `SDL_StorageReady` says so, which on a
--- console can be after a download or a mount completes and every call before
--- then fails. On this machine every backing it can have is the plain
--- filesystem, so a spec here would only ever exercise the ready-immediately
--- path and would prove nothing about the model that is the reason to have it.
--- Building a surface whose one interesting property cannot be tested is how
--- that property ends up wrong.
---
--- And its paths are a different space: relative to the storage root, always
--- `/`-separated, never absolute, and not resolvable by `tecs.paths`. A single
--- function taking a path that might mean either would be the disguise this
--- module exists not to be.
---
--- **What adopting it later costs, and why this surface does not change shape.**
--- Every storage call is the twin of one above, with an `SDL_Storage *` in
--- front: `SDL_GlobStorageDirectory`, `SDL_GetStoragePathInfo`,
--- `SDL_CreateStorageDirectory`, `SDL_RemoveStoragePath`,
--- `SDL_RenameStoragePath`, `SDL_CopyStorageFile`, `SDL_WriteStorageFile`. So
--- the shape it wants is a `Storage` class whose methods are these functions
--- minus the module, and that composes with what is here rather than replacing
--- it, because:
---
--- * every function takes its path first and returns `(value, error)`, so a
---   method can return the same pair;
--- * `Info`, `PathType` and `GlobOptions` are filled from the same
---   `SDL_PathInfo` and the same `SDL_GlobFlags`, so a storage reuses them
---   rather than declaring parallel ones;
--- * `currentDirectory` and `userFolder` have no storage twin and are correctly
---   module-level, not methods;
--- * nothing here resolves a path, so nothing here has to learn that a storage
---   path means something else.
---
--- Two things it adds rather than changes: `ready`, `close` and
--- `spaceRemaining`, which have no path equivalent; and a `read`, because
--- `SDL_ReadStorageFile` fills a caller's buffer after
--- `SDL_GetStorageFileSize` and is not `SDL_LoadFile`, so `assets.read` cannot
--- reach a storage and the storage has to carry its own. That is the one
--- asymmetry the note above about reading does not already cover.
---
--- ## Headless
---
--- SDL's filesystem API needs no subsystem initialised, and nothing here
--- initialises one. There is no `available()` and no video gate, unlike
--- `clipboard`, because there is nothing to gate on: with no window, no device
--- and no `SDL_Init` at all, every function below answers for real. This is one
--- of the few subsystems that is more useful without a window than with one.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

local record filesystem
    --- What a path is, from `SDL_PathInfo.type`. Symbolic links are followed,
    --- so a link never reports as one: "other" is a socket, a fifo or a device.
    enum PathType
        "file"
        "directory"
        "other"
    end

    --- What `SDL_GetPathInfo` answered.
    record Info
        kind: PathType
        --- Size in bytes. Zero for a directory.
        size: integer
        --- Nanoseconds since the epoch, as a double. Zero where the platform
        --- or the filesystem does not record a creation time, which is common
        --- enough that this is the one of the three worth testing for.
        createdAt: number
        modifiedAt: number
        accessedAt: number
    end

    --- Which of the platform's well-known folders to ask for.
    enum UserFolder
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

    --- Passed straight to `SDL_GlobFlags`.
    record GlobOptions
        --- Match the pattern without regard to case. Optional; defaults to
        --- false, which is a case-sensitive match on every platform including
        --- the ones whose filesystem is not.
        caseInsensitive: boolean
    end
end

local type PathType = filesystem.PathType
local type Info = filesystem.Info
local type UserFolder = filesystem.UserFolder
local type GlobOptions = filesystem.GlobOptions

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

--- Raises when a required string argument is missing.
---
--- LuaJIT passes a Lua nil to a `const char *` parameter as a null pointer, so
--- a nil that reached SDL would be a call against an empty or invalid path
--- rather than an error anyone could trace back here. A path is the one thing
--- every function below needs, and a missing one is a defect in the caller.
local function required(value: string, what: string)
    if value == nil then
        error(("tecs: filesystem.%s needs a path"):format(what), 3)
    end
end

--- Converts a string SDL allocated and frees it.
---
--- The generated cdef says which returns are owed this: `SDL_GetCurrentDirectory`
--- hands back `char *` and the caller frees it, while `SDL_GetUserFolder` hands
--- back `const char *` that belongs to SDL and must not be freed. The
--- constness in the binding is the ownership, and `paths` reads
--- `SDL_GetBasePath` and `SDL_GetPrefPath` under the same rule.
local function take(pointer: loader.CValue): string
    if pointer == nil then return nil end
    local text = loader.toString(pointer)
    C.SDL_free(pointer)
    return text
end

--- Fills the scratch `SDL_PathInfo` for `path`.
local function look(path: string): boolean
    return C.SDL_GetPathInfo(path, INFO) as boolean
end

--- What is at `path`, or nil when there is nothing there.
---
--- `SDL_GetPathInfo`, and the same call and the same fields `watch` polls with.
--- Nil is the answer for a path that does not exist, for a broken symbolic
--- link, and for a directory that cannot be searched; the second return
--- separates them.
--- @return The info, or nil and the reason.
function filesystem.info(path: string): Info, string
    required(path, "info")
    if not look(path) then return nil, sdl.error() end
    return {
        kind = PATH_TYPES[tonumber(FIELDS.type) as integer],
        size = tonumber(FIELDS.size) as integer,
        createdAt = tonumber(FIELDS.create_time),
        modifiedAt = tonumber(FIELDS.modify_time),
        accessedAt = tonumber(FIELDS.access_time),
    }
end

--- Whether anything is at `path`.
---
--- The same `SDL_GetPathInfo` as `info`, so asking this and then `info` is two
--- syscalls; call `info` once and test it against nil when you want both.
function filesystem.exists(path: string): boolean
    required(path, "exists")
    return look(path)
end

--- Whether `path` is a regular file, following symbolic links.
function filesystem.isFile(path: string): boolean
    required(path, "isFile")
    if not look(path) then return false end
    return tonumber(FIELDS.type) == tonumber(C.SDL_PATHTYPE_FILE)
end

--- Whether `path` is a directory, following symbolic links.
function filesystem.isDirectory(path: string): boolean
    required(path, "isDirectory")
    if not look(path) then return false end
    return tonumber(FIELDS.type) == tonumber(C.SDL_PATHTYPE_DIRECTORY)
end

--- Entries under `path` matching `pattern`, as paths relative to `path`.
---
--- `SDL_GlobDirectory`. **Recursive unless the pattern stops it**: with no
--- pattern this walks the whole tree below `path` and returns every descendant,
--- joined with `/` whatever the platform's separator is. `*` and `?` never
--- match a separator, so `"*"` is one level, `"*/*"` is exactly two, and
--- `"*.png"` matches only immediate children. Directories are returned
--- alongside files and are not distinguished; ask `info`.
---
--- The order is the platform's own and is not sorted.
--- @param pattern `*` and `?` wildcards, or nil for everything, recursively.
--- @return The entries, or nil and the reason `path` could not be enumerated.
---     An empty list means an empty directory, which nil does not.
function filesystem.glob(path: string, pattern?: string,
                         options?: GlobOptions): {string}, string
    required(path, "glob")
    local flags = 0
    if options ~= nil and options.caseInsensitive then
        flags = CASE_INSENSITIVE
    end

    local list = C.SDL_GlobDirectory(path, pattern, flags, countOut)
    if list == nil then return nil, sdl.error() end

    local found: {string} = {}
    local items = loader.castPointer("char **", list)
    local count = tonumber(countOut[0]) as integer
    for index = 0, count - 1 do
        found[index + 1] = loader.toString(items[index] as loader.CValue)
    end
    -- One allocation holds the array and every string it points at, exactly as
    -- the clipboard's mime list does, so one free releases all of it and
    -- freeing an entry would be a double free.
    C.SDL_free(list)
    return found
end

--- Names directly inside `path`, not recursively.
---
--- `SDL_GlobDirectory` with a `"*"` pattern, which is what confines it to one
--- level. Names, not paths: join them to `path` yourself, which is also what
--- keeps this from being a second path resolver.
--- @return The names, or nil and the reason.
function filesystem.list(path: string): {string}, string
    required(path, "list")
    return filesystem.glob(path, "*")
end

--- Creates `path`, and any parents it needs.
---
--- `SDL_CreateDirectory`, which succeeds on a directory that already exists.
--- It also leaves an SDL error string behind on success, having tried once
--- before making the parents; that string is not returned here and nothing
--- clears it, so do not read `SDL_GetError` after a call that reported success.
function filesystem.createDirectory(path: string): boolean, string
    required(path, "createDirectory")
    if C.SDL_CreateDirectory(path) then return true end
    return false, sdl.error()
end

--- Removes a file, or an empty directory.
---
--- `SDL_RemovePath`. It does not recurse and fails on a directory with
--- anything in it. It **succeeds when there is nothing at `path`**: the result
--- says the path is gone, not that this call is what removed it.
---
--- Emptying a tree is a glob and a loop, deepest first, and is left to the
--- caller because SDL does not offer it and a recursive delete nobody asked
--- for is the wrong thing to find in a library:
---
---     local entries = filesystem.glob(root)
---     table.sort(entries, function(a, b) return #a > #b end)
---     for _, entry in ipairs(entries) do
---         filesystem.remove(root .. "/" .. entry)
---     end
---     filesystem.remove(root)
function filesystem.remove(path: string): boolean, string
    required(path, "remove")
    if C.SDL_RemovePath(path) then return true end
    return false, sdl.error()
end

--- Moves `from` to `to`, replacing whatever was at `to`.
---
--- `SDL_RenamePath`. Directories move as well as files, and an existing
--- destination is overwritten with no warning and nothing to undo it. Whether
--- this works across filesystems is the platform's business, not SDL's.
function filesystem.rename(from: string, to: string): boolean, string
    required(from, "rename")
    required(to, "rename")
    if C.SDL_RenamePath(from, to) then return true end
    return false, sdl.error()
end

--- Copies the file at `from` to `to`, replacing whatever was at `to`.
---
--- `SDL_CopyFile`. Files only: a directory is refused. The destination's parent
--- must already exist.
function filesystem.copy(from: string, to: string): boolean, string
    required(from, "copy")
    required(to, "copy")
    if C.SDL_CopyFile(from, to) then return true end
    return false, sdl.error()
end

--- Writes `bytes` to `path`, replacing whatever was there.
---
--- `SDL_SaveFile`. Binary: the string's own length is what is written, so a NUL
--- in the middle of it is a byte like any other and an empty string makes an
--- empty file. The parent directory must already exist.
---
--- The other half of this is `assets.read`, which is `SDL_LoadFile` plus the
--- record of what this process has opened that `watch` polls. See the note at
--- the top of this module for why the pair lives in two places.
function filesystem.write(path: string, bytes: string): boolean, string
    required(path, "write")
    if bytes == nil then
        error("tecs: filesystem.write needs bytes to write", 2)
    end
    if C.SDL_SaveFile(path, bytes, #bytes) then return true end
    return false, sdl.error()
end

--- The process working directory, with a trailing separator.
---
--- `SDL_GetCurrentDirectory`. Here because a command line tool is given
--- relative paths by whoever ran it and has to resolve them against something.
--- It is emphatically not where a game reads content from or writes state to:
--- `paths.assets` and `paths.pref` answer that, and say why.
--- @return The directory, or nil and the reason.
function filesystem.currentDirectory(): string, string
    local directory = take(C.SDL_GetCurrentDirectory())
    if directory == nil then return nil, sdl.error() end
    return directory
end

--- One of the platform's well-known folders, with a trailing separator.
---
--- `SDL_GetUserFolder`. The string belongs to SDL and is not freed here.
---
--- **Often nil, and legitimately so.** A platform that has no such concept says
--- so rather than inventing a path: macOS has no saved-games, screenshots or
--- templates folder and answers nil for all three. Treat every one of these as
--- absent until it is not, and never as a place a build may write; `paths.pref`
--- is the only such place.
--- @return The folder, or nil and the reason.
function filesystem.userFolder(which: UserFolder): string, string
    local folder = FOLDERS[which]
    if folder == nil then
        error(("tecs: filesystem.userFolder does not know '%s'")
            :format(tostring(which)), 2)
    end
    local path = C.SDL_GetUserFolder(folder)
    if path == nil then return nil, sdl.error() end
    return loader.toString(path)
end

return filesystem
