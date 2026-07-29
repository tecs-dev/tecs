--[=[
A compiled shader stage on the device.

The resource counts SDL_GPU needs come from reflection rather than from the
caller: a wrong count is not a compile error, it is a silent binding
mismatch.

Prefer `load`, which asks for a registered shader by name and so works on a
build that ships packaged artifacts instead of a compiler. `fromGLSL` takes
source directly and therefore always needs one.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaders <const> = require("tecs.gpu.shaders")

local C <const> = sdl.C

local record ShaderOptions
    --- Name a compile error is reported against. Read by `fromGLSL`, which has
    --- no other name for the source it was handed; `load` already has one.
    name: string
    --- Preprocessor macros, for material variants. Part of the key a packaged
    --- shader is found under, so a define set that was not declared in the
    --- source is not in the pack either.
    defines: {string: string}
end

--- One compiled graphics stage on a device, and the type `load` returns.
---
--- A shader is only needed while pipelines are being created against it: SDL
--- retains what a pipeline uses, so `destroy` is safe as soon as the last one
--- exists.
local record Shader
    --- The `SDL_GPUShader`. Nil once `destroy` has run.
    handle: loader.CPtr
    --- "vertex" or "fragment".
    stage: string
    --- What the shader binds, reflected out of the SPIR-V. Carried so a caller
    --- can check a pipeline's bindings against what the shader expects.
    counts: shadercompiler.ResourceCounts
    --- The `SDL_GPUDevice` it was created against, and the one `destroy`
    --- releases it from.
    _device: loader.CPtr
    --- The bytecode buffer SDL read the code from, kept for the shader's life
    --- and dropped by `destroy`.
    _code: loader.CArray
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local ShaderMT <const>: metatable<Shader> = {__index = Shader}

local STAGES <const>: {string: integer} = {
    vertex = 0,
    fragment = 1,
}

--- Creates a shader on `device` from an already compiled stage.
local function create(device: loader.CPtr, stage: string, compiled: shadercompiler.CompiledShader): Shader
    local stageEnum = STAGES[stage]
    if stageEnum == nil then
        error(("tecs: '%s' is not a graphics shader stage"):format(tostring(stage)), 3)
    end

    local info = loader.newArray("SDL_GPUShaderCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.code = compiled.code
    settings.code_size = compiled.codeSize
    settings.entrypoint = compiled.entrypoint
    settings.format = compiled.format
    settings.stage = stageEnum
    settings.num_samplers = compiled.counts.samplers
    settings.num_storage_textures = compiled.counts.readOnlyStorageTextures
    settings.num_storage_buffers = compiled.counts.readOnlyStorageBuffers
    settings.num_uniform_buffers = compiled.counts.uniformBuffers
    settings.props = 0

    local handle = C.SDL_CreateGPUShader(device, info)
    if handle == nil then
        sdl.fail("SDL_CreateGPUShader")
    end

    local self = setmetatable({} as Shader, ShaderMT)
    self.handle = handle
    self.stage = stage
    self.counts = compiled.counts
    self._device = device
    self._code = compiled.code
    self._destroyed = false
    return self
end

--- Creates a shader from the GLSL registered under `name`.
---
--- This is how the engine asks for a shader, because a name is what a pack is
--- keyed by. On a build that links a compiler this compiles; on one that does
--- not, it reads the packaged artifact, and a shader missing from the pack
--- raises rather than leaving a pass silently unbuilt.
---
--- The stage comes from the name's suffix rather than from the caller, so a
--- `.frag` asked for as a vertex shader is not a thing that can be said.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param name A registered shader, without the `.glsl` extension, such as
---     "deferred.lighting.frag".
--- @param options Nil is no defines, which is the whole of what a shader with
---     no variants needs.
--- @return A shader the caller owns and releases with `destroy`, once every
---     pipeline built from it exists.
function Shader.load(device: loader.CPtr, name: string, options: ShaderOptions): Shader
    options = options or {}
    local entry = shaders.get(name)
    return create(device, entry.stage, shadercompiler.load(name, options.defines))
end

--- Compiles GLSL directly and creates a shader on `device`.
---
--- Needs a shader compiler, so a packaged build cannot use this. Engine code
--- goes through `load`; this is for a caller holding source that was never
--- registered, which in practice means a test.
---
--- Includes are not expanded: that happens in `shaders` on the way from a file,
--- and source handed in directly has already been assembled by whoever holds
--- it.
--- @param source Whole GLSL, with every `#include` already resolved.
--- @param stage "vertex" or "fragment". Compute uses `ComputePipeline`.
---     Anything else raises.
function Shader.fromGLSL(device: loader.CPtr, source: string, stage: string, options: ShaderOptions): Shader
    options = options or {}
    return create(
        device,
        stage,
        shadercompiler.compile(
            source,
            stage,
            {
                name = options.name,
                defines = options.defines,
            }
        )
    )
end

--- Releases the shader. Safe to call more than once.
---
--- A shader may be released once every pipeline using it has been created;
--- SDL retains what it needs.
function Shader:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.SDL_ReleaseGPUShader(self._device, self.handle)
    self.handle = nil
    self._code = nil
end

return Shader
