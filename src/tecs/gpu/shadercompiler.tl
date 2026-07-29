--[=[
GLSL to backend bytecode, with the reflection SDL_GPU requires.

SDL_GPU consumes compiled shaders and is told, separately, how many
resources of each class the shader binds. Getting those counts wrong is not
a compile error; it is a binding mismatch that surfaces as wrong pixels. So
they are reflected out of the SPIR-V rather than declared by hand.

SDL_GPU fixes the descriptor layout shaders must be authored against, and
it differs by stage:

  vertex    set 0  sampled textures, storage textures, storage buffers
            set 1  uniform buffers
  fragment  set 2  sampled textures, storage textures, storage buffers
            set 3  uniform buffers
  compute   set 0  sampled textures, read-only storage textures and buffers
            set 1  read-write storage textures and buffers
            set 2  uniform buffers

Only compute distinguishes read-only from read-write storage, and it does
so by set, which is what SDL mandates and simpler than recovering the
distinction from NonWritable decorations. Graphics storage resources are
always read-only.

Metal has no descriptor sets, so bindings are flattened to the order
SDL_GPU's Metal backend expects:

  [[buffer]]   uniform, then read-only storage, then read-write storage
  [[texture]]  sampled, then read-only storage, then read-write storage
]=]

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local shaders <const> = require("tecs.gpu.shaders")
local shaderpack <const> = require("tecs.gpu.shaderpack")

local K <const> = sdl.K

--- shaderc and SPIRV-Cross, loaded on first use.
---
--- Not at require time: a release links neither and reads a pack instead, and
--- that build still has to be able to load this module to consume one. So the
--- absence of a compiler is a condition to report, not a load failure.
local SC: loader.CNamespace = nil
local SP: loader.CNamespace = nil
local compilerMissing: string = nil

local function loadCompiler(): boolean
    if SC ~= nil then
        return true
    end
    if compilerMissing ~= nil then
        return false
    end
    local okShaderc, shadercModule = pcall(require, "tecs.ffi.shaderc")
    if not okShaderc then
        compilerMissing = tostring(shadercModule)
        return false
    end
    local okSpvc, spvcModule = pcall(require, "tecs.ffi.spvc")
    if not okSpvc then
        compilerMissing = tostring(spvcModule)
        return false
    end
    SC = (shadercModule as {string: any}).C as loader.CNamespace
    SP = (spvcModule as {string: any}).C as loader.CNamespace
    return true
end

local function requireCompiler(level: integer)
    if loadCompiler() then
        return
    end
    error(
        "tecs: this build links no shader compiler, so every shader must " .. "come from a pack: " .. compilerMissing,
        level + 1
    )
end

-- SPIR-V decorations, from the SPIR-V core grammar.
local DECORATION_BINDING <const> = 33
local DECORATION_DESCRIPTOR_SET <const> = 34

local record SetLayout
    --- Set holding sampled textures, storage textures, and storage buffers.
    --- For compute this is the read-only set.
    resources: integer
    --- Set holding read-write storage resources. Compute only; -1 elsewhere,
    --- since graphics storage bindings are always read-only. No set is -1, so
    --- the value doubles as "there is no such set here".
    readWrite: integer
    --- Set holding uniform buffers, which every stage has and which is always
    --- a set of its own.
    uniforms: integer
end

-- Per-stage descriptor sets, per SDL_GPU's documented layout.
local SET_LAYOUTS <const>: {string: SetLayout} = {
    vertex = {resources = 0, readWrite = -1, uniforms = 1},
    fragment = {resources = 2, readWrite = -1, uniforms = 3},
    compute = {resources = 0, readWrite = 1, uniforms = 2},
}

--- MSL reserves `main`, so SPIRV-Cross renames the entry point.
local MSL_ENTRYPOINT <const> = "main0"

--- Resources a shader binds. Owned by `shaderpack`, because it is part of a
--- pack's serialized layout, and re-exported here so callers reach it through
--- the module that produces it.
local type ResourceCounts = shaderpack.ResourceCounts

local record CompiledShader
    --- Backend bytecode or source, as a byte buffer. Must outlive the create
    --- call that reads it, which is why the buffer is carried rather than a
    --- string.
    code: loader.CArray
    --- Bytes SDL reads, which includes the terminator where the format is
    --- text: MSL is source, and SDL is told a length rather than trusting one.
    codeSize: integer
    --- Retains the buffer that `code` points into.
    _codeOwner: loader.CArray
    --- SDL shader format the code is in, and what the device must have been
    --- created claiming.
    format: integer
    --- Entry point name, which is not always `main`: MSL reserves that, so the
    --- translation renames it.
    entrypoint: string
    --- What the shader binds, for the counts SDL is told separately.
    counts: ResourceCounts
    --- Local workgroup size, for compute shaders. Nil for the other stages,
    --- which have none.
    threadCount: {integer}
