--- Text render plugin (renderer-owned shadow-column path).
---
--- Per-frame flow:
---   1. PreRender: `text_sync.Sync` writes glyph slab data to the
---      shared glyph buffer and stamps `gpuStartIdx` / `fontLayer` /
---      `pivotOffset*` back onto the Text canonical column via
---      `archetype:getMut`, marking Text dirty.
---   2. PreRender: `text.ShadowRenderState` builds blend / material
---      group lists for the frame.
---   3. PreRender: `text.ShadowUpload` flushes shadow input columns
---      (Transform / Text / Color / ClipBounds / RenderFlags / Material
---      / TextEffects) to GPU, gated on per-component dirty bits.
---   4. Cull phase (this plugin): dispatch the text cull shader. Per
---      visible entity, write the packed 128-byte TextHeader and the
---      per-glyph VisibleGlyph entries; emit material params in cull
---      output order so the render shader's `materialParams[vg.headerIndex]`
---      lookup hits the right slot.
---   5. Render phase: bind the cull-written outputs and the persistent
---      glyph buffer; draw via `lg.drawFromShaderIndirect`.

local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local buffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local types <const> = require("tecs2d.gfx.internal.gpu.types")
local materialcompiler <const> = require("tecs2d.gfx.internal.materialcompiler")
local materialregistry <const> = require("tecs2d.gfx.internal.materialregistry")
local shadowdispatch <const> = require("tecs2d.gfx.internal.text.shadowdispatch")
local shadowrenderstate <const> = require("tecs2d.gfx.internal.gpu.shadowrenderstate")
local archetyperegistry <const> = require("tecs2d.gfx.internal.archetyperegistry")
local shadowstate <const> = require("tecs2d.gfx.internal.gpu.shadowstate")
local forwardblend <const> = require("tecs2d.gfx.internal.gpu.forwardblend")

local lg <const> = love.graphics

