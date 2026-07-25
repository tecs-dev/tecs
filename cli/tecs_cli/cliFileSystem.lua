-- Cross-platform path and filesystem operations used by the Tecs CLI.

local M = {}

local haveLfs, lfs = pcall(require, "lfs")
local sep, isMsys, isWindows

function M.detectPlatform()
    local hostSep = package.config:sub(1, 1)
    local msys = os.getenv("MSYSTEM") ~= nil
    local separator = msys and "/" or hostSep
    return {
        sep = separator,
        isMsys = msys,
        isWindows = separator == "\\" and not msys,
    }
end

function M.setPlatform(platform)
    sep = platform.sep
    isMsys = platform.isMsys or false
    isWindows = platform.isWindows or false
end

M.setPlatform(M.detectPlatform())

local function requireLfs()
    if not haveLfs then
        error("filesystem adapter unavailable; run tecs through its installed launcher", 0)
    end
    return lfs
end

function M.q(path)
    path = tostring(path)
    if isWindows then
        return '"' .. path:gsub('"', '""') .. '"'
    end
    return '"' .. path:gsub('"', '\\"') .. '"'
end

-- Resolved once at load time: callers may chdir later (project staging,
-- specs), and a LUA_PATH-relative source path would then resolve nowhere.
-- Absolutizing lazily is not enough -- by first call the cwd may already
-- have moved -- so capture it here, but only when lfs is actually loadable
-- (the packaged CLI resolves through the Love loader and has no lfs need).
local moduleSource = (function()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) ~= "@" then return nil end
    local path = source:sub(2)
    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
        return path
    end
    local okLfs, lfsMod = pcall(require, "lfs")
    if okLfs and lfsMod and lfsMod.currentdir then
        local pwd = lfsMod.currentdir()
        if pwd then return pwd .. "/" .. path end
    end
    return path
end)()

function M.sourcePath()
    return moduleSource
end

function M.normalize(path)
    if isWindows then
        return (path:gsub("/", "\\"))
    end
    path = path:gsub("\\", "/")
    if isMsys then
        path = path:gsub("^(%a):", function(drive)
            return "/" .. drive:lower()
        end)
    end
    return path
end

function M.luaModulePath(path)
    return tostring(path):gsub("\\", "/")
end

