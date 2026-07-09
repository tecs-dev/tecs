--- Per-definition cull dispatch for the renderer-owned shadow mesh
--- path. Iterates the shadow archetype registry and issues one
--- compute dispatch per (definition, archetype). The dispatch binds
--- the archetype's shadow source SSBOs, sets `TargetDefinitionId`
--- and `MeshBounds` uniforms, and routes outputs to the definition's
--- own output / indirect-args buffers (each MeshDefinition has its
--- own draw because the geometry is per-definition).
---
--- A row's `mesh._definitionId` filters per-row inside the cull
--- shader: rows that don't match `TargetDefinitionId` early-return.
--- This keeps the shadow path compatible with archetypes that mix
--- multiple mesh definitions without forcing a relationship-style
--- API change.

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local archetyperegistry <const> = require("tecs2d.gfx.internal.archetyperegistry")
local shadowstate <const> = require("tecs2d.gfx.internal.gpu.shadowstate")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local blend <const> = require("tecs2d.gfx.internal.blend")
local meshDefinition <const> = require("tecs2d.gfx.internal.mesh.definition")
local dummyFor <const> = require("tecs2d.gfx.internal.gpu.dummyssbo").dummyFor

local Transform <const> = tecs.builtins.Transform

local lg <const> = love.graphics
local ceil <const> = math.ceil
local bor <const> = require("bit").bor

local record shadow_dispatch
    record OptionalBinding
        component: tecs.Component
        layout: std430.Descriptor
        mask: integer
        ssboName: string
    end

    --- Per-archetype tag-to-flag binding. When the archetype has the
    --- tag component, `flag` is OR'd into the dispatch's `StaticFlags`
    --- uniform. Used for zero-data tags like `Unlit`.
    record TagFlagBinding
        component: tecs.Component
        flag: integer
    end

    record Config
        --- The compute cull shader. Pass nil to set up bookkeeping
        --- without enabling dispatch (useful while authoring).
        shader: love.graphics.ComputeShader
        registry: archetyperegistry.Registry
        meshComponent: tecs.Component
        optional: {OptionalBinding}
        --- Tag-to-flag bindings (see TagFlagBinding). Defaults to none.
        tagFlags: {TagFlagBinding}
    end

    --- Fire one cull dispatch per (definition, archetype). Skips
    --- empty archetypes and definitions with capacity==0 outputs.
    --- Caller is responsible for resetting `def.indirectBuffer`
    --- before the dispatch and for ensuring `def.outputBuffer`
    --- has capacity for visible instances.
    new: function(config: Config): function(any, love.graphics.Buffer)
end

function shadow_dispatch.new(config: shadow_dispatch.Config): function(any, love.graphics.Buffer)
    local shader <const> = config.shader
    local registry <const> = config.registry
    local meshComponent <const> = config.meshComponent
    local optional <const> = config.optional
    local tagFlags <const> = config.tagFlags
    local tagFlagCount <const> = tagFlags and #tagFlags or 0

    return function(_renderer: any, cullParamsBuffer: love.graphics.Buffer)
        if shader == nil then return end

        for _, def in pairs(meshDefinition.getAll()) do
            -- Skip definitions whose output buffer is unallocated
            -- (registered late, before the renderer initialized them).
            if def.outputBuffer == nil then goto continue_def end

            local hasArch = false
            for _arch, _state in registry:archetypes() do
                hasArch = true
                break
            end
            if not hasArch then goto continue_def end

            -- Reset per-definition indirect counter before the
            -- dispatch loop. Every (def, archetype) pair atomicAdds
            -- into the same counter so the cull writes form a
            -- contiguous instance list for this definition's draw.
            def.indirectBuffer:setArrayData(def.indirectResetData)

            -- Total live entities across all archetypes (worst-case
            -- output size). The host can grow `def.outputBuffer` to
            -- match before dispatching; for now we trust the
            -- def:grow() / capacity logic in the caller.
            local meshBounds = {def.boundsCenterX, def.boundsCenterY, def.boundsHalfW, def.boundsHalfH}

            for arch, stateAny in registry:archetypes() do
                local state = stateAny as shadowstate.ArchetypeState
                if state.destroyed then goto continue_arch end

                local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
                if rowCount == 0 then goto continue_arch end

                local shadows = state.shadows

                -- Required: Transform.
                local transformBuf = shadows:get(Transform)
                if not transformBuf then goto continue_arch end
                shader:send("TransformInput", (transformBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

                -- Required: Mesh.
                local meshBuf = shadows:get(meshComponent)
                if not meshBuf then goto continue_arch end
                shader:send("MeshInput", (meshBuf as {string:any}).gpuBuffer as love.graphics.Buffer)

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
                local cols = (arch as tecsInternal.ArchetypeInternal).columns
                for i = 1, tagFlagCount do
                    local tf = tagFlags[i]
                    if cols[tf.component] ~= nil then
                        staticFlags = bor(staticFlags, tf.flag)
                    end
                end

                shader:send("CullParams", cullParamsBuffer)
                shader:send("ArchetypeRowCount", rowCount)
                shader:send("ComponentMask", mask)
                shader:send("TargetDefinitionId", def.id)
                shader:send("MeshBounds", meshBounds)
                shader:send("BlendId", blend.groupBy(arch))
                if (shader as {string:any}).hasUniform and shader:hasUniform("StaticFlags") then
                    shader:send("StaticFlags", staticFlags)
                end

                shader:send("MeshOutput", def.outputBuffer)
                shader:send("MaterialParamsOutput", def.materialParamsBuffer)
                shader:send("IndirectArgs", def.indirectBuffer)

                lg.dispatchThreadgroups(shader, ceil(rowCount / 256), 1, 1)

                ::continue_arch::
            end

            ::continue_def::
        end
    end
end

return shadow_dispatch
