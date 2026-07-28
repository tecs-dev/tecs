--- What a project is, and how one is found.
---
--- **A project is a directory holding `tecs.lua`, and that file is both the
--- marker and the manifest.** It returns a table. Every field but `name` has a
--- default, so the smallest legal project is four words long.
---
---     return { name = "hello" }
---
--- The search runs upward from the working directory, which is the difference
--- from the previous tool: that one treated `tlconfig.lua` in the working
--- directory as the definition of a project, so `tecs check` answered from the
--- root of a project and failed one directory inside it. Conflating the type
--- checker's configuration with the project's own is what caused that, and the
--- two are separate files here for exactly that reason. `tecs new` still writes
--- a `tlconfig.lua`, because `tl` needs one; nothing looks for it.
---
--- Lua rather than JSON, for three reasons. It needs no parser, it takes
--- comments, and it can be type-checked by the same Teal the CLI already runs.
--- Executable configuration is a trust question in general and is not one here:
--- `tecs run` compiles and runs this project's own source in this process, so a
--- manifest that can run code is not a boundary that was otherwise closed.

local tecs <const> = require("tecs")

local record project
    --- Absolute path to the directory holding `tecs.lua`.
    root: string
    --- What the game is called. The only required field.
    name: string
    --- Reverse-DNS identifier, for a bundle and for the save directory.
    identifier: string
    --- Teal entry point, relative to the root. Must return an application.
    entry: string
    --- Where the project's own Teal lives.
    source: string
    --- Where its assets live.
    assets: string
    --- Where its specs live.
    spec: string
    --- Where compiled output goes.
    build: string

    --- Native code the project builds for itself.
    ---
    --- Declared rather than detected. A `CMakeLists.txt` in a project may be
    --- there for something that has nothing to do with the game, and a build
    --- that starts a compiler because it found a file is a build whose slow
    --- path nobody asked for. This key is what turns it on, and its absence is
    --- what makes the common case need no compiler at all.
    record Native
        --- Directory holding the project's own CMakeLists.txt.
        cmake: string
        --- Library name, without the platform's prefix or extension.
        library: string
    end
    native: Native

    --- The manifest's file name, which is also the marker.
    manifest: string

    record Window
        title: string
        width: integer
        height: integer
    end
    window: Window
end

--- The manifest's own file name, which is also the marker.
local MANIFEST <const> = "tecs.lua"

--- Reads `tecs.lua` at `directory` and fills in every default.
local function read(directory: string): project, string
    local path = directory .. "/" .. MANIFEST
    local chunk, syntaxError = loadfile(path)
    if chunk == nil then
        return nil, syntaxError
    end

    local ok, value = pcall(chunk as function(): any)
    if not ok then
        return nil, ("%s: %s"):format(path, tostring(value))
    end
    if not (value is table) then
        return nil, ("%s must return a table"):format(path)
    end

    local fields = value as {string: any}
    local name = fields.name as string
    if name == nil or name == "" then
        return nil, ("%s must set a name"):format(path)
    end

    return {
        root = directory,
        name = name,
        identifier = fields.identifier as string or ("com.example." .. name:gsub("[^%w]", "")),
        entry = fields.entry as string or "src/main.tl",
        source = fields.source as string or "src",
        assets = fields.assets as string or "assets",
        spec = fields.spec as string or "spec",
        build = fields.build as string or "build",
        native = fields.native as project.Native,
        window = fields.window as project.Window,
    }
end

--- Whether `directory` is a project root.
function project.marks(directory: string): boolean
    return tecs.filesystem.isFile(directory .. "/" .. MANIFEST)
end

--- The project containing `from`, searched for upward.
---
--- Stops at the filesystem root rather than at a fixed depth, because a project
--- can be nested arbitrarily deep inside itself and a limit would be a number
--- somebody's tree eventually exceeds.
--- @return The project, or nil and the reason there is none.
function project.find(from?: string): project, string
    local directory = from
    if directory == nil or directory == "" then
        directory = tecs.filesystem.currentDirectory()
    end
    if directory == nil then
        return nil, "cannot read the working directory"
    end
    if directory:sub(-1) == "/" then
        directory = directory:sub(1, -2)
    end

    local at = directory
    while at ~= nil and at ~= "" do
        if project.marks(at) then
            return read(at)
        end
        local up = at:match("^(.*)/[^/]+$")
        if up == nil or up == at then
            break
        end
        at = up
    end

    return nil, ("no %s here or in any parent of %s"):format(MANIFEST, directory)
end

--- Resolves a project-relative path.
function project.path(self: project, relative: string): string
    return self.root .. "/" .. relative
end

--- The manifest's file name, for the messages that name it.
project.manifest = MANIFEST

return project