end

--- Where a shader comes from: compiled here, or read out of an installed pack.
---
--- The compiler is loaded on first use and its absence is a condition rather
--- than a load failure, so a release that links neither shaderc nor
--- SPIRV-Cross still requires this module and serves every shader from a pack.
--- `available` reports which of the two this build is.
local record shadercompiler
    --- A built pack, re-exported so a caller loading one need not also require
    --- `shaderpack`.
    Pack: shaderpack.Pack
    --- What a shader binds, re-exported from `shaderpack`, which owns it
    --- because it is part of the serialized layout.
    ResourceCounts: ResourceCounts
    --- What both `compile` and a pack lookup produce, so a pipeline is built
    --- the same way whichever a shader came from.
    CompiledShader: CompiledShader
end

-------------------------------------------------------------------------------
-- GLSL -> SPIR-V
-------------------------------------------------------------------------------

local STAGE_KINDS: {string: any} = nil

local compilerHandle: loader.CValue = nil

local function shadercCompiler(): loader.CValue
    if compilerHandle == nil then
        requireCompiler(3)
        compilerHandle = SC.shaderc_compiler_initialize()
        if compilerHandle == nil then
            error("tecs: shaderc_compiler_initialize failed", 2)
        end
        STAGE_KINDS = {
            vertex = SC.shaderc_vertex_shader,
            fragment = SC.shaderc_fragment_shader,
            compute = SC.shaderc_compute_shader,
        }
    end
    return compilerHandle
end

