--- Text sync system. Drives the renderer-owned shadow-column path:
--- on dirty (component change or spawn), copies persistent glyph data
--- from the slab into the GPU glyph buffer and stamps the resolved
--- `gpuStartIdx`, `fontLayer` (with SDF bit), and `pivotOffset*` back
--- onto the Text canonical column. The shadow pipeline's upload system
--- runs after this and flushes the canonical bytes to GPU; the cull
--- shader reads them by archetype row.
---
--- Blend / material grouping for the per-frame draw lives in
--- `shadow_render_state` (see `gpu/shadow_render_state.tl`), not here.

local tecs <const> = require("tecs")
local bit <const> = require("bit")
local gpuBuffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local ClipBoundsComponent <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local PivotComponent <const> = require("tecs2d.gfx.internal.Pivot")
local MaterialComponent <const> = require("tecs2d.gfx.internal.Material")
local TextEffectsComponent <const> = require("tecs2d.gfx.internal.text.effects")
local textModule <const> = require("tecs2d.gfx.internal.text")
local bmfontMod <const> = require("tecs2d.gfx.bmfont")
local render_plugin <const> = require("tecs2d.gfx.internal.text.render_plugin")
local ColorComponent = require("tecs2d.gfx.internal.Color") as tecs.Component
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local shadow_setup <const> = require("tecs2d.gfx.internal.text.shadow_setup")
local shadow_dispatch <const> = require("tecs2d.gfx.internal.text.shadow_dispatch")
local modifier_binding <const> = require("tecs2d.gfx.internal.gpu.modifier_binding")

local lg <const> = love.graphics
local TEXT_SHADERS <const> = "tecs2d/gfx/internal/text/"
local textRenderSource <const> = shaderUtils.insertAfterPragma(
    shaderUtils.loadShader("text", TEXT_SHADERS), shaderUtils.RENDER_COMMON .. shaderUtils.DEPTH_COMMON)
local textRenderShader <const> = lg.newShader(textRenderSource)
local textCullShader <const> = lg.newComputeShader(shaderUtils.loadCullShader("text_cull", TEXT_SHADERS))
material_compiler.registerBaseSource("text", textRenderSource)

local Transform <const> = tecs.builtins.Transform
local type Query = tecs.Query
local type GPUBuffer = gpuBuffer.GPUBuffer

local glyph_slab <const> = require("tecs2d.gfx.internal.text.glyph_slab")
local glyph_block <const> = require("tecs2d.gfx.internal.text.glyph_block")
local C <const> = require("ffi")

-- Pointer arithmetic helper. `+ offset * 32` because glyph slab entries
-- are 32 bytes and the source/dest are typed glyph pointers -- index
-- arithmetic in glyph units.
local ffi_offset_ptr: function(ptr: C.CData, offset: integer): C.CData
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local code = "local ffi = require('ffi'); return function(ptr, offset) return ffi.cast('char*', ptr) + offset * 32 end"
    local fn = (loadfn as function(string): function(): any)(code)()
    ffi_offset_ptr = fn as function(C.CData, integer): C.CData
end

-- Text FFI data record (matches the canonical FFI component, 40 bytes).
local record TextFFI
    slabOffset: integer
    charCount: integer
    fontId: integer
    textId: integer
    glyphBlockId: integer
    gpuStartIdx: integer
    fontLayer: integer
    pivotOffsetX: number
    pivotOffsetY: number
    width: number
    height: number
end

local record PivotData
    x: number
    y: number
end

local FONT_LAYER_SDF_BIT <const> = 0x80000000

local record text_sync
    record TextSync
        world: tecs.World
        registerFont: function(bmfontMod.BMFont): integer, boolean
        glyphBuffer: GPUBuffer
        query: Query
        textComponent: tecs.Component
        sync: function(self: TextSync)
    end

    new: function(
        world: tecs.World,
        registerFont: function(bmfontMod.BMFont): integer, boolean,
        glyphBuffer: GPUBuffer,
        query: Query,
        textComponent: tecs.Component
    ): TextSync

    plugin: function(world: tecs.World, renderer: gpuTypes.Renderer, TextComponent: tecs.Component): function(tecs.World)
end

local TextSync <const> = text_sync.TextSync
local SYNC_MT <const>: metatable<TextSync> = { __index = TextSync }

