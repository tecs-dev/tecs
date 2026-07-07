--- Generic plugin assembly for the shadow-column path. One call
--- (`shadow_plugin.register(world, descriptor)`) covers the bookkeeping
--- every shape needs:
---
---   - Build the shadow registry (gates on `Transform` + the shape's
---     primary component).
---   - Allocate indirect + growable + shadow-indirect buffers.
---   - Wire `ensureGrowableCapacity` so the cull's atomicAdd writes
---     never go OOB on the output buffer (skipping this manifests as
---     pink garbage on screen).
---   - Stub the `simpleShapePlugin` slots since the shadow path
---     overrides `cull` and `upload`.
---   - Add the two PreRender systems: `<shape>.ShadowRenderState`
---     (build syncRef) and `<shape>.ShadowUpload` (flushAll +
---     ensureGrowableCapacity + stubTransform.count).
---
--- Per-shape `init.tl` shrinks to: register the component, build a
--- descriptor, call `shadow_plugin.register`. Most knobs are
--- mechanical (shader paths, format constants, naming).

local tecs <const> = require("tecs")
local pipeline <const> = require("tecs2d.gfx.internal.pipeline")
local gpuBuffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shape_utils <const> = require("tecs2d.gfx.internal.gpu.shape_utils")
local shape_sync_base <const> = require("tecs2d.gfx.internal.shape_sync_base")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local shadow_render_state <const> = require("tecs2d.gfx.internal.gpu.shadow_render_state")
local shadow_dispatch <const> = require("tecs2d.gfx.internal.gpu.shadow_dispatch")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpu_backing <const> = require("tecs2d.gfx.internal.gpu.gpu_backing")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")
local Material <const> = require("tecs2d.gfx.internal.Material")

local lg <const> = love.graphics

local Transform <const> = tecs.builtins.Transform

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.shadow_plugin")

local record shadow_plugin
    --- See `shadow_dispatch.OptionalBinding`. Re-exported here so
    --- callers building a descriptor don't need to import both
    --- modules.
    type OptionalBinding = shadow_dispatch.OptionalBinding
    type TagFlagBinding = shadow_dispatch.TagFlagBinding

    record StubFormats
        transformFormat: love.graphics.BufferFormat
        transformCtype: string
        metadataFormat: love.graphics.BufferFormat
        metadataCtype: string
        inputFormat: love.graphics.BufferFormat
        inputCtype: string
    end

    record ShapeDescriptor
        --- Names used by `simpleShapePlugin` and the system labels.
        prefix: string                  -- e.g. "Circle" / "Rect" / "Ellipse"
        plural: string                  -- e.g. "Circles" / "Rects"
        materialShapeName: string       -- e.g. "circle" / "rectangle"
        sizeHintKey: string             -- e.g. "circles" / "rects"
        registryName: string            -- e.g. "circle.shadows"
        renderStateSystemName: string   -- e.g. "circle.ShadowRenderState"
        uploadSystemName: string        -- e.g. "circle.ShadowUpload"

        --- Primary shape component (Circle / Rectangle / Ellipse).
        --- The shadow registry gates on `Transform` AND this
        --- component being present on the archetype.
        primary: tecs.Component
        primaryLayout: std430.Descriptor
        primaryInputName: string        -- shader SSBO name, e.g. "CircleInput"

        --- Optional components, with mask bits + SSBO names.
        optional: {OptionalBinding}

        --- Tag-to-flag bindings. When the archetype has the tag, the
        --- flag bit is OR'd into the dispatch's `StaticFlags` uniform,
        --- and the cull shader folds it into the output flags.
        tagFlags: {TagFlagBinding}

        --- Shaders + buffer formats.
        cullShader: love.graphics.ComputeShader
        renderShader: love.graphics.Shader
        shadowMaskShader: love.graphics.Shader
        outputFormat: love.graphics.BufferFormat
        outputName: string              -- e.g. "CircleOutput"
        shadowOutputName: string        -- e.g. "CircleShadowOutput"

        --- Stub formats -- `simpleShapePlugin` requires these even
        --- though the shadow cull/upload override means they're
        --- never read by a shader. The renderer reads
        --- `transformBuffer.count` to gate `renderGBuffer`.
        stub: StubFormats

        hasShadow: boolean
        hasAlphaBlendFilter: boolean
    end

    register: function(world: tecs.World, descriptor: ShapeDescriptor)
