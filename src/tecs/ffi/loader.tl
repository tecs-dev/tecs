--- Native library resolution, cdef installation, and FFI-boundary types.
---
--- Generated cdefs are produced by the build from the installed headers.
--- Loading them here, rather than hand-maintaining declarations, is what keeps
--- the bindings honest: a cdef that drifts from the real ABI corrupts memory
--- instead of failing to link.
---
--- A library is reached through the registry the host installed if there is
--- one, and through `ffi.load` otherwise. The registry is a table of function
--- pointers taken at build time, which is the only way to call C on a target
--- that links everything statically and forbids loading a library by name.
--- `ffi.load` remains for desktop development, where running under a plain
--- `luajit` means no host installed anything.

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

    --- A byte pointer that supports arithmetic, so a producer can be handed
    --- the exact address to write at.
    record BytePointer
        metamethod __add: function(self: BytePointer, offset: integer): BytePointer
        metamethod __index: function(self: BytePointer, index: integer): integer
    end

    --- A loaded library's symbol table. Resolution happens in the FFI at
    --- call time, so the namespace is open rather than enumerated.
    record CNamespace
        metamethod __index: function(self: CNamespace, key: string): CValue
    end

    --- Directories searched for a library when the dynamic linker cannot
    --- resolve its plain soname. Homebrew installs outside the default path.
    searchPaths: {string}
end

--- Directory this file was loaded from, or nil when that cannot be told.
---
--- The libraries this project builds itself sit beside the Lua it ships, so
--- where this module came from is the one thing that locates them without being
--- told. A tool installed under a prefix nobody chose in advance still finds
--- them, which is what a command line program needs: an environment variable
--- that has to be set is a program that does not run.
local function ownDirectory(): string
    local source = debug.getinfo(1, "S").source
    if source == nil or source:sub(1, 1) ~= "@" then return nil end
    local directory = source:sub(2):match("^(.*)[/\\][^/\\]*$")
    if directory == nil or directory == "" then return nil end
    return directory
end

