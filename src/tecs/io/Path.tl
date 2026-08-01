--[=[
Immutable, platform-native filesystem paths.

[`Path`](tealdoc:tecs.io.Path) is an immutable platform-native UTF-8
filesystem path. Methods interpret roots, separators, drive prefixes, and UNC
paths according to the operating system running Tecs. They return new paths
rather than mutating their receiver:

```teal
local root <const> = tecs.io.Path.new("assets")
local shader <const> = root:join("shaders", "sprite.glsl")

print(shader:fileName())
print(shader:withExtension("spv"))
```

`normalize` is lexical. It removes redundant separators and `.` components
and resolves `..` without reading the filesystem. That is useful for output
paths which do not exist yet, but it can change which object a path denotes
when a traversed component is a symbolic link. `canonicalize` reads the
filesystem, requires the path to exist, and follows symbolic links:
use `resolve` for a normalized absolute spelling of a configured output and
`canonicalize` only when an existing object's filesystem identity matters.

Paths contain valid UTF-8 and no NUL byte, matching the string contract used
by Tecs file and process APIs. Unix filenames containing invalid UTF-8 cannot
be represented. A path object owns only its immutable Lua string and needs no
`close`.
]=]

local ffi <const> = require("ffi")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")

local C <const> = rust.C

local record Path
    --- Returns this path's platform-native UTF-8 spelling.
    ---
    --- `tostring(path)` returns the same string.
    --- @param self The immutable path to render.
    --- @return Returns the complete path without accessing the filesystem.
    toString: function(self: Path): string

    --- Appends path components and returns the result.
    ---
    --- A later absolute argument replaces everything accumulated before it,
    --- following the host platform's path rules. The result is not normalized
    --- and no component needs to exist.
    --- @param self The base path left unchanged.
    --- @param ... The caller supplies strings or paths to append in order.
    --- @return Returns a new immutable path.
    join: function(self: Path, ...: string | Path): Path

    --- Returns a lexically normalized path without filesystem access.
    ---
    --- Redundant separators and `.` are removed and `..` is resolved. A
    --- symbolic link can make that lexical result denote a different object.
    --- @param self The path to normalize.
    --- @return Returns a new immutable path.
    normalize: function(self: Path): Path

    --- Returns an absolute spelling without requiring the path to exist.
    ---
    --- A relative receiver is based on the process's current directory.
    --- Unlike `resolve`, this preserves platform-significant parent
    --- components where the native absolute operation preserves them.
    --- @param self The path to make absolute.
    --- @return Returns a new immutable absolute path.
    --- @return Returns the platform reason when the current directory cannot
    ---     be determined.
    absolute: function(self: Path): Path, string

    --- Returns a normalized absolute spelling without filesystem access.
    ---
    --- Arguments are joined first. The process's current directory supplies
    --- the base when the joined path remains relative.
    --- @param self The first path in the resolution.
    --- @param ... The caller supplies strings or paths to append in order.
    --- @return Returns a new immutable normalized absolute path.
    --- @return Returns the platform reason when the current directory cannot
    ---     be determined.
    resolve: function(self: Path, ...: string | Path): Path, string

    --- Resolves filesystem identity and follows symbolic links.
    ---
    --- The receiver must exist. The result is absolute and normalized by the
    --- operating system.
    --- @param self The existing path to canonicalize.
    --- @return Returns a new immutable canonical path.
    --- @return Returns the filesystem reason when the first return is nil.
    canonicalize: function(self: Path): Path, string

    --- Expresses this path relative to a base path.
    ---
    --- Neither path is accessed. On Windows, paths on different drives or UNC
    --- roots have no relative spelling.
    --- @param self The destination path.
    --- @param base The caller supplies the directory from which to describe
    ---     the destination.
    --- @return Returns a new immutable relative path.
    --- @return Returns a reason when the two paths cannot share a coordinate
    ---     system.
    relativeTo: function(self: Path, base: string | Path): Path, string

    --- Returns this path without its final component.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns a new immutable parent, or nil when the path has none.
    parent: function(self: Path): Path

    --- Returns the final path component.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns the final component, or nil for a root or terminal
    ---     parent component.
    fileName: function(self: Path): string

    --- Returns the final component without its last extension.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns the stem, or nil when the path has no file name.
    stem: function(self: Path): string

    --- Returns the final component's last extension without its dot.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns the extension, or nil when none exists.
    extension: function(self: Path): string

    --- Replaces the final component.
    ---
    --- @param self The path whose parent is retained.
    --- @param name The caller supplies one non-empty platform path component.
    --- @return Returns a new immutable path.
    withFileName: function(self: Path, name: string): Path

    --- Replaces or removes the final component's extension.
    ---
    --- @param self The path whose final component changes.
    --- @param extension The caller supplies one component without a leading
    ---     dot, or an empty string to remove the extension.
    --- @return Returns a new immutable path.
    withExtension: function(self: Path, extension: string): Path

    --- Returns whether this path carries a platform root.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns true when the path is absolute on this platform.
    isAbsolute: function(self: Path): boolean

    --- Returns whether this path needs a base directory.
    ---
    --- @param self The path to inspect without filesystem access.
    --- @return Returns true when the path is relative on this platform.
    isRelative: function(self: Path): boolean

    --- Creates an immutable path from platform-native components.
    ---
    --- Construction joins the components lexically and does not require the
    --- path to exist. A later absolute component replaces the accumulated
    --- prefix according to the host platform's rules.
    --- @param first The caller supplies the first valid UTF-8 path component
    ---     or complete path, without a NUL byte.
    --- @param ... The caller supplies additional path components in order.
    --- @return Returns a new immutable path.
    new: function(first: string, ...: string): Path

    --- Returns the process's current working directory.
    ---
    --- @return Returns a new immutable normalized absolute path.
    --- @return Returns the platform reason when the first return is nil.
    currentDirectory: function(): Path, string

    --- Returns the platform's preferred path separator.
    ---
    --- Paths accept the forms supported by the host platform; this value is
    --- only for text that must display or emit a separator itself.
    --- @return Returns `"\\"` on Windows and `"/"` elsewhere.
    separator: function(): string
