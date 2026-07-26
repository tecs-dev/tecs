--- An immutable compute pipeline.
---
--- Compute is not an optional extra here. It is how the renderer decides what
--- to draw: a compute pass culls instances and writes the draw arguments, and
--- the CPU never learns the resulting count.
---
--- The workgroup size and every resource count are reflected out of the
--- SPIR-V, so the pipeline cannot disagree with the shader it was built from.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local shadercompiler <const> = require("tecs2d.gpu.shadercompiler")
local shaders <const> = require("tecs2d.gpu.shaders")

local C <const> = sdl.C

local record ComputePipelineOptions
    name: string
    defines: {string: string}
end

local record ComputePipeline
    handle: loader.CPtr
    counts: shadercompiler.ResourceCounts
    --- Declared workgroup size, as {x, y, z}.
    threadCount: {integer}
    _device: loader.CPtr
    _code: loader.CArray
    _destroyed: boolean
end

local ComputePipelineMT <const>: metatable<ComputePipeline> = {
    __index = ComputePipeline,
}

--- Creates a pipeline from an already compiled compute shader.
local function create(device: loader.CPtr,
                      compiled: shadercompiler.CompiledShader): ComputePipeline
    local info = loader.newArray("SDL_GPUComputePipelineCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.code = compiled.code
    settings.code_size = compiled.codeSize
    settings.entrypoint = compiled.entrypoint
    settings.format = compiled.format
    settings.num_samplers = compiled.counts.samplers
    settings.num_readonly_storage_textures = compiled.counts.readOnlyStorageTextures
    settings.num_readonly_storage_buffers = compiled.counts.readOnlyStorageBuffers
    settings.num_readwrite_storage_textures = compiled.counts.readWriteStorageTextures
    settings.num_readwrite_storage_buffers = compiled.counts.readWriteStorageBuffers
    settings.num_uniform_buffers = compiled.counts.uniformBuffers
    settings.threadcount_x = compiled.threadCount[1]
    settings.threadcount_y = compiled.threadCount[2]
    settings.threadcount_z = compiled.threadCount[3]
    settings.props = 0

    local handle = C.SDL_CreateGPUComputePipeline(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUComputePipeline") end

    local self = setmetatable({} as ComputePipeline, ComputePipelineMT)
    self.handle = handle
    self.counts = compiled.counts
    self.threadCount = compiled.threadCount
    self._device = device
    self._code = compiled.code
    self._destroyed = false
    return self
end

--- Creates a pipeline from the compute shader registered under `name`.
---
--- The path the engine uses: a name is what a pack is keyed by, so this works
--- on a build that ships artifacts rather than a compiler.
function ComputePipeline.load(device: loader.CPtr, name: string,
                              options: ComputePipelineOptions): ComputePipeline
    options = options or {}
    local entry = shaders.get(name)
    if entry.stage ~= "compute" then
        error(("tecs2d: '%s' is a %s shader, not compute"):format(
            name, entry.stage), 2)
    end
    return create(device, shadercompiler.load(name, options.defines))
end

--- Compiles GLSL directly and creates a pipeline from it.
---
--- Needs a shader compiler. Engine code goes through `load`.
function ComputePipeline.fromGLSL(device: loader.CPtr, source: string,
                                  options: ComputePipelineOptions): ComputePipeline
    options = options or {}
    return create(device, shadercompiler.compile(source, "compute", {
        name = options.name,
        defines = options.defines,
    }))
end

--- Releases the pipeline. Safe to call more than once.
function ComputePipeline:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_ReleaseGPUComputePipeline(self._device, self.handle)
    self.handle = nil
    self._code = nil
end

return ComputePipeline