--- Compiles GLSL to a SPIR-V word buffer.
---
--- `defines` become preprocessor macros, which is how material variants are
--- produced from one source without string surgery at the call site.
local function toSpirv(source: string, stage: string, name: string, defines: {string: string}): loader.CArray, integer
    local compiler = shadercCompiler()
    local kind = STAGE_KINDS[stage]
    if kind == nil then
        error(("tecs: unknown shader stage '%s'"):format(tostring(stage)), 3)
    end

    local options = SC.shaderc_compile_options_initialize()
    -- Vulkan semantics give us real descriptor sets, which is what SDL_GPU's
    -- authoring layout is expressed in.
    SC.shaderc_compile_options_set_target_env(options, SC.shaderc_target_env_vulkan, SC.shaderc_env_version_vulkan_1_0)
    SC.shaderc_compile_options_set_optimization_level(options, SC.shaderc_optimization_level_performance)
    if defines ~= nil then
        for key, value in pairs(defines) do
            SC.shaderc_compile_options_add_macro_definition(options, key, #key, value, #value)
        end
    end

    local result = SC.shaderc_compile_into_spv(compiler, source, #source, kind, name or "shader.glsl", "main", options)
    SC.shaderc_compile_options_release(options)

    local status = SC.shaderc_result_get_compilation_status(result)
    if tonumber(status) ~= 0 then
        local message = loader.toString(SC.shaderc_result_get_error_message(result))
        SC.shaderc_result_release(result)
        error(("tecs: %s failed to compile:\n%s"):format(name or "shader", message), 3)
    end

    local length = tonumber(SC.shaderc_result_get_length(result)) as integer
    local bytes = SC.shaderc_result_get_bytes(result)

    -- Copy out before releasing: the result owns the storage.
    local words = loader.newArray("uint32_t[?]", math.floor(length / 4))
    loader.copyBytes(words, bytes as loader.CValue, length)
    SC.shaderc_result_release(result)

    return words, math.floor(length / 4)
end

-------------------------------------------------------------------------------
-- SPIR-V reflection and MSL translation
-------------------------------------------------------------------------------

local record Binding
    set: integer
    binding: integer
    id: any
end

local function spvcCheck(context: loader.CValue, result: any, what: string)
    if tonumber(result) ~= 0 then
        local message = loader.toString(SP.spvc_context_get_last_error_string(context))
        error(("tecs: %s failed: %s"):format(what, message), 3)
    end
end

--- Collects the (set, binding) of every resource of one SPIRV-Cross type,
--- ordered by binding so that flattened Metal indices are stable across runs.
local function collect(compiler: loader.CValue, resources: loader.CValue, resourceType: any): {Binding}
    local listOut = loader.newArray("const spvc_reflected_resource*[1]")
    local countOut = loader.newArray("size_t[1]")
    SP.spvc_resources_get_resource_list_for_type(resources, resourceType, listOut, countOut)

    local list = listOut[0]
    local count = tonumber(countOut[0]) as integer
    local found: {Binding} = {}
    for i = 0, count - 1 do
        local entry = (list as loader.CArray)[i] as loader.CValue
        local id = entry.id
        found[#found + 1] = {
            set = tonumber(SP.spvc_compiler_get_decoration(compiler, id, DECORATION_DESCRIPTOR_SET)) as integer,
            binding = tonumber(SP.spvc_compiler_get_decoration(compiler, id, DECORATION_BINDING)) as integer,
            id = id,
        }
    end
    table.sort(found, function(a: Binding, b: Binding): boolean return a.binding < b.binding end)
    return found
end

local function inSet(bindings: {Binding}, set: integer): {Binding}
    local out: {Binding} = {}
    for _, entry in ipairs(bindings) do
        if entry.set == set then
            out[#out + 1] = entry
        end
    end
    return out
end

--- SpvExecutionModeLocalSize, whose three arguments are the workgroup size.
local EXECUTION_MODE_LOCAL_SIZE <const> = 17

--- Reads a compute shader's declared workgroup size.
---
--- SDL_GPU wants this at pipeline creation, and it is already stated in the
--- shader source. Reflecting it keeps the two from disagreeing.
local function localSize(compiler: loader.CValue): {integer}
    local size: {integer} = {}
    for axis = 0, 2 do
        size[axis + 1] = tonumber(
            SP.spvc_compiler_get_execution_mode_argument_by_index(compiler, EXECUTION_MODE_LOCAL_SIZE, axis)
        ) as integer
    end
    return size
end

--- Reflects SPIR-V and, when `translate` is set, emits MSL with bindings
--- remapped into SDL_GPU's Metal order.
---
--- Backends that consume SPIR-V directly still need the reflected resource
--- counts, but must not depend on the MSL backend accepting the module: a
--- shader that is valid SPIR-V and that SPIRV-Cross cannot express in MSL
--- would otherwise fail on Vulkan for a reason that has nothing to do with
--- Vulkan. Reflection therefore runs on the no-output backend.
local function reflect(
    words: loader.CArray, wordCount: integer, stage: string, translate: boolean
): string, ResourceCounts, {integer}
    local contextOut = loader.newArray("spvc_context[1]")
    if tonumber(SP.spvc_context_create(contextOut)) ~= 0 then
        error("tecs: spvc_context_create failed", 3)
    end
    local context = contextOut[0] as loader.CValue

    local work = function(): string, ResourceCounts, {integer}
        local irOut = loader.newArray("spvc_parsed_ir[1]")
        spvcCheck(context, SP.spvc_context_parse_spirv(context, words, wordCount, irOut), "spvc_context_parse_spirv")

        local compilerOut = loader.newArray("spvc_compiler[1]")
        local backend = translate and SP.SPVC_BACKEND_MSL or SP.SPVC_BACKEND_NONE
        spvcCheck(
            context,
            SP.spvc_context_create_compiler(
                context, backend, irOut[0], SP.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, compilerOut
            ),
            "spvc_context_create_compiler"
        )
        local compiler = compilerOut[0] as loader.CValue

        local resourcesOut = loader.newArray("spvc_resources[1]")
        spvcCheck(
            context,
            SP.spvc_compiler_create_shader_resources(compiler, resourcesOut),
            "spvc_compiler_create_shader_resources"
        )
        local resources = resourcesOut[0] as loader.CValue

        local layout = SET_LAYOUTS[stage]
        if layout == nil then
            error(("tecs: no descriptor layout for stage '%s'"):format(tostring(stage)), 2)
        end

        local sampled = inSet(collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_SAMPLED_IMAGE), layout.resources)
        local images = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_STORAGE_IMAGE)
        local buffers = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_STORAGE_BUFFER)
        local uniforms = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER)

        local roTextures = inSet(images, layout.resources)
        local roBuffers = inSet(buffers, layout.resources)
        local rwTextures = inSet(images, layout.readWrite)
        local rwBuffers = inSet(buffers, layout.readWrite)
        local uniformBuffers = inSet(uniforms, layout.uniforms)

        local counts: ResourceCounts = {
            samplers = #sampled,
            readOnlyStorageTextures = #roTextures,
            readOnlyStorageBuffers = #roBuffers,
            readWriteStorageTextures = #rwTextures,
            readWriteStorageBuffers = #rwBuffers,
            uniformBuffers = #uniformBuffers,
        }

        local executionModel = stage == "vertex" and 0 or stage == "fragment" and 4 or 5

        -- Flatten to Metal's binding space in SDL_GPU's documented order.
        local binding = loader.newArray("spvc_msl_resource_binding[1]")
        local function remap(entry: Binding, bufferIndex: integer, textureIndex: integer, samplerIndex: integer)
            SP.spvc_msl_resource_binding_init(binding)
            local slot = binding[0] as loader.CStruct
            slot.stage = executionModel
            slot.desc_set = entry.set
            slot.binding = entry.binding
            slot.msl_buffer = bufferIndex
            slot.msl_texture = textureIndex
            slot.msl_sampler = samplerIndex
            spvcCheck(
                context,
                SP.spvc_compiler_msl_add_resource_binding(compiler, binding),
                "spvc_compiler_msl_add_resource_binding"
            )
        end

        if not translate then
            local threadsOnly = stage == "compute" and localSize(compiler) or {1, 1, 1}
            return nil, counts, threadsOnly
        end

        local bufferSlot = 0
        for _, entry in ipairs(uniformBuffers) do
            remap(entry, bufferSlot, 0, 0)
            bufferSlot = bufferSlot + 1
        end
        for _, entry in ipairs(roBuffers) do
            remap(entry, bufferSlot, 0, 0)
            bufferSlot = bufferSlot + 1
        end
        for _, entry in ipairs(rwBuffers) do
            remap(entry, bufferSlot, 0, 0)
            bufferSlot = bufferSlot + 1
        end

        local textureSlot = 0
        for _, entry in ipairs(sampled) do
            remap(entry, 0, textureSlot, textureSlot)
            textureSlot = textureSlot + 1
        end
        for _, entry in ipairs(roTextures) do
            remap(entry, 0, textureSlot, 0)
            textureSlot = textureSlot + 1
        end
        for _, entry in ipairs(rwTextures) do
            remap(entry, 0, textureSlot, 0)
            textureSlot = textureSlot + 1
        end

        local optionsOut = loader.newArray("spvc_compiler_options[1]")
        spvcCheck(
            context,
            SP.spvc_compiler_create_compiler_options(compiler, optionsOut),
            "spvc_compiler_create_compiler_options"
        )
        spvcCheck(
            context,
            SP.spvc_compiler_install_compiler_options(compiler, optionsOut[0]),
            "spvc_compiler_install_compiler_options"
        )

        local sourceOut = loader.newArray("const char*[1]")
        spvcCheck(context, SP.spvc_compiler_compile(compiler, sourceOut), "spvc_compiler_compile")

        local threads = stage == "compute" and localSize(compiler) or {1, 1, 1}

        -- The MSL string is owned by the context, so toString copies it out
        -- before the context is destroyed below.
        return loader.toString(sourceOut[0] as loader.CValue), counts, threads
    end

    local ok, source, counts, threads = pcall(work)
    SP.spvc_context_destroy(context)
    if not ok then
        error(source, 3)
    end
    return source as string, counts as ResourceCounts, threads as {integer}
