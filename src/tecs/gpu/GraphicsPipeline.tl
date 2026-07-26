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

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local Shader <const> = require("tecs.gpu.Shader")

local C <const> = sdl.C

--- Depth state a pipeline bakes.
---
--- A pipeline whose options omit this has no depth-stencil target at all,
--- which is what a fullscreen pass over an already-resolved image wants. The
--- two cases are different pipelines because the target info is part of what a
--- pipeline is, not something a pass can flip on afterwards.
local record DepthConfig
    --- Format of the attachment. Must match the pass this pipeline draws in.
    format: integer
    --- Tests each fragment against the attachment. Defaults to true; false
    --- attaches depth without letting it reject anything.
    test: boolean
    --- Writes surviving fragments' depth back. Defaults to true, and has no
    --- effect while `test` is false.
    write: boolean
    --- "never", "less", "equal", "lessOrEqual", "greater", "notEqual",
    --- "greaterOrEqual", or "always". Defaults to "lessOrEqual".
    compare: string
end

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
    --- Depth state. Omit for a pipeline with no depth-stencil target.
    depth: DepthConfig
    --- Name shown in GPU debugging tools.
    name: string
end

local record GraphicsPipeline
    DepthConfig: DepthConfig

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

-- SDL_GPUCompareOp values, in the order the enum declares them.
local COMPARE_OPS <const>: {string: integer} = {
    never = 1,
    less = 2,
    equal = 3,
    lessOrEqual = 4,
    greater = 5,
    notEqual = 6,
    greaterOrEqual = 7,
    always = 8,
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
        error(("tecs: unknown primitive type '%s'"):format(
            tostring(options.primitive)), 2)
    end
    local cull = CULL_MODES[options.cull or "none"]
    if cull == nil then
        error(("tecs: unknown cull mode '%s'"):format(tostring(options.cull)), 2)
    end

    local formats = options.colorFormats
    if formats == nil then
        if options.colorFormat == nil then
            error("tecs: a pipeline needs colorFormat or colorFormats", 2)
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

    -- Absence of depth state is a decision, not a default: a pass with no depth
    -- attachment needs a pipeline that declares none, and SDL rejects a
    -- pipeline whose target info disagrees with the pass it is bound in.
    local depth = options.depth
    if depth == nil then
        targetInfo.has_depth_stencil_target = false
    else
        if depth.format == nil then
            error("tecs: depth state needs the attachment's format", 2)
        end
        local compare = COMPARE_OPS[depth.compare or "lessOrEqual"]
        if compare == nil then
            error(("tecs: unknown depth compare op '%s'")
                :format(tostring(depth.compare)), 2)
        end
        targetInfo.has_depth_stencil_target = true
        targetInfo.depth_stencil_format = depth.format

        local state = settings.depth_stencil_state as loader.CStruct
        state.compare_op = compare
        state.enable_depth_test = depth.test ~= false
        state.enable_depth_write = depth.write ~= false
        state.enable_stencil_test = false
    end

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