end

function shadow_plugin.register(world: tecs.World, descriptor: shadow_plugin.ShapeDescriptor)
    local pipelineInstance <const> = world.resources[pipeline._contextKey as tecs.Key<pipeline.Pipeline>]
    if not pipelineInstance then
        LOGGER:error("No render pipeline found in world resources")
        return
    end
    local renderer = pipelineInstance:getRenderer()
    if not renderer then
        LOGGER:error("No GPU renderer available")
        return
    end
    local gpuRenderer = renderer as gpuTypes.Renderer

    -- Back identity-layout component storages with ByteData so the shadow path
    -- uploads them straight to their SSBO with no staging copy. Runs at install
    -- (before the game plugin spawns), so the columns are ByteData from the
    -- start. Non-identity layouts and non-FFI storages are skipped.
    gpu_backing.enable(Transform, std430.layouts.Transform as {string:any})
    gpu_backing.enable(descriptor.primary, descriptor.primaryLayout as {string:any})
    for i = 1, #descriptor.optional do
        local b = descriptor.optional[i]
        gpu_backing.enable(b.component, b.layout as {string:any})
    end

    local DEFAULT_CAPACITY <const> = 4096
    local initialCapacity = gpuRenderer.config.sizeHints[descriptor.sizeHintKey] or DEFAULT_CAPACITY

    -- Indirect args (cull's atomicAdd target) + growable output.
    local indirectBuffer = lg.newBuffer({{format = "uint32"}}, 4,
        {usage = "dynamic", shaderstorage = true, indirectarguments = true})
    local shadowIndirectBuffer: love.graphics.Buffer = nil
    if descriptor.hasShadow then
        shadowIndirectBuffer = lg.newBuffer({{format = "uint32"}}, 4,
            {usage = "dynamic", shaderstorage = true, indirectarguments = true})
    end

    local growable: shape_utils.GrowableBuffers = {
        outputBuffer = lg.newBuffer(descriptor.outputFormat, initialCapacity,
            {usage = "dynamic", shaderstorage = true}),
        shadowOutputBuffer = nil,
        materialParamsOutBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, initialCapacity,
            {usage = "dynamic", shaderstorage = true}),
    }
    if descriptor.hasShadow then
        growable.shadowOutputBuffer = lg.newBuffer(descriptor.outputFormat, initialCapacity,
            {usage = "dynamic", shaderstorage = true})
    end

    -- Grow `growable.*` to fit `entityCount` visible instances. Cull's
    -- atomicAdd writes one entry per visible instance; if the buffer
    -- is too small the write is OOB → garbage reads (visible as pink)
    -- in the render shader.
    local growableCapacity = initialCapacity
    local hasShadow <const> = descriptor.hasShadow
    local function ensureGrowableCapacity(entityCount: integer)
        if entityCount <= growableCapacity then return end
        local newCap = growableCapacity * 2
        if newCap < entityCount then newCap = entityCount end
        -- In-flight GPU work may still read the replaced buffers;
        -- release them through the deferred retire list.
        retire.push(growable.outputBuffer)
        growable.outputBuffer = lg.newBuffer(descriptor.outputFormat, newCap,
            {usage = "dynamic", shaderstorage = true})
        if hasShadow then
            retire.push(growable.shadowOutputBuffer)
            growable.shadowOutputBuffer = lg.newBuffer(descriptor.outputFormat, newCap,
                {usage = "dynamic", shaderstorage = true})
        end
        retire.push(growable.materialParamsOutBuffer)
        growable.materialParamsOutBuffer = lg.newBuffer(gpuTypes.MATERIAL_PARAMS_FORMAT, newCap,
            {usage = "dynamic", shaderstorage = true})
        growableCapacity = newCap
    end

    local syncRef: shape_sync_base.SyncRecord = {
        hasAlphaBlend = false,
        blendGroups = {},
        blendGroupCount = 0,
        materialGroups = {},
        materialGroupCount = 0,
        materialParamsBuffer = nil,
    }

    -- Stub buffers: `simpleShapePlugin` reads `transformBuffer.count`
    -- to gate `renderGBuffer`'s early-bail. Everything else on these
    -- buffers is unused since `cull` and `upload` are overridden below.
    local stubTransform = gpuBuffer.new(descriptor.stub.transformFormat, 1, descriptor.stub.transformCtype)
    local stubMetadata  = gpuBuffer.new(descriptor.stub.metadataFormat, 1, descriptor.stub.metadataCtype)
    local stubInput     = gpuBuffer.new(descriptor.stub.inputFormat, 1, descriptor.stub.inputCtype)

    local plugin <const> = shape_utils.simpleShapePlugin({
        prefix = descriptor.prefix,
        plural = descriptor.plural,
        materialShapeName = descriptor.materialShapeName,
        transformBuffer = stubTransform,
        metadataBuffer = stubMetadata,
        inputBuffer = stubInput,
        indirectBuffer = indirectBuffer,
        growable = growable,
        cullShader = descriptor.cullShader,
        renderShader = descriptor.renderShader,
        syncRef = syncRef,
        shadowIndirectBuffer = shadowIndirectBuffer,
        shadowMaskShader = descriptor.shadowMaskShader,
        hasAlphaBlendFilter = descriptor.hasAlphaBlendFilter,
    })

    plugin.upload = function(_renderer: any) end

    -- Build the archetype-state spec from the descriptor's component
    -- list. The state factory ignores entries whose component isn't
    -- on the archetype, so passing the full list is safe.
    local function buildSpecs(): {tecs.Component: std430.Descriptor}
        local specs: {tecs.Component: std430.Descriptor} = {
            [Transform] = std430.layouts.Transform,
            [descriptor.primary] = descriptor.primaryLayout,
        }
        for i = 1, #descriptor.optional do
            local b = descriptor.optional[i]
            specs[b.component] = b.layout
        end
        return specs
    end

    local primary <const> = descriptor.primary
    local shadowRegistry = archetype_registry.new(world, {
        name = descriptor.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return arch.columns[Transform] ~= nil and arch.columns[primary] ~= nil
        end,
        create = function(arch: tecs.Archetype): any
            return shadow_state.new(arch, buildSpecs())
        end,
    })

    local dispatch <const> = shadow_dispatch.new({
        shader = descriptor.cullShader,
        registry = shadowRegistry,
        growable = growable,
        indirectBuffer = indirectBuffer,
        shadowIndirectBuffer = shadowIndirectBuffer,
        hasShadow = descriptor.hasShadow,
        primaryShadowCtype = descriptor.primaryLayout.shadowCtype,
        primaryInputName = descriptor.primaryInputName,
        outputName = descriptor.outputName,
        shadowOutputName = descriptor.shadowOutputName,
        optional = descriptor.optional,
        tagFlags = descriptor.tagFlags,
    })
    plugin.cull = function(rendererArg: any, cullParamsBuffer: love.graphics.Buffer)
        dispatch(rendererArg, cullParamsBuffer)
    end

    gpuRenderer:registerPlugin(plugin)

    world:addSystem({
        name = descriptor.renderStateSystemName,
        phase = tecs.phases.PreRender,
        run = function()
            shadow_render_state.run(
                shadowRegistry,
                syncRef as shadow_render_state.Frame,
                Material as tecs.Component
            )
        end,
    })

    world:addSystem({
        name = descriptor.uploadSystemName,
        phase = tecs.phases.PreRender,
        after = {descriptor.renderStateSystemName},
        run = function()
            shadowRegistry:flushAll()
            local total = 0
            for arch, _state in shadowRegistry:archetypes() do
                total = total + ((arch as {string:any}).entities as {integer})[0]
            end
            ensureGrowableCapacity(total)
            stubTransform.count = total
        end,
    })
end

return shadow_plugin
