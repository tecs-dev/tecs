--- Where content is, reading it, and remembering what was read.
---
--- The half of `tecs.filesystem` that sits below the rest of the engine rather
--- than beside it, and the reason it is a module of its own is a direction in
--- the graph. Three things read content: the shader loader, the material
--- loader, and the watcher that polls what this process has opened. The
--- watcher also sits under `tecs.filesystem` as a name a game writes, so the
--- public module has to name the watcher's type, and Teal refuses a require
--- cycle even when one side of it is erased at codegen. So the names those
--- three need are here, below both, and the public module is what a game
--- writes.
---
--- Nothing here is public and nothing here is a second API. Every name below
--- appears on `tecs.filesystem`, documented there, and this file is the seam
--- rather than the surface.
---
--- Content is resolved through `adapter`, never through the process working
--- directory. On desktop that happens to work when launched from a project root
--- and breaks the moment someone double-clicks; on a device there is no
--- meaningful working directory and writing next to the executable is not
--- permitted.

local adapter <const> = require("tecs.platform.adapter")

local record content
end

local cachedGeneration = -1
local baseCache: string = nil
local prefCache: string = nil
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

--- Writable directory for `organisation` and `application`, created if absent.
---
--- The names are the caller's rather than this module's, because they are a
--- value a game assigns and the place it assigns them is the public module.
function content.prefPath(organisation: string, application: string): string
    fresh()
    if prefCache ~= nil then
        return prefCache
    end
    prefCache = adapter.current().prefPath(organisation, application)
    return prefCache
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
--- Synchronises first, so the override outlives the platform change that may
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
