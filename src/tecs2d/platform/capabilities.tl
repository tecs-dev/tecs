--- What this build of the engine can do on this target.
---
--- Read rather than inferred. Selecting behaviour from `ffi.os` guesses: it
--- cannot tell a build that linked a shader compiler from one that did not, or
--- an interpreter-only LuaJIT from a jitting one, and both distinctions change
--- what the engine is allowed to attempt.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local adapter <const> = require("tecs2d.platform.adapter")
local shadercompiler <const> = require("tecs2d.gpu.shadercompiler")
local shaderpack <const> = require("tecs2d.gpu.shaderpack")

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
    --- Whether shaders are being read from a packaged artifact. Independent of
    --- `runtimeShaders`: a development build may have both, and a release has
    --- only this.
    packagedShaders: boolean
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
local cachedGeneration = -1

--- Whether the platform reports a touch device.
---
--- Asked rather than inferred from the platform: a desktop with a touchscreen
--- has one and a simulator may not, so neither answer follows from the OS.
local function hasTouch(): boolean
    local count = loader.newArray("int[1]")
    local devices = C.SDL_GetTouchDevices(count)
    if devices == nil then return false end
    C.SDL_free(devices)
    return tonumber(count[0]) > 0
end

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

--- Forgets the cached answer. A platform change is noticed without this.
function capabilities.reset()
    resolved = nil
end

--- Reads the capabilities of the running build.
---
--- Cached, since none of these change while a platform is installed.
function capabilities.get(): capabilities
    local generation = adapter.generation()
    if generation ~= cachedGeneration then
        cachedGeneration = generation
        resolved = nil
    end
    if resolved ~= nil then return resolved end

    -- The platform in use, which is not always SDL: a licensed port installs
    -- its own and everything here has to describe that one.
    local platform = loader.toString(C.SDL_GetPlatform())
    local installed = adapter.current()
    if installed.name ~= "sdl" then platform = installed.name end

    -- The shader pipeline is asked rather than guessed at: whether a compiler
    -- was linked is a property of the build, and a loaded pack narrows the
    -- format to the one it holds.
    local pack = shadercompiler.pack()
    local formats: {string} = { shaderpack.formatName(shadercompiler.format()) }

    resolved = {
        target = platform,
        architecture = ffi.arch,
        -- Whether machine code is being generated. On a target that forbids
        -- writable executable memory it is not, and the interpreter runs.
        jit = jitEnabled(),
        ffi = true,
        -- A registry means the libraries were linked, which is the case
        -- precisely where loading one by name is not available.
        dynamicLibraries = installed.dynamicLibraries,
        runtimeShaders = shadercompiler.available(),
        packagedShaders = pack ~= nil,
        shaderFormats = formats,
        touch = hasTouch(),
        controller = true,
        sensors = platform == "iOS" or platform == "Android",
        workers = pcall(require, "tecs2d.workers"),
        cores = tonumber(C.SDL_GetNumLogicalCPUCores()) as integer,
        writableStorage = true,
    }
    return resolved
end

return capabilities
