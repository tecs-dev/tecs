--- Sprite render plugin for the Tecs ECS framework.
--- Handles bucket-based sprite rendering (per-tier, per-array texture arrays)
--- and sprite blend batches. Implements upload, cull, G-buffer render,
--- forward blend, and shadow mask hooks.

local types <const> = require("tecs2d.gfx.internal.gpu.types")
local forward_blend <const> = require("tecs2d.gfx.internal.gpu.forward_blend")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local material_registry <const> = require("tecs2d.gfx.internal.material_registry")
local lg <const> = love.graphics

-- Local type alias for blend group (from shape_sync_base)
local record BlendGroupRecord
    blendId: integer
    blendMode: love.graphics.BlendMode
    blendAlphaMode: love.graphics.BlendAlphaMode
end

-- Local type alias for bucket sync array state. Fields are the
-- cull-output buffers + indirect args + active-entity count gate.
local record ArraySyncRecord
    outputBuffer: love.graphics.Buffer
    indirectBuffer: love.graphics.Buffer
    shadowOutputBuffer: love.graphics.Buffer
    shadowIndirectBuffer: love.graphics.Buffer
    dropShadowOutputBuffer: love.graphics.Buffer
    dropShadowIndirectBuffer: love.graphics.Buffer
    materialParamsOutputBuffer: love.graphics.Buffer
    dropShadowCapacity: integer
    count: integer
end

-- Local type alias for tier sync state
local record TierSyncRecord
    tier: string
    arraySyncs: {integer: ArraySyncRecord}
end

-- Local type alias for sprite bucket sync
local record SpriteBucketSyncRecord
    tiers: {string: TierSyncRecord}
    materialGroups: {MaterialGroup}
    materialGroupCount: integer
    hasDropShadows: boolean
    blendGroups: {BlendGroupRecord}
    blendGroupCount: integer
    hasAlphaBlend: boolean
    getArraySyncs: function(SpriteBucketSyncRecord, tier: string): {integer: ArraySyncRecord}
    getActiveTiers: function(SpriteBucketSyncRecord): {string}
end

-- Local type alias for bucket manager texture array
local record BucketTextureArray
    albedo: love.graphics.Canvas
    normal: love.graphics.Canvas
    emission: love.graphics.Canvas
    orm: love.graphics.Canvas
    generations: {integer}
    generationsBuffer: love.graphics.Buffer
end

-- Local type alias for bucket manager
local record BucketManagerRecord
    getArrays: function(BucketManagerRecord, tier: string): {BucketTextureArray}
end

-- Local type alias for material group
local record MaterialGroup
    materialId: integer
end

local record sprite_plugin
    record SpritePluginConfig
        renderShader: love.graphics.Shader
        shadowMaskShader: love.graphics.Shader
        dropShadowShader: love.graphics.Shader
        bucketSync: any
        bucketManager: any
        --- Cull dispatch closure. Owns the per-frame cull pass: walks
        --- registered sprite archetypes, binds shadow source columns,
        --- routes outputs to arraySync's per-(tier, array) buffers.
        --- Provided by `shadow_dispatch.new`'s returned context.
        cullDispatch: function(types.Renderer, love.graphics.Buffer)
    end
    create: function(config: SpritePluginConfig): types.RenderPlugin
end

