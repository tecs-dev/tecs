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
---
--- ## Two calls the JIT must not compile
---
--- Neither is this module's to enforce, because both are properties of a call
--- site rather than of a binding, and both are silent. They are written down
--- here because this is where a binding's conventions are read.
---
--- **A variadic C function.** A call can report success and deliver a
--- corrupted value once its loop is traced. `SDL_LogMessage` in `tecs.log`
--- survives the same stress, so the rule is based on the measured call rather
--- than a theory about which arguments make it through.
---
--- **A function that calls back into Lua.** LuaJIT cannot enter an FFI
--- callback from a compiled trace and does not raise an error anything could
--- catch: it panics with "bad callback" and the process is gone. So the
--- function making the call, not the callback, is the one that has to stay
--- interpreted.
---
--- Both appear only after the loop around them has gone round fifty-six times,
--- which is the trace threshold, so a spec that exercises a call once passes
--- and a game running it every frame fails a minute in. A spec that guards one
--- has to cross that threshold on purpose; `spec/http_spec.lua` sends a
--- hundred and twenty requests for exactly that reason.
---
--- The remedy for a variadic call is `jit.off(fn)` on the calling function,
--- which makes a trace abort where it would have recorded the call.
--- Keep every variadic call behind a named helper so there is a finite set of
--- functions to mark. Prefer a native queue over any callback on a hot path.

local ffi <const> = require("ffi")

-- Enough of dlfcn to pin a library in memory. Declared here rather than
-- generated, because it is the C library's own interface and exists on every
-- target that can load one at all.
ffi.cdef([[
void *dlopen(const char *path, int mode);
char *dlerror(void);
void *LoadLibraryA(const char *path);
unsigned long GetLastError(void);
]])

--- Load now, and never unmap.
---
--- `ffi.load` returns a namespace whose collection dlcloses the library, and
--- at `lua_close` everything is collected, including a module-level cache. A
--- library holding running threads is then unmapped while they are executing
--- its code, and they fault on the next instruction: the crash report shows
--- the main thread inside `lua_close` and `dlclose` while a solver thread
--- takes a translation fault at an address that no longer maps.
---
--- Keeping a second reference the loader never drops means the mapping
--- outlives the state that asked for it, which is what a thread the engine
--- started needs. The raw handles are retained privately and are never passed
--- to `dlclose`.
local RTLD_NOW <const> = 0x2
local RTLD_NODELETE <const> = ffi.os == "OSX" and 0x80 or 0x1000
local pinned <const>: {string: any} = {}
local platformLoader <const>: any = ffi.os == "Windows" and ffi.load("kernel32") or ffi.C

--- Takes a process-lifetime reference to a dynamically loaded library.
local function pinLibrary(path: string)
    if ffi.os == "Windows" then
        -- Deliberately leaked. `ffi.load` releases its own LoadLibrary
        -- reference when the namespace is collected; this second reference
        -- remains until process exit, after every native thread has stopped.
        local loadLibrary = (platformLoader as {string: any}).LoadLibraryA as function(string): any
        local getLastError = (platformLoader as {string: any}).GetLastError as function(): integer
        local handle = loadLibrary(path)
        if handle == nil then
            error(
                ("tecs: loaded %s but could not pin it with LoadLibraryA: Windows error %d"):format(
                    path, getLastError()
                ),
                3
            )
        end
        pinned[path] = handle
        return
    end

    local dlopen = (platformLoader as {string: any}).dlopen as function(string, integer): any
    local dlerror = (platformLoader as {string: any}).dlerror as function(): any
    dlerror()
    local handle = dlopen(path, RTLD_NOW + RTLD_NODELETE)
    if handle == nil then
        local detailValue = dlerror()
        local detail = detailValue ~= nil and ffi.string(detailValue as string) as string or ""
        error(
            ("tecs: loaded %s but could not pin it with dlopen: %s"):format(
                path, detail ~= "" and detail or "unknown dynamic loader error"
            ),
            3
        )
    end
    pinned[path] = handle
