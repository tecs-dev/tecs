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
---
--- What a pipeline bakes has to agree with the pass it is bound in and with the
--- shaders it was built from, and neither agreement is checked here:
---
--- - Colour formats must match the pass's attachments in count and in order.
---   `RenderPass.begin` takes the attachments and this takes the formats, and
---   nothing joins the two up before SDL rejects the bind.
--- - A pipeline with `depth` set can only be bound in a pass begun with a depth
---   attachment, and one without it only in a pass begun without one.
--- - Resource bindings follow the set numbering SDL fixes for SPIR-V: the
---   vertex stage reads sampled textures then storage textures then storage
---   buffers from set 0 and its uniforms from set 1, and the fragment stage
---   reads the same sequence from set 2 and its uniforms from set 3. A shader
---   that numbers its sets otherwise binds nothing where the pass puts it.

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
    --- Format of the attachment. Required, and it must be the format of the
    --- texture the pass attaches, not merely a depth format.
    format: integer
    --- Tests each fragment against the attachment. Defaults to true; false
    --- attaches depth without letting it reject anything.
    test: boolean
    --- Writes surviving fragments' depth back. Defaults to true, and has no
    --- effect while `test` is false.
    write: boolean
    --- "never", "less", "equal", "lessOrEqual", "greater", "notEqual",
    --- "greaterOrEqual", or "always". Defaults to "lessOrEqual".
    ---
    --- The incoming fragment is the left side, so "lessOrEqual" keeps a
    --- fragment nearer than or level with what is stored. Level is what makes
    --- draw order the tie-breaker for two instances at one depth: the later
    --- draw passes the test and overwrites, which is the resolution
    --- `layers.depthOf` is written to rely on.
    compare: string
end

local record PipelineOptions
    --- Both are required, and both may be destroyed once `create` returns:
    --- SDL keeps whatever it needs out of them.
    vertexShader: Shader
    fragmentShader: Shader
    --- Format of the single colour target this pipeline writes to. Use
    --- `colorFormats` for a G-buffer or any other multi-target pass. One of the
    --- two is required and `colorFormats` wins when both are given.
    colorFormat: integer
    --- Formats of every colour target, in attachment order. A pipeline bakes
    --- these, so they must match the pass it is used in exactly.
    colorFormats: {integer}
    --- "triangleList", "triangleStrip", "lineList", "lineStrip", "pointList".
    --- Defaults to "triangleList".
    primitive: string
    --- "none", "front", or "back", defaulting to "none". Facing is decided by
    --- counter-clockwise winding, which this does not expose, so a mesh wound
    --- the other way has its two faces swapped rather than its culling
    --- disabled.
    cull: string
    --- Straight alpha blending, applied to every colour target rather than to
    --- one of them. Defaults to false, which writes the fragment's colour and
    --- alpha through unmodified. Ignored when `blendMode` is given.
    blend: boolean
    --- Which blend to bake, for the cases a boolean cannot say.
    ---
    --- `"alpha"` is what `blend = true` means. `"min"` and `"max"` take the
    --- smaller or the larger of the fragment and what is already there, per
    --- channel, and both ignore the two factors entirely. They are what a
    --- target resolving by coverage rather than by order needs: the value in a
    --- pixel becomes a function of the set of fragments that covered it and not
    --- of their order, which on an unsigned normalised target is bit exact. An
    --- occluder mask wants the tallest occluder to win and a shadow target
    --- wants the darkest shadow to, and neither may depend on which of them the
    --- device rasterised first.
    blendMode: string
    --- Depth state. Omit for a pipeline with no depth-stencil target, which is
    --- also the only kind that can be bound in a pass begun without one.
    depth: DepthConfig
    --- Accepted and not applied. Nothing here reaches the pipeline's debug
    --- name, so a capture labels this pipeline whatever the driver defaults to.
    name: string
end

--- An immutable graphics pipeline, and the type `create` returns.
---
--- Everything a pipeline decides is fixed when it is made, so a second
--- combination of blend, depth, cull, primitive or target formats is a second
--- object. The shaders it was built from are not retained: SDL keeps what it
--- needs, and the caller may destroy them as soon as `create` returns.
local record GraphicsPipeline
    --- Depth state a pipeline bakes, and what `PassGraph:depthOf` answers with.
    DepthConfig: DepthConfig

    --- The `SDL_GPUGraphicsPipeline`. Nil once `destroy` has run.
    handle: loader.CPtr
    --- The `SDL_GPUDevice` it was created against, and the one `destroy`
    --- releases it from.
    _device: loader.CPtr
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean

    --- Creates a pipeline.
    ---
    --- Raises on an unknown primitive, cull mode or depth compare op, and on
    --- options that name no colour format at all. Everything that has to agree
    --- with a pass or a shader is unchecked and surfaces as an SDL failure at
    --- creation or at bind.
    --- @param device The `SDL_GPUDevice` the pipeline is created on, and the
    ---     one `destroy` releases it against.
    --- @param options Baked state. Nothing here is amendable afterwards; a
    ---     second combination is a second pipeline.
    --- @return The pipeline, whose shaders the caller is free to destroy.
    create: function(device: loader.CPtr, options: PipelineOptions): GraphicsPipeline

    --- Releases the pipeline.
    ---
    --- Safe to call more than once. The device outlives its pipelines, so this
    --- has to run before the device is destroyed rather than after.
    destroy: function(self)
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