end

-------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------

local record CompileOptions
    --- Name used in diagnostics.
    name: string
    --- Preprocessor macros, which is how material variants are produced from
    --- one source without assembling strings at the call site.
    defines: {string: string}
end

--- Compiles GLSL to whatever the running backend consumes.
---
--- SPIR-V everywhere but macOS, where it is translated to MSL and the bindings
--- are flattened into the order SDL's Metal backend expects. Which of the two
--- happens is decided by the host this runs on, so a pack built here is a pack
--- for this backend.
--- @param source GLSL source text, with includes already expanded.
--- @param stage "vertex", "fragment", or "compute". Anything else raises.
--- @param options Nil is no defines and a name derived from the stage. Raises
---     on a build with no compiler, and on any GLSL that fails to compile.
--- @return A shader whose `code` buffer must outlive the SDL create call that
---     reads it, which is why the buffer is carried rather than a string.
function shadercompiler.compile(source: string, stage: string, options: CompileOptions): CompiledShader
    options = options or {}
    local name = options.name or ("<%s shader>"):format(stage)

    local words, wordCount = toSpirv(source, stage, name, options.defines)

    if ffi.os ~= "OSX" then
        -- SPIR-V is consumed directly; the authoring layout is already the
        -- one SDL_GPU expects.
        local _, counts, threads = reflect(words, wordCount, stage, false)
        return {
            code = words,
            codeSize = wordCount * 4,
            _codeOwner = words,
            format = K.SDL_GPU_SHADERFORMAT_SPIRV,
            entrypoint = "main",
            counts = counts,
            threadCount = threads,
        }
    end

    local msl, counts, threads = reflect(words, wordCount, stage, true)
    -- SDL copies the code during shader creation, but it reads `codeSize`
    -- bytes, so the buffer must outlive the call and include the terminator.
    local bytes = loader.newArray("uint8_t[?]", #msl + 1)
    loader.copyString(bytes, msl)
    return {
        code = bytes,
        codeSize = #msl + 1,
        _codeOwner = bytes,
        format = K.SDL_GPU_SHADERFORMAT_MSL,
        entrypoint = MSL_ENTRYPOINT,
        counts = counts,
        threadCount = threads,
    }
end

--- Compiles GLSL to MSL and returns the translated source.
--- Exposed for inspection and tests; the pipeline uses `compile`.
---
--- Translates on every host, unlike `compile`, which only does so on macOS.
--- @return The MSL, with bindings already flattened into SDL's Metal order.
--- @return What the shader binds, reflected out of the SPIR-V.
--- @return The declared workgroup size for a compute stage, and `{1, 1, 1}`
---     for the other two.
function shadercompiler.translate(
    source: string, stage: string, options: CompileOptions
): string, ResourceCounts, {integer}
    options = options or {}
    local words, wordCount = toSpirv(source, stage, options.name or "<shader>", options.defines)
    return reflect(words, wordCount, stage, true)
end

--- Whether this build can compile a shader from source.
---
--- False in a release that links no compiler, where every shader has to be
--- found in a pack. Nothing degrades quietly on that path: a shader the pack
--- does not contain raises, because the alternative is a window that opens and
--- then draws nothing.
function shadercompiler.available(): boolean
    return loadCompiler()
end

-------------------------------------------------------------------------------
-- Packs
-------------------------------------------------------------------------------

local loadedPack: shaderpack.Pack = nil

--- Uses `pack` for every subsequent lookup by name.
---
--- Also decides `format`, and so what a device is created claiming. Install a
--- pack before creating the device, or the device claims one format and the
--- pack supplies another.
--- @param pack Held, not copied, and replacing whatever was installed before.
---     Nil goes back to compiling, which a build with no compiler cannot do.
function shadercompiler.usePack(pack: shaderpack.Pack)
    loadedPack = pack
end

--- The pack in use, or nil if shaders are being compiled.
function shadercompiler.pack(): shaderpack.Pack
    return loadedPack
end

--- The shader format this build supplies.
---
--- A loaded pack decides it, because a pack holds one format and no compiler
--- may be present to produce another. This is what the device claims, so
--- getting it wrong selects a backend that then fails at shader creation
--- rather than at device creation.
function shadercompiler.format(): integer
    if loadedPack ~= nil then
        return loadedPack.format
    end
    return require("tecs.platform.adapter").current().shaderFormat()
end

--- Turns a pack entry into the same shape a fresh compile produces.
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
---
--- Separated from `load` and given `hasCompiler` explicitly because this is the
--- rule that matters on a target with no compiler, and a running process cannot
--- unlink one to check it. Returns "pack" or "compile".
---
--- A pack entry built from source that has since changed is not used. On a
--- build that can compile that is a recompile; on one that cannot it is an
--- error, because drawing with a shader that no longer matches its source is
--- worse than not starting.
--- @param hasCompiler Whether compiling is available. Passed in rather than
---     asked for, so a test can put this on the branch a packaged build takes.
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

--- Resolves a registered shader, from the pack if there is one.
---
--- This is how the engine asks for a shader. Going through a name rather than
--- a source is what lets a build ship artifacts: a name is enumerable ahead of
--- time and a source assembled at the call site is not.
--- @param name A registered shader, without the `.glsl` extension.
--- @param defines Nil is the plain variant, which is what everything but a
---     material asks for.
--- @return The same shape `compile` produces, whichever route it took, so a
---     pipeline is built the same way either way.
function shadercompiler.load(name: string, defines?: {string: string}): CompiledShader
    -- Materials are compiled into a shader rather than bound to it, so they
    -- have to be read before one is resolved. Done here rather than by each
    -- caller, since forgetting would produce a shader that knows about no
    -- materials and renders everything as the unknown-id color.
    require("tecs.gpu.materials").install()
    local entry = shaders.get(name)
    if shadercompiler.plan(name, defines, shadercompiler.available()) == "pack" then
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
