--- Files: where they are, what is in them, and when one changed.
---
--- Where and what are one module because they were never two questions. Every
--- path a game touches is resolved and then acted on in the same breath, and a
--- caller holding one half had to name the other to do anything with it.
---
--- ## Where a path comes from
---
--- Never the process working directory. On desktop that happens to work when
--- launched from a project root and breaks the moment someone double-clicks; on
--- mobile there is no meaningful working directory at all, and writing next to
--- the executable is not permitted. So the platform is asked, through
--- `adapter`, which is the seam a licensed port replaces. Assets sit beside the
--- executable, or wherever the bundle put them; writable state goes where the
--- platform keeps it for this application and nowhere else.
---
--- There is deliberately no second way to resolve a path: every function here
--- takes the string the platform takes, so `writablePath("slot1")`, a path a
--- user typed and an absolute path from somewhere else all work and none of
--- them is rewritten on the way through. No virtual filesystem, no mount table,
--- no invented scheme.
---
--- Watching is the one thing below rather than beside, under
--- `tecs.filesystem.watch`. It is a running poller with a lifecycle of its own
--- rather than a call that answers, and its vocabulary, an interval, a settle
--- count and a set of kinds, means nothing to the rest of this.
---
--- ## Nothing here reaches the operating system
---
--- Every function below delegates to the storage backend the installed
--- platform supplies, which is `storagebackend.sdl` unless a port replaced it.
--- That is the whole reason this module exists as a layer rather than as a
--- shorthand for a dozen SDL calls: `adapter` names storage as a seam, and a
--- seam that only covered *where* content is would leave every read of a path
--- under that root going to the host's own file API.
---
--- What stays here is what a port should not have to write again: the argument
--- checks, the record of what has been opened, and the four questions that are
--- one backend call answered differently.
---
--- ```
---  This module          The backend        SDL's backend does
---  ───────────────────  ─────────────────  ─────────────────────
---  read                 read               SDL_LoadFile
---  write                write              SDL_SaveFile
---  openRead             openRead           SDL_IOFromFile
---  openWrite            openWrite          SDL_IOFromFile
---  info                 info               SDL_GetPathInfo
---  exists               info               SDL_GetPathInfo
---  isFile               info               SDL_GetPathInfo
---  isDirectory          info               SDL_GetPathInfo
---  glob                 glob               SDL_GlobDirectory
---  list                 glob               SDL_GlobDirectory
---  createDirectory      createDirectory    SDL_CreateDirectory
---  remove               remove             SDL_RemovePath
---  rename               rename             SDL_RenamePath
---  copy                 copy               SDL_CopyFile
---  currentDirectory     currentDirectory   SDL_GetCurrentDirectory
---  userFolder           userFolder         SDL_GetUserFolder
--- ```
---
--- Nothing is composed out of several backend calls and nothing is emulated,
--- so a failure is the backend's failure and, on SDL, the name in the third
--- column is what to read the documentation for.
---
--- ## Reading and writing are both here
---
--- `read` and `write` are one pair in one module, and the record of what this
--- process has opened lives with them. That record is what `watch` polls to
--- decide whether a changed file is one anything asked for, so it belongs
--- beside the call that opens a file rather than beside the code that decodes
--- one. `assets` records its own decodes through `note` for the same reason.
---
---     local tecs <const> = require("tecs")
---     local save <const> = tecs.filesystem.writablePath("slot1.json")
---     tecs.filesystem.write(save, tecs.data.encodeJSON(state))
---     local bytes <const> = tecs.filesystem.read(save)
---
--- ## Path info is one answer, asked four ways
---
--- `info` fills an `Info` from one backend call and reports a size in bytes and
--- three stamps in nanoseconds since the epoch, carried as doubles. That rounds
--- to the nearest 256 nanoseconds at present-day values, which no filesystem
--- timestamp comes close to needing and is worth having in exchange for a plain
--- number rather than a boxed 64-bit integer.
---
--- `exists`, `isFile` and `isDirectory` are that same call with the answer
--- thrown away, so asking two of them about one path is two syscalls; call
--- `info` once when you want more than one bit of it.
---
--- SDL's backend follows symbolic links, so a link to a file reports "file" and
--- a link to nothing reports nothing at all. "other" is what is left: a socket,
--- a fifo, a device node.
---
--- ## Enumeration is glob, and there is no callback
---
--- SDL offers two ways to walk a directory. `SDL_EnumerateDirectory` takes a
--- function pointer it calls per entry; `SDL_GlobDirectory` allocates a list
--- and returns it. The seam is shaped around the second and never installs an
--- FFI callback.
---
--- The callback would in fact be the safe kind: it fires synchronously inside
--- the call and is not retained past it, unlike the clipboard's data offer,
--- which SDL keeps and enters at a moment this process does not choose. But it
--- buys nothing here. A LuaJIT FFI callback is a trampoline allocated from a
--- small, process-wide pool, entering Lua from C aborts the enclosing trace,
--- and an error raised inside one cannot unwind through the C frame that called
--- it, so a handler that raises has to be wrapped anyway. Against that, glob
--- answers the same entries in one allocation the backend already knows how to
--- free. `physics.TaskPool` keeps its callbacks native for the harder version
--- of the same reason; the cheap version applies here.
---
--- What that costs is that the whole result exists before the first entry is
--- seen, so a directory with a million entries is a million Lua strings. That
--- is the honest trade and there is no streaming form of it.
---
--- **Glob recurses, and the pattern is what stops it.** This is the surprise
--- worth knowing before anything else here:
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
--- ## Semantics, documented rather than smoothed over
---
--- * `createDirectory` creates missing parents, and succeeds on a directory
---   that already exists. On SDL it also **leaves an SDL error string set even
---   when it succeeds**, because it tries, fails, makes the parents and tries
---   again. Nothing here clears it, since clearing SDL's error is as global a
---   side effect as setting it; read the second return value of these
---   functions rather than `SDL_GetError` after them.
--- * `remove` takes a file or an **empty** directory and does not recurse.
--- * `remove` **succeeds when there is nothing there**. It reports that the
---   path is gone, not that it did something. Ask `exists` first if the
---   difference matters.
--- * `rename` and `copy` **overwrite an existing destination** without asking.
---   `rename` moves directories; `copy` refuses one.
--- * `copy` and `write` do **not** create the destination's parent directory.
---   `createDirectory` first.
--- * `userFolder` genuinely has no answer for some folders on some platforms;
---   macOS has no saved-games, screenshots or templates folder, and says so. A
---   platform may have no such folders at all, and then every one of them
---   answers nil. Handle nil.
---
--- ## Failure is a value
---
--- Nothing here raises for a filesystem outcome. Every function answers a
--- status, and every failing one puts the backend's reason beside it as its
--- second return, so the message a caller shows is the operating system's own.
--- Only a missing or non-string path raises, because that is a defect in the
--- calling program rather than something the filesystem did.
---
--- A failed enumeration answers nil rather than an empty list, so "this
--- directory is empty" and "this directory could not be opened" stay apart.
---
--- ## Blocking, and what to do about it
---
--- **Every function here is synchronous and blocks the calling thread.** That
--- is a different answer from the two neighbors that went the other way, so
--- here is why.
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
--- copy, and adding it would make one of twelve entry points non-blocking while
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
--- ## Headless
---
--- SDL's filesystem API needs no subsystem initialized, and neither this module
--- nor its default backend initializes one. There is no `available()` and no
--- video gate, unlike `clipboard`, because there is nothing to gate on: with no
--- window, no device and no `SDL_Init` at all, every function below answers for
--- real. This is one of the few subsystems that is more useful without a window
--- than with one.

