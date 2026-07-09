--- Renderer-owned shadow-column scaffolding for sprite archetypes.
---
--- Builds per-archetype `shadow_state` instances for any archetype that
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
    end

    record Context
        registry: archetype_registry.Registry
        syncRef: shadow_render_state.Frame
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
    local syncRef: shadow_render_state.Frame = {
        hasAlphaBlend = false,
        blendGroups = {},
        blendGroupCount = 0,
        materialGroups = {},
        materialGroupCount = 0,
    }

    local sprite <const> = config.sprite
    local bucketMarkers <const> = config.bucketMarkers
    local specs <const> = buildSpecs(sprite, config.optional)

    -- Back identity-layout columns (Transform, SpriteData, ...) with ByteData
    -- so the shadow path uploads them straight to their SSBO. Install-time, so
    -- columns are ByteData from first spawn.
    for comp, layout in pairs(specs) do
        gpu_backing.enable(comp, layout as {string:any})
    end

    local shadowRegistry = archetype_registry.new(world, {
        name = config.registryName,
        matches = function(arch: tecs.Archetype): boolean
            return archMatches(arch, sprite, bucketMarkers)
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
