--[=[
Where content is, reading it, and remembering what was read.

The content state shared below `tecs.io.files`, `tecs.io.watcher`, and the
rest of the engine.

The filesystem resolves roots and records every path it reads. The watcher
polls that set, while the shader and material loaders resolve content through
the same roots. Keeping those names here lets the two public I/O children
remain siblings instead of requiring one another.

Nothing here is public and nothing here is a second API. Filesystem operations
publish the path half, the watcher consumes the loaded-path half, and this file
is their seam rather than either surface.

Content is resolved through `adapter`, never through the process working
directory. On desktop that happens to work when launched from a project root
and breaks the moment someone double-clicks; on a device there is no
meaningful working directory and writing next to the executable is not
permitted.
]=]

local adapter <const> = require("tecs.platform.adapter")

local record content
end

local cachedGeneration = -1
local baseCache: string = nil
local prefCache: string = nil
local prefOrganization: string = nil
local prefApplication: string = nil
local cacheCache: string = nil
local cacheOrganization: string = nil
local cacheApplication: string = nil
local assetsCache: string = nil

--- Every path read or decoded this process, by the kind it was read as.
local opened <const>: {string: string} = {}

--- Drops cached roots when the platform has changed under us.
local function fresh()
    local generation <const> = adapter.generation()
    if generation == cachedGeneration then
        return
    end
    cachedGeneration = generation
    baseCache = nil
    prefCache = nil
    prefOrganization = nil
    prefApplication = nil
    cacheCache = nil
    cacheOrganization = nil
    cacheApplication = nil
    assetsCache = nil
end

--- Directory the executable was loaded from, with a trailing separator.
function content.basePath(): string
    fresh()
    if baseCache ~= nil then
        return baseCache
    end
    baseCache = adapter.current().basePath()
    return baseCache
end

--- Writable directory for `organization` and `application`, created if absent.
---
--- The names are the caller's rather than this module's, because they are a
--- value a game assigns and the place it assigns them is the public module.
function content.prefPath(organization: string, application: string): string
    fresh()
    if prefCache ~= nil and prefOrganization == organization and prefApplication == application then
        return prefCache
    end
    prefCache = adapter.current().prefPath(organization, application)
    prefOrganization = organization
    prefApplication = application
    return prefCache
end

--- Disposable directory for `organization` and `application`, created if
--- absent.
function content.cachePath(organization: string, application: string): string
    fresh()
    if cacheCache ~= nil and cacheOrganization == organization and cacheApplication == application then
        return cacheCache
    end
    cacheCache = adapter.current().cachePath(organization, application)
    cacheOrganization = organization
    cacheApplication = application
    return cacheCache
end

--- Root the engine reads content from.
---
--- Three sources, in order. `TECS_ASSETS` wins, which is how a development run
--- reads straight out of a build tree instead of a staged copy. Then what the
--- host was told at build time, since the build knows the layout it installed
--- and this is not something to sniff for. Then the executable's own directory,
--- which is where a single-directory build puts everything.
function content.assetRoot(): string
    fresh()
    if assetsCache ~= nil then
        return assetsCache
    end

    local override = os.getenv("TECS_ASSETS")
    if override == nil or override == "" then
        override = (_G as {string: any})["__tecsContent"] as string
    end
    if override ~= nil and override ~= "" then
        assetsCache = override:sub(-1) == "/" and override or override .. "/"
    else
        assetsCache = content.basePath()
    end
    return assetsCache
end

--- Resolves `relative` against the asset root.
function content.assetPath(relative: string): string
    return content.assetRoot() .. relative
end

--- Overrides the asset root, for a test or a tool.
---
--- Synchronizes first, so the override outlives the platform change that may
--- have preceded it rather than being dropped by the next read.
function content.setAssetRoot(root: string)
    fresh()
    assetsCache = root:sub(-1) == "/" and root or root .. "/"
end

--- Forgets the cached roots. A platform change is noticed without this.
function content.reset()
    cachedGeneration = adapter.generation()
    baseCache = nil
    prefCache = nil
    prefOrganization = nil
    prefApplication = nil
    cacheCache = nil
    cacheOrganization = nil
    cacheApplication = nil
    assetsCache = nil
end

--- Records a path under the kind it was first read as.
---
--- A named kind supersedes "document", whichever order the two arrive in.
function content.note(path: string, kind: string)
    local held <const> = opened[path]
    if held == nil or (held == "document" and kind ~= "document") then
        opened[path] = kind
    end
end

--- Every path this process has read or decoded, by the kind it was read as.
---
--- The live table, so the watcher polling it does not copy it every pass.
function content.loaded(): {string: string}
    return opened
end

--- Reads a whole file and returns its bytes, or nil when there is none there.
---
--- Through the platform rather than stdio, because on Android content lives
--- inside the package and only SDL's IO reaches it, and on a target with no
--- filesystem nothing else reaches it at all.
function content.read(path: string, kind?: string): string
    local bytes <const> = adapter.storage().read(path)
    if bytes == nil then
        return nil
    end
    content.note(path, kind or "document")
    return bytes
end

return content
