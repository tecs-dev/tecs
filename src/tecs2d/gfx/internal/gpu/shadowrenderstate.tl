--- Generic per-shape render-state pass for the shadow-column path.
--- Walks the registered archetypes for a shape and produces this
--- frame's blend/material grouping. Shadow flushes are NOT invoked
--- here; the registry's `flushAll` runs after this pass finishes.
---
--- Replaces per-shape `render_state.tl` files that were byte-for-byte
--- identical except for the state-record cast.

local tecs <const> = require("tecs")
local archetype_registry <const> = require("tecs2d.gfx.internal.archetype_registry")
local shadow_state <const> = require("tecs2d.gfx.internal.gpu.shadow_state")
local shape_sync_base <const> = require("tecs2d.gfx.internal.shape_sync_base")
local blend <const> = require("tecs2d.gfx.internal.blend")

local type Registry = archetype_registry.Registry
local type ArchetypeState = shadow_state.ArchetypeState
local type BlendGroup = shape_sync_base.BlendGroup
local type MaterialGroup = shape_sync_base.MaterialGroup
local type MaterialData = shape_sync_base.MaterialData

local trackBlendGroup <const> = shape_sync_base.trackBlendGroup
local trackMaterialGroup <const> = shape_sync_base.trackMaterialGroup

local record shadow_render_state
    --- Per-frame render-scheduling state. Same shape as
    --- `shape_sync_base.SyncRecord` so it can be passed to the
    --- renderer's renderGBuffer without translation.
    record Frame
        hasAlphaBlend: boolean
        blendGroups: {BlendGroup}
        blendGroupCount: integer
        materialGroups: {MaterialGroup}
        materialGroupCount: integer
    end

    --- Walk the registered archetypes and update `frame` in place.
    run: function(registry: Registry, frame: Frame, materialComponent: tecs.Component)
end

function shadow_render_state.run(
    registry: Registry,
    frame: shadow_render_state.Frame,
    materialComponent: tecs.Component
)
    frame.hasAlphaBlend = false
    frame.blendGroupCount = 0
    frame.materialGroupCount = 0

    for arch, stateAny in registry:archetypes() do
        local state = stateAny as ArchetypeState
        if state.destroyed then goto continue_arch end

        local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
        if rowCount == 0 then goto continue_arch end

        local blendId = blend.groupBy(arch)
        if blendId == 0 then
            frame.hasAlphaBlend = true
        else
            frame.blendGroupCount = trackBlendGroup(
                frame.blendGroups, frame.blendGroupCount, blendId
            )
        end

        local materials = arch:get(materialComponent) as {MaterialData}
        if materials then
            for row = 1, rowCount do
                local mat = materials[row]
                if mat and mat.materialId > 0 then
                    frame.materialGroupCount = trackMaterialGroup(
                        frame.materialGroups, frame.materialGroupCount, mat.materialId
                    )
                end
            end
        end

        ::continue_arch::
    end
end

return shadow_render_state
