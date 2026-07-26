--- What this build of the engine can do on this target.
---
--- Read rather than inferred. Selecting behaviour from `ffi.os` guesses: it
--- cannot tell a build that linked a shader compiler from one that did not, or
--- an interpreter-only LuaJIT from a jitting one, and both distinctions change
--- what the engine is allowed to attempt.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

local record capabilities
    --- Platform name as SDL reports it.
    target: string
    --- CPU architecture LuaJIT was built for.
    architecture: string

    --- Whether machine code is being generated. False on a target that
    --- forbids it, where the interpreter runs instead. Independent of `ffi`,
    --- which is required everywhere.
    jit: boolean
    --- Always true. The engine has no path that does not use the FFI, so a
    --- build without it does not run at all rather than running degraded.
    ffi: boolean

    --- Whether a library can be loaded by name at run time. False where every
    --- library is linked into the executable.
    dynamicLibraries: boolean
    --- Whether shaders can be compiled from source at run time.
    runtimeShaders: boolean
    --- Shader formats this target consumes.
    shaderFormats: {string}

    --- Input and threading the target provides.
    touch: boolean
    controller: boolean
    sensors: boolean
    workers: boolean
    --- Logical cores, for sizing a worker pool.
    cores: integer

    --- Where content is read from and state is written to.
    writableStorage: boolean
end

local resolved: capabilities = nil

--- Whether LuaJIT is compiling rather than interpreting.
---
--- Reached dynamically so a build whose `jit` module was stripped reports
--- honestly instead of failing to load.
local function jitEnabled(): boolean
    local ok, module = pcall(require, "jit")
    if not ok then return false end
    local status = (module as {string: any}).status
    if status == nil then return false end
    local running = (status as function(): boolean)()
    return running == true
end

--- Reads the capabilities of the running build.
---
--- Cached: none of these change while the process lives.
function capabilities.get(): capabilities
    if resolved ~= nil then return resolved end

    local platform = loader.toString(C.SDL_GetPlatform())

    -- Compiling a shader needs the compiler to have been linked. A release
    -- links none and consumes packaged artifacts, so this is a property of the
    -- build rather than of the platform.
    local hasCompiler = pcall(require, "tecs2d.ffi.shaderc")
        and pcall(require, "tecs2d.ffi.spvc")

    -- Metal takes MSL, everything else takes SPIR-V.
    local formats: {string} = { "spirv" }
    if ffi.os == "OSX" or ffi.os == "iOS" then
        formats = { "msl", "metallib" }
    end

    resolved = {
        target = platform,
        architecture = ffi.arch,
        -- Whether machine code is being generated. On a target that forbids
        -- writable executable memory it is not, and the interpreter runs.
        jit = jitEnabled(),
        ffi = true,
        -- A registry means the libraries were linked, which is the case
        -- precisely where loading one by name is not available.
        dynamicLibraries = not loader.isStatic("sdl3"),
        runtimeShaders = hasCompiler,
        shaderFormats = formats,
        touch = tonumber(C.SDL_GetNumLogicalCPUCores()) ~= nil
            and (platform == "iOS" or platform == "Android"),
        controller = true,
        sensors = platform == "iOS" or platform == "Android",
        workers = pcall(require, "tecs2d.workers"),
        cores = tonumber(C.SDL_GetNumLogicalCPUCores()) as integer,
        writableStorage = true,
    }
    return resolved
end

return capabilities
