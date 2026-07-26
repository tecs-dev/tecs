--- GPU-instanced mesh rendering -- renderer-owned shadow-column path.
---
--- Source columns (Transform / Color / ClipBounds / Pivot / Material
--- + the Mesh row's `_definitionId`) flow through per-archetype
--- shadow buffers held by `shadow_state` instances (registered via
--- `mesh/shadowsetup.tl`). The cull dispatch
--- (`mesh/shadowdispatch.tl`) issues one compute pass per
--- (definition, archetype) and writes per-instance results into the
--- definition's own output / indirect / material-params buffers.
--- Each MeshDefinition draws with its own `love.graphics.Mesh` so
--- per-definition output buffers are the natural fan-out.

local tecs <const> = require("tecs")
local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local Material <const> = require("tecs2d.gfx.internal.Material")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local meshDefinition <const> = require("tecs2d.gfx.internal.mesh.definition")
local materialcompiler <const> = require("tecs2d.gfx.internal.materialcompiler")
local shadowsetup <const> = require("tecs2d.gfx.internal.mesh.shadowsetup")
local shadowdispatch <const> = require("tecs2d.gfx.internal.mesh.shadowdispatch")
local modifierbinding <const> = require("tecs2d.gfx.internal.gpu.modifierbinding")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")

local lg <const> = love.graphics

local MESH_SHADERS <const> = "tecs2d/gfx/internal/mesh/"
local meshRenderSource <const> = shaderUtils.loadRenderShader("mesh", MESH_SHADERS)
local meshRenderShader <const> = lg.newShader(meshRenderSource)
local meshCullShader <const> = lg.newComputeShader(shaderUtils.loadCullShader("mesh_cull", MESH_SHADERS))
materialcompiler.registerBaseSource("mesh", meshRenderSource)

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.mesh")

local record mesh
    --- A Mesh component used for GPU-instanced mesh rendering.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    --- The mesh geometry is defined by a MeshDefinition registered via MeshDefinition.new().
    ---
    --- Storage is FFI-backed (`int32_t _definitionId`); the user-facing
    --- API is unchanged -- `Mesh("name")` resolves the definition name to
    --- its id at construction. The string is held only on
    --- MeshDefinition (looked up via `_definitionId` for serialize).
    record Mesh is tecs.Component
        --- Resolved MeshDefinition id. 0 means "definition not yet
        --- registered when this Mesh was created"; the cull dispatch
        --- treats id=0 as a row to skip.
        _definitionId: integer

        --- Creates a new Mesh component.
        ---
        --- @param definition The name of the registered MeshDefinition
        --- @return The created Mesh component
        metamethod __call: function(self, definition: string): Mesh
    end

    --- Re-export MeshDefinition for convenient access
    MeshDefinition: meshDefinition

    --- Plugin function to register mesh rendering systems
    plugin: function(world: tecs.World)
end

local Mesh <const> = mesh.Mesh

mesh.MeshDefinition = meshDefinition

tecs.newFFIComponent({
    name = "Mesh",
    container = Mesh,
    fields = {
        {"_definitionId", "int32_t"},
    },
    -- Resolve the definition name → id at construction. Definitions
    -- registered later won't be picked up automatically; user code
    -- should register definitions before spawning meshes that point
    -- at them. id=0 means "unresolved"; the cull dispatch skips those.
    __call = function(instance: mesh.Mesh, definition: string)
        local def = meshDefinition.getByName(definition)
        instance._definitionId = (def and def.id) or 0
    end,
    serialize = function(instance: mesh.Mesh): {string: any}
        local def = meshDefinition.getById(instance._definitionId)
        if not def then return nil end
        return { definition = def.name }
    end,
    deserialize = function(_world: tecs.World, data: {string: any}): mesh.Mesh
        return Mesh(data.definition as string)
    end
})

function mesh.plugin(world: tecs.World)
    local pipelineInstance <const> = world.resources[pipelinekey.PIPELINE as tecs.Key<gpuTypes.PipelineInternal>]
    if not pipelineInstance then
        LOGGER:error("No render pipeline found in world resources")
        return
    end
    local gpuRenderer =
        pipelineInstance:getRenderer() as gpuTypes.Renderer

    -- Build the per-archetype shadow registry + render-state /
    -- upload PreRender systems.
    -- Modifier bindings (layout, mask bit, SSBO name) derived from the
    -- shared registry so they can't drift from cull_common.glsl. The
    -- mesh shadow modules declare their own structurally identical
    -- OptionalBinding records, hence the casts.
    local meshModifiers <const> = modifierbinding.bind({
        ColorComponent, ClipBounds, Pivot, Material,
    })

    local shadowCtx = shadowsetup.register(world, {
        meshComponent = Mesh as tecs.Component,
        optional = meshModifiers as {shadowsetup.OptionalBinding},
        registryName = "mesh.shadows",
        renderStateSystemName = "mesh.ShadowRenderState",
        uploadSystemName = "mesh.ShadowUpload",
        disableInterpolation =
            gpuRenderer.config.disableInterpolation == true,
    })

    -- Per-(definition, archetype) cull dispatch. Each archetype's
    -- shadow buffers are bound; the dispatch sets `TargetDefinitionId`
    -- + `MeshBounds` per definition so the cull shader skips rows with
    -- mismatched mesh ids.
    local cullDispatch <const> = shadowdispatch.new({
        shader = meshCullShader,
        registry = shadowCtx.registry,
        meshComponent = Mesh as tecs.Component,
        optional = meshModifiers as {shadowdispatch.OptionalBinding},
        tagFlags = {
            {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
        },
    })

    -- Per-definition live entity counts, summed across all archetypes
    -- the registry tracks. Used to grow output buffers ahead of cull
    -- so atomicAdd writes never go OOB. Computed in the upload-after
    -- system that runs after `shadowRegistry:flushAll()`.
    local function countLivePerDefinition(): {integer: integer}
        local counts: {integer: integer} = {}
        for arch, _state in shadowCtx.registry:archetypes() do
            local rowCount = ((arch as {string:any}).entities as {integer})[0] as integer
            if rowCount == 0 then goto continue end
            local meshes = arch:get(Mesh) as {mesh.Mesh}
            if not meshes then goto continue end
            for i = 1, rowCount do
                local id = meshes[i]._definitionId
                if id ~= 0 then
                    counts[id] = (counts[id] or 0) + 1
                end
            end
            ::continue::
        end
        return counts
    end

    -- Per-definition output capacity is independent of upload; the
    -- shadow upload system already runs in PreRender. Capacity sizing
    -- runs alongside cull (which fires from the renderer plugin's
    -- `cull` hook) so we don't traverse archetypes twice per frame.

    local liveCounts: {integer: integer} = {}

    gpuRenderer:registerPlugin({
        name = "Mesh",
        cull = function(rendererArg: gpuTypes.Renderer, cullParamsBuffer: love.graphics.Buffer)
            -- Size each definition's output buffer to fit the current
            -- live entities for that definition. Cull's atomicAdd
            -- writes one MeshOut per visible instance; OOB writes
            -- corrupt unrelated buffers.
            liveCounts = countLivePerDefinition()
            for id, count in pairs(liveCounts) do
                local def = meshDefinition.getById(id)
                if def and count > def.capacity then
                    local newCap = def.capacity * 2
                    if newCap < count then newCap = count end
                    def:grow(newCap)
                end
            end

            cullDispatch(rendererArg, cullParamsBuffer)
        end,
        renderGBuffer = function(rendererArg: gpuTypes.Renderer, renderParamsBuffer: love.graphics.Buffer, globalTime: number)
            local syncRef <const> = shadowCtx.syncRef
            for id, count in pairs(liveCounts) do
                if count == 0 then goto continue end
                local def = meshDefinition.getById(id)
                if not def then goto continue end

                -- Default pass: materialId == 0 only (variant shaders
                -- handle the rest below). BlendModePass=0 means alpha-
                -- blend instances; non-alpha mesh instances aren't
                -- supported on the G-buffer pass yet.
                lg.setShader(meshRenderShader)
                meshRenderShader:send("RenderParams", renderParamsBuffer)
                meshRenderShader:send("MeshOutput", def.outputBuffer)
                if meshRenderShader:hasUniform("BlendModePass") then
                    meshRenderShader:send("BlendModePass", 0)
                end
                if meshRenderShader:hasUniform("MaterialPass") then
                    meshRenderShader:send("MaterialPass", -1)
                end
                lg.drawIndirect(def.mesh, def.indirectBuffer, 1, 1)

                -- Material variants. Mesh's syncRef.materialGroups is
                -- shared across all definitions, so each variant
                -- shader is drawn once per definition that has live
                -- instances. The variant shader filters per-instance
                -- by `MaterialPass == matId`.
                if syncRef and syncRef.materialGroupCount > 0 then
                    for i = 1, syncRef.materialGroupCount do
                        local matGroup = syncRef.materialGroups[i]
                        local variantShader = materialcompiler.compile(matGroup.materialId, "mesh")
                        if variantShader then
                            lg.setShader(variantShader)
                            variantShader:send("RenderParams", renderParamsBuffer)
                            if variantShader:hasUniform("LayerRange") then
                                local lr = (rendererArg as {string:any})._layerRange as {number}
                                variantShader:send("LayerRange", lr)
                            end
                            if variantShader:hasUniform("BlendModePass") then
                                variantShader:send("BlendModePass", 0)
                            end
                            variantShader:send("MaterialPass", matGroup.materialId)
                            if variantShader:hasUniform("GlobalTime") then
                                variantShader:send("GlobalTime", globalTime)
                            end
                            variantShader:send("MeshOutput", def.outputBuffer)
                            if variantShader:hasUniform("MaterialParamsBuffer") then
                                variantShader:send("MaterialParamsBuffer", def.materialParamsBuffer)
                            end
                            lg.drawIndirect(def.mesh, def.indirectBuffer, 1, 1)
                        end
                    end
                end

                ::continue::
            end
        end,
        setLayerRange = function(_r: gpuTypes.Renderer, range: {number})
            if meshRenderShader:hasUniform("LayerRange") then
                meshRenderShader:send("LayerRange", range)
            end
        end,
    })
end

return mesh