local adapter <const> = require("tecs.platform.adapter")
local storagebackend <const> = require("tecs.platform.storagebackend")
local content <const> = require("tecs.platform.content")

-- Type-only, so nothing loads here: the field below declares the name and
-- `tecs.init` fills it in on the first read of it. `watch` reaches content
-- through `platform.content` rather than through this module, which is what
-- keeps naming its type from being a require cycle.
local type watch = require("tecs.platform.watch")

local record filesystem
    --- Polling for changed files, and dispatching what changed.
    watch: watch

    --- Organization and application names, used to name the writable
    --- directory. Set before anything asks for `preferencePath`.
    organization: string
    application: string

    --- What a path is. Symbolic links are followed, so a link never reports as
    --- one: "other" is a socket, a fifo or a device.
    type PathType = storagebackend.PathType

    --- What the backend answered about one path.
    type Info = storagebackend.Info

    --- Which of the platform's well-known folders to ask for.
    type UserFolder = storagebackend.UserFolder

    --- How a pattern is matched.
    type GlobOptions = storagebackend.GlobOptions

    --- A write that takes its bytes in pieces.
    type Writer = storagebackend.Writer

    --- A read that hands its bytes over in pieces.
    type Reader = storagebackend.Reader
end

local type Info = filesystem.Info
local type UserFolder = filesystem.UserFolder
local type GlobOptions = filesystem.GlobOptions
local type Writer = filesystem.Writer
local type Reader = filesystem.Reader

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
        error(("tecs: filesystem.%s needs a path"):format(what), 3)
    end