-- The blend factors and op straight alpha needs, read from the generated
-- cdef rather than copied out of the header. An enum constant is a
-- compile-time value the FFI resolves through any namespace, so this needs no
-- library loaded, and a number that comes from the header cannot drift from
-- it. Copying went wrong here once: these enums open with an INVALID member,
-- so every name sits one above where the header appears to list it, and
-- source alpha spent that time meaning destination colour.
local BLEND_FACTOR_SRC_ALPHA <const> = tonumber(C.SDL_GPU_BLENDFACTOR_SRC_ALPHA) as integer
local BLEND_FACTOR_ONE_MINUS_SRC_ALPHA <const> = tonumber(C.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA) as integer
local BLEND_FACTOR_ONE <const> = tonumber(C.SDL_GPU_BLENDFACTOR_ONE) as integer
local BLEND_OP_ADD <const> = tonumber(C.SDL_GPU_BLENDOP_ADD) as integer
local BLEND_OP_MIN <const> = tonumber(C.SDL_GPU_BLENDOP_MIN) as integer
local BLEND_OP_MAX <const> = tonumber(C.SDL_GPU_BLENDOP_MAX) as integer

--- The op a named blend mode resolves overlap with, for the two that take the
--- fragment and the target as they are. Alpha is not here: it needs four
--- factors as well as an op, so it stays a branch rather than a table entry.
local EXTREME_OPS <const>: {string: integer} = {
    min = BLEND_OP_MIN,
    max = BLEND_OP_MAX,
}

function GraphicsPipeline.create(device: loader.CPtr, options: PipelineOptions): GraphicsPipeline
    local primitive = PRIMITIVES[options.primitive or "triangleList"]
    if primitive == nil then
        error(("tecs: unknown primitive type '%s'"):format(tostring(options.primitive)), 2)
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
        formats = {options.colorFormat}
    end

    local mode = options.blendMode or (options.blend and "alpha" or nil)
    local extreme: integer = nil
    if mode ~= nil and mode ~= "alpha" then
        extreme = EXTREME_OPS[mode]
        if extreme == nil then
            error(("tecs: unknown blend mode '%s'"):format(tostring(mode)), 2)
        end
    end

    local targets = loader.newArray("SDL_GPUColorTargetDescription[?]", #formats)
    for index, format in ipairs(formats) do
        local target = targets[index - 1] as loader.CStruct
        target.format = format

        local blend = target.blend_state as loader.CStruct
        if mode == nil then
            blend.enable_blend = false
        elseif extreme ~= nil then
            -- SDL still wants factors on a min or max op and the op ignores
            -- them, so they are set to one rather than left at the enum's
            -- invalid member, which some backends reject at creation.
            blend.enable_blend = true
            blend.src_color_blendfactor = BLEND_FACTOR_ONE
            blend.dst_color_blendfactor = BLEND_FACTOR_ONE
            blend.color_blend_op = extreme
            blend.src_alpha_blendfactor = BLEND_FACTOR_ONE
            blend.dst_alpha_blendfactor = BLEND_FACTOR_ONE
            blend.alpha_blend_op = extreme
        else
            blend.enable_blend = true
            blend.src_color_blendfactor = BLEND_FACTOR_SRC_ALPHA
            blend.dst_color_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            blend.color_blend_op = BLEND_OP_ADD
            blend.src_alpha_blendfactor = BLEND_FACTOR_ONE
            blend.dst_alpha_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            blend.alpha_blend_op = BLEND_OP_ADD
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
            error(("tecs: unknown depth compare op '%s'"):format(tostring(depth.compare)), 2)
        end
        targetInfo.has_depth_stencil_target = true
        targetInfo.depth_stencil_format = depth.format

        -- Stencil is never enabled, so the stencil ops in this struct describe
        -- nothing and are left at zero.
        local state = settings.depth_stencil_state as loader.CStruct
        state.compare_op = compare
        state.enable_depth_test = depth.test ~= false
        state.enable_depth_write = depth.write ~= false
        state.enable_stencil_test = false
    end

    local handle = C.SDL_CreateGPUGraphicsPipeline(device, info)
    if handle == nil then
        sdl.fail("SDL_CreateGPUGraphicsPipeline")
    end

    local self = setmetatable({} as GraphicsPipeline, GraphicsPipelineMT)
    self.handle = handle
    self._device = device
    self._destroyed = false
    return self
end

function GraphicsPipeline:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.SDL_ReleaseGPUGraphicsPipeline(self._device, self.handle)
    self.handle = nil
end

return GraphicsPipeline