--- Every `lib` directory beside this file or any of its parents.
---
--- Walked rather than computed, because the depth differs: a build tree has the
--- Lua at `<root>/lua` and the libraries at `<root>/lib`, and an installed one
--- has them at `<prefix>/share/tecs/lua` and `<prefix>/lib`. Walking up finds
--- both without either layout being written down here, and finds neither when
--- the answer is somewhere else entirely.
local function siblingLibraryPaths(): {string}
    local paths: {string} = {}
    local directory = ownDirectory()
    if directory == nil then return paths end

    -- Six is past the deepest layout either tree uses, so this stops rather
    -- than walking to the filesystem root on a path it does not recognise.
    for _ = 1, 6 do
        paths[#paths + 1] = directory .. "/lib/"
        local parent = directory:match("^(.*)[/\\][^/\\]+$")
        if parent == nil or parent == "" or parent == directory then break end
        directory = parent
    end
    return paths
end

loader.searchPaths = {}

-- The build system knows where it put them, so it is asked first.
local configured <const> = os.getenv("TECS_LIB")
if configured ~= nil and configured ~= "" then
    loader.searchPaths[#loader.searchPaths + 1] = configured .. "/"
end

-- Then wherever this file is, which is how an installed tree answers.
for _, path in ipairs(siblingLibraryPaths()) do
    loader.searchPaths[#loader.searchPaths + 1] = path
end

-- Then the system, where a dependency such as SDL lives. Homebrew installs
-- outside the default linker path, hence the prefixes.
for _, path in ipairs({
    "/opt/homebrew/lib/",
    "/opt/homebrew/opt/%s/lib/",
    "/usr/local/lib/",
    "/usr/local/opt/%s/lib/",
    "/usr/lib/",
}) do
    loader.searchPaths[#loader.searchPaths + 1] = path
end

local suffix <const> = ffi.os == "Windows" and ".dll"
    or ffi.os == "OSX" and ".dylib"
    or ".so"

local loaded <const>: {string: loader.CNamespace} = {}

--- Builds a require path at runtime so the type checker does not try to
--- resolve a generated module that only exists after `make cdef`.
local function requireGenerated(name: string): boolean, any
    return pcall(require, "tecs.ffi." .. name)
end

--- Struct name of each library's function-pointer table, by registry key.
---
--- Generated by the build from the same list that produces the registry
--- itself, because a library added to one and not the other resolves through
--- `ffi.load` in development and fails only under the host, where the registry
--- is the path that runs. Loaded on first use, since it is only consulted when
--- a host installed a registry at all.
local structs: {string: string} = nil

--- The function-pointer table the host installed for `name`, if any.
local function registryTable(name: string): loader.CValue
    local registry = (_G as {string: any})["__tecsRegistry"]
    if registry == nil then return nil end
    return (registry as {string: any})[name] as loader.CValue
end

--- Wraps a function-pointer table so it answers like a C namespace.
---
--- The table holds functions only. Enum constants are compile-time values the
--- FFI resolves through any namespace, so those come from `ffi.C`, which needs
--- no library loaded to answer.
---
--- Resolved names are written back into the proxy, so a name costs a
--- metatable miss once and is a plain table read afterwards. Leaving every
--- access on the metamethod would put a lookup in front of every C call the
--- engine makes.
local function registryNamespace(functions: loader.CValue): loader.CNamespace
    local proxy = {}
    return setmetatable(proxy, {
        __index = function(_self: any, name: string): any
            -- Indexing a struct with a name it does not have raises rather
            -- than answering nil, so the miss has to be caught to fall
            -- through to the constants.
            local ok, found = pcall(function(): any
                return (functions as loader.CValue)[name]
            end)
            if not ok or found == nil then
                found = (ffi.C as loader.CValue)[name]
            end
            rawset(proxy, name, found)
            return found
        end,
    }) as loader.CNamespace
end

--- Whether a library is reachable without dynamic loading.
function loader.isStatic(name: string): boolean
    return registryTable(name) ~= nil
end

--- Resolves a native library.
---
--- Prefers the registry, then an explicit override from `envVar`, then the
--- plain soname so the dynamic linker's own search applies, then each known
--- prefix. Returns the namespace and what satisfied it.
---
--- @param soname Library name without the `lib` prefix or extension.
--- @param formula Package name used to expand per-package prefixes.
--- @param envVar Environment variable holding an absolute override path.
--- @param registryName Key the host registered this library under.
function loader.library(soname: string, formula: string, envVar: string,
                        registryName?: string): loader.CNamespace, string
    -- Keyed by the registry name rather than the library, because several
    -- registered APIs can share one library: the worker, the log sink and the
    -- solver pool are all in libtecsworker, and each has its own table of
    -- function pointers. Keyed by the library, the first one loaded would
    -- answer for the rest, and a name only the others declare would miss.
    local key = registryName or soname
    local cached = loaded[key]
    if cached ~= nil then return cached, "(cached)" end

    -- Taken at build time, so this path needs no dlopen and works where one is
    -- not permitted.
    local table_ = registryTable(key)
    if table_ ~= nil then
        if structs == nil then
            local hasStructs, generated = requireGenerated("registrystructs")
            structs = hasStructs and generated as {string: string} or {}
        end
        local struct = structs[key]
        if struct == nil then
            error(("tecs: %s is in the registry with no declared table"):format(key), 2)
        end
        local namespace = registryNamespace(
            ffi.cast(struct .. " *", table_ as string) as loader.CValue)
        loaded[key] = namespace
        return namespace, "(registry)"
    end

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
            loaded[key] = namespace
            return namespace, path
        end
        failures[#failures + 1] = path
    end

    error(("tecs: cannot load %s. Tried:\n  %s\nSet %s to an absolute path.")
        :format(soname, table.concat(failures, "\n  "), envVar), 2)
end

local declared <const>: {string: boolean} = {}

--- Installs a generated cdef exactly once.
---
--- Also installs the function-pointer table's declaration when the host
--- registered one, since that is what `library` casts through.
--- @param name Module basename, e.g. "sdl3" for `tecs.ffi.sdl3cdef`.
function loader.declare(name: string)
    if declared[name] then return end
    local ok, source = requireGenerated(name .. "cdef")
    if not ok then
        error(("tecs: missing generated cdef for %s. Run the build."):format(name), 2)
    end
    ffi.cdef(source as string)

    if registryTable(name) ~= nil then
        local hasApi, api = requireGenerated(name .. "apicdef")
        if not hasApi then
            error(("tecs: %s is registered but its table declaration is missing")
                :format(name), 2)
        end
        ffi.cdef(api as string)
    end

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

--- Converts `length` bytes at `value` to a Lua string.
---
--- Unlike `toString` this does not stop at a NUL, so it is what reads a binary
--- blob such as SPIR-V or a packed shader artifact.
function loader.toBytes(value: loader.CValue, length: integer): string
    if value == nil then return "" end
    return ffi.string(value as string, length) as string
end

--- Allocates a single C struct.
---
--- Prefer this to a one-element array when a reusable scratch struct is
--- wanted. Indexing an array yields a *reference* into it, and a reference
--- does not keep its parent alive: if nothing else holds the array, the
--- collector frees it while the reference still points inside, and the next
--- write through that reference corrupts the heap.
function loader.newStruct(declaration: string): loader.CValue
    return ffi.new(declaration) as loader.CValue
end

--- Allocates a C array and types it for integer indexing.
function loader.newArray(declaration: string, count?: integer): loader.CArray
    if count ~= nil then
        return ffi.new(declaration, count) as loader.CArray
    end
    return ffi.new(declaration) as loader.CArray
end

--- Views a pointer as bytes, so callers can offset into it.
function loader.bytePointer(base: loader.CValue): loader.BytePointer
    return ffi.cast("uint8_t *", base) as loader.BytePointer
end

--- Reinterprets a pointer as another type, for writing struct fields directly
--- into mapped memory instead of memcpying a staging array.
function loader.castPointer(declaration: string, base: loader.CValue): loader.CArray
    return ffi.cast(declaration, base) as loader.CArray
end

--- Copies `size` bytes between FFI buffers.
function loader.copyBytes(destination: loader.CArray, source: loader.CValue,
                          size: integer)
    ffi.copy(destination as string, source as string, size)
end

--- Copies `size` bytes to a byte pointer, which may be an offset into a
--- mapped region.
function loader.copyTo(destination: loader.BytePointer, source: loader.CValue,
                       size: integer)
    ffi.copy(destination as string, source as string, size)
end

--- Copies a Lua string into an FFI buffer, including its NUL terminator.
--- The destination must have room for `#source + 1` bytes.
function loader.copyString(destination: loader.CArray, source: string)
    ffi.copy(destination as string, source)
end

--- Allocates a byte buffer holding exactly the bytes of `source`.
---
--- No terminator, so this is what carries a blob whose length is known and
--- whose content may contain NULs, such as SPIR-V.
function loader.fromString(source: string): loader.CArray, integer
    local bytes = ffi.new("uint8_t[?]", #source) as loader.CArray
    ffi.copy(bytes as string, source, #source)
    return bytes, #source
end

--- Loads a generated table of integer `#define` constants.
---
--- These never reach the cdef: the preprocessor expands them away, so they
--- are recovered separately and cannot be read through a C namespace.
function loader.constants(name: string): {string: integer}
    local ok, table_ = requireGenerated(name .. "const")
    if not ok then
        error(("tecs: missing generated constants for %s. Run `make cdef`."):format(name), 2)
    end
    return table_ as {string: integer}
end

return loader