end

local type Part = string | Path
local values <const>: {Path: string} = setmetatable({}, {__mode = "k"} as metatable<{Path: string}>)

local function reason(): string
    return loader.toString(C.tecsRustError())
end

local function bytes(handle: loader.CPtr): string
    if handle == nil then
        return nil
    end
    local length <const> = tonumber(C.tecsBytesLength(handle)) as integer
    local value <const> = loader.toBytes(C.tecsBytesData(handle), length)
    C.tecsBytesDestroy(handle)
    return value
end

local PathMT: metatable<Path>

local function make(value: string): Path
    local made <const> = setmetatable({} as Path, PathMT)
    values[made] = value
    return made
end

local function valueOf(value: Part, level: integer): string
    if type(value) == "string" then
        local text <const> = value as string
        if not C.tecsPathValidate(text, #text) then
            error("tecs: invalid path: " .. reason(), level)
        end
        return text
    end
    local stored <const> = values[value as Path]
    if stored == nil then
        error("tecs: expected a string or io.Path", level)
    end
    return stored
end

local function lexical(handle: loader.CPtr, what: string, level: integer): Path
    local value <const> = bytes(handle)
    if value == nil then
        error(("tecs: cannot %s path: %s"):format(what, reason()), level)
    end
    return make(value)
end

PathMT = {
    __index = Path,
    __tostring = function(value: Path): string
        return values[value]
    end,
    __eq = function(left: Path, right: Path): boolean
        return values[left] == values[right]
    end,
}

function Path:toString(): string
    return values[self]
end

local function joinValues(held: {string}): Path
    local count <const> = #held
    local views <const> = loader.newArray("TecsStringView[?]", count)
    for index = 1, count do
        local view = views[index - 1] as {string: any}
        view.data = ffi.cast("const uint8_t *", held[index])
        view.length = #held[index]
    end
    return lexical(C.tecsPathJoin(views, count), "join", 2)
end

function Path:join(...: string | Path): Path
    local arguments <const>: {Part} = {...}
    local held <const>: {string} = {values[self]}
    for index = 1, #arguments do
        held[index + 1] = valueOf(arguments[index], 3)
    end
    return joinValues(held)
end

function Path:normalize(): Path
    local value <const> = values[self]
    return lexical(C.tecsPathNormalize(value, #value), "normalize", 2)
end

function Path:absolute(): Path, string
    local value <const> = values[self]
    local result <const> = bytes(C.tecsPathAbsolute(value, #value))
    if result == nil then
        return nil, reason()
    end
    return make(result)
end

function Path:resolve(...: string | Path): Path, string
    local absolute <const>, absoluteReason = self:join(...):absolute()
    if absolute == nil then
        return nil, absoluteReason
    end
    return absolute:normalize()
end

function Path:canonicalize(): Path, string
    local value <const> = values[self]
    local result <const> = bytes(C.tecsPathCanonicalize(value, #value))
    if result == nil then
        return nil, reason()
    end
    return make(result)
end

function Path:relativeTo(base: string | Path): Path, string
    local value <const> = values[self]
    local baseValue <const> = valueOf(base, 2)
    local result <const> = bytes(C.tecsPathRelative(value, #value, baseValue, #baseValue))
    if result == nil then
        return nil, reason()
    end
    return make(result)
end

function Path:parent(): Path
    local value <const> = values[self]
    local result <const> = bytes(C.tecsPathParent(value, #value))
    return result ~= nil and make(result) or nil
end

function Path:fileName(): string
    local value <const> = values[self]
    return bytes(C.tecsPathFileName(value, #value))
end

function Path:stem(): string
    local value <const> = values[self]
    return bytes(C.tecsPathStem(value, #value))
end

function Path:extension(): string
    local value <const> = values[self]
    return bytes(C.tecsPathExtension(value, #value))
end

function Path:withFileName(name: string): Path
    local value <const> = values[self]
    local checked <const> = valueOf(name, 2)
    return lexical(C.tecsPathWithFileName(value, #value, checked, #checked), "replace file name in", 2)
end

function Path:withExtension(extension: string): Path
    local value <const> = values[self]
    local checked <const> = valueOf(extension, 2)
    return lexical(C.tecsPathWithExtension(value, #value, checked, #checked), "replace extension in", 2)
end

function Path:isAbsolute(): boolean
    local value <const> = values[self]
    return C.tecsPathIsAbsolute(value, #value) as boolean
end

function Path:isRelative(): boolean
    return not self:isAbsolute()
end

function Path.new(first: string, ...: string): Path
    local rest <const>: {string} = {...}
    local held <const>: {string} = {valueOf(first, 2)}
    for index = 1, #rest do
        held[index + 1] = valueOf(rest[index], 2)
    end
    return joinValues(held)
end

function Path.currentDirectory(): Path, string
    return Path.new("."):resolve()
end

function Path.separator(): string
    return ffi.os == "Windows" and "\\" or "/"
end

return Path
