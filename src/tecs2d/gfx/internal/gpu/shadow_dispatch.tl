--- Generic per-archetype cull dispatch driver for the shadow-column
--- path. Replaces per-shape `*_cull.tl` files that diverged only in
--- the SSBO names + optional-component list.
---
--- Architecture:
---
--- - One dispatch per (archetype, shape).
--- - Each dispatch binds the archetype's shadow source-component
---   SSBOs directly, plus a dispatch-uniform `BlendId` and
---   `ComponentMask` (which optional components this archetype has).
--- - All dispatches share the same cull-output, shadow-output,
---   indirect args, and materialParamsOutBuffer SSBOs. atomicAdd
---   inside the shader gives globally-unique output indices across
---   all archetypes for the shape.
--- - Absent optional components are bound to a small zero-filled
---   dummy SSBO so the shader has a valid binding; the
---   `ComponentMask` uniform-branches the read to a hardcoded
---   default.

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local blend <const> = require("tecs2d.gfx.internal.blend")
local shape_utils <const> = require("tecs2d.gfx.internal.gpu.shape_utils")
local dummyFor <const> = require("tecs2d.gfx.internal.gpu.dummy_ssbo").dummyFor

local Transform <const> = tecs.builtins.Transform

local lg <const> = love.graphics
local ceil <const> = math.ceil
local bor <const> = require("bit").bor

