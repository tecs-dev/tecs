--- Renderer-owned shadow-column scaffolding for text archetypes.
---
--- Builds per-archetype `shadow_state` instances for any archetype that
--- contains both `Transform` and `Text`, plus optional bindings for
--- the renderer's dynamic input columns (Color, ClipBounds, RenderFlags,
--- Material, TextEffects). Adds the two PreRender systems (render-state
--- and upload) that drive blend/material grouping and bulk flushRange
--- uploads.
---
--- This module just stands up the input-side shadow buffers; the cull
--- dispatch and render-side integration live in
--- `text/shadow_dispatch.tl` and `text/render_plugin.tl`.
---
--- Naming: this lives in `tecs2d.gfx.internal.text` rather than
--- `gpu/shadow_plugin.tl` because text needs a custom dispatch shape
--- (two output streams: per-entity headerOut + per-glyph visibleGlyph)
--- that the generic `shadow_plugin` doesn't model. Reusing the same
--- lower-level building blocks (`shadow_state`, `archetype_registry`,
--- `shadow_render_state`) keeps the architectures aligned.

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local shadow_render_state <const> = require("tecs2d.gfx.internal.gpu.shadow_render_state")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpu_backing <const> = require("tecs2d.gfx.internal.gpu.gpu_backing")
local Material <const> = require("tecs2d.gfx.internal.Material")

local Transform <const> = tecs.builtins.Transform

local record shadow_setup
    record OptionalBinding
        component: tecs.Component
        layout: std430.Descriptor
        mask: integer
        ssboName: string
    end

    record Config
        --- Component handle for the Text canonical column. Must be
        --- on every archetype the registry tracks.
        text: tecs.Component
        --- Optional component bindings. A shadow buffer is attached if
        --- the component is present on the archetype; the cull shader
        --- will branch via ComponentMask.
        optional: {OptionalBinding}
        --- System / registry naming. Mirrors gpu/shadow_plugin's
        --- convention (`<prefix>.ShadowRenderState`, etc.) so debug
        --- output is consistent across shapes.
        registryName: string
        renderStateSystemName: string
        uploadSystemName: string
        --- Extra `after` constraints for the upload system. Used to
        --- order the shadow flush after any caller-side systems that
        --- write to the canonical columns (e.g. `text_sync.Sync`
        --- writing `gpuStartIdx` / `fontLayer` to Text).
        uploadAfter: {string}
    end

    record Context
        registry: archetype_registry.Registry
        syncRef: shadow_render_state.Frame
    end

    register: function(world: tecs.World, config: Config): Context
end

local function buildSpecs(text: tecs.Component, optional: {shadow_setup.OptionalBinding}): {tecs.Component: std430.Descriptor}
    local specs: {tecs.Component: std430.Descriptor} = {
        [Transform] = std430.layouts.Transform,
        [text] = std430.layouts.Text,
    }
    for i = 1, #optional do
        local b = optional[i]
        specs[b.component] = b.layout
    end
    return specs
end

function shadow_setup.register(world: tecs.World, config: shadow_setup.Config): shadow_setup.Context
    local syncRef: shadow_render_state.Frame = {
        hasAlphaBlend = false,
        blendGroups = {},
        blendGroupCount = 0,
        materialGroups = {},
        materialGroupCount = 0,
    }

    local text <const> = config.text
    local specs <const> = buildSpecs(text, config.optional)

    -- Back identity-layout columns (Transform, ...) with ByteData so the shadow
    -- path uploads them straight to their SSBO. Install-time, before spawn.
    for comp, layout in pairs(specs) do
        gpu_backing.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetype_registry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return arch.columns[Transform] ~= nil and arch.columns[text] ~= nil
        end,
        create = function(arch: tecs.Archetype): any
            return shadow_state.new(arch, specs)
        end,
    })

    world:addSystem({
        name = config.renderStateSystemName,
        phase = tecs.phases.PreRender,
        run = function()
            shadow_render_state.run(
                shadowRegistry,
                syncRef,
                Material as tecs.Component
            )
        end,
    })

    local uploadAfter: {string} = {config.renderStateSystemName}
    if config.uploadAfter then
        for i = 1, #config.uploadAfter do
            uploadAfter[#uploadAfter + 1] = config.uploadAfter[i]
        end
    end

    world:addSystem({
        name = config.uploadSystemName,
        phase = tecs.phases.PreRender,
        after = uploadAfter,
        run = function()
            shadowRegistry:flushAll()
        end,
    })

    return {
        registry = shadowRegistry,
        syncRef = syncRef,
    }
end

return shadow_setup
