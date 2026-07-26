--- An immutable graphics pipeline.
---
--- Blend, depth, cull, primitive type, and target formats are baked in at
--- creation. This is the structural difference from an immediate-mode API:
--- there is no global state to flip mid-frame, so every distinct combination
--- is a separate object, created once and reused.
---
--- No vertex input state is declared. The renderer is SSBO-driven: vertex data
--- is read from storage buffers indexed by vertex ID, so there are no vertex
--- buffers to describe.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local Shader <const> = require("tecs2d.gpu.Shader")

local C <const> = sdl.C

local record PipelineOptions
    vertexShader: Shader
    fragmentShader: Shader
    --- Format of the single colour target this pipeline writes to. Use
    --- `colorFormats` for a G-buffer or any other multi-target pass.
    colorFormat: integer
    --- Formats of every colour target, in attachment order. A pipeline bakes
    --- these, so they must match the pass it is used in exactly.
    colorFormats: {integer}
    --- "triangleList", "triangleStrip", "lineList", "lineStrip", "pointList".
    primitive: string
    --- "none", "front", or "back".
    cull: string
    --- Straight alpha blending on the colour target.
    blend: boolean
    --- Name shown in GPU debugging tools.
    name: string
end

local record GraphicsPipeline
    handle: loader.CPtr
    _device: loader.CPtr
    _destroyed: boolean
end

local GraphicsPipelineMT <const>: metatable<GraphicsPipeline> = {
    __index = GraphicsPipeline,
}

local PRIMITIVES <const>: {string: integer} = {
    triangleList = 0,
    triangleStrip = 1,
    lineList = 2,
    lineStrip = 3,
    pointList = 4,
}

local CULL_MODES <const>: {string: integer} = {
    none = 0,
    front = 1,
    back = 2,
}

-- SDL_GPUBlendFactor / SDL_GPUBlendOp values used for straight alpha.
local BLEND_FACTOR_SRC_ALPHA <const> = 5
local BLEND_FACTOR_ONE_MINUS_SRC_ALPHA <const> = 6
local BLEND_FACTOR_ONE <const> = 2
local BLEND_OP_ADD <const> = 1

--- Creates a pipeline. The shaders may be released once this returns.
function GraphicsPipeline.create(device: loader.CPtr,
                                 options: PipelineOptions): GraphicsPipeline
    local primitive = PRIMITIVES[options.primitive or "triangleList"]
    if primitive == nil then
        error(("tecs2d: unknown primitive type '%s'"):format(
            tostring(options.primitive)), 2)
    end
    local cull = CULL_MODES[options.cull or "none"]
    if cull == nil then
        error(("tecs2d: unknown cull mode '%s'"):format(tostring(options.cull)), 2)
    end

    local formats = options.colorFormats
    if formats == nil then
        if options.colorFormat == nil then
            error("tecs2d: a pipeline needs colorFormat or colorFormats", 2)
        end
        formats = { options.colorFormat }
    end

    local targets = loader.newArray("SDL_GPUColorTargetDescription[?]", #formats)
    for index, format in ipairs(formats) do
        local target = targets[index - 1] as loader.CStruct
        target.format = format

        local blend = target.blend_state as loader.CStruct
        if options.blend then
            blend.enable_blend = true
            blend.src_color_blendfactor = BLEND_FACTOR_SRC_ALPHA
            blend.dst_color_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            blend.color_blend_op = BLEND_OP_ADD
            blend.src_alpha_blendfactor = BLEND_FACTOR_ONE
            blend.dst_alpha_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            blend.alpha_blend_op = BLEND_OP_ADD
        else
            blend.enable_blend = false
        end
    end

    local info = loader.newArray("SDL_GPUGraphicsPipelineCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.vertex_shader = options.vertexShader.handle
    settings.fragment_shader = options.fragmentShader.handle
    settings.primitive_type = primitive

    local rasterizer = settings.rasterizer_state as loader.CStruct
    rasterizer.fill_mode = 0
    rasterizer.cull_mode = cull
    rasterizer.front_face = 0

    local targetInfo = settings.target_info as loader.CStruct
    targetInfo.color_target_descriptions = targets
    targetInfo.num_color_targets = #formats
    targetInfo.has_depth_stencil_target = false

    local handle = C.SDL_CreateGPUGraphicsPipeline(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUGraphicsPipeline") end

    local self = setmetatable({} as GraphicsPipeline, GraphicsPipelineMT)
    self.handle = handle
    self._device = device
    self._destroyed = false
    return self
end

--- Releases the pipeline. Safe to call more than once.
function GraphicsPipeline:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_ReleaseGPUGraphicsPipeline(self._device, self.handle)
    self.handle = nil
end

return GraphicsPipeline