function sprite_plugin.create(config: sprite_plugin.SpritePluginConfig): types.RenderPlugin
    local plugin: types.RenderPlugin = { name = "Sprite" }
    local spriteRenderShader <const> = config.renderShader
    local spriteShadowMaskShader <const> = config.shadowMaskShader
    local spriteDropShadowShader <const> = config.dropShadowShader
    local spriteBucketSync <const> = config.bucketSync as SpriteBucketSyncRecord
    local bucketManager <const> = config.bucketManager as BucketManagerRecord
    local cullDispatch <const> = config.cullDispatch

    function plugin.upload(_self: types.Renderer)
        -- Shadow pipeline uploads input columns each frame (Transform,
        -- Sprite, SpriteData, optional bindings) via dirty-gated
        -- flushRange. Cull-output buffers are GPU-only; no upload.
    end

    function plugin.resetIndirect(self: types.Renderer)
        for _, tierSync in pairs(spriteBucketSync.tiers) do
            for _, arraySync in pairs(tierSync.arraySyncs) do
                arraySync.indirectBuffer:setArrayData(self.indirectResetData)
                arraySync.shadowIndirectBuffer:setArrayData(self.indirectResetData)
                arraySync.dropShadowIndirectBuffer:setArrayData(self.indirectResetData)
            end
        end
    end

    function plugin.cull(self: types.Renderer, cullParamsBuffer: love.graphics.Buffer)
        -- Signal that drop shadow AO pass is needed (set during sync)
        self._hasDropShadows = spriteBucketSync.hasDropShadows

        -- The shadow pipeline owns the cull dispatch. It walks tracked
        -- archetypes, binds shadow source columns, and routes outputs
        -- to arraySync's per-(tier, array) buffers. The rest of the
        -- render plugin reads those same arraySync buffers below.
        cullDispatch(self, cullParamsBuffer)
    end

    function plugin.renderGBuffer(self: types.Renderer, renderParamsBuffer: love.graphics.Buffer, globalTime: number)
        -- Draw bucket sprites (size-bucketed texture arrays)
        local shader = spriteRenderShader
        lg.setShader(shader)
        shader:send("RenderParams", renderParamsBuffer)

        for tier, tierSync in pairs(spriteBucketSync.tiers) do
            local textureArrays = bucketManager:getArrays(tier)
            for arrayIdx, arraySync in pairs(tierSync.arraySyncs) do
                if arraySync.count > 0 then
                    local texArray = textureArrays[arrayIdx]

                    shader:send("SpriteOutput", arraySync.outputBuffer)

                    -- Albedo texture array
                    local mainTex = texArray.albedo as love.graphics.Texture
                    mainTex:setFilter("nearest", "nearest")
                    mainTex:setWrap("clampzero", "clampzero")
                    shader:send("MainTex", mainTex)

                    -- Normal texture array
                    if shader:hasUniform("NormalTex") then
                        local normalTex = texArray.normal as love.graphics.Texture
                        normalTex:setFilter("nearest", "nearest")
                        shader:send("NormalTex", normalTex)
                    end

                    -- Emission texture array
                    if shader:hasUniform("EmissionTex") then
                        local emissionTex = texArray.emission as love.graphics.Texture
                        emissionTex:setFilter("nearest", "nearest")
                        shader:send("EmissionTex", emissionTex)
                    end

                    -- ORM texture array
                    if shader:hasUniform("ORMTex") then
                        local ormTex = texArray.orm as love.graphics.Texture
                        ormTex:setFilter("nearest", "nearest")
                        shader:send("ORMTex", ormTex)
                    end

                    -- G-buffer pass: only render alpha-blend sprites (blendId=0)
                    if spriteBucketSync.hasAlphaBlend then
                        shader:send("BlendModePass", 0)
                        shader:send("MaterialPass", -1)
                        lg.drawFromShaderIndirect("triangles", arraySync.indirectBuffer, 1, mainTex)
                    end
                end
            end
        end

        -- Draw sprite material variants (G-buffer pass)
        if spriteBucketSync.materialGroupCount > 0 then
            for i = 1, spriteBucketSync.materialGroupCount do
                local matGroup = spriteBucketSync.materialGroups[i]
                local variantShader = material_compiler.compile(matGroup.materialId, "sprite")
                if variantShader then
                    lg.setShader(variantShader)
                    variantShader:send("RenderParams", renderParamsBuffer)
                    if variantShader:hasUniform("LayerRange") then
                        variantShader:send("LayerRange", self._layerRange)
                    end
                    if variantShader:hasUniform("BlendModePass") then
                        variantShader:send("BlendModePass", 0)
                    end
                    variantShader:send("MaterialPass", matGroup.materialId)
                    variantShader:send("GlobalTime", globalTime)
                    -- Bind material textures
                    local def = material_registry.getById(matGroup.materialId)
                    if def then
                        for uniformName, tex in pairs(def.textures) do
                            if variantShader:hasUniform(uniformName) then
                                variantShader:send(uniformName, tex)
                            end
                        end
                    end
                    -- Draw across all tiers/arrays
                    for tier2, tierSync2 in pairs(spriteBucketSync.tiers) do
                        local textureArrays2 = bucketManager:getArrays(tier2)
                        for arrayIdx2, arraySync2 in pairs(tierSync2.arraySyncs) do
                            if arraySync2.count > 0 then
                                local texArray2 = textureArrays2[arrayIdx2]
                                variantShader:send("SpriteOutput", arraySync2.outputBuffer)
                                variantShader:send("MaterialParamsBuffer", arraySync2.materialParamsOutputBuffer)
                                local mainTex2 = texArray2.albedo as love.graphics.Texture
                                mainTex2:setFilter("nearest", "nearest")
                                mainTex2:setWrap("clampzero", "clampzero")
                                variantShader:send("MainTex", mainTex2)
                                if variantShader:hasUniform("NormalTex") then
                                    local normalTex2 = texArray2.normal as love.graphics.Texture
                                    normalTex2:setFilter("nearest", "nearest")
                                    variantShader:send("NormalTex", normalTex2)
                                end
                                if variantShader:hasUniform("EmissionTex") then
                                    local emissionTex2 = texArray2.emission as love.graphics.Texture
                                    emissionTex2:setFilter("nearest", "nearest")
                                    variantShader:send("EmissionTex", emissionTex2)
                                end
                                if variantShader:hasUniform("ORMTex") then
                                    local ormTex2 = texArray2.orm as love.graphics.Texture
                                    ormTex2:setFilter("nearest", "nearest")
                                    variantShader:send("ORMTex", ormTex2)
                                end
                                lg.drawFromShaderIndirect("triangles", arraySync2.indirectBuffer, 1, mainTex2)
                            end
                        end
                    end
                end
            end
        end

    end

    function plugin.renderForwardBlend(self: types.Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)
        -- useLowRes is now a parameter
        local vw, vh = self.config.virtualRes[1], self.config.virtualRes[2]
        local rw = useLowRes and vw or self.screenWidth
        local rh = useLowRes and vh or self.screenHeight
        subPixelX = subPixelX or 0.0
        subPixelY = subPixelY or 0.0

        forward_blend.populateRenderParams(self, cameraX, cameraY, cameraZoom, subPixelX, subPixelY, rw, rh, 0.0)

        local shader = spriteRenderShader
        lg.setShader(shader)
        shader:send("RenderParams", self.renderParamsBuffer)
        shader:send("MaterialPass", -1)

        -- Iterate blend groups at the SpriteBucketSync level, then draw across all active arrays
        for i = 1, spriteBucketSync.blendGroupCount do
            local blendGroup = spriteBucketSync.blendGroups[i]
            if blendGroup.blendId > 0 then
                shader:send("BlendModePass", blendGroup.blendId)
                lg.setBlendMode(blendGroup.blendMode, blendGroup.blendAlphaMode)

                for _, tierSync in pairs(spriteBucketSync.tiers) do
                    local textureArrays = bucketManager:getArrays(tierSync.tier)
                    for arrayIdx, arraySync in pairs(tierSync.arraySyncs) do
                        if arraySync.count > 0 then
                            local texArray = textureArrays[arrayIdx]
                            shader:send("SpriteOutput", arraySync.outputBuffer)

                            local mainTex = texArray.albedo as love.graphics.Texture
                            mainTex:setFilter("nearest", "nearest")
                            mainTex:setWrap("clampzero", "clampzero")
                            shader:send("MainTex", mainTex)
                            -- The fragment shader samples NormalTex/EmissionTex/ORMTex
                            -- unconditionally, so we must bind all four array textures
                            -- here even though the forward-blend pass only outputs to
                            -- one canvas. Without these binds, the shader samples
                            -- whatever stale array was left bound from a prior pass.
                            shader:send("NormalTex", texArray.normal as love.graphics.Texture)
                            shader:send("EmissionTex", texArray.emission as love.graphics.Texture)
                            shader:send("ORMTex", texArray.orm as love.graphics.Texture)

                            lg.drawFromShaderIndirect("triangles", arraySync.indirectBuffer, 1, mainTex)
                        end
                    end
                end
            end
        end

        lg.setBlendMode("alpha", "alphamultiply")
        lg.setShader()
    end

    function plugin.renderShadowMask(_self: types.Renderer, shadowTransform: love.math.Transform)
        local shader = spriteShadowMaskShader
        lg.setShader(shader)
        shader:send("ShadowViewProj", shadowTransform)
        shader:send("AlphaThreshold", 0.5)

        for tier, tierSync in pairs(spriteBucketSync.tiers) do
            local textureArrays = bucketManager:getArrays(tier)
            for arrayIdx, arraySync in pairs(tierSync.arraySyncs) do
                if arraySync.count > 0 then
                    local texArray = textureArrays[arrayIdx]
                    if texArray then
                        shader:send("SpriteShadowOutput", arraySync.shadowOutputBuffer)
                        local mainTex = texArray.albedo as love.graphics.Texture
                        mainTex:setFilter("nearest", "nearest")
                        mainTex:setWrap("clampzero", "clampzero")
                        local texW, texH = mainTex:getDimensions()
                        shader:send("TextureSize", {texW, texH})
                        shader:send("SpriteMainTex", mainTex)
                        lg.drawFromShaderIndirect("triangles", arraySync.shadowIndirectBuffer, 1)
                    end
                end
            end
        end
    end

    function plugin.renderDropShadowAO(_self: types.Renderer, renderParamsBuffer: love.graphics.Buffer)
        local dsShader = spriteDropShadowShader
        lg.setShader(dsShader)
        dsShader:send("RenderParams", renderParamsBuffer)
        dsShader:send("AOOverride", -1.0)  -- Use computed AO from shadow opacity

        -- Pass 1: draw drop shadows (replace blend, set by caller)
        for tier, tierSync in pairs(spriteBucketSync.tiers) do
            local textureArrays = bucketManager:getArrays(tier)
            for arrayIdx, arraySync in pairs(tierSync.arraySyncs) do
                if arraySync.count > 0 then
                    local texArray = textureArrays[arrayIdx]
                    -- Cap instances to this bucket's drop-shadow capacity:
                    -- the cull's atomicAdd counter can exceed it (writes
                    -- past it are skipped), so the indirect instance count
                    -- may name rows that were never written.
                    dsShader:send("MaxDropShadows", arraySync.dropShadowCapacity)
                    dsShader:send("DropShadowSpriteOutput", arraySync.dropShadowOutputBuffer)
                    local mainTex = texArray.albedo as love.graphics.Texture
                    dsShader:send("MainTex", mainTex)
                    lg.drawFromShaderIndirect("triangles", arraySync.dropShadowIndirectBuffer, 1, mainTex)
                end
            end
        end

        -- Pass 2: stamp out source sprites with ao=1.0 (lighten/max blend)
        -- This erases shadow where the character sprite exists, preventing self-shadowing.
        lg.setBlendMode("lighten", "premultiplied")
        dsShader:send("AOOverride", 1.0)
        -- Pass 2 draws the main sprite list, which has no drop-shadow cap.
        dsShader:send("MaxDropShadows", 0xFFFFFFFF)

        for tier, tierSync in pairs(spriteBucketSync.tiers) do
            local textureArrays = bucketManager:getArrays(tier)
            for arrayIdx, arraySync in pairs(tierSync.arraySyncs) do
                if arraySync.count > 0 then
                    local texArray = textureArrays[arrayIdx]
                    -- Use the MAIN sprite output buffer (character positions)
                    dsShader:send("DropShadowSpriteOutput", arraySync.outputBuffer)
                    local mainTex = texArray.albedo as love.graphics.Texture
                    dsShader:send("MainTex", mainTex)
                    lg.drawFromShaderIndirect("triangles", arraySync.indirectBuffer, 1, mainTex)
                end
            end
        end

        lg.setShader()
    end

    plugin.setLayerRange = function(_r: types.Renderer, range: {number})
        if spriteRenderShader:hasUniform("LayerRange") then
            spriteRenderShader:send("LayerRange", range)
        end
        if spriteDropShadowShader:hasUniform("LayerRange") then
            spriteDropShadowShader:send("LayerRange", range)
        end
    end

    return plugin
end

return sprite_plugin
