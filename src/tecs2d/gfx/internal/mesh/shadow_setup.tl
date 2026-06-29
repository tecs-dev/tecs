--- Renderer-owned shadow-column scaffolding for mesh archetypes.
---
--- Builds a single per-archetype `shadow_state` registry gated on
--- `Transform + Mesh`. Each Mesh entity carries an `_definitionId`
--- field; multiple definitions can share an archetype, so the cull
--- shader filters per-row by `TargetDefinitionId`.
---
--- Adds the two PreRender systems (render-state pass and upload
--- flush) that drive blend/material grouping and per-component dirty
--- uploads. Per-(definition, archetype) cull dispatch lives in
--- `mesh/shadow_dispatch.tl`; that module consumes the registry this
--- one builds.

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
        --- Component handle for the Mesh canonical column. Must be
        --- on every archetype the registry tracks.
        meshComponent: tecs.Component
        --- Optional component bindings. A shadow buffer is attached
        --- if the component is present on the archetype; the cull
        --- shader branches via `ComponentMask`.
        optional: {OptionalBinding}
        --- System / registry naming.
        registryName: string
        renderStateSystemName: string
        uploadSystemName: string
    end

    record Context
        registry: archetype_registry.Registry
        syncRef: shadow_render_state.Frame
    end

    register: function(world: tecs.World, config: Config): Context
end

local function buildSpecs(
    meshComponent: tecs.Component,
    optional: {shadow_setup.OptionalBinding}
): {tecs.Component: std430.Descriptor}
    -- Mesh itself is shadowed because the cull shader reads
    -- `_definitionId` per row to filter against `TargetDefinitionId`.
    local specs: {tecs.Component: std430.Descriptor} = {
        [Transform] = std430.layouts.Transform,
        [meshComponent] = std430.layouts.Mesh,
    }
    for i = 1, #optional do
        local b = optional[i]
        specs[b.component] = b.layout
    end
    return specs
end

local function archMatches(arch: tecs.Archetype, meshComponent: tecs.Component): boolean
    if arch.columns[Transform] == nil then return false end
    if arch.columns[meshComponent] == nil then return false end
    return true
end

function shadow_setup.register(world: tecs.World, config: shadow_setup.Config): shadow_setup.Context
    local syncRef: shadow_render_state.Frame = {
        hasAlphaBlend = false,
        blendGroups = {},
        blendGroupCount = 0,
        materialGroups = {},
        materialGroupCount = 0,
    }

    local meshComponent <const> = config.meshComponent
    local specs <const> = buildSpecs(meshComponent, config.optional)

    -- Back identity-layout columns (Transform, ...) with ByteData so the shadow
    -- path uploads them straight to their SSBO. Install-time, before spawn.
    for comp, layout in pairs(specs) do
        gpu_backing.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetype_registry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return archMatches(arch, meshComponent)
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

    world:addSystem({
        name = config.uploadSystemName,
        phase = tecs.phases.PreRender,
        after = {config.renderStateSystemName},
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