function text_sync.new(
    world: tecs.World,
    registerFont: function(bmfontMod.BMFont): integer, boolean,
    glyphBuffer: GPUBuffer,
    query: Query,
    textComponent: tecs.Component
): text_sync.TextSync
    local sync: text_sync.TextSync = {
        world = world,
        registerFont = registerFont,
        glyphBuffer = glyphBuffer,
        query = query,
        textComponent = textComponent,
    }
    return setmetatable(sync, SYNC_MT)
end

--- Re-resolve the per-entity Text canonical fields the cull shader
--- consumes (`gpuStartIdx`, `fontLayer`, `pivotOffset*`) and copy this
--- entity's glyph layout into the persistent GPU glyph buffer at the
--- block's stable start index.
local function initEntityGlyphs(
    sync: text_sync.TextSync,
    archetype: tecs.Archetype,
    entityIndex: integer
)
    local textComponent = sync.textComponent
    local world = sync.world
    local glyphBuffer = sync.glyphBuffer

    -- getMut marks the Text column dirty; the shadow upload system
    -- gates on per-component dirty bits, so the canonical bytes flush
    -- to GPU after we write `gpuStartIdx` / `fontLayer` / `pivotOffset*`.
    local texts = archetype:getMut(textComponent) as {TextFFI}
    local pivots = archetype:get(PivotComponent) as {PivotData}

    local meta = world.resources[textModule.TEXT_META] as textModule.TextMetaRegistry
    local slab = world.resources[textModule.SLAB_ALLOCATOR] as glyph_slab.SlabAllocator
    local blockAlloc = world.resources[textModule.BLOCK_ALLOCATOR] as glyph_block.GlyphBlockAllocator
    local entities = archetype.entities as {integer}

    local txt = texts[entityIndex]
    local entityId = entities[entityIndex]

    local font = meta.fonts[entityId]
    local fontLayerIndex = 0
    local isSDF = false
    if font then
        fontLayerIndex, isSDF = sync.registerFont(font)
    end

    local pivotX, pivotY = 0.5, 0.5
    if pivots then
        local pivot = pivots[entityIndex]
        if pivot then
            pivotX = pivot.x
            pivotY = pivot.y
        end
    end

    local ox = meta.originX[entityId] or 0
    local oy = meta.originY[entityId] or 0
    local pivotOffsetX = ox + pivotX * txt.width
    local pivotOffsetY = oy + pivotY * txt.height

    local blockId = txt.glyphBlockId
    local block = blockAlloc:get(blockId)
    if not block then return end
    local glyphCount = txt.charCount
    local glyphStartIdx = block.gpuStartIdx

    -- Stamp resolved values onto the Text canonical column. The cull
    -- shader reads these by row. `fontLayer` packs the SDF flag into
    -- bit 31 so the cull doesn't need a CPU-side font-registry lookup.
    txt.gpuStartIdx = glyphStartIdx
    if isSDF then
        txt.fontLayer = bit.bor(fontLayerIndex, FONT_LAYER_SDF_BIT)
    else
        txt.fontLayer = fontLayerIndex
    end
    txt.pivotOffsetX = pivotOffsetX
    txt.pivotOffsetY = pivotOffsetY

    -- Grow the GPU glyph buffer to fit this block's range, then copy
    -- the slab's pre-laid-out glyph data to the entity's stable slot.
    local requiredGlyphs = glyphStartIdx + block.capacity
    while glyphBuffer.capacity < requiredGlyphs do
        glyphBuffer:grow()
    end
    if requiredGlyphs > glyphBuffer.count then
        glyphBuffer.count = requiredGlyphs
    end

    if glyphCount > 0 then
        local destPtr = ffi_offset_ptr(glyphBuffer.dataPtr, glyphStartIdx)
        local srcPtr = ffi_offset_ptr(slab:getDataPtr() as C.CData, txt.slabOffset)
        C.copy(destPtr, srcPtr, glyphCount * 32)
        glyphBuffer:markDirtyRange(glyphStartIdx, glyphStartIdx + glyphCount - 1)
    end
end

--- Walk text archetypes; on any-component-dirty (spawn or component
--- mutation), refresh per-entity glyph data and Text canonical writeback.
function TextSync:sync()
    for archetype, len in self.query:iter() do
        if len > 0 and archetype:anyComponentDirty() then
            for i = 1, len do
                initEntityGlyphs(self, archetype, i)
            end
        end
    end