function M.pathJoin(...)
    local parts = {...}
    local out = {}
    for i = 1, #parts do
        local part = tostring(parts[i])
        local unixAbs = i == 1 and part:match("^/")
        part = part:gsub("[/\\]+$", "")
        if not unixAbs then
            part = part:gsub("^[/\\]+", "")
        end
        if i == 1 and (part:match("^%a:[/\\]") or unixAbs) then
            part = parts[i]:gsub("[/\\]+$", "")
        end
        if part ~= "" then out[#out + 1] = part end
    end
    return M.normalize(table.concat(out, sep))
end

function M.pathFromBuild(path)
    path = M.normalize(path)
    if path:match("^%a:[/\\]") or path:match("^[/\\]") then return path end
    return M.pathJoin("..", path)
end

function M.dirname(path)
    local dir = M.normalize(path):gsub("[/\\][^/\\]+$", "")
    if dir == path or dir == "" then return "." end
    return dir
end

function M.basename(path)
    return M.normalize(path):match("[^/\\]+$") or M.normalize(path)
end

function M.exists(path)
    return requireLfs().attributes(M.normalize(path)) ~= nil
end

-- Check generated files through the native filesystem. The packaged CLI's
-- read-only PhysFS mount can retain stale metadata after build output changes
-- during the same process.
function M.isFile(path)
    local file = io.open(M.normalize(path), "rb")
    if not file then return false end
    local readable = file:read(0) ~= nil
    file:close()
    return readable
end

function M.fileMtime(path)
    local mtime = requireLfs().attributes(M.normalize(path), "modification")
    return tonumber(mtime) or 0
end

function M.listDir(path)
    local entries = {}
    for entry in requireLfs().dir(M.normalize(path)) do
        entries[#entries + 1] = entry
    end
    return entries
end

function M.mkdir(path)
    path = M.normalize(path)
    if M.exists(path) then return end
    local current = ""
    if path:match("^%a:[/\\]") then
        current = path:sub(1, 2)
        path = path:sub(4)
    elseif path:match("^[/\\]") then
        current = sep
        path = path:gsub("^[/\\]+", "")
    end
    for part in path:gmatch("[^/\\]+") do
        if current == "" then
            current = part
        elseif current == sep then
            current = sep .. part
        else
            current = M.pathJoin(current, part)
        end
        if not M.exists(current) then
            local ok, err = requireLfs().mkdir(current)
            if not ok and not M.exists(current) then
                error("could not create directory " .. current .. ": " .. tostring(err), 0)
            end
        end
    end
end

function M.writeFile(path, content)
    M.mkdir(M.dirname(path))
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

function M.isDir(path)
    return requireLfs().attributes(M.normalize(path), "mode") == "directory"
end

function M.isEmptyDir(path)
    if not M.isDir(path) then return false end
    for entry in requireLfs().dir(M.normalize(path)) do
        if entry ~= "." and entry ~= ".." then return false end
    end
    return true
end

function M.remove(path)
    path = M.normalize(path)
    if not M.exists(path) then return end
    local mode = requireLfs().attributes(path, "mode")
    if mode == "directory" then
        for entry in requireLfs().dir(path) do
            if entry ~= "." and entry ~= ".." then
                M.remove(M.pathJoin(path, entry))
            end
        end
        local ok, err = requireLfs().rmdir(path)
        if not ok then error("could not remove directory " .. path .. ": " .. tostring(err), 0) end
    else
        local ok, err = os.remove(path)
        if not ok then error("could not remove file " .. path .. ": " .. tostring(err), 0) end
    end
end

function M.patternEscape(value)
    return (value:gsub("([^%w])", "%%%1"))
end

function M.shouldExclude(relativePath, exclude)
    if not exclude then return false end
    for _, pattern in ipairs(exclude) do
        if relativePath == pattern
            or relativePath:match("^" .. M.patternEscape(pattern) .. "[/\\]") then
            return true
        end
        local suffix = pattern:match("^%*%.(.+)$")
        if suffix and relativePath:match("%." .. M.patternEscape(suffix) .. "$") then
            return true
        end
    end
    return false
end

function M.copyFile(source, target)
    M.mkdir(M.dirname(target))
    local input = assert(io.open(source, "rb"))
    local content = input:read("*a")
    input:close()
    local output = assert(io.open(target, "wb"))
    output:write(content)
    output:close()
end

function M.walkFiles(dir, out)
    dir = M.normalize(dir)
    out = out or {}
    local attr = requireLfs().attributes(dir)
    if not attr then return out end
    if attr.mode ~= "directory" then
        out[#out + 1] = dir
        return out
    end
    for entry in requireLfs().dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = M.pathJoin(dir, entry)
            local mode = requireLfs().attributes(path, "mode")
            if mode == "directory" then
                M.walkFiles(path, out)
            elseif mode == "file" then
                out[#out + 1] = path
            end
        end
    end
    return out
end

function M.relativeTo(path, base)
    path = M.normalize(path)
    base = M.normalize(base):gsub("[/\\]+$", "")
    local prefix = M.patternEscape(base) .. "[/\\]?"
    return path:gsub("^" .. prefix, "")
end

function M.copyDir(source, target, exclude)
    source = M.normalize(source)
    target = M.normalize(target)
    M.mkdir(target)
    local seen = {}
    for _, file in ipairs(M.walkFiles(source, {})) do
        local relativePath = M.relativeTo(file, source)
        if not M.shouldExclude(relativePath, exclude) then
            local destination = M.pathJoin(target, relativePath)
            M.copyFile(file, destination)
            seen[M.normalize(destination)] = true
        end
    end
    for _, file in ipairs(M.walkFiles(target, {})) do
        local relativePath = M.relativeTo(file, target)
        if M.shouldExclude(relativePath, exclude) or not seen[M.normalize(file)] then
            M.remove(file)
        end
    end
end

function M.cwd()
    return M.normalize(requireLfs().currentdir())
end

return M