local record shadow_dispatch
    --- One optional-component binding. The shader has a fixed SSBO
    --- name and a `ComponentMask` bit; the driver wires real or
    --- dummy SSBO based on whether the archetype has the component.
    record OptionalBinding
        component: tecs.Component
        layout: std430.Descriptor
        mask: integer            -- bit value (must match shader's COMP_X define)
        ssboName: string         -- as declared in the shader
    end

    --- Per-archetype tag-to-flag binding. When the archetype has the
    --- tag component, `flag` is OR'd into the dispatch's `StaticFlags`
    --- uniform, which the cull shader folds into the per-instance
    --- output flags. Used for zero-data tags like `Unlit` so they
    --- don't need their own SSBO.
    record TagFlagBinding
        component: tecs.Component
        flag: integer
    end

    record DispatchConfig
        --- The compute shader (loaded from the shape's
        --- `*_cull.glsl`).
        shader: love.graphics.ComputeShader
        --- Renderer-owned shape registry.
        registry: archetype_registry.Registry
        --- Shared output / indirect buffers.
        growable: shape_utils.GrowableBuffers
        --- Indirect args + shadow indirect args. Shared across
        --- dispatches for the shape.
        indirectBuffer: love.graphics.Buffer
        shadowIndirectBuffer: love.graphics.Buffer
        --- True iff shadow output should be written.
        hasShadow: boolean

        --- The shape's primary component (Circle / Rectangle /
        --- Ellipse). Always required on the archetype; the dispatch
        --- looks it up in the shadow set by `primaryShadowCtype`
        --- (NOT by component handle, to avoid a require cycle when
        --- the component is defined in the shape's own init.tl).
        primaryShadowCtype: string
        primaryInputName: string

        --- SSBO names for the writeable output buffers.
        outputName: string
        shadowOutputName: string

        --- Optional component bindings. Order doesn't matter; mask
        --- bits are independent.
        optional: {OptionalBinding}

        --- Tag-to-flag bindings. Each entry maps a tag component to a
        --- flag bit. For each archetype, `StaticFlags` is the OR of
        --- bits whose tags are present. Defaults to no tags.
        tagFlags: {TagFlagBinding}
    end

    new: function(config: DispatchConfig): function(any, love.graphics.Buffer)
end

function shadow_dispatch.new(config: shadow_dispatch.DispatchConfig): function(any, love.graphics.Buffer)
    local shader = config.shader
    local registry = config.registry
    local growable = config.growable
    local indirectBuffer = config.indirectBuffer
    local shadowIndirectBuffer = config.shadowIndirectBuffer
    local hasShadow = config.hasShadow
    local primaryShadowCtype = config.primaryShadowCtype
    local primaryInputName = config.primaryInputName
    local outputName = config.outputName
    local shadowOutputName = config.shadowOutputName
    local optional = config.optional
    local tagFlags = config.tagFlags
    local tagFlagCount = tagFlags and #tagFlags or 0

    return function(renderer: any, cullParamsBuffer: love.graphics.Buffer)
        for arch, stateAny in registry:archetypes() do
            local state = stateAny as shadow_state.ArchetypeState
            if state.destroyed then goto continue end

            local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
            if rowCount == 0 then goto continue end

            local shadows = state.shadows

            -- Required: Transform. The shadow set always carries it
            -- since the registry's `matches` predicate gates on it.
            local transformBuf = shadows:get(Transform)
            if not transformBuf then goto continue end
            shader:send("TransformInput", (transformBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

            -- Required: shape's primary component. Look it up by
            -- shadowCtype on the shadow entries to avoid requiring a
            -- direct handle (the primary component is defined in the
            -- shape's own init.tl, which would create a cycle).
            local primaryBuf: love.graphics.Buffer = nil
            local shadowEntries = (shadows as {string:any}).entries as {{string:any}}
            for i = 1, #shadowEntries do
                local e = shadowEntries[i]
                local layout = e.layout as std430.Descriptor
                if layout.shadowCtype == primaryShadowCtype then
                    primaryBuf = (e.buffer as {string:any}).gpuBuffer as love.graphics.Buffer
                    break
                end
            end
            if not primaryBuf then goto continue end
            shader:send(primaryInputName, primaryBuf)

            -- Optional components.
            local mask = 0
            for i = 1, #optional do
                local b = optional[i]
                local mb = shadows:get(b.component)
                if mb then
                    shader:send(b.ssboName, (mb as {string:any}).gpuBuffer as love.graphics.Buffer)
                    mask = bor(mask, b.mask)
                else
                    shader:send(b.ssboName, dummyFor(b.layout))
                end
            end

            local staticFlags = 0
            for i = 1, tagFlagCount do
                local tf = tagFlags[i]
                if arch.columns[tf.component] ~= nil then
                    staticFlags = bor(staticFlags, tf.flag)
                end
            end

            shader:send("CullParams", cullParamsBuffer)
            shader:send("ArchetypeRowCount", rowCount)
            shader:send("ComponentMask", mask)
            -- StaticFlags is a per-archetype OR of tagFlag bits. GLSL
            -- strips unused uniforms, so guard the send: shaders that
            -- don't fold StaticFlags into their output (e.g. when no
            -- tag bindings are wired) will have it stripped.
            if (shader as {string:any}).hasUniform and shader:hasUniform("StaticFlags") then
                shader:send("StaticFlags", staticFlags)
            end
            -- Arc/Ellipse cull shaders declare `BlendId` but don't use
            -- it (their render path doesn't filter per-blend), so GLSL
            -- strips the uniform. Skip the send when the binding isn't
            -- present on this shader.
            if (shader as {string:any}).hasUniform and shader:hasUniform("BlendId") then
                shader:send("BlendId", blend.groupBy(arch))
            end

            shader:send(outputName, growable.outputBuffer)
            shader:send("MaterialParamsOutput", growable.materialParamsOutBuffer)
            shader:send("IndirectArgs", indirectBuffer)

            if hasShadow then
                shader:send(shadowOutputName, growable.shadowOutputBuffer)
                shader:send("ShadowIndirectArgs", shadowIndirectBuffer)
                local rendererAny = renderer as {string:any}
                local rConfig = rendererAny.config as {string:any}
                shader:send("ShadowMargin", (rConfig.shadowMargin as number) or 200.0)
            end

            lg.dispatchThreadgroups(shader, ceil(rowCount / 256), 1, 1)

            ::continue::
        end
    end
end

return shadow_dispatch
