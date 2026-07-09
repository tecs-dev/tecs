--- Factory for simple shape render plugins (circle, ellipse, arc, line, rect).
--- All 5 shapes follow the same dual-buffer architecture pattern:
---   transform buffer (synced every frame) + metadata buffer (synced on dirty)
--- This factory generates all phase closures from a configuration table.

local buffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local types <const> = require("tecs2d.gfx.internal.gpu.types")
local forward_blend <const> = require("tecs2d.gfx.internal.gpu.forward_blend")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local material_registry <const> = require("tecs2d.gfx.internal.material_registry")
local shape_sync_base <const> = require("tecs2d.gfx.internal.shape_sync_base")

local lg <const> = love.graphics
local ceil <const> = math.ceil

local type SyncRecord = shape_sync_base.SyncRecord

local record shape_utils
    --- Holder for buffers that get replaced on growth.
    --- The table reference is stable; closures share it.
    record GrowableBuffers
        outputBuffer: love.graphics.Buffer
        shadowOutputBuffer: love.graphics.Buffer
        materialParamsOutBuffer: love.graphics.Buffer
    end

    --- Configuration for a simple shape render plugin.
    record SimpleShapeConfig
        --- Shape prefix for uniform naming: "Circle", "Ellipse", "Arc", "Line", "Rect"
        prefix: string
        --- Plural form: "Circles", "Ellipses", "Arcs", "Lines", "Rects"
        plural: string
        --- Material shape name: "circle", "ellipse", "arc", "line", "rectangle"
        materialShapeName: string

        --- Stable GPUBuffer references (wrappers handle internal growth)
        transformBuffer: buffer.GPUBuffer
        metadataBuffer: buffer.GPUBuffer
        inputBuffer: buffer.GPUBuffer

        --- Indirect buffer (stable, never re-created)
        indirectBuffer: love.graphics.Buffer

        --- Growable buffers (replaced on growth, shared via table ref)
        growable: GrowableBuffers

        --- Shaders
        cullShader: love.graphics.ComputeShader
        renderShader: love.graphics.Shader

        --- Sync module reference. Must implement shape_sync_base.SyncRecord.
        syncRef: SyncRecord

        --- Optional shadow support (nil = no shadows)
        shadowIndirectBuffer: love.graphics.Buffer
        shadowMaskShader: love.graphics.Shader

        --- If true, G-buffer only draws alpha-blend entities (BlendModePass=0)
        --- and forward blend draws non-alpha via blendGroups.
        --- Circle, rect use this. Ellipse, arc, line do not.
        hasAlphaBlendFilter: boolean
    end

    --- Create a RenderPlugin from a SimpleShapeConfig.
    simpleShapePlugin: function(config: SimpleShapeConfig): types.RenderPlugin
end