end

--- Resolves native libraries, installs their generated cdefs, and names the
--- types a value crosses the FFI boundary as.
---
--- A resolved library is cached under its registry name, so the second call for
--- it hands back the first call's namespace and loads nothing. Failure is
--- always a raise: no function here answers nil to mean "not found", and the
--- two that take a possibly-NULL pointer, `toString` and `toBytes`, answer the
--- empty string for it rather than nil.
local record loader
    --- A value that crossed the FFI boundary: a function, an enum constant,
    --- a pointer, or a struct. Readable, callable, and comparable, because
    --- cdata is all of those depending on what the header declared.
    record CValue
        --- Reads a field, or resolves a symbol. Naming something the
        --- declaration does not have raises rather than answering nil, so a
        --- speculative lookup has to go through `pcall`.
        metamethod __index: function(self: CValue, key: string): CValue
        --- Calls the value as a C function. Typed to answer `CValue` because
        --- the boundary is open; what arrives is whatever the FFI converts the
        --- declared return type to, and nothing at all for a `void` function.
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
        --- Advances by whole bytes. The result aliases the same memory and
        --- carries no length, so an offset past the end of the allocation is
        --- not detected here or anywhere later.
        metamethod __add: function(self: BytePointer, offset: integer): BytePointer
        --- Reads one byte, 0-based as C pointer indexing is: index 0 is the
        --- byte the pointer itself addresses. Unchecked in both directions.
        metamethod __index: function(self: BytePointer, index: integer): integer
    end

    --- A loaded library's symbol table. Resolution happens in the FFI at
    --- call time, so the namespace is open rather than enumerated.
    record CNamespace
        --- Resolves a symbol and remembers it, so a name costs a lookup once
        --- and a table read on every call after. A name the library does not
        --- export raises at this access, not at load.
        metamethod __index: function(self: CNamespace, key: string): CValue
    end

    --- Directories searched for a library when the dynamic linker cannot
    --- resolve its plain soname. Homebrew installs outside the default path.
    ---
    --- Ordered, and searched in order: `$TECS_LIB`, then every `lib` directory
    --- beside this file or above it, then the system prefixes. Each entry ends
    --- in a separator, and a `%s` in one is replaced with the formula name
    --- `library` was given.
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
    if source == nil or source:sub(1, 1) ~= "@" then
        return nil
    end
    local directory = source:sub(2):match("^(.*)[/\\][^/\\]*$")
    if directory == nil or directory == "" then
        return nil
    end
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
    if directory == nil then
        return paths
    end

    -- Six is past the deepest layout either tree uses, so this stops rather
    -- than walking to the filesystem root on a path it does not recognise.
    for _ = 1, 6 do
        if ffi.os == "Windows" then
            -- Windows resolves linked DLLs beside the executable, so release
            -- packages stage runtime libraries in `bin` rather than `lib`.
            paths[#paths + 1] = directory .. "/bin/"
        end
        paths[#paths + 1] = directory .. "/lib/"
        local parent = directory:match("^(.*)[/\\][^/\\]+$")
        if parent == nil or parent == "" or parent == directory then
            break
        end
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

local suffix <const> = ffi.os == "Windows" and ".dll" or ffi.os == "OSX" and ".dylib" or ".so"

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
    if registry == nil then
        return nil
    end
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
    return setmetatable(
        proxy,
        {
            __index = function(_self: any, name: string): any
                -- Indexing a struct with a name it does not have raises rather
                -- than answering nil, so the miss has to be caught to fall
                -- through to the constants.
                local ok, found = pcall(function(): any return (functions as loader.CValue)[name] end)
                if not ok or found == nil then
                    found = (ffi.C as loader.CValue)[name]
                end
                rawset(proxy, name, found)
                return found
            end,
        }
    ) as loader.CNamespace
end

--- Whether a library is reachable without dynamic loading.
---
--- @param name The registry key, which is the `registryName` given to
---     `library` rather than the soname.
--- @return True when the host installed a function-pointer table for it, so
---     `library` answers without touching the filesystem. False under a plain
---     `luajit`, where nothing installed a registry at all.
function loader.isStatic(name: string): boolean
    return registryTable(name) ~= nil
end

--- Resolves a native library.
---
--- Prefers the registry, then an explicit override from `envVar`, then each
--- known prefix, and finally the plain soname so the dynamic linker's own
--- search applies. Returns the namespace and what satisfied it.
---
--- Raises when every candidate fails, with the full list of what was tried;
--- there is no nil return to test for. A library that resolved once is cached,
--- and the cache is per Lua state, so a worker resolves it again.
---
--- @param soname Library name without the `lib` prefix or extension.
--- @param formula Package name used to expand per-package prefixes, that is,
---     the `%s` in a `searchPaths` entry.
--- @param envVar Environment variable holding an absolute override path. An
---     unset or empty value is skipped rather than treated as a failure.
--- @param registryName Key the host registered this library under, and the
---     cache key. Defaults to `soname`. Several registered APIs can share one
---     library, so this is what separates them.
--- @return The library's symbol table.
--- @return What satisfied the load: an absolute path, or `"(registry)"` when
---     the host had it, or `"(cached)"` when an earlier call did. Only the
---     first is a path a caller can open.
function loader.library(
    soname: string, formula: string, envVar: string, registryName?: string
): loader.CNamespace, string
    -- Keyed by the registry name rather than the library, because several
    -- registered APIs can share one library: the worker, the log sink and the
    -- solver pool are all in libtecsworker, and each has its own table of
    -- function pointers. Keyed by the library, the first one loaded would
    -- answer for the rest, and a name only the others declare would miss.
    local key = registryName or soname
    local cached = loaded[key]
    if cached ~= nil then
        return cached, "(cached)"
    end

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
        local namespace = registryNamespace(ffi.cast(struct .. " *", table_ as string) as loader.CValue)
        loaded[key] = namespace
        return namespace, "(registry)"
    end

    local attempts: {string} = {}

    local override = os.getenv(envVar)
    if override ~= nil and override ~= "" then
        attempts[#attempts + 1] = override
    end

    for _, prefix in ipairs(loader.searchPaths) do
        local dir = prefix:find("%%s") and prefix:format(formula) or prefix
        if ffi.os == "Windows" then
            attempts[#attempts + 1] = dir .. soname .. suffix
            if formula ~= soname then
                attempts[#attempts + 1] = dir .. formula .. suffix
            end
            -- Some MinGW projects retain the Unix prefix even for a DLL.
            attempts[#attempts + 1] = dir .. "lib" .. soname .. suffix
        else
            attempts[#attempts + 1] = dir .. "lib" .. soname .. suffix
        end
    end
    if ffi.os == "Windows" then
        attempts[#attempts + 1] = soname .. suffix
        if formula ~= soname then
            attempts[#attempts + 1] = formula .. suffix
        end
    else
        -- `ffi.load("name")` adds the platform spelling internally, but the
        -- raw `dlopen` used to pin it does not. Keep the attempted value valid
        -- for both calls.
        attempts[#attempts + 1] = "lib" .. soname .. suffix
    end

    local failures: {string} = {}
    for _, path in ipairs(attempts) do
        local ok, result = pcall(ffi.load, path)
        if ok then
            local namespace = result as loader.CNamespace
            -- Pinned before anything can start a thread inside it. Loading the
            -- namespace without pinning it is not a safe partial success: the
            -- failure would surface later as executable code being unmapped
            -- during `lua_close`.
            pinLibrary(path)
            loaded[key] = namespace
            return namespace, path
        end
        failures[#failures + 1] = path .. ": " .. tostring(result)
    end

    error(
        ("tecs: cannot load %s. Tried:\n  %s\nSet %s to an absolute path."):format(
            soname, table.concat(failures, "\n  "), envVar
        ),
        2
    )
end

local declared <const>: {string: boolean} = {}

--- Installs a generated cdef exactly once.
---
--- Also installs the function-pointer table's declaration when the host
--- registered one, since that is what `library` casts through.
---
--- The record of what has already been declared is per Lua state, so a worker
--- state declares the same cdef again rather than inheriting it. Raises when
--- the generated module is absent, which means the build has not run.
---
--- @param name Module basename, e.g. "sdl3" for `tecs.ffi.sdl3cdef`. The same
---     name `constants` and `textConstants` take, and the registry key.
function loader.declare(name: string)
    if declared[name] then
        return
    end
    local ok, source = requireGenerated(name .. "cdef")
    if not ok then
        error(("tecs: missing generated cdef for %s. Run the build."):format(name), 2)
    end
    ffi.cdef(source as string)

    if registryTable(name) ~= nil then
        local hasApi, api = requireGenerated(name .. "apicdef")
        if not hasApi then
            error(("tecs: %s is registered but its table declaration is missing"):format(name), 2)
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
---
--- @param value NULL is allowed and answers the empty string, so a C getter
---     that reports absence that way needs no guard at the call site.
--- @return The bytes up to the first NUL, copied. Nothing afterwards refers to
---     the C memory, so it is free to be reused or freed.
function loader.toString(value: loader.CValue): string
    if value == nil then
        return ""
    end
    return ffi.string(value as string) as string
end

--- Converts `length` bytes at `value` to a Lua string.
---
--- Unlike `toString` this does not stop at a NUL, so it is what reads a binary
--- blob such as SPIR-V or a packed shader artifact.
---
--- @param value NULL answers the empty string whatever `length` says.
--- @param length Bytes, exactly: not an upper bound, and not checked against
---     the size of the allocation. Too large a value reads past it.
--- @return A copy, embedded NULs included, so `#` on it is `length`.
function loader.toBytes(value: loader.CValue, length: integer): string
    if value == nil then
        return ""
    end
    return ffi.string(value as string, length) as string
end

--- Allocates a single C struct.
---
--- Prefer this to a one-element array when a reusable scratch struct is
--- wanted. Indexing an array yields a *reference* into it, and a reference
--- does not keep its parent alive: if nothing else holds the array, the
--- collector frees it while the reference still points inside, and the next
--- write through that reference corrupts the heap.
---
--- @param declaration A struct type the cdef already declared, e.g.
---     `"SDL_Event"`. Naming one it did not raises.
--- @return Zero-filled, and owned by the collector: it lives exactly as long
---     as something holds this value, and no longer.
function loader.newStruct(declaration: string): loader.CValue
    return ffi.new(declaration) as loader.CValue
end

--- Allocates a C array and types it for integer indexing.
---
--- @param declaration An array type. Use the `[?]` form when `count` is given,
---     and a fixed length such as `"int[1]"` when it is not.
--- @param count Element count for a `[?]` declaration, not a byte count. Omit
---     it for a fixed-length one, where the FFI reads a second argument as an
---     initialiser for element 0 instead of as a length.
--- @return Zero-filled, and indexed from 0 rather than 1. The FFI does not
---     bound-check the index in either direction.
function loader.newArray(declaration: string, count?: integer): loader.CArray
    if count ~= nil then
        return ffi.new(declaration, count) as loader.CArray
    end
    return ffi.new(declaration) as loader.CArray
end

--- Views a pointer as bytes, so callers can offset into it.
---
--- @param base The caller keeps this alive. A cast borrows the address without
---     referencing the allocation, so a `base` that nothing else holds is
---     collected while the returned pointer still addresses it.
--- @return A view of the same memory rather than a copy: writes through it are
---     writes to `base`.
function loader.bytePointer(base: loader.CValue): loader.BytePointer
    return ffi.cast("uint8_t *", base) as loader.BytePointer
end

--- Reinterprets a pointer as another type, for writing struct fields directly
--- into mapped memory instead of memcpying a staging array.
---
--- @param declaration A pointer type, e.g. `"float *"` or `"MyVertex *"`.
---     Alignment is the caller's to establish; the FFI does not check that
---     `base` is aligned for the type being read through it.
--- @param base The caller keeps this alive, as with `bytePointer`.
--- @return Indexed from 0 and unchecked, aliasing `base` rather than copying.
function loader.castPointer(declaration: string, base: loader.CValue): loader.CArray
    return ffi.cast(declaration, base) as loader.CArray
end

--- Copies `size` bytes between FFI buffers.
---
--- @param destination Must already have room for `size` bytes. Nothing here
---     knows how large it is, so an overrun is a silent heap write.
--- @param source Read for `size` bytes from its own address, whatever its
---     declared type says its length is.
--- @param size Bytes, not elements. Zero is allowed and copies nothing.
function loader.copyBytes(destination: loader.CArray, source: loader.CValue, size: integer)
    ffi.copy(destination as string, source as string, size)
end

--- Copies `size` bytes to a byte pointer, which may be an offset into a
--- mapped region.
---
--- @param destination Carries no length, so the room for `size` bytes past it
---     is entirely the caller's to have established.
--- @param source Read for `size` bytes from its own address.
--- @param size Bytes. Zero is allowed and copies nothing.
function loader.copyTo(destination: loader.BytePointer, source: loader.CValue, size: integer)
    ffi.copy(destination as string, source as string, size)
end

--- Copies a Lua string into an FFI buffer, including its NUL terminator.
--- The destination must have room for `#source + 1` bytes.
---
--- @param destination Unchecked, as everything on this boundary is.
--- @param source Copied whole, embedded NULs and all, and then terminated.
---     Anything reading the destination back as a C string therefore stops at
---     the first embedded NUL rather than at `#source`.
function loader.copyString(destination: loader.CArray, source: string)
    ffi.copy(destination as string, source)
end

--- Allocates a byte buffer holding exactly the bytes of `source`.
---
--- No terminator, so this is what carries a blob whose length is known and
--- whose content may contain NULs, such as SPIR-V.
---
--- @param source Copied, so the buffer does not alias the Lua string and
---     outlives it. An empty string yields a zero-length allocation.
--- @return The bytes, indexed from 0, owned by the collector.
--- @return `#source`, which has to travel with the buffer: nothing in it marks
---     where the content ends.
function loader.fromString(source: string): loader.CArray, integer
    local bytes = ffi.new("uint8_t[?]", #source) as loader.CArray
    ffi.copy(bytes as string, source, #source)
    return bytes, #source
end

local function constantTable(name: string): {string: any}
    local ok, table_ = requireGenerated(name .. "const")
    if not ok then
        error(("tecs: missing generated constants for %s. Run `make cdef`."):format(name), 2)
    end
    return table_ as {string: any}
end

--- Loads a generated table of numeric `#define` constants.
---
--- These never reach the cdef: the preprocessor expands them away, so they
--- are recovered separately and cannot be read through a C namespace.
---
--- Numbers only. The same table holds the string constants, which
--- `loader.textConstants` reads under the type they actually have.
---
--- @param name Binding basename, the same one `declare` takes.
--- @return The generated table itself, not a copy, and the same table on every
---     call: mutating it changes what every other caller sees. A name this
---     library does not define reads nil. Raises when the build has not
---     produced the table at all.
function loader.constants(name: string): {string: integer}
    return constantTable(name) as {string: integer}
end

--- The same table, for the constants whose value is text.
---
--- SDL names every hint and every property with a string macro, and that name
--- is the argument the API reading it takes, so they are recovered alongside
--- the numbers rather than left out. Two views because one table cannot be
--- typed as both, and a caller knows which kind it is asking for.
---
--- @param name Binding basename, the same one `declare` takes.
--- @return The very table `loader.constants` answers with, retyped. Nothing
---     filters it, so reading a numeric constant through this view hands back
---     a number wearing a string type and the mistake surfaces downstream.
function loader.textConstants(name: string): {string: string}
    return constantTable(name) as {string: string}
end

return loader
