--- A compiled shader stage on the device.
---
--- Created from GLSL, which is compiled and reflected by `shadercompiler`.
--- The resource counts SDL_GPU needs come from that reflection rather than
--- from the caller: a wrong count is not a compile error, it is a silent
--- binding mismatch.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local shadercompiler <const> = require("tecs2d.gpu.shadercompiler")

local C <const> = sdl.C

local record ShaderOptions
    --- Name used in diagnostics and GPU debugging tools.
    name: string
    --- Preprocessor macros, for material variants.
    defines: {string: string}
end

local record Shader
    handle: loader.CPtr
    stage: string
    counts: shadercompiler.ResourceCounts
    _device: loader.CPtr
    -- Retains the buffer SDL read the code from.
    _code: loader.CArray
    _destroyed: boolean
end

local ShaderMT <const>: metatable<Shader> = { __index = Shader }

local STAGES <const>: {string: integer} = {
    vertex = 0,
    fragment = 1,
}

--- Compiles GLSL and creates a shader on `device`.
--- @param stage "vertex" or "fragment". Compute uses `ComputePipeline`.
function Shader.fromGLSL(device: loader.CPtr, source: string, stage: string,
                         options: ShaderOptions): Shader
    options = options or {}
    local stageEnum = STAGES[stage]
    if stageEnum == nil then
        error(("tecs2d: '%s' is not a graphics shader stage"):format(tostring(stage)), 2)
    end

    local compiled = shadercompiler.compile(source, stage, {
        name = options.name,
        defines = options.defines,
    })

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
    if handle == nil then sdl.fail("SDL_CreateGPUShader") end

    local self = setmetatable({} as Shader, ShaderMT)
    self.handle = handle
    self.stage = stage
    self.counts = compiled.counts
    self._device = device
    self._code = compiled.code
    self._destroyed = false
    return self
end

--- Releases the shader. Safe to call more than once.
---
--- A shader may be released once every pipeline using it has been created;
--- SDL retains what it needs.
function Shader:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_ReleaseGPUShader(self._device, self.handle)
    self.handle = nil
    self._code = nil
end

return Shader
