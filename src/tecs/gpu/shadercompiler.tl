--[=[
GLSL compilation and shader-pack lookup.

Development builds compile GLSL through Cargo-owned shaderc and SPIRV-Cross
crates in the Rust native service.
Packaged builds contain no compiler and consume only the shader pack produced
for their backend. The compiler also reflects the resource counts SDL_GPU
requires and flattens Metal bindings into SDL's documented order.

SDL_GPU fixes the descriptor layout shaders must be authored against:

  vertex    set 0  sampled textures, storage textures, storage buffers
            set 1  uniform buffers
  fragment  set 2  sampled textures, storage textures, storage buffers
            set 3  uniform buffers
  compute   set 0  sampled textures, read-only storage textures and buffers
            set 1  read-write storage textures and buffers
            set 2  uniform buffers

Metal has no descriptor sets. The compiler maps buffers as uniform, read-only storage,
then read-write storage, and textures as sampled, read-only storage, then
read-write storage. This is the order SDL_GPU's Metal backend expects.
]=]

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local rust <const> = require("tecs.ffi.rust")
local shaders <const> = require("tecs.gpu.shaders")
local shaderpack <const> = require("tecs.gpu.shaderpack")

local K <const> = sdl.K
local R <const> = rust.C

local TARGET_SPIRV <const> = 0
local TARGET_MSL <const> = 1

local STAGES <const>: {string: integer} = {
    vertex = 0,
    fragment = 1,
    compute = 2,
}

--- Resources a shader binds. Owned by `shaderpack`, because it is part of a
--- pack's serialized layout, and re-exported here so callers reach it through
--- the module that produces it.
local type ResourceCounts = shaderpack.ResourceCounts

local record CompiledShader
    --- Backend bytecode or source, as a byte buffer. Must outlive the create
    --- call that reads it, which is why the buffer is carried rather than a
    --- string.
    code: loader.CArray
    --- Bytes SDL reads, including the terminator for text formats.
    codeSize: integer
    --- Retains the buffer that `code` points into.
    _codeOwner: loader.CArray
    --- SDL shader format the code is in.
    format: integer
    --- Entry point name produced for the target backend.
    entrypoint: string
    --- What the shader binds, for the counts SDL is told separately.
    counts: ResourceCounts
    --- Local workgroup size for compute, or `{1, 1, 1}` otherwise.
    threadCount: {integer}
end

--- Where a shader comes from: compiled here, or read from an installed pack.
local record shadercompiler
    --- A built pack, re-exported so a caller loading one need not also require
    --- `shaderpack`.
    Pack: shaderpack.Pack
    --- What a shader binds, re-exported from `shaderpack`.
    ResourceCounts: ResourceCounts
    --- What both `compile` and a pack lookup produce.
    CompiledShader: CompiledShader
end

local record CompileOptions
    --- Name used in diagnostics.
    name: string
    --- Preprocessor macros used to produce material variants.
    defines: {string: string}
end

local function compileTarget(source: string, stage: string, options: CompileOptions, target: integer): CompiledShader
    local stageKind <const> = STAGES[stage]
    if stageKind == nil then
        error(("tecs: unknown shader stage '%s'"):format(tostring(stage)), 3)
    end
    if not R.tecsShaderCompilerAvailable() then
        error("tecs: this build links no shader compiler, so every shader must come from a pack", 3)
    end

    options = options or {}
    local name <const> = options.name or ("<%s shader>"):format(stage)
    local defineCount = 0
    if options.defines ~= nil then
        for _ in pairs(options.defines) do
            defineCount = defineCount + 1
        end
    end
    local nativeDefines: loader.CArray = nil
    if defineCount > 0 then
        nativeDefines = loader.newArray("TecsShaderDefine[?]", defineCount)
        local at = 0
        for key, value in pairs(options.defines) do
            local definition = nativeDefines[at] as {string: any}
            definition.name = ffi.cast("const uint8_t *", key)
            definition.name_length = #key
            definition.value = ffi.cast("const uint8_t *", value)
            definition.value_length = #value
            at = at + 1
        end
    end

    local compiled <const> = R.tecsShaderCompile(
        source, #source, name, #name, stageKind, target, nativeDefines, defineCount
    )
    if compiled == nil then
        error(("tecs: %s failed to compile:\n%s"):format(name, loader.toString(R.tecsRustError())), 3)
    end

    local infoOwner <const> = loader.newArray("TecsShaderInfo[1]")
    if not R.tecsShaderGetInfo(compiled, infoOwner) then
        local reason <const> = loader.toString(R.tecsRustError())
        R.tecsShaderDestroy(compiled)
        error("tecs: cannot read compiled shader: " .. reason, 3)
    end
    local info <const> = infoOwner[0] as {string: any}
    local codeSize <const> = tonumber(info.code_length) as integer
    local bytes <const> = loader.newArray("uint8_t[?]", codeSize)
    loader.copyBytes(bytes, info.code as loader.CValue, codeSize)
    local entrypoint <const> = loader.toString(info.entrypoint as loader.CValue)
    local counts: ResourceCounts = {
        samplers = tonumber(info.samplers) as integer,
        readOnlyStorageTextures = tonumber(info.read_only_storage_textures) as integer,
        readOnlyStorageBuffers = tonumber(info.read_only_storage_buffers) as integer,
        readWriteStorageTextures = tonumber(info.read_write_storage_textures) as integer,
        readWriteStorageBuffers = tonumber(info.read_write_storage_buffers) as integer,
        uniformBuffers = tonumber(info.uniform_buffers) as integer,
    }
    local threadCount <const>: {integer} = {
        tonumber(info.thread_count_x) as integer,
        tonumber(info.thread_count_y) as integer,
        tonumber(info.thread_count_z) as integer,
    }
    R.tecsShaderDestroy(compiled)

    return {
        code = bytes,
        codeSize = codeSize,
        _codeOwner = bytes,
        format = target == TARGET_MSL and K.SDL_GPU_SHADERFORMAT_MSL or K.SDL_GPU_SHADERFORMAT_SPIRV,
        entrypoint = entrypoint,
        counts = counts,
        threadCount = threadCount,
    }
