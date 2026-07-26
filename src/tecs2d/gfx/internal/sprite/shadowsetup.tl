--- Renderer-owned shadow-column scaffolding for sprite archetypes.
---
--- Builds per-archetype `shadowstate` instances for any archetype that
--- contains `Transform`, `Sprite`, and one of the size-tier bucket
--- markers. Shadow source columns are Transform + Sprite plus every
--- optional binding the cull cares about (Color, ClipBounds, Unlit,
--- Material, Pivot, Occluder, DropShadow, RepeatedSprite). The bucket
--- marker itself is NOT shadowed -- the cull shader reads layerIndex /
--- generation from SpriteData.textureSlice instead.
---
--- Adds the two PreRender systems (render-state pass and upload flush)
--- that drive blend/material grouping and per-component dirty uploads.
--- Bucket-aware dispatch and per-bucket output buffers live in
--- `sprite/shadow_dispatch.tl`; that module consumes the registry this
--- one builds.
---
--- Shadow buffers fill each frame and the cull shader reads them as
--- typed SSBO inputs. The bucket-aware dispatch picks the active
--- TextureBucket marker per archetype and routes the cull's outputs
--- to that tier's per-array buffers (see `shadow_dispatch.tl`).

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local fixedtracking <const> = require("tecs.internal.fixedtracking")
local archetyperegistry <const> = require("tecs2d.gfx.internal.archetyperegistry")
local shadowstate <const> = require("tecs2d.gfx.internal.gpu.shadowstate")
local shadowrenderstate <const> = require("tecs2d.gfx.internal.gpu.shadowrenderstate")
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
        --- Component handle for the Sprite canonical column. Must be
        --- on every archetype the registry tracks.
        sprite: tecs.Component
        --- The six bucket-marker components (Tiny / Small / Medium /
        --- Large / XL / XXL). The registry's `matches` predicate
        --- accepts an archetype if it carries any one of them.
        bucketMarkers: {tecs.Component}
        --- Optional component bindings. A shadow buffer is attached if
        --- the component is present on the archetype; the cull shader
        --- branches via `ComponentMask`.
        --- Bucket markers are NOT in this list -- they're handled
        --- separately because exactly one is present per archetype
        --- and the dispatch module looks the active marker up by
        --- iterating shadow entries.
        optional: {OptionalBinding}
        --- System / registry naming. Mirrors `gpu/shadow_plugin`'s
        --- convention (`<prefix>.ShadowRenderState`, etc.) so debug
        --- output is consistent across shapes.
        registryName: string
        renderStateSystemName: string
        uploadSystemName: string
        --- Extra `after` constraints for the upload system. Orders the
        --- shadow flush after sync systems that write to the canonical
        --- columns (e.g. sprite.GPUSync).
        uploadAfter: {string}
        --- Do not retain consecutive fixed-step Transform samples.
        disableInterpolation: boolean
    end

    record Context
        registry: archetyperegistry.Registry
        syncRef: shadowrenderstate.Frame
    end

    register: function(world: tecs.World, config: Config): Context
end

local function buildSpecs(
    sprite: tecs.Component,
    optional: {shadow_setup.OptionalBinding}
): {tecs.Component: std430.Descriptor}
    -- Bucket markers gate archetype matching (must have one of the six
    -- TextureBucket components) but have NO shadow buffer -- the cull shader
    -- reads layerIndex/generation from SpriteData.textureSlice, packed
    -- by sync's dirty path. Skipping the bucket-marker shadow saves
    -- one upload column per sprite archetype.
    local specs: {tecs.Component: std430.Descriptor} = {
        [Transform] = std430.layouts.Transform,
        [sprite] = std430.layouts.Sprite,
    }
    for i = 1, #optional do
        local b = optional[i]
        specs[b.component] = b.layout
    end
    return specs
end

local function archMatches(arch: tecs.Archetype, sprite: tecs.Component, bucketMarkers: {tecs.Component}): boolean
    local cols = (arch as tecsInternal.ArchetypeInternal).columns
    if cols[Transform] == nil then return false end
    if cols[sprite] == nil then return false end
    -- Must carry one of the six tier markers. Sprites without a bucket
    -- marker haven't been bucket-allocated yet and aren't renderable.
    for i = 1, #bucketMarkers do
        if cols[bucketMarkers[i]] ~= nil then
            return true
        end
    end
    return false
end

function shadow_setup.register(world: tecs.World, config: shadow_setup.Config): shadow_setup.Context
    local syncRef: shadowrenderstate.Frame = {
        hasAlphaBlend = false,
        blendGroups = {},
        blendGroupCount = 0,
        materialGroups = {},
        materialGroupCount = 0,
    }

    local sprite <const> = config.sprite
    local bucketMarkers <const> = config.bucketMarkers
    local specs <const> = buildSpecs(sprite, config.optional)

    if not config.disableInterpolation then
        fixedtracking.track(world, Transform)
    end

    -- Back identity-layout columns (Transform, SpriteData, ...) with ByteData
    -- so the shadow path uploads them straight to their SSBO. Install-time, so
    -- columns are ByteData from first spawn.
    for comp, layout in pairs(specs) do
        gpubacking.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetyperegistry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return archMatches(arch, sprite, bucketMarkers)
        end,
        create = function(arch: tecs.Archetype): any
            return shadowstate.new(arch, specs)
        end,
    })

    local lastPresentedStep = fixedtracking.currentStep(world)
    if not config.disableInterpolation then
        fixedtracking.beforeStep(world, function()
            if fixedtracking.currentStep(world) ~= lastPresentedStep + 1 then
                return
            end
            for _, stateAny in shadowRegistry:archetypes() do
                local state = stateAny as shadowstate.ArchetypeState
                if not state.destroyed then
                    -- Variable-rate writes before the fixed loop snap the
                    -- presentation baseline once before catch-up starts.
                    state.shadows:flushCurrent(Transform)
                end
            end
        end)
    end

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
            if not config.disableInterpolation then
                local currentStep = fixedtracking.currentStep(world)
                local elapsedSteps = currentStep - lastPresentedStep
                if elapsedSteps == 1 then
                    for arch, stateAny in shadowRegistry:archetypes() do
                        if fixedtracking.wroteThisStep(
                            world,
                            arch,
                            Transform
                        ) then
                            local state =
                                stateAny as shadowstate.ArchetypeState
                            if not state.destroyed then
                                state.shadows:flushFixed(
                                    Transform,
                                    currentStep
                                )
                            end
                        end
                    end
                end
                lastPresentedStep = currentStep
            end
            shadowRegistry:flushAll()
        end,
    })

    return {
        registry = shadowRegistry,
        syncRef = syncRef,
    }
end

return shadow_setup