end

filesystem.organization = "tecs"
filesystem.application = "tecs"

--- Directory the executable was loaded from, with a trailing separator.
---
--- @return The directory. Empty rather than nil when the platform declines to
---     say, which is the case on some targets and is not an error: a caller
---     falls back to a relative path.
function filesystem.basePath(): string
    return content.basePath()
end

--- Writable directory for this application, created if absent.
---
--- @return The directory, with a trailing separator, named from `organization`
---     and `application`. The only place a build may write: everything else is
---     read-only on at least one target, and finding that out at run time on a
---     device is expensive.
function filesystem.preferencePath(): string
    return content.prefPath(filesystem.organization, filesystem.application)
end

--- Root the engine reads content from, with a trailing separator.
---
--- @return `TECS_ASSETS` if it is set, then what the host was told at build
---     time, then `basePath`. Cached until the platform changes.
function filesystem.assetRoot(): string
    return content.assetRoot()
end

--- Resolves `relative` against the asset root.
---
--- @param relative A path under the content root, with `/` separators. Joined,
---     not validated: nothing here asks whether the file is there.
--- @return The absolute path.
function filesystem.assetPath(relative: string): string
    return content.assetPath(relative)
end

--- Resolves `relative` against the writable root.
---
--- @param relative A path under the preference directory.
--- @return The absolute path.
function filesystem.writablePath(relative: string): string
    return filesystem.preferencePath() .. relative
end

--- Overrides the asset root, for a test or a tool.
---
--- @param root The directory to read content from. A trailing separator is
---     added when it is missing rather than doubled when it is not.
function filesystem.setAssetRoot(root: string)
    content.setAssetRoot(root)
end

--- Forgets the cached roots.
---
--- A platform change is noticed without this, so this is for a test that moved
--- something under the process. Named for what it forgets rather than as a bare
--- `reset`, which on this module would read as resetting the filesystem.
function filesystem.resetPaths()
    content.reset()
end

--- What is at `path`, or nil when there is nothing there.
---
--- Nil is the answer for a path that does not exist, for a broken symbolic
--- link, and for a directory that cannot be searched; the second return
--- separates them.
--- @return The info, or nil and the reason.
function filesystem.info(path: string): Info, string
    required(path, "info")
    return adapter.storage().info(path)
end

--- Whether anything is at `path`.
function filesystem.exists(path: string): boolean
    required(path, "exists")
    return adapter.storage().info(path) ~= nil
end

--- Whether `path` is a regular file, following symbolic links.
function filesystem.isFile(path: string): boolean
    required(path, "isFile")
    local info <const> = adapter.storage().info(path)
    return info ~= nil and info.kind == "file"
end

--- Whether `path` is a directory, following symbolic links.
function filesystem.isDirectory(path: string): boolean
    required(path, "isDirectory")
    local info <const> = adapter.storage().info(path)
    return info ~= nil and info.kind == "directory"
end

--- Entries under `path` matching `pattern`, as paths relative to `path`.
---
--- **Recursive unless the pattern stops it**: with no pattern this walks the
--- whole tree below `path` and returns every descendant, joined with `/`
--- whatever the platform's separator is. `*` and `?` never match a separator,
--- so `"*"` is one level, `"*/*"` is exactly two, and `"*.png"` matches only
--- immediate children. Directories are returned alongside files and are not
--- distinguished; ask `info`.
---
--- The order is the platform's own and is not sorted.
--- @param pattern `*` and `?` wildcards, or nil for everything, recursively.
--- @return The entries, or nil and the reason `path` could not be enumerated.
---     An empty list means an empty directory, which nil does not.
function filesystem.glob(path: string, pattern?: string, options?: GlobOptions): {string}, string
    required(path, "glob")
    return adapter.storage().glob(path, pattern, options)
