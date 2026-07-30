--- Enough of LuaFileSystem for the two tools this binary carries.
---
--- Teal and Cerulean both `require("lfs")`, and LuaFileSystem is a C module: a
--- `.so` found on `package.cpath`, which is precisely what a single executable
--- has none of. Vendoring its source would mean another C dependency, another
--- license entry and another thing to build per platform, for three functions.
---
--- SDL already answers all three, and the engine already reaches SDL through
--- `tecs.io.filesystem`. So this is the shim, installed under the name the tools
--- ask for, and it is exactly as large as what they call:
---
--- ```
---  LuaFileSystem            Reached through          Called by
---  ───────────────────────  ───────────────────────  ──────────────────────
---  attributes(path, mode)   filesystem.info          Cerulean's discovery
---  dir(path)                filesystem.list          Cerulean's discovery
---  mkdir(path)              filesystem.create...     Teal's generator
--- ```
---
--- Anything else raises rather than answering nil, because a tool reaching for
--- a function that is not here has found a gap somebody should be told about,
--- and an unexplained nil in a formatter is a file silently left unformatted.

local tecs <const> = require("tecs")

local record lfsshim
end

--- What LuaFileSystem calls a path's `mode`, from what SDL calls its kind.
local KIND <const>: {string: string} = {
    file = "file",
    directory = "directory",
    other = "other",
}

--- One attribute of a path, or every attribute when none is named.
---
--- Only `mode` is answered, since it is the only one asked for. A caller
--- naming another attribute gets nil rather than a wrong number.
function lfsshim.attributes(path: string, request?: string): any, string
    local info = tecs.io.filesystem.info(path)
    if info == nil then
        return nil, ("cannot stat %s"):format(path)
    end
    local mode = KIND[info.kind] or "other"
    if request == nil then
        return {mode = mode, size = info.size}
    end
    if request == "mode" then
        return mode
    end
    if request == "size" then
        return info.size
    end
    return nil
end

--- Iterates the names in a directory, including `.` and `..`.
---
--- The two dot entries are produced here because LuaFileSystem produces them
--- and every caller filters them out; a shim that omitted them would be right
--- about the filesystem and wrong about the interface.
function lfsshim.dir(path: string): function(): string
    local entries = tecs.io.filesystem.list(path)
    if entries == nil then
        error(("cannot list %s"):format(path), 2)
    end
    local names <const>: {string} = {".", ".."}
    for _, entry in ipairs(entries) do
        names[#names + 1] = entry
    end
    local index = 0
    return function(): string index = index + 1; return names[index] end
end

--- Creates one directory.
function lfsshim.mkdir(path: string): boolean, string
    return tecs.io.filesystem.createDirectory(path)
end

--- Installs this under the name the tools require.
---
--- Through `package.preload` rather than by writing a file, so it answers
--- before any search path is consulted and cannot be shadowed by a real
--- LuaFileSystem the machine happens to have installed for something else.
function lfsshim.install()
    package.preload["lfs"] = function(): lfsshim return lfsshim end
end

return lfsshim