end

--- Compiles GLSL to whatever the running backend consumes.
--- @param source GLSL source text, with includes already expanded.
--- @param stage "vertex", "fragment", or "compute". Anything else raises.
--- @param options Nil is no defines and a name derived from the stage. Raises
---     on a build with no compiler, and on any GLSL that fails to compile.
--- @return A shader whose `code` buffer must outlive the SDL create call.
function shadercompiler.compile(source: string, stage: string, options: CompileOptions): CompiledShader
    local target <const> = ffi.os == "OSX" and TARGET_MSL or TARGET_SPIRV
    return compileTarget(source, stage, options, target)
end

--- Compiles GLSL to MSL and returns the translated source.
--- Exposed for inspection and tests; the pipeline uses `compile`.
--- @return The MSL, with bindings flattened into SDL's Metal order.
--- @return What the shader binds, reflected from the compiled SPIR-V.
--- @return The declared workgroup size for compute, or `{1, 1, 1}`.
function shadercompiler.translate(
    source: string, stage: string, options: CompileOptions
): string, ResourceCounts, {integer}
    local compiled <const> = compileTarget(source, stage, options, TARGET_MSL)
    return loader.toBytes(compiled.code as loader.CValue, compiled.codeSize - 1), compiled.counts, compiled.threadCount
end

--- Whether this build can compile a shader from source.
function shadercompiler.isSupported(): boolean
    return tonumber(R.tecsShaderCompilerAvailable()) ~= 0
end

local loadedPack: shaderpack.Pack = nil

--- Uses `pack` for every subsequent lookup by name.
--- @param pack Held, not copied, and replacing whatever was installed before.
---     Nil returns to compiling, which a pack-only build cannot do.
function shadercompiler.usePack(pack: shaderpack.Pack)
    loadedPack = pack
end

--- Returns the pack in use, or nil if shaders are being compiled.
function shadercompiler.pack(): shaderpack.Pack
    return loadedPack
end

--- Returns the shader format this build supplies.
function shadercompiler.format(): integer
    if loadedPack ~= nil then
        return loadedPack.format
    end
    return require("tecs.platform.adapter").current().shaderFormat()
end

local function fromPack(entry: shaderpack.Shader): CompiledShader
    local bytes, size = loader.fromString(entry.code)
    return {
        code = bytes,
        codeSize = size,
        _codeOwner = bytes,
        format = entry.format,
        entrypoint = entry.entrypoint,
        counts = entry.counts,
        threadCount = entry.threadCount,
    }
end

--- Decides where a shader comes from, or raises if it can come from nowhere.
--- @param name A registered shader name.
--- @param defines Material preprocessor definitions, or nil.
--- @param hasCompiler Whether compiling is available. It is explicit so specs
---     can cover the branch used by a packaged build.
--- @return "pack" or "compile". Raises where neither is possible.
function shadercompiler.plan(name: string, defines: {string: string}, hasCompiler: boolean): string
    local entry = shaders.get(name)
    local key = shaders.key(name, defines)
    local packed = loadedPack ~= nil and loadedPack.shaders[key] or nil

    if packed ~= nil then
        local hash = shaders.hash(entry.source)
        if packed.sourceHash == hash then
            return "pack"
        end
        if not hasCompiler then
            error(
                (
                    "tecs: packed shader '%s' was built from different source "
                    .. "(%s, now %s) and this build cannot recompile"
                ):format(key, packed.sourceHash, hash),
                2
            )
        end
        return "compile"
    end

    if hasCompiler then
        return "compile"
    end
    if loadedPack == nil then
        error(("tecs: no shader pack is loaded and this build cannot compile " .. "'%s'"):format(key), 2)
    end
    error(("tecs: shader '%s' is not in the pack and this build cannot " .. "compile it"):format(key), 2)
end

--- Resolves a registered shader, from the pack if one is installed.
--- @param name A registered shader, without the `.glsl` extension.
--- @param defines Nil is the plain variant.
--- @return The same shape `compile` produces whichever route it takes.
function shadercompiler.load(name: string, defines?: {string: string}): CompiledShader
    require("tecs.gpu.materials").install()
    local entry = shaders.get(name)
    if shadercompiler.plan(name, defines, shadercompiler.isSupported()) == "pack" then
        return fromPack(loadedPack.shaders[shaders.key(name, defines)])
    end
    return shadercompiler.compile(
        entry.source,
        entry.stage,
        {
            name = name,
            defines = defines,
        }
    )
end

return shadercompiler
