--- Persistent restricted environment for the MCP run_lua tool.
---
--- The sandbox owns capability filtering and compilation. Transport handlers
--- only schedule the compiled function on the world thread and serialize its
--- result, keeping security policy out of protocol dispatch.

local tecs <const> = require("tecs")

local record sandbox
    --- Compile code as a function(world) inside the shared sandbox.
    --- Returns nil plus a diagnostic when compilation fails.
    compile: function(code: string): function(tecs.World), string
    --- Drop user globals and filtered API caches between MCP sessions.
    reset: function()
end

local G <const> = (_G as any) as {string: any}
local sandboxSetfenv <const> = G["setfenv"] as function(any, {string: any})
local sandboxSetmt <const> = setmetatable as function(any, any): any
local sandboxRawset <const> = rawset as function(any, any, any)

local SAFE_OS <const>: {string} = {"time", "clock", "date", "difftime"}
local DENIED_GLOBAL <const>: {string: boolean} = {
    io = true, ffi = true, package = true,
    load = true, loadstring = true, dofile = true, loadfile = true,
    debug = true, collectgarbage = true, newproxy = true,
    getfenv = true, setfenv = true, _ENV = true,
}

local function sandboxRequire(name: string): any
    if type(name) ~= "string" then
        error("run_lua require expects a module name", 2)
    end
    local root = name:match("^([^.]+)") or name
    local allowed = (root == "tecs" or root == "tecs2d")
        and name:match("^tecs2d%.testing") == nil
        and name:match("^tecs2d%.mcp") == nil
        and name:match("^tecs2d%.debug") == nil
    if not allowed then
        error("require('" .. name .. "') is blocked in run_lua: the filesystem, "
            .. "network, and process modules are unavailable. love2d APIs and the "
            .. "ECS world are already in scope.", 2)
    end
    return (require as function(string): any)(name)
end

local DENIED_MODULE_ROOT <const>: {string: boolean} = {
    io = true, os = true, ffi = true, package = true, debug = true,
    socket = true, mime = true, ltn12 = true, lfs = true, love = true,
    jit = true, string = true, table = true, math = true, coroutine = true,
    bit = true, _G = true,
}

local function sandboxModules(name: string): any
    if type(name) ~= "string" then
        error("modules expects a module name", 2)
    end
    local root = name:match("^([^.]+)") or name
    if DENIED_MODULE_ROOT[root]
        or name:match("^tecs2d%.testing") ~= nil
        or name:match("^tecs2d%.mcp") ~= nil
        or name:match("^tecs2d%.debug") ~= nil then
        error("modules('" .. name .. "') is blocked in run_lua", 2)
    end
    local pkg = G["package"] as {string: any}
    local loaded = pkg.loaded as {string: any}
    local mod = loaded[name]
    if mod == nil then
        error("modules('" .. name .. "'): not loaded. Game modules load at boot; "
            .. "check the exact require name.", 2)
    end
    return mod
end

local DENIED_LOVE_TOP <const>: {string: boolean} = {thread = true}
local DENIED_LOVE_FS <const>: {string: boolean} = {
    load = true, mount = true, mountFullPath = true, unmount = true,
    setIdentity = true, setSource = true,
    setRequirePath = true, setCRequirePath = true,
}
local WRITE_GUARDED_LOVE_FS <const>: {string: boolean} = {
    write = true, append = true, newFile = true,
}
local DENIED_LOVE_SYSTEM <const>: {string: boolean} = {openURL = true}
local DENIED_LOVE_EVENT <const>: {string: boolean} = {quit = true}

local function guardedFsWrite(name: string, fn: function): any
    return function(path: any, ...: any): any
        if path is string then
            local p = path:lower()
            if p:match("%.lua$") or p:match("%.tl$") then
                error("love.filesystem." .. name .. "('" .. path .. "') is "
                    .. "blocked in run_lua: the save directory shadows the "
                    .. "source on the require path, so writing code files "
                    .. "there could execute outside the sandbox. Data files "
                    .. "(.png, .json, ...) are fine.", 2)
            end
        end
        return (fn as function(any, ...: any): any)(path, ...)
    end
end

local function filteredCopy(t: {string: any},
        denied: {string: boolean}): {string: any}
    local out: {string: any} = {}
    for k, v in pairs(t) do
        if not denied[k] then out[k] = v end
    end
    return out
end

local sandboxLoveCache: {string: any} = nil
local function sandboxLove(): any
    if sandboxLoveCache then return sandboxLoveCache end
    local source = G["love"] as {string: any}
    if not source then return nil end
    local out = filteredCopy(source, DENIED_LOVE_TOP)
    if type(source["filesystem"]) == "table" then
        local fs = filteredCopy(source["filesystem"] as {string: any},
            DENIED_LOVE_FS)
        for name in pairs(WRITE_GUARDED_LOVE_FS) do
            if type(fs[name]) == "function" then
                fs[name] = guardedFsWrite(name, fs[name] as function)
            end
        end
        out["filesystem"] = fs
    end
    if type(source["system"]) == "table" then
        out["system"] = filteredCopy(source["system"] as {string: any},
            DENIED_LOVE_SYSTEM)
    end
    if type(source["event"]) == "table" then
        out["event"] = filteredCopy(source["event"] as {string: any},
            DENIED_LOVE_EVENT)
    end
    sandboxLoveCache = out
    return out
end

local sandboxEnvCache: {string: any} = nil
local function environment(): {string: any}
    if sandboxEnvCache then return sandboxEnvCache end
    local realOs = G["os"] as {string: any}
    local safeOs: {string: any} = {}
    if realOs then
        for _, key in ipairs(SAFE_OS) do safeOs[key] = realOs[key] end
    end
    local mt: {string: any} = {}
    mt["__index"] = function(t: any, key: string): any
        if key == "_G" then return t end
        if key == "require" then return sandboxRequire end
        if key == "modules" then return sandboxModules end
        if key == "os" then return safeOs end
        if key == "love" then return sandboxLove() end
        if DENIED_GLOBAL[key] then return nil end
        return G[key]
    end
    mt["__newindex"] = function(t: any, key: any, value: any)
        sandboxRawset(t, key, value)
    end
    mt["__metatable"] = false
    sandboxEnvCache = sandboxSetmt({}, mt) as {string: any}
    return sandboxEnvCache
end

function sandbox.reset()
    sandboxEnvCache = nil
    sandboxLoveCache = nil
end

function sandbox.compile(code: string): function(tecs.World), string
    local wrapped <const> = "return function(world) " .. code .. "\nend"
    local ok, result = pcall(function(): function(tecs.World)
        local chunk, loadErr = load(wrapped, "mcp_lua", "t")
        if not chunk then
            error("Failed to load code: " .. tostring(loadErr))
        end
        sandboxSetfenv(chunk, environment())
        local fn = chunk()
        if type(fn) ~= "function" then
            error("Code must return a function, got " .. type(fn))
        end
        return fn as function(tecs.World)
    end)
    if not ok then return nil, tostring(result) end
    return result as function(tecs.World), nil
end

return sandbox
