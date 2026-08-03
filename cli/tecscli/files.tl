--- Walking, copying and removing trees.
---
--- Everything here is `tecs.io.files` plus command-specific policy. The
--- engine supplies the traversal; this module decides which project trees to
--- prune and which files each command keeps.
---
--- Paths come back relative to the root they were walked from and always use a
--- forward slash, so a caller joins them without asking which separator this
--- platform prefers. Nothing here follows a symbolic link into a directory: a
--- link that points at its own ancestor is a walk that does not end, and a
--- project holding one is not a reason for `tecs build` to hang.

local tecs <const> = require("tecs")

local record files
end

--- Whether a directory entry should be descended into.
---
--- Four names, and each is a tree somebody else owns. Descending into `.git`
--- alone would multiply the cost of every walk by the size of the history.
local SKIP <const>: {string: boolean} = {
    [".git"] = true,
    [".hg"] = true,
    [".svn"] = true,
    ["node_modules"] = true,
}

--- Every file under `root`, as paths relative to it.
---
--- @param keep Answers whether a relative path is wanted. Omitted keeps all.
function files.walk(root: string, keep?: function(string): boolean): {string}
    local found: {string} = {}
    local stream = tecs.io.files.glob(root)
    if stream == nil then
        return found
    end
    while true do
        local entry = stream:next()
        if entry == nil then
            break
        end
        if SKIP[entry.name] then
            if entry.kind == "directory" then
                stream:skipDirectory()
            end
        elseif entry.kind == "file" then
            local relative = assert(entry.path:relativeTo(root)):toString()
            if keep == nil or keep(relative) then
                found[#found + 1] = relative
            end
        end
    end
    table.sort(found)
    return found
end

--- Creates `path` and every parent it needs.
function files.ensure(path: string): boolean, string
    return tecs.io.files.createDirectory(path)
end

--- Creates the directory a file will be written into.
function files.ensureParent(path: string): boolean, string
    local directory = path:match("^(.*)/[^/]+$")
    if directory == nil or directory == "" then
        return true
    end
    return files.ensure(directory)
end

--- Copies every file under `from` into `to`, creating directories as needed.
function files.copyTree(from: string, to: string): integer
    local copied = 0
    for _, relative in ipairs(files.walk(from)) do
        local target = to .. "/" .. relative
        files.ensureParent(target)
        if tecs.io.files.copy(from .. "/" .. relative, target) then
            copied = copied + 1
        end
    end
    return copied
end

--- Removes `path` and everything under it.
---
--- Depth first, because `SDL_RemovePath` removes an empty directory and
--- refuses a full one. A path that is not there is a success: this is what
--- `tecs clean` calls, and cleaning a tree that was already clean is not a
--- failure anyone wants reported.
function files.removeTree(path: string): boolean
    local info = tecs.io.files.info(path)
    if info == nil then
        return true
    end
    if info.kind == "directory" then
        local stream = tecs.io.files.glob(path, "*")
        local entries = stream ~= nil and stream:toArray() or nil
        if entries ~= nil then
            for _, entry in ipairs(entries) do
                files.removeTree(entry.path:toString())
            end
        end
    end
    local removed = tecs.io.files.remove(path)
    return removed
end

--- Reads a whole file, or nil when there is nothing there.
function files.read(path: string): string
    if not tecs.io.files.isFile(path) then
        return nil
    end
    local bytes <const> = tecs.io.files.read(path)
    return bytes
end

--- Writes `bytes` to `path`, creating the directory it goes in.
function files.write(path: string, bytes: string): boolean, string
    files.ensureParent(path)
    return tecs.io.files.write(path, bytes)
end

--- Whether `path` ends with `suffix`.
function files.hasSuffix(path: string, suffix: string): boolean
    return path:sub(-#suffix) == suffix
end

return files