end

function text_sync.plugin(_world: tecs.World, renderer: gpuTypes.Renderer, TextComponent: tecs.Component): function(tecs.World)
    return function(w: tecs.World)
        local gpuRenderer = renderer as gpuTypes.Renderer
        local DEFAULT_TEXT_ENTITIES <const> = 1024
        local DEFAULT_TEXT_GLYPHS <const> = 16384
        local initialTextEntities = gpuRenderer.config.sizeHints["textEntities"] or DEFAULT_TEXT_ENTITIES
        local initialTextGlyphs = gpuRenderer.config.sizeHints["textGlyphs"] or DEFAULT_TEXT_GLYPHS

        local glyphBuffer = gpuBuffer.new(gpuTypes.GLYPH_DATA_FORMAT, initialTextGlyphs, gpuTypes.GLYPH_DATA_CTYPE)

        -- 1x1x1 placeholder SDF atlas array so the sampler binding is
        -- always valid even before any SDF font has been registered.
        local placeholderSdfArray = lg.newCanvas(1, 1, 1, {
            type = "array",
            format = "rgba8",
            linear = true,
        } as love.graphics.CanvasSetting)
        placeholderSdfArray:setFilter("linear", "linear")

        local MAX_FONT_LAYERS <const> = 16

        local function defaultFontParams(): {{number}}
            local params: {{number}} = {}
            for i = 1, MAX_FONT_LAYERS do
                params[i] = {1.0, 1.0, 4.0, 0.0}
            end
            return params
        end

        local growable: render_plugin.TextGrowable = {
            atlasArray = nil,
            sdfAtlasArray = placeholderSdfArray as love.graphics.Texture,
            sdfFontParams = defaultFontParams(),
            bitmapFontParams = defaultFontParams(),
        }

        -- Bitmap font registry (nearest filter)
        local bitmapFontLayers: {love.graphics.Image: integer} = {}
        local bitmapFontAtlases: {love.graphics.Image} = {}
        local nextBitmapFontLayer = 0

        -- SDF font registry (linear filter)
        local sdfFontLayers: {love.graphics.Image: integer} = {}
        local sdfFontAtlases: {love.graphics.Image} = {}
        local nextSdfFontLayer = 0

        local sdfDistanceRanges: {integer: number} = {}

        local function rebuildAtlasArray(atlases: {love.graphics.Image}, filter: string, isLinear: boolean): love.graphics.Texture
            local numLayers = #atlases
            if numLayers == 0 then return nil end

            local maxW: number = 0
            local maxH: number = 0
            for _, img in ipairs(atlases) do
                local iw = img:getWidth()
                local ih = img:getHeight()
                if iw > maxW then maxW = iw end
                if ih > maxH then maxH = ih end
            end

            local newArray = lg.newCanvas(maxW, maxH, numLayers, {
                type = "array",
                format = "rgba8",
                linear = isLinear or false,
            } as love.graphics.CanvasSetting)
            newArray:setFilter(filter as love.graphics.FilterMode, filter as love.graphics.FilterMode)

            for i, img in ipairs(atlases) do
                lg.setCanvas({{newArray, layer = i}})
                lg.clear(0, 0, 0, 0)
                lg.setBlendMode("replace")
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, 0, 0)
            end
            lg.setCanvas()
            lg.setBlendMode("alpha")

            return newArray as love.graphics.Texture
        end

        -- Recompute per-layer params after a rebuild: every atlas smaller
        -- than the (max-sized) array needs a UV scale so per-font UVs land
        -- on the right texels, and SDF layers carry their own pxRange
        -- instead of sharing whichever font registered last.
        local function rebuildFontParams(
            params: {{number}},
            atlases: {love.graphics.Image},
            array: love.graphics.Texture,
            ranges?: {integer: number}
        )
            if not array then return end
            local arrayW, arrayH = array:getWidth(), array:getHeight()
            for i = 1, MAX_FONT_LAYERS do
                local img = atlases[i]
                local entry = params[i]
                if img then
                    entry[1] = img:getWidth() / arrayW
                    entry[2] = img:getHeight() / arrayH
                    entry[3] = ranges and (ranges[i - 1] or 4.0) or 0.0
                else
                    entry[1], entry[2], entry[3] = 1.0, 1.0, 4.0
                end
            end
        end

        local function registerBitmapFontAtlas(atlas: love.graphics.Image): integer
            local existing = bitmapFontLayers[atlas]
            if existing then return existing end
            if nextBitmapFontLayer >= MAX_FONT_LAYERS then
                error("text: at most " .. MAX_FONT_LAYERS .. " bitmap font atlases are supported")
            end
            local layerIndex = nextBitmapFontLayer
            bitmapFontLayers[atlas] = layerIndex
            bitmapFontAtlases[#bitmapFontAtlases + 1] = atlas
            nextBitmapFontLayer = layerIndex + 1
            growable.atlasArray = rebuildAtlasArray(bitmapFontAtlases, "nearest", false)
            rebuildFontParams(growable.bitmapFontParams, bitmapFontAtlases, growable.atlasArray)
            return layerIndex
        end

        local function registerSDFFontAtlas(atlas: love.graphics.Image, distanceRange: number): integer
            local existing = sdfFontLayers[atlas]
            if existing then return existing end
            if nextSdfFontLayer >= MAX_FONT_LAYERS then
                error("text: at most " .. MAX_FONT_LAYERS .. " SDF font atlases are supported")
            end
            local layerIndex = nextSdfFontLayer
            sdfFontLayers[atlas] = layerIndex
            sdfFontAtlases[#sdfFontAtlases + 1] = atlas
            sdfDistanceRanges[layerIndex] = distanceRange
            nextSdfFontLayer = layerIndex + 1
            growable.sdfAtlasArray = rebuildAtlasArray(sdfFontAtlases, "linear", true)
            rebuildFontParams(growable.sdfFontParams, sdfFontAtlases, growable.sdfAtlasArray, sdfDistanceRanges)
            return layerIndex
        end

        local function registerFont(font: bmfontMod.BMFont): integer, boolean
            if font:isSDF() then
                local dr = font.distanceField and font.distanceField.distanceRange or 4.0
                return registerSDFFontAtlas(font.atlas, dr), true
            end
            return registerBitmapFontAtlas(font.atlas), false
        end

        local textQuery = w:query({
            name = "text_sync.Query",
            include = {TextComponent, Transform},
        })

        local syncSystem = text_sync.new(w, registerFont, glyphBuffer, textQuery, TextComponent)

        local optional <const> = modifier_binding.bind({
            ColorComponent,
            ClipBoundsComponent as tecs.Component,
            MaterialComponent as tecs.Component,
            TextEffectsComponent as tecs.Component,
        }) as {shadow_setup.OptionalBinding}

        local tagFlags: {shadow_dispatch.TagFlagBinding} = {
            {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
        }

        local shadowCtx = shadow_setup.register(w, {
            text = TextComponent,
            optional = optional,
            registryName = "text.shadows",
            renderStateSystemName = "text.ShadowRenderState",
            uploadSystemName = "text.ShadowUpload",
            -- Sync writes `gpuStartIdx` / `fontLayer` / `pivotOffset*` to
            -- the Text canonical column on its dirty path. Shadow upload
            -- must run after, otherwise the cull shader sees stale
            -- bytes on first-frame entities and renders garbled glyphs.
            uploadAfter = {"text_sync.Sync"},
        })

        local shadowBuffers = shadow_dispatch.newBuffers(initialTextEntities, initialTextGlyphs)
        local cullDispatch, ensureShadowCapacity = shadow_dispatch.new({
            shader = textCullShader,
            registry = shadowCtx.registry,
            textComponent = TextComponent,
            optional = optional as {shadow_dispatch.OptionalBinding},
            tagFlags = tagFlags,
            buffers = shadowBuffers,
            initialEntityCapacity = initialTextEntities,
            initialGlyphCapacity = initialTextGlyphs,
        })

        gpuRenderer:registerPlugin(render_plugin.create({
            renderShader = textRenderShader,
            cullDispatch = cullDispatch,
            ensureCapacity = ensureShadowCapacity,
            shadowBuffers = shadowBuffers,
            glyphBuffer = glyphBuffer,
            growable = growable,
            syncRef = shadowCtx.syncRef,
            registry = shadowCtx.registry,
            textComponent = TextComponent,
        }))

        w:addSystem({
            name = "text_sync.Sync",
            phase = tecs.phases.PreRender,
            run = function()
                syncSystem:sync()
            end,
        })
    end
end

return text_sync
