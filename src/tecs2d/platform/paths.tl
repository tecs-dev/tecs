--- Where assets are read from and state is written to.
---
--- Never the process working directory. On desktop that happens to work when
--- launched from a project root and breaks the moment someone double-clicks;
--- on mobile there is no meaningful working directory at all, and writing next
--- to the executable is not permitted.
---
--- So the platform is asked. Assets sit beside the executable, or wherever the
--- bundle put them; writable state goes where the platform keeps it for this
--- application and nowhere else.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

local record paths
    --- Organisation and application names, used to name the writable
    --- directory. Set before anything asks for `pref`.
    organisation: string
    application: string
end

paths.organisation = "tecs2d"
paths.application = "tecs2d"

local baseCache: string = nil
local prefCache: string = nil
local assetsCache: string = nil

--- Directory the executable was loaded from, with a trailing separator.
---
--- Empty when the platform declines to say, which is the case on some targets
--- rather than an error: callers fall back to a relative path.
function paths.base(): string
    if baseCache ~= nil then return baseCache end
    local given = C.SDL_GetBasePath()
    baseCache = given == nil and "" or loader.toString(given)
    return baseCache
end

--- Writable directory for this application, created if absent.
---
--- The only place a build may write. Everything else is read-only on at least
--- one target, and finding that out at run time on a device is expensive.
function paths.pref(): string
    if prefCache ~= nil then return prefCache end
    local given = C.SDL_GetPrefPath(paths.organisation, paths.application)
    if given == nil then
        error(("tecs2d: no writable directory: %s"):format(sdl.error()), 2)
    end
    prefCache = loader.toString(given)
    C.SDL_free(given)
    return prefCache
end

--- Root the engine reads content from.
---
--- `TECS2D_ASSETS` overrides it, which is how a development run reads straight
--- out of a source tree instead of a staged copy.
function paths.assets(): string
    if assetsCache ~= nil then return assetsCache end
    local override = os.getenv("TECS2D_ASSETS")
    if override ~= nil and override ~= "" then
        assetsCache = override:sub(-1) == "/" and override or override .. "/"
    else
        assetsCache = paths.base()
    end
    return assetsCache
end

--- Resolves `relative` against the asset root.
function paths.asset(relative: string): string
    return paths.assets() .. relative
end

--- Resolves `relative` against the writable root.
function paths.writable(relative: string): string
    return paths.pref() .. relative
end

--- Overrides the asset root, for a test or a tool.
function paths.setAssets(root: string)
    assetsCache = root:sub(-1) == "/" and root or root .. "/"
end

return paths
