--- Render plugin for tile chunk rendering (16x16 tile grids as single GPU instances).
--- Unlike simple shapes, tile chunks use individual cull uniforms instead of the CullParams SSBO,
--- and require texture array bindings for albedo, normal, emission, and ORM maps.

local types <const> = require("tecs2d.gfx.internal.gpu.types")
local lg <const> = love.graphics
local ceil <const> = math.ceil

local function sendMat4(shader: any, name: string, data: {number})
    local send = (shader as {string: any}).send as function(any, string, string, {number})
    send(shader, name, "column", data)
end

local record tilechunk_plugin
    -- Growable buffers that may be replaced on growth (accessed via stable table ref)
    record TileChunkGrowable
        outputBuffer: love.graphics.Buffer
        shadowOutputBuffer: love.graphics.Buffer
        textureArray: love.graphics.Texture
        normalArray: love.graphics.Texture
        emissionArray: love.graphics.Texture
        ormArray: love.graphics.Texture
        textureSize: {number}
        heightLookup: love.graphics.Texture
        --- Highest live slot + 1. Tracks the tight dispatch range so cull/render
        --- don't iterate over freed slots above the true high-water mark.
        activeCount: integer
    end

    --- Thin handle holder for the input buffer. The cull shader reads
    --- `handle` each frame; on grow the plugin replaces it on this same
    --- table reference so consumers don't need a re-binding step.
    record InputBufferRef
        handle: love.graphics.Buffer
    end

    record TileChunkPluginConfig
        renderShader: love.graphics.Shader
        cullShader: love.graphics.ComputeShader
        shadowMaskShader: love.graphics.Shader
        inputBuffer: InputBufferRef
        indirectBuffer: love.graphics.Buffer
        shadowIndirectBuffer: love.graphics.Buffer
        growable: TileChunkGrowable
    end
    create: function(config: TileChunkPluginConfig): types.RenderPlugin
end

function tilechunk_plugin.create(config: tilechunk_plugin.TileChunkPluginConfig): types.RenderPlugin
    local plugin: types.RenderPlugin = { name = "TileChunk" }
    local tileChunkRenderShader <const> = config.renderShader
    local tileChunkCullShader <const> = config.cullShader
    local tileChunkShadowMaskShader <const> = config.shadowMaskShader
    local inputBuffer <const> = config.inputBuffer
    local indirectBuffer <const> = config.indirectBuffer
    local shadowIndirectBuffer <const> = config.shadowIndirectBuffer
    local growable <const> = config.growable

    ---------------------------------------------------------------------------
    -- UPLOAD
    ---------------------------------------------------------------------------
    -- Tilechunk sync writes to the input buffer with per-slot setArrayData
    -- inline (gated by the DirtyTileChunk tag query), so the plugin's
    -- upload phase has nothing to do.
    plugin.upload = function(_r: types.Renderer) end

    ---------------------------------------------------------------------------
    -- RESET INDIRECT
    ---------------------------------------------------------------------------
    plugin.resetIndirect = function(r: types.Renderer)
        indirectBuffer:setArrayData(r.indirectResetData)
        shadowIndirectBuffer:setArrayData(r.indirectResetData)
    end

    ---------------------------------------------------------------------------
    -- CULL
    ---------------------------------------------------------------------------
    plugin.cull = function(r: types.Renderer, _cullParamsBuffer: love.graphics.Buffer)
        local tileChunkCount = growable.activeCount
        if tileChunkCount > 0 then
            local shader = tileChunkCullShader
            shader:send("CameraViewport", r._cullViewport)
            shader:send("CameraPos", r._cullCameraPos)
            sendMat4(shader, "ParallaxX", r._cullParallaxMatX)
            sendMat4(shader, "ParallaxY", r._cullParallaxMatY)
            shader:send("TotalChunks", tileChunkCount)
            shader:send("CameraLayerMask", r._cullCameraLayerMask)
            shader:send("TileChunkInput", inputBuffer.handle)
            shader:send("TileChunkOutput", growable.outputBuffer)
            shader:send("IndirectArgs", indirectBuffer)
            shader:send("TileChunkShadowOutput", growable.shadowOutputBuffer)
            shader:send("ShadowIndirectArgs", shadowIndirectBuffer)
            shader:send("ShadowMargin", r.config.shadowMargin or 200.0)
            lg.dispatchThreadgroups(shader, ceil(tileChunkCount / 256), 1, 1)
        end
    end

    ---------------------------------------------------------------------------
    -- RENDER G-BUFFER
    ---------------------------------------------------------------------------
    plugin.renderGBuffer = function(_r: types.Renderer, renderParamsBuffer: love.graphics.Buffer, _globalTime: number)
        if growable.activeCount > 0 and growable.textureArray then
            local shader = tileChunkRenderShader
            lg.setShader(shader)
            shader:send("RenderParams", renderParamsBuffer)
            shader:send("TilesetSize", growable.textureSize)
            shader:send("TileChunkOutput", growable.outputBuffer)
            -- Compact vis records reference rows in the input buffer.
            shader:send("TileChunkInput", inputBuffer.handle)

            local tex = growable.textureArray
            shader:send("MainTex", tex)

            if growable.normalArray then
                shader:send("NormalTex", growable.normalArray)
            end

            if growable.emissionArray then
                shader:send("EmissionTex", growable.emissionArray)
            end

            if growable.ormArray and shader:hasUniform("ORMTex") then
                shader:send("ORMTex", growable.ormArray)
            end

            lg.drawFromShaderIndirect("triangles", indirectBuffer, 1, tex)
        end
    end

    ---------------------------------------------------------------------------
    -- RENDER SHADOW MASK
    ---------------------------------------------------------------------------
    plugin.renderShadowMask = function(_r: types.Renderer, shadowTransform: love.math.Transform)
        if growable.activeCount > 0 and growable.textureArray and growable.heightLookup then
            local shader = tileChunkShadowMaskShader
            lg.setShader(shader)
            shader:send("ShadowViewProj", shadowTransform)
            shader:send("AlphaThreshold", 0.5)

            local texArray = growable.textureArray
            local texW, texH = texArray:getDimensions()
            shader:send("TilesetSize", {texW, texH})
            shader:send("TileChunkMainTex", texArray)

            local heightLookup = growable.heightLookup
            local heightW, heightH = heightLookup:getDimensions()
            shader:send("HeightLookup", heightLookup)
            shader:send("HeightLookupSize", {heightW, heightH})

            shader:send("TileChunkShadowOutput", growable.shadowOutputBuffer)
            -- Compact vis records reference rows in the input buffer.
            shader:send("TileChunkInput", inputBuffer.handle)
            lg.drawFromShaderIndirect("triangles", shadowIndirectBuffer, 1)
        end
    end

    plugin.setLayerRange = function(_r: types.Renderer, range: {number})
        if tileChunkRenderShader:hasUniform("LayerRange") then
            tileChunkRenderShader:send("LayerRange", range)
        end
    end

    return plugin
end

return tilechunk_plugin
