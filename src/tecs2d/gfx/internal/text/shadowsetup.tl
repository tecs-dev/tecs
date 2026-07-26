--- Renderer-owned shadow-column scaffolding for text archetypes.
---
--- Builds per-archetype `shadowstate` instances for any archetype that
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
--- lower-level building blocks (`shadowstate`, `archetyperegistry`,
--- `shadowrenderstate`) keeps the architectures aligned.

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local archetyperegistry <const> = require("tecs2d.gfx.internal.archetyperegistry")
local shadowstate <const> = require("tecs2d.gfx.internal.gpu.shadowstate")
local shadowrenderstate <const> = require("tecs2d.gfx.internal.gpu.shadowrenderstate")
local transforminterpolation <const> =
    require("tecs2d.gfx.internal.gpu.transforminterpolation")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local gpubacking <const> = require("tecs2d.gfx.internal.gpu.gpubacking")
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
        disableInterpolation: boolean
    end

    record Context
        registry: archetyperegistry.Registry
        syncRef: shadowrenderstate.Frame
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
    local syncRef: shadowrenderstate.Frame = {
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
        gpubacking.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetyperegistry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            local cols = (arch as tecsInternal.ArchetypeInternal).columns
            return cols[Transform] ~= nil and cols[text] ~= nil
        end,
        create = function(arch: tecs.Archetype): any
            return shadowstate.new(arch, specs)
        end,
    })
    local interpolation <const> = transforminterpolation.new(
        world,
        shadowRegistry,
        config.disableInterpolation
    )

    world:addSystem({
        name = config.renderStateSystemName,
        phase = tecs.phases.PreRender,
        run = function()
            shadowrenderstate.run(
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
            interpolation:flush()
        end,
    })

    return {
        registry = shadowRegistry,
        syncRef = syncRef,
    }
end

return shadow_setup