end

--- Names directly inside `path`, not recursively.
---
--- A glob with a `"*"` pattern, which is what confines it to one level. Names,
--- not paths: join them to `path` yourself, which is also what keeps this from
--- being a second path resolver.
--- @return The names, or nil and the reason.
function filesystem.list(path: string): {string}, string
    required(path, "list")
    return filesystem.glob(path, "*")
end

--- Creates `path`, and any parents it needs.
---
--- Succeeds on a directory that already exists. SDL's backend also leaves an
--- SDL error string behind on success, having tried once before making the
--- parents; that string is not returned here and nothing clears it, so do not
--- read `SDL_GetError` after a call that reported success.
function filesystem.createDirectory(path: string): boolean, string
    required(path, "createDirectory")
    return adapter.storage().createDirectory(path)
end

--- Removes a file, or an empty directory.
---
--- It does not recurse and fails on a directory with anything in it. It
--- **succeeds when there is nothing at `path`**: the result says the path is
--- gone, not that this call is what removed it.
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
    return adapter.storage().remove(path)
end

--- Moves `from` to `to`, replacing whatever was at `to`.
---
--- Directories move as well as files, and an existing destination is
--- overwritten with no warning and nothing to undo it. Whether this works
--- across filesystems is the platform's business.
function filesystem.rename(from: string, to: string): boolean, string
    required(from, "rename")
    required(to, "rename")
    return adapter.storage().rename(from, to)
end

--- Copies the file at `from` to `to`, replacing whatever was at `to`.
---
--- Files only: a directory is refused. The destination's parent must already
--- exist.
function filesystem.copy(from: string, to: string): boolean, string
    required(from, "copy")
    required(to, "copy")
    return adapter.storage().copy(from, to)
end

--- Records a path under the kind it was first read as.
---
--- A named kind supersedes "document". `read` answers bytes and cannot know
--- what asked for them, so whatever did is the only thing that can say what the
--- file is, and it says so by naming a kind. The two can arrive in either
--- order, since a game is free to read a font's metrics as a document before
--- anything loads them as a font.
---
--- Decoding happens elsewhere, on a worker, so `assets` records what it opened
--- through here rather than keeping a second list nothing else can see.
function filesystem.note(path: string, kind: string)
    content.note(path, kind)
end

--- Reads a whole file and returns its bytes, or nil when there is none there.
---
--- Through the platform rather than stdio, because on Android content lives
--- inside the package and only SDL's IO reaches it, and on a target with no
--- filesystem nothing else reaches it at all. Binary: the result carries its
--- own length, so a NUL in the middle of it is a byte like any other.
---
--- Synchronous, which is what makes it usable while a world is being built.
--- This is for the documents a game or the engine reads once; a decode a frame
--- should not wait on goes through `assets.loadImage` or `assets.loadSound`.
--- @param path An absolute path, or one `assetPath` has resolved.
--- @param kind What the bytes were read as, for anything watching what this
---     process has opened. Bytes are bytes, so nothing here can tell a font's
---     metrics from a level; whatever asked can, and this is where it says so.
---     Omitted, the path is recorded as a document.
--- @return The bytes, or nil when the file could not be read.
function filesystem.read(path: string, kind?: string): string
    required(path, "read")
    return content.read(path, kind)
end

--- Every path this process has read or decoded, by the kind it was read as:
--- "image", "sound", "font", or "document" for bytes nothing named.
---
--- A path that failed to load is here too. Whatever asked for it named it, and
--- a file that would not decode is exactly the one worth noticing a change to.
--- @return The live table, so something consulting it periodically does not
---     copy it. Shared, so a caller that means to keep it does not also mean to
---     edit it.
function filesystem.loaded(): {string: string}
    return content.loaded()
end

