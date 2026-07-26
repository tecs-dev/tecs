--- Renderer-owned shadow-column scaffolding for mesh archetypes.
---
--- Builds a single per-archetype `shadowstate` registry gated on
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
        disableInterpolation: boolean
    end

    record Context
        registry: archetyperegistry.Registry
        syncRef: shadowrenderstate.Frame
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
    local cols = (arch as tecsInternal.ArchetypeInternal).columns
    if cols[Transform] == nil then return false end
    if cols[meshComponent] == nil then return false end
    return true
end

function shadow_setup.register(world: tecs.World, config: shadow_setup.Config): shadow_setup.Context
    local syncRef: shadowrenderstate.Frame = {
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
        gpubacking.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetyperegistry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return archMatches(arch, meshComponent)
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

    world:addSystem({
        name = config.uploadSystemName,
        phase = tecs.phases.PreRender,
        after = {config.renderStateSystemName},
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
