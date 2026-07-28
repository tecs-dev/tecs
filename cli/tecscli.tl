--- Entry chunk for the `tecs` command.
---
--- The host loads this the same way it loads a game: it is the chunk named by
--- `TECS_ENTRY`, and it returns an application. So the command line tool and a
--- game are the same binary running two entry chunks, and `tecs run` hands off
--- to the second by executing this binary again with `--entry`.
---
--- Everything below the first require is ordinary Teal. This file is only the
--- bootstrap, because it is loaded before `package.path` names anything:
--- nothing here can `require` until the lines that make `require` work have
--- run, and in a single-file build there is nothing on disk for them to name
--- until this has written it there.
---
--- ## Why a single-file build unpacks rather than serving from memory
---
--- A `package.loaders` entry over the payload would answer `require` without
--- touching the disk, and would answer only half the question. The engine
--- resolves an asset as a path and opens it through
--- `src/tecs/platform/filesystem.tl`, so shaders, materials and fonts would still
--- need a directory. Serving Lua from memory and assets from a directory is two
--- mechanisms where the tree has one, so this writes both out and points the
--- ordinary one at the result.
---
--- What that costs is one unpack per version, into a cache directory named
--- after a digest of the payload. What it keeps is that the binary is one file
--- to install, copy and put on a PATH, and that a cold machine needs no network.
---
--- The engine change that would remove it is a seam in `filesystem.tl` for opening
--- an asset, so a port can answer from memory rather than from a path. That is
--- a change to `src/tecs`, and it is named here rather than made.

--- Runs a shell command, answering whether it succeeded.
---
--- The one place the CLI shells out for something the engine does better.
--- `tecs.filesystem.createDirectory` is the right call and it is not reachable
--- yet: it is inside the payload this is in the middle of writing out.
local function shellSucceeded(command: string): boolean
    local first = os.execute(command)
    if first is boolean then
        return first
    end
    return (first as integer) == 0
end

--- Quotes one argument for `/bin/sh`.
local function quote(argument: string): string
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end

--- Whether a readable file is at `path`.
local function readable(path: string): boolean
    local handle = io.open(path, "r")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

--- Where an unpacked payload lives.
---
--- Named after a digest of the archive, so two builds of the same tree share
--- one directory and an upgraded binary never reads the last one's copy.
local function cacheDirectory(identity: string): string
    local explicit = os.getenv("TECS_HOME")
    if explicit ~= nil and explicit ~= "" then
        return explicit .. "/" .. identity
    end
    local base = os.getenv("XDG_CACHE_HOME")
    if base == nil or base == "" then
        local home = os.getenv("HOME")
        if home == nil or home == "" then
            return "/tmp/tecs/" .. identity
        end
        base = home .. "/.cache"
    end
    return base .. "/tecs/" .. identity
end

--- Writes every entry of the payload under `directory`.
---
--- Into a sibling first and renamed into place, so two `tecs` processes
--- starting at once cannot read a half-written tree. A rename onto a directory
--- that already exists fails, and that is the right answer rather than a
--- problem: the other process won, and its tree is byte for byte this one.
local function unpack(payload: {string: any}, directory: string): boolean, string
    local entries = (payload.entries as function(): {{string}})()
    if entries == nil then
        return false, "the payload could not be read"
    end

    local staging = ("%s.%d"):format(directory, math.floor(os.time() % 1000000))
    shellSucceeded("rm -rf " .. quote(staging))

    -- Every directory in one call. A `mkdir` per file would be a process per
    -- file, and there are several hundred.
    local seen: {string: boolean} = {}
    local directories: {string} = {quote(staging)}
    for _, entry in ipairs(entries) do
        local parent = entry[1]:match("^(.*)/[^/]*$")
        if parent ~= nil and not seen[parent] then
            seen[parent] = true
            directories[#directories + 1] = quote(staging .. "/" .. parent)
        end
    end
    if not shellSucceeded("mkdir -p " .. table.concat(directories, " ")) then
        return false, ("cannot create %s"):format(staging)
    end

    for _, entry in ipairs(entries) do
        local handle = io.open(staging .. "/" .. entry[1], "wb")
        if handle == nil then
            return false, ("cannot write %s"):format(entry[1])
        end
        handle:write(entry[2])
        handle:close()
    end

    if os.rename(staging, directory) then
        return true
    end

    shellSucceeded("rm -rf " .. quote(staging))
    if not readable(directory .. "/lua/tecscli.lua") then
        return false, ("cannot place %s"):format(directory)
    end
    return true
end

--- The content root, unpacking the payload first where there is one.
local function contentRoot(): string
    -- Named indirectly, because the module exists only in a single-file
    -- build: it is installed from C by cli/payload.c, has no .tl beside it,
    -- and a literal require would be a module the type checker cannot find.
    local carried, payload = pcall(require, "tecs." .. "payload")
    if carried then
        local identity = ((payload as {string: any}).identity as function(): string)()
        local directory = cacheDirectory(identity)
        if not readable(directory .. "/lua/tecscli.lua") then
            local ok, reason = unpack(payload as {string: any}, directory)
            if not ok then
                io.stderr:write(("tecs: %s\n"):format(reason))
                os.exit(1)
            end
        end
        return directory .. "/lua"
    end

    -- Where this tree was compiled or installed to. The build says so during
    -- development, the host says so for an installed run, and neither is the
    -- working directory: a command is run from wherever the user happens to be
    -- standing, which is the one place its own code is certainly not.
    local found = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "."
    if found:sub(-1) == "/" then
        found = found:sub(1, -2)
    end
    return found
end

local root <const> = contentRoot()

-- The engine's Lua, then the pinned tools beside it. Teal and Cerulean are
-- ordinary Lua modules that live under `tecstools`, so both reach `require`
-- through the same path rather than through a loader written for them.
package.path = root
    .. "/?.lua;"
    .. root
    .. "/?/init.lua;"
    .. root
    .. "/tecstools/?.lua;"
    .. root
    .. "/tecstools/?/init.lua;"
    .. package.path

local run <const> = require("tecscli.run")

return {
    -- Nothing to set up: no window, no device, no world. The host reserves its
    -- event batches around this and then calls `_iterate` once.
    _init = function(): boolean return true end,

    -- One iteration, and it never returns. A command exits with its own status
    -- rather than letting the host decide, because the host has two answers
    -- and a command line tool needs as many as it has failure modes.
    _iterate = function() run.main(root) end,

    _shutdown = function(): boolean return true end,
}
