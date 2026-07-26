--- Shared library resolution, cdef installation, and FFI-boundary types.
---
--- Generated cdefs live in `build/tecs2d/ffi/<name>cdef.lua` and are produced
--- by `make cdef` from the installed headers. Loading them here, rather than
--- hand-maintaining declarations, is what keeps the bindings honest: a cdef
--- that drifts from the real ABI corrupts memory instead of failing to link.

local ffi <const> = require("ffi")

local record loader
    --- A value that crossed the FFI boundary: a function, an enum constant,
    --- a pointer, or a struct. Readable, callable, and comparable, because
    --- cdata is all of those depending on what the header declared.
    record CValue
        metamethod __index: function(self: CValue, key: string): CValue
        metamethod __call: function(self: CValue, ...: any): CValue
    end

    --- A struct viewed for field assignment. Reads go through `CValue`;
    --- writes need a type that accepts arbitrary field values, which is the
    --- one thing `CValue` cannot express.
    type CStruct = {string: any}

    --- Anything addressable by integer index: arrays, pointers, and the
    --- single-element out-parameter buffers the SDL API uses.
    type CArray = {integer: any}

    --- An opaque handle. Stored and passed on, never dereferenced from Lua.
    type CPtr = CValue

    --- A loaded library's symbol table. Resolution happens in the FFI at
    --- call time, so the namespace is open rather than enumerated.
    record CNamespace
        metamethod __index: function(self: CNamespace, key: string): CValue
    end

    --- Directories searched for a library when the dynamic linker cannot
    --- resolve its plain soname. Homebrew installs outside the default path.
    searchPaths: {string}
end

loader.searchPaths = {
    -- Libraries this project links itself, such as the shared SPIRV-Cross
    -- that Homebrew only ships as static archives.
    "build/lib/",
    "/opt/homebrew/lib/",
    "/opt/homebrew/opt/%s/lib/",
    "/usr/local/lib/",
    "/usr/local/opt/%s/lib/",
    "/usr/lib/",
}

local suffix <const> = ffi.os == "Windows" and ".dll"
    or ffi.os == "OSX" and ".dylib"
    or ".so"

local loaded <const>: {string: loader.CNamespace} = {}

--- Resolves and loads a shared library.
---
--- Tries, in order: an explicit override from `envVar`, the plain soname (so
--- the dynamic linker's own search applies), then each known prefix. Returns
--- the C namespace and the path that satisfied it.
---
--- @param soname Library name without the `lib` prefix or extension.
--- @param formula Package name used to expand per-package prefixes.
--- @param envVar Environment variable holding an absolute override path.
function loader.library(soname: string, formula: string, envVar: string): loader.CNamespace, string
    local cached = loaded[soname]
    if cached ~= nil then return cached, "(cached)" end

    local attempts: {string} = {}

    local override = os.getenv(envVar)
    if override ~= nil and override ~= "" then
        attempts[#attempts + 1] = override
    end
    attempts[#attempts + 1] = soname

    for _, prefix in ipairs(loader.searchPaths) do
        local dir = prefix:find("%%s") and prefix:format(formula) or prefix
        attempts[#attempts + 1] = dir .. "lib" .. soname .. suffix
    end

    local failures: {string} = {}
    for _, path in ipairs(attempts) do
        local ok, result = pcall(ffi.load, path)
        if ok then
            local namespace = result as loader.CNamespace
            loaded[soname] = namespace
            return namespace, path
        end
        failures[#failures + 1] = path
    end

    error(("tecs2d: cannot load %s. Tried:\n  %s\nSet %s to an absolute path.")
        :format(soname, table.concat(failures, "\n  "), envVar), 2)
end

local declared <const>: {string: boolean} = {}

--- Builds a require path at runtime so the type checker does not try to
--- resolve a generated module that only exists after `make cdef`.
local function requireGenerated(name: string): boolean, any
    return pcall(require, "tecs2d.ffi." .. name)
end

--- Installs a generated cdef exactly once.
--- @param name Module basename, e.g. "sdl3" for `tecs2d.ffi.sdl3cdef`.
function loader.declare(name: string)
    if declared[name] then return end
    local ok, source = requireGenerated(name .. "cdef")
    if not ok then
        error(("tecs2d: missing generated cdef for %s. Run `make cdef`."):format(name), 2)
    end
    ffi.cdef(source as string)
    declared[name] = true
end

--- Converts a `const char *` result to a Lua string.
---
--- The cast is the narrow, deliberate kind: `ffi.string` is declared over a
--- CData union that cannot name an open FFI value, so it lives here once
--- instead of at every call site.
function loader.toString(value: loader.CValue): string
    if value == nil then return "" end
    return ffi.string(value as string) as string
end

--- Allocates a C array and types it for integer indexing.
function loader.newArray(declaration: string, count?: integer): loader.CArray
    if count ~= nil then
        return ffi.new(declaration, count) as loader.CArray
    end
    return ffi.new(declaration) as loader.CArray
end

--- Copies `size` bytes between FFI buffers.
function loader.copyBytes(destination: loader.CArray, source: loader.CValue,
                          size: integer)
    ffi.copy(destination as string, source as string, size)
end

--- Copies a Lua string into an FFI buffer, without a terminator.
function loader.copyString(destination: loader.CArray, source: string)
    ffi.copy(destination as string, source)
end

--- Loads a generated table of integer `#define` constants.
---
--- These never reach the cdef: the preprocessor expands them away, so they
--- are recovered separately and cannot be read through a C namespace.
function loader.constants(name: string): {string: integer}
    local ok, table_ = requireGenerated(name .. "const")
    if not ok then
        error(("tecs2d: missing generated constants for %s. Run `make cdef`."):format(name), 2)
    end
    return table_ as {string: integer}
end

return loader
