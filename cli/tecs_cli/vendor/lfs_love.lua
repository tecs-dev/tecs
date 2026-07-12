-- Minimal LuaFileSystem-compatible adapter for the self-contained LÖVE CLI.
-- LÖVE ships LuaJIT and PhysFS, but not LuaFileSystem. The CLI only needs
-- directory traversal, metadata, and basic directory operations, so keeping
-- that small surface here avoids requiring LuaRocks or a native compiler.
local ffi = require("ffi")

ffi.cdef([[
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
int mkdir(const char *path, unsigned int mode);
int rmdir(const char *path);
int SetCurrentDirectoryA(const char *path);
unsigned long GetCurrentDirectoryA(unsigned long size, char *buffer);
int CreateDirectoryA(const char *path, void *securityAttributes);
int RemoveDirectoryA(const char *path);
]])

local M = {}
local isWindows = package.config:sub(1, 1) == "\\"
local kernel32 = isWindows and ffi.load("kernel32") or nil
local projectRoot
local externalSource
local mountedProject

local function slash(path)
    path = tostring(path):gsub("\\", "/")
    if path == "/" or path:match("^%a:/$") then return path end
    return path:gsub("/+$", "")
end

local function clean(path)
    path = slash(path)
    local prefix = path:match("^%a:") or (path:sub(1, 1) == "/" and "/" or "")
    local body = prefix == "/" and path:sub(2) or path:sub(#prefix + 1):gsub("^/", "")
    local parts = {}
    for part in body:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    local joined = table.concat(parts, "/")
    if prefix == "/" then return "/" .. joined end
    if prefix ~= "" then return prefix .. "/" .. joined end
    return joined
end

local function native(path)
    return isWindows and path:gsub("/", "\\") or path
end

local function cwd_native()
    local buffer = ffi.new("char[?]", 32768)
    if isWindows then
        local length = kernel32.GetCurrentDirectoryA(32768, buffer)
        if length == 0 or length >= 32768 then return nil, "GetCurrentDirectory failed" end
        return ffi.string(buffer, length)
    end
    local result = ffi.C.getcwd(buffer, 32768)
    if result == nil then return nil, "getcwd failed: " .. tostring(ffi.errno()) end
    return ffi.string(buffer)
end

local function absolute(path)
    path = slash(path)
    if path:match("^%a:/") or path:sub(1, 1) == "/" then return clean(path) end
    local current = assert(cwd_native())
    return clean(slash(current) .. "/" .. path)
end

local function dirname(path)
    local dir = slash(path):gsub("/[^/]+$", "")
    if dir:match("^%a:$") then dir = dir .. "/" end
    return dir ~= "" and dir or "/"
end

local function basename(path)
    return slash(path):match("[^/]+$") or ""
end

local function starts_with(path, root)
    if isWindows then
        path, root = path:lower(), root:lower()
    end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function remount_external(source)
    -- LÖVE 12's full-path mounts expose arbitrary host directories through
    -- PhysFS. Only one external mount is needed at a time during a traversal.
    if externalSource == source then return true end
    if externalSource then love.filesystem.unmountFullPath(externalSource) end
    if not love.filesystem.mountFullPath(source, "__tecs_external", "read", true) then return false end
    externalSource = source
    return true
end

local function virtual_file(path)
    local full = absolute(path)
    if starts_with(full, projectRoot) then
        local rel = full:sub(#projectRoot + 1):gsub("^/", "")
        return rel == "" and "__tecs_project" or "__tecs_project/" .. rel
    end
    local parent = dirname(full)
    if not remount_external(parent) then return nil end
    return "__tecs_external/" .. basename(full)
end

local function virtual_dir(path)
    local full = absolute(path)
    if starts_with(full, projectRoot) then
        local rel = full:sub(#projectRoot + 1):gsub("^/", "")
        return rel == "" and "__tecs_project" or "__tecs_project/" .. rel
    end
    if not remount_external(full) then return nil end
    return "__tecs_external"
end

function M.setRoot(path)
    -- io.open and os.remove operate on native paths, while attributes and dir
    -- use PhysFS. Keep both views rooted at the same project directory.
    local full = absolute(path)
    local changed
    if isWindows then
        changed = kernel32.SetCurrentDirectoryA(native(full)) ~= 0
    else
        changed = ffi.C.chdir(full) == 0
    end
    if not changed then return nil, "chdir failed: " .. tostring(ffi.errno()) end
    projectRoot = slash(assert(cwd_native()))
    love.filesystem.setSymlinksEnabled(true)
    if mountedProject then love.filesystem.unmountFullPath(mountedProject) end
    if not love.filesystem.mountFullPath(projectRoot, "__tecs_project", "read", true) then
        return nil, "could not mount project directory"
    end
    mountedProject = projectRoot
    return true
end

function M.currentdir()
    return cwd_native()
end

function M.chdir(path)
    return M.setRoot(path)
end

function M.attributes(path, field)
    local virtual = virtual_file(path)
    if not virtual then return nil end
    local info = love.filesystem.getInfo(virtual)
    if not info then return nil end
    local attrs = {
        mode = info.type == "directory" and "directory" or "file",
        size = info.size or 0,
        modification = info.modtime or 0,
    }
    return field and attrs[field] or attrs
end

function M.dir(path)
    local virtual = virtual_dir(path)
    if not virtual then error("cannot open directory: " .. tostring(path), 2) end
    local entries = love.filesystem.getDirectoryItems(virtual)
    table.insert(entries, 1, "..")
    table.insert(entries, 1, ".")
    local index = 0
    return function()
        index = index + 1
        return entries[index]
    end
end

function M.mkdir(path)
    -- Writes must use the host API: this adapter intentionally mounts project
    -- directories read-only so filesystem discovery never broadens access.
    local full = absolute(path)
    local ok
    if isWindows then
        ok = kernel32.CreateDirectoryA(native(full), nil) ~= 0
    else
        ok = ffi.C.mkdir(full, 493) == 0
    end
    if ok then return true end
    return nil, "mkdir failed: " .. tostring(ffi.errno())
end

function M.rmdir(path)
    local full = absolute(path)
    local ok
    if isWindows then
        ok = kernel32.RemoveDirectoryA(native(full)) ~= 0
    else
        ok = ffi.C.rmdir(full) == 0
    end
    if ok then return true end
    return nil, "rmdir failed: " .. tostring(ffi.errno())
end

return M
