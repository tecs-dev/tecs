--- Build metadata for the running game. `tecs build` writes a
--- `tecs_buildinfo.lua` module at the game root describing the build (name,
--- timestamp, tool versions) and whether it is a dev build; `tecs dist`
--- packages the same module with `dev = false`. A game running without the
--- module (from source, a fixture app, or a hand-rolled build) counts as a
--- dev build.
local record buildinfo
    record Info
        --- False in builds packaged by `tecs dist`.
        dev: boolean
        --- Project name the build was created from.
        name: string
        --- Build timestamp, ISO 8601 UTC.
        built: string
        --- Tecs CLI version that produced the build.
        cli: string
        --- LÖVE version the build targeted.
        love: string
        --- LuaJIT version the build targeted.
        luajit: string
    end

    --- The build metadata, or nil when no tecs_buildinfo module exists.
    get: function(): Info

    --- Re-read the manifest from disk, bypassing the module cache. Hot
    --- reload swaps the manifest file under the running process, so the
    --- cached copy reports BOOT-time metadata; staleness checks (the MCP
    --- ping's `build`) must see what is on disk now.
    fresh: function(): Info

    --- True unless the metadata marks a distributed build.
    isDev: function(): boolean
end

local cached: buildinfo.Info = nil
local loaded = false

-- Resolved dynamically: the module only exists in CLI-produced builds, so a
-- literal require would fail the framework's own type checks.
local manifestModule = "tecs_buildinfo"

function buildinfo.get(): buildinfo.Info
    if not loaded then
        loaded = true
        local ok, info = pcall(require, manifestModule) as (boolean, any)
        if ok and info is table then
            cached = info as buildinfo.Info
        end
    end
    return cached
end

function buildinfo.fresh(): buildinfo.Info
    local pkg = (_G as {string: any}).package as {string: any}
    local loadedModules = pkg and pkg.loaded as {string: any}
    if loadedModules then loadedModules[manifestModule] = nil end
    local ok, info = pcall(require, manifestModule) as (boolean, any)
    if ok and info is table then
        cached = info as buildinfo.Info
        loaded = true
    end
    return cached
end

function buildinfo.isDev(): boolean
    local info = buildinfo.get()
    if info == nil then
        return true
    end
    return info.dev ~= false
end

return buildinfo