local record render_plugin
    record TextGrowable
        atlasArray: love.graphics.Texture
        sdfAtlasArray: love.graphics.Texture
        --- Per-layer font params (16 vec4s each): uvScaleX, uvScaleY
        --- (font atlas size over array size), pxRange (SDF only), 0.
        --- Rebuilt by sync whenever a font atlas registers.
        sdfFontParams: {{number}}
        bitmapFontParams: {{number}}
    end

    record Config
        renderShader: love.graphics.Shader
        --- Shadow cull dispatch. Plugin.cull invokes this on each frame.
        cullDispatch: function(any, love.graphics.Buffer)
        --- Capacity hook. Called before cull each frame so the output
        --- buffers can grow ahead of the cull's atomicAdds.
        ensureCapacity: function(integer, integer)
        --- Shadow-pipeline output buffers (cull writes, render reads).
        shadowBuffers: shadowdispatch.Buffers
        --- The persistent glyph slab buffer (shared with the slot path).
        glyphBuffer: buffer.GPUBuffer
        --- Atlas textures (shared with the slot path's growable).
        growable: TextGrowable
        --- Render-state syncRef from the shadow pipeline; provides
        --- blend / material group lists for this frame.
        syncRef: shadowrenderstate.Frame
        --- Live-entity / live-glyph counters used to gate the draw and
        --- size the cull output buffers. Walked by the plugin from the
        --- shadow registry on each cull pass.
        registry: archetyperegistry.Registry
        textComponent: tecs.Component
    end

    create: function(config: Config): types.RenderPlugin
end

local record TextFFIRead
    charCount: integer
end

local function countLive(
    registry: archetyperegistry.Registry,
    textComponent: tecs.Component
): integer, integer
    local entities = 0
    local glyphs = 0
    for arch, _state in registry:archetypes() do
        local state = _state as shadowstate.ArchetypeState
        if state.destroyed then goto continue end
        local archInternal = arch as tecsInternal.ArchetypeInternal
        local rowCount = archInternal.entities[0]
        if rowCount == 0 then goto continue end
        entities = entities + rowCount
        local textCol = archInternal.columns[textComponent] as {TextFFIRead}
        if textCol then
            for r = 1, rowCount do
                glyphs = glyphs + (textCol[r].charCount or 0)
            end
        end
        ::continue::
    end
    return entities, glyphs
end

function render_plugin.create(config: render_plugin.Config): types.RenderPlugin
    local plugin: types.RenderPlugin = { name = "TextShadow" }

    local renderShader <const> = config.renderShader
    local cullDispatch <const> = config.cullDispatch
    local ensureCapacity <const> = config.ensureCapacity
    local shadowBuffers = config.shadowBuffers
    local glyphBuffer <const> = config.glyphBuffer
    local growable <const> = config.growable
    local syncRef <const> = config.syncRef
    local registry <const> = config.registry
    local textComponent <const> = config.textComponent
    local unpackFn <const> = (rawget(_G as table, "unpack") or (table as {string:any}).unpack) as function({{number}}): {number}...

    -- Cached frame state populated by `cull`, consumed by the draw
    -- hooks. Avoids a second registry walk per frame.
    local liveEntities = 0

    local function sendSDFUniforms(shader: love.graphics.Shader)
        if shader:hasUniform("SDFAtlas") and growable.sdfAtlasArray then
            local sdfTex = growable.sdfAtlasArray
            sdfTex:setFilter("linear", "linear")
            sdfTex:setWrap("clamp", "clamp")
            shader:send("SDFAtlas", sdfTex)
        end
        if shader:hasUniform("SDFFontParams") and growable.sdfFontParams then
            shader:send("SDFFontParams", unpackFn(growable.sdfFontParams))
        end
        if shader:hasUniform("BitmapFontParams") and growable.bitmapFontParams then
            shader:send("BitmapFontParams", unpackFn(growable.bitmapFontParams))
        end
    end

    plugin.upload = function(_r: types.Renderer)
        -- Glyph buffer is the only CPU-side upload; headers / visible
        -- glyphs / material params are all cull-shader-written, no
        -- CPU upload step.
        glyphBuffer:upload()
    end

    plugin.resetIndirect = nil  -- cull dispatch handles its own reset

    plugin.cull = function(r: types.Renderer, cullParamsBuffer: love.graphics.Buffer)
        local ents, glyphs = countLive(registry, textComponent)
        liveEntities = ents
        if ents == 0 then return end
        ensureCapacity(ents, glyphs)
        cullDispatch(r, cullParamsBuffer)
    end

    plugin.renderGBuffer = function(r: types.Renderer, renderParamsBuffer: love.graphics.Buffer, globalTime: number)
        if liveEntities == 0 then return end

        local tex = growable.atlasArray
        local shader = renderShader
        lg.setShader(shader)
        shader:send("RenderParams", renderParamsBuffer)
        shader:send("MaterialPass", -1)
        shader:send("BlendModePass", 0)  -- G-buffer: skip blend entities
        shader:send("TextHeaderBuffer", shadowBuffers.headerBuffer)
        shader:send("GlyphDataBuffer", glyphBuffer.handle)
        shader:send("VisibleGlyphBuffer", shadowBuffers.visibleGlyphBuffer)

        if tex then
            tex:setFilter("nearest", "nearest")
            tex:setWrap("clamp", "clamp")
            shader:send("MainTex", tex)
        end

        sendSDFUniforms(shader)

        if shader:hasUniform("ShadowPass") then
            shader:send("ShadowPass", 1)
            lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
            shader:send("ShadowPass", 0)
        end

        lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)

        -- Material variants. shadowrenderstate populated
        -- syncRef.materialGroups during the PreRender phase.
        if syncRef.materialGroupCount > 0 then
            for i = 1, syncRef.materialGroupCount do
                local matGroup = syncRef.materialGroups[i]
                local matId = matGroup.materialId
                local variantShader = materialcompiler.compile(matId, "text")
                if variantShader then
                    lg.setShader(variantShader)
                    variantShader:send("RenderParams", renderParamsBuffer)
                    if variantShader:hasUniform("LayerRange") then
                        variantShader:send("LayerRange", r._layerRange)
                    end
                    variantShader:send("MaterialPass", matId)
                    if variantShader:hasUniform("BlendModePass") then
                        variantShader:send("BlendModePass", 0)
                    end
                    variantShader:send("GlobalTime", globalTime)
                    variantShader:send("TextHeaderBuffer", shadowBuffers.headerBuffer)
                    variantShader:send("GlyphDataBuffer", glyphBuffer.handle)
                    variantShader:send("VisibleGlyphBuffer", shadowBuffers.visibleGlyphBuffer)
                    variantShader:send("MaterialParamsBuffer", shadowBuffers.materialParamsBuffer)
                    if tex then
                        variantShader:send("MainTex", tex)
                    end
                    sendSDFUniforms(variantShader)

                    local def = materialregistry.getById(matId)
                    if def then
                        for uniformName, t in pairs(def.textures) do
                            if variantShader:hasUniform(uniformName) then
                                variantShader:send(uniformName, t)
                            end
                        end
                    end

                    -- Mirror the base pass's drop-shadow dispatch: material
                    -- text keeps its MSDF drop shadows.
                    if variantShader:hasUniform("ShadowPass") then
                        variantShader:send("ShadowPass", 1)
                        lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
                        variantShader:send("ShadowPass", 0)
                    end
                    lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
                end
            end
        end
    end

    plugin.renderForwardBlend = function(renderer: types.Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)
        if liveEntities == 0 then return end
        if syncRef.blendGroupCount == 0 then return end

        local vw, vh = renderer.config.virtualRes[1], renderer.config.virtualRes[2]
        local rw = useLowRes and vw or renderer.screenWidth
        local rh = useLowRes and vh or renderer.screenHeight
        subPixelX = subPixelX or 0.0
        subPixelY = subPixelY or 0.0

        forwardblend.populateRenderParams(renderer, cameraX, cameraY, cameraZoom, subPixelX, subPixelY, rw, rh, 0.0)

        local tex = growable.atlasArray
        local shader = renderShader
        lg.setShader(shader)
        shader:send("RenderParams", renderer.renderParamsBuffer)
        shader:send("MaterialPass", -1)
        shader:send("TextHeaderBuffer", shadowBuffers.headerBuffer)
        shader:send("GlyphDataBuffer", glyphBuffer.handle)
        shader:send("VisibleGlyphBuffer", shadowBuffers.visibleGlyphBuffer)

        if tex then
            tex:setFilter("nearest", "nearest")
            tex:setWrap("clamp", "clamp")
            shader:send("MainTex", tex)
        end
        sendSDFUniforms(shader)

        for i = 1, syncRef.blendGroupCount do
            local group = syncRef.blendGroups[i]
            shader:send("BlendModePass", group.blendId)

            if shader:hasUniform("ShadowPass") then
                shader:send("ShadowPass", 1)
                lg.setBlendMode(group.blendMode, group.blendAlphaMode)
                lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
                shader:send("ShadowPass", 0)
            end

            lg.setBlendMode(group.blendMode, group.blendAlphaMode)
            lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
        end

        -- Material variants: text with both a Material and a blend mode is
        -- filtered out of the base draws above (MaterialPass -1), so run
        -- the variant shaders per blend group too.
        if syncRef.materialGroupCount > 0 then
            for m = 1, syncRef.materialGroupCount do
                local matGroup = syncRef.materialGroups[m]
                local matId = matGroup.materialId
                local variantShader = materialcompiler.compile(matId, "text")
                if variantShader then
                    lg.setShader(variantShader)
                    variantShader:send("RenderParams", renderer.renderParamsBuffer)
                    if variantShader:hasUniform("LayerRange") then
                        variantShader:send("LayerRange", renderer._layerRange)
                    end
                    variantShader:send("MaterialPass", matId)
                    variantShader:send("TextHeaderBuffer", shadowBuffers.headerBuffer)
                    variantShader:send("GlyphDataBuffer", glyphBuffer.handle)
                    variantShader:send("VisibleGlyphBuffer", shadowBuffers.visibleGlyphBuffer)
                    variantShader:send("MaterialParamsBuffer", shadowBuffers.materialParamsBuffer)
                    if tex then
                        variantShader:send("MainTex", tex)
                    end
                    sendSDFUniforms(variantShader)

                    local def = materialregistry.getById(matId)
                    if def then
                        for uniformName, t in pairs(def.textures) do
                            if variantShader:hasUniform(uniformName) then
                                variantShader:send(uniformName, t)
                            end
                        end
                    end

                    for b = 1, syncRef.blendGroupCount do
                        local group = syncRef.blendGroups[b]
                        if variantShader:hasUniform("BlendModePass") then
                            variantShader:send("BlendModePass", group.blendId)
                        end
                        lg.setBlendMode(group.blendMode, group.blendAlphaMode)
                        if variantShader:hasUniform("ShadowPass") then
                            variantShader:send("ShadowPass", 1)
                            lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
                            variantShader:send("ShadowPass", 0)
                        end
                        lg.drawFromShaderIndirect("triangles", shadowBuffers.indirectBuffer, 1, tex or growable.sdfAtlasArray)
                    end
                end
            end
        end

        lg.setBlendMode("alpha", "alphamultiply")
        lg.setShader()
    end

    plugin.setLayerRange = function(_r: types.Renderer, range: {number})
        if renderShader:hasUniform("LayerRange") then
            renderShader:send("LayerRange", range)
        end
    end

    return plugin
end

return render_plugin