--- Create a RenderPlugin from a SimpleShapeConfig.
--- All phase closures are generated from the config. Nil optional fields
--- produce nil hooks (skipped by the renderer).
function shape_utils.simpleShapePlugin(config: shape_utils.SimpleShapeConfig): types.RenderPlugin
    local prefix <const> = config.prefix
    local plural <const> = config.plural

    -- Derive cull shader uniform names
    local totalUniform <const> = "Total" .. plural
    local transformInputUniform <const> = prefix .. "TransformInput"
    local metadataInputUniform <const> = prefix .. "MetadataInput"
    local outputUniform <const> = prefix .. "Output"
    local shadowOutputUniform <const> = prefix .. "ShadowOutput"

    local hasShadow <const> = config.shadowMaskShader ~= nil
    local growable <const> = config.growable

    local plugin: types.RenderPlugin = {
        name = prefix,
    }

    ---------------------------------------------------------------------------
    -- UPLOAD
    ---------------------------------------------------------------------------
    plugin.upload = function(_renderer: types.Renderer)
        config.transformBuffer:upload()
        config.metadataBuffer:upload()
        config.inputBuffer:upload()

        local syncRef = config.syncRef
        if syncRef and syncRef.materialParamsBuffer then
            syncRef.materialParamsBuffer:upload()
        end
    end

    ---------------------------------------------------------------------------
    -- RESET INDIRECT
    ---------------------------------------------------------------------------
    plugin.resetIndirect = function(renderer: types.Renderer)
        config.indirectBuffer:setArrayData(renderer.indirectResetData)
        if hasShadow then
            config.shadowIndirectBuffer:setArrayData(renderer.indirectResetData)
        end
    end

    ---------------------------------------------------------------------------
    -- CULL
    ---------------------------------------------------------------------------
    plugin.cull = function(renderer: types.Renderer, cullParamsBuffer: love.graphics.Buffer)
        local count = config.transformBuffer.count
        if count > 0 then
            local shader = config.cullShader
            shader:send("CullParams", cullParamsBuffer)
            shader:send(totalUniform, count)
            shader:send(transformInputUniform, config.transformBuffer.handle)
            shader:send(metadataInputUniform, config.metadataBuffer.handle)
            shader:send(outputUniform, growable.outputBuffer)
            shader:send("IndirectArgs", config.indirectBuffer)

            if hasShadow then
                shader:send(shadowOutputUniform, growable.shadowOutputBuffer)
                shader:send("ShadowIndirectArgs", config.shadowIndirectBuffer)
                shader:send("ShadowMargin", renderer.config.shadowMargin or 200.0)
            end

            -- Material params forwarding
            local syncRef = config.syncRef
            local matIn: love.graphics.Buffer
            if syncRef and syncRef.materialParamsBuffer then
                matIn = syncRef.materialParamsBuffer.handle
            else
                matIn = renderer.dummyMaterialParamsBuffer
            end
            shader:send("MaterialParamsInput", matIn)
            shader:send("MaterialParamsOutput", growable.materialParamsOutBuffer)
            lg.dispatchThreadgroups(shader, ceil(count / 256), 1, 1)
        end
    end

    ---------------------------------------------------------------------------
    -- RENDER G-BUFFER
    ---------------------------------------------------------------------------
    plugin.renderGBuffer = function(renderer: types.Renderer, renderParamsBuffer: love.graphics.Buffer, globalTime: number)
        local count = config.transformBuffer.count
        if count == 0 then return end

        local syncRef = config.syncRef

        -- G-buffer main pass draws only alpha-blend entities (blendId=0).
        -- Non-alpha entities go through forward blend post-lighting.
        -- Always set BlendModePass explicitly so stale values from the prior
        -- frame's forward-blend pass (which cycles through non-zero IDs)
        -- don't leak into this draw.
        local rough = renderer._roughGeometry and 1.0 or 0.0
        if config.hasAlphaBlendFilter then
            local hasAlpha = syncRef and syncRef.hasAlphaBlend
            if hasAlpha then
                local shader = config.renderShader
                lg.setShader(shader)
                shader:send("RenderParams", renderParamsBuffer)
                shader:send("BlendModePass", 0)
                shader:send("MaterialPass", -1)
                if shader:hasUniform("RoughGeometry") then
                    shader:send("RoughGeometry", rough)
                end
                shader:send(outputUniform, growable.outputBuffer)
                lg.drawFromShaderIndirect("triangles", config.indirectBuffer, 1)
            end
        else
            local shader = config.renderShader
            lg.setShader(shader)
            shader:send("RenderParams", renderParamsBuffer)
            if shader:hasUniform("BlendModePass") then
                shader:send("BlendModePass", 0)
            end
            shader:send("MaterialPass", -1)
            if shader:hasUniform("RoughGeometry") then
                shader:send("RoughGeometry", rough)
            end
            shader:send(outputUniform, growable.outputBuffer)
            lg.drawFromShaderIndirect("triangles", config.indirectBuffer, 1)
        end

        -- Material variants
        if syncRef and syncRef.materialGroupCount > 0 then
            for i = 1, syncRef.materialGroupCount do
                local matGroup = syncRef.materialGroups[i]
                local variantShader = material_compiler.compile(matGroup.materialId, config.materialShapeName)
                if variantShader then
                    lg.setShader(variantShader)
                    variantShader:send("RenderParams", renderParamsBuffer)
                    if variantShader:hasUniform("LayerRange") then
                        variantShader:send("LayerRange", renderer._layerRange)
                    end
                    -- Material variants only render with alpha blend, regardless
                    -- of hasAlphaBlendFilter. Blend modes + materials are not
                    -- compatible by design; any non-alpha-blend material entity
                    -- is treated as invalid input and skipped here.
                    if variantShader:hasUniform("BlendModePass") then
                        variantShader:send("BlendModePass", 0)
                    end
                    variantShader:send("MaterialPass", matGroup.materialId)
                    variantShader:send("GlobalTime", globalTime)
                    if variantShader:hasUniform("RoughGeometry") then
                        variantShader:send("RoughGeometry", rough)
                    end
                    variantShader:send(outputUniform, growable.outputBuffer)
                    variantShader:send("MaterialParamsBuffer", growable.materialParamsOutBuffer)
                    local def = material_registry.getById(matGroup.materialId)
                    if def then
                        for uniformName, tex in pairs(def.textures) do
                            if variantShader:hasUniform(uniformName) then
                                variantShader:send(uniformName, tex)
                            end
                        end
                    end
                    lg.drawFromShaderIndirect("triangles", config.indirectBuffer, 1)
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- RENDER FORWARD BLEND (non-alpha blend modes, post-lighting)
    -- Active for shapes whose sync ref reports blendGroups.
    ---------------------------------------------------------------------------
    plugin.renderForwardBlend = function(renderer: types.Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)
        local syncRef = config.syncRef
        if not syncRef or not syncRef.blendGroupCount or syncRef.blendGroupCount == 0 then return end

        local vw, vh = renderer.config.virtualRes[1], renderer.config.virtualRes[2]
        local rw = useLowRes and vw or renderer.screenWidth
        local rh = useLowRes and vh or renderer.screenHeight
        subPixelX = subPixelX or 0.0
        subPixelY = subPixelY or 0.0

        forward_blend.populateRenderParams(renderer, cameraX, cameraY, cameraZoom, subPixelX, subPixelY, rw, rh, 0.0)

        local shader = config.renderShader
        lg.setShader(shader)
        shader:send("RenderParams", renderer.renderParamsBuffer)
        shader:send(outputUniform, growable.outputBuffer)
        shader:send("MaterialPass", -1)
        if shader:hasUniform("RoughGeometry") then
            shader:send("RoughGeometry", renderer._roughGeometry and 1.0 or 0.0)
        end

        for i = 1, syncRef.blendGroupCount do
            local group = syncRef.blendGroups[i]
            shader:send("BlendModePass", group.blendId)
            lg.setBlendMode(group.blendMode, group.blendAlphaMode)
            lg.drawFromShaderIndirect("triangles", config.indirectBuffer, 1)
        end

        lg.setBlendMode("alpha", "alphamultiply")
        lg.setShader()
    end

    ---------------------------------------------------------------------------
    -- SET LAYER RANGE
    ---------------------------------------------------------------------------
    plugin.setLayerRange = function(_renderer: types.Renderer, range: {number})
        local shader = config.renderShader
        if shader:hasUniform("LayerRange") then
            shader:send("LayerRange", range)
        end
    end

    ---------------------------------------------------------------------------
    -- RENDER SHADOW MASK
    ---------------------------------------------------------------------------
    if hasShadow then
        plugin.renderShadowMask = function(_renderer: types.Renderer, shadowTransform: love.math.Transform)
            if config.transformBuffer.count == 0 then return end

            local shader = config.shadowMaskShader
            lg.setShader(shader)
            shader:send("ShadowViewProj", shadowTransform)
            shader:send(outputUniform, growable.shadowOutputBuffer)
            lg.drawFromShaderIndirect("triangles", config.shadowIndirectBuffer, 1)
        end
    end

    return plugin
end

return shape_utils
