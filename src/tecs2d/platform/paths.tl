--- Where assets are read from and state is written to.
---
--- Never the process working directory. On desktop that happens to work when
--- launched from a project root and breaks the moment someone double-clicks;
--- on mobile there is no meaningful working directory at all, and writing next
--- to the executable is not permitted.
---
--- So the platform is asked, through `adapter`, which is the seam a licensed
--- port replaces. Assets sit beside the executable, or wherever the bundle put
--- them; writable state goes where the platform keeps it for this application
--- and nowhere else.

local adapter <const> = require("tecs2d.platform.adapter")

local record paths
    --- Organisation and application names, used to name the writable
    --- directory. Set before anything asks for `pref`.
    organisation: string
    application: string
end

paths.organisation = "tecs2d"
paths.application = "tecs2d"

local cachedGeneration = -1
local baseCache: string = nil
local prefCache: string = nil
local assetsCache: string = nil

--- Drops cached roots when the platform has changed under us.
local function fresh()
    local generation = adapter.generation()
    if generation == cachedGeneration then return end
    cachedGeneration = generation
    baseCache = nil
    prefCache = nil
    assetsCache = nil
end

--- Directory the executable was loaded from, with a trailing separator.
---
--- Empty when the platform declines to say, which is the case on some targets
--- rather than an error: callers fall back to a relative path.
function paths.base(): string
    fresh()
    if baseCache ~= nil then return baseCache end
    baseCache = adapter.current().basePath()
    return baseCache
end

--- Writable directory for this application, created if absent.
---
--- The only place a build may write. Everything else is read-only on at least
--- one target, and finding that out at run time on a device is expensive.
function paths.pref(): string
    fresh()
    if prefCache ~= nil then return prefCache end
    prefCache = adapter.current().prefPath(paths.organisation, paths.application)
    return prefCache
end

--- Root the engine reads content from.
---
--- Three sources, in order. `TECS2D_ASSETS` wins, which is how a development
--- run reads straight out of a build tree instead of a staged copy. Then what
--- the host was told at build time, since the build knows the layout it
--- installed and this is not something to sniff for. Then the executable's own
--- directory, which is where a single-directory build puts everything.
function paths.assets(): string
    fresh()
    if assetsCache ~= nil then return assetsCache end

    local override = os.getenv("TECS2D_ASSETS")
    if override == nil or override == "" then
        override = (_G as {string: any})["__tecs2dContent"] as string
    end
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

--- Forgets the cached roots. A platform change is noticed without this.
function paths.reset()
    cachedGeneration = adapter.generation()
    baseCache = nil
    prefCache = nil
    assetsCache = nil
end

--- Overrides the asset root, for a test or a tool.
---
--- Synchronises first, so the override outlives the platform change that may
--- have preceded it rather than being dropped by the next read.
function paths.setAssets(root: string)
    fresh()
    assetsCache = root:sub(-1) == "/" and root or root .. "/"
end

return paths