--- A `Writer` for a backend that has no streaming write.
---
--- Holds the pieces and writes them once on close, which is what `write`
--- already does and costs what it already costs. It exists so a caller has one
--- interface everywhere: a port that streams gets the memory back without the
--- caller knowing, and a port that does not is no worse than it was.
local function bufferedWriter(backend: storagebackend.Backend, path: string): Writer, string
    local pieces: {string} = {}
    local count = 0

    local writer <const>: Writer = {}
    writer.write = function(_self: Writer, bytes: string): boolean, string
        if pieces == nil then
            return false, "the writer is closed"
        end
        count = count + 1
        pieces[count] = bytes
        return true
    end
    writer.close = function(_self: Writer): boolean, string
        if pieces == nil then
            return true
        end
        local whole <const> = table.concat(pieces, "", 1, count)
        pieces = nil
        return backend.write(path, whole)
    end
    return writer
end

--- A `Reader` over bytes already in memory, for the same reason.
local function slicingReader(bytes: string): Reader
    local at = 1

    local reader <const>: Reader = {}
    reader.read = function(_self: Reader, count: integer): string, string
        if at > #bytes then
            return ""
        end
        local last <const> = math.min(#bytes, at + math.max(1, count) - 1)
        local piece <const> = bytes:sub(at, last)
        at = last + 1
        return piece
    end
    reader.close = function(_self: Reader) at = #bytes + 1 end
    return reader
end

--- Writes `bytes` to `path`, replacing whatever was there.
---
--- Binary: the string's own length is what is written, so a NUL in the middle
--- of it is a byte like any other and an empty string makes an empty file. The
--- parent directory must already exist.
---
--- The other half of this is `read`, just above.
function filesystem.write(path: string, bytes: string): boolean, string
    required(path, "write")
    if bytes == nil then
        error("tecs: filesystem.write needs bytes to write", 2)
    end
    return adapter.storage().write(path, bytes)
end

--- Opens `path` for writing in pieces, replacing whatever was there.
---
--- What `write` cannot do: a body that arrives over time never becomes one
--- string as large as itself. A download that ends in a file writes through
--- this, and so does anything else assembled from parts.
---
--- Close it. The bytes are not guaranteed to be on disk until `close` answers,
--- and it is the call a full disk is reported by.
---
--- ```teal
--- local writer <const> = assert(tecs.filesystem.openWrite(path))
--- writer:write(chunk)
--- assert(writer:close())
--- ```
---
--- @return The writer, or nil and the reason there is none.
function filesystem.openWrite(path: string): Writer, string
    required(path, "openWrite")
    local backend <const> = adapter.storage()
    if backend.openWrite ~= nil then
        return backend.openWrite(path)
    end
    return bufferedWriter(backend, path)
end

--- Opens `path` for reading in pieces. The mirror of `openWrite`.
---
--- `read` is the right call for a file a program wants whole. This is for one
--- it wants to hand over as it goes: an upload body is read through this, so
--- the file being sent is never also in memory.
---
--- @return The reader, or nil and the reason there is none.
function filesystem.openRead(path: string): Reader, string
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

--- The process working directory, with a trailing separator.
---
--- Here because a command line tool is given relative paths by whoever ran it
--- and has to resolve them against something. It is emphatically not where a
--- game reads content from or writes state to: `assetRoot` and `preferencePath`
--- answer that, and say why. A platform with no working directory answers nil,
--- which is most of the ones that are not a desktop.
--- @return The directory, or nil and the reason.
function filesystem.currentDirectory(): string, string
    local storage <const> = adapter.storage()
    if storage.currentDirectory == nil then
        return nil, "this platform has no working directory"
    end
    return storage.currentDirectory()
end

--- One of the platform's well-known folders, with a trailing separator.
---
--- **Often nil, and legitimately so.** A platform that has no such concept says
--- so rather than inventing a path: macOS has no saved-games, screenshots or
--- templates folder and answers nil for all three, and a platform that is not a
--- desktop may have none of them. Treat every one of these as absent until it
--- is not, and never as a place a build may write; `preferencePath` is the only
--- such place.
--- @return The folder, or nil and the reason.
function filesystem.userFolder(which: UserFolder): string, string
    if not storagebackend.folders[which] then
        error(("tecs: filesystem.userFolder does not know '%s'"):format(tostring(which)), 2)
    end
    local storage <const> = adapter.storage()
    if storage.userFolder == nil then
        return nil, "this platform has no well-known folders"
    end
    return storage.userFolder(which)
end

return filesystem
