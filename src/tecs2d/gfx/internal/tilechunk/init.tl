--- TileChunk component for GPU-driven tilemap rendering.
---
--- Each TileChunk represents a 16x16 grid of static tiles rendered
--- as a single GPU draw call. Animated tiles should be spawned as
--- individual Sprite entities instead.

local tecs <const> = require("tecs")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local renderplugin <const> = require("tecs2d.gfx.internal.tilechunk.renderplugin")
local SlotManager <const> = require("tecs2d.gfx.internal.gpu.SlotManager")
local Color <const> = require("tecs2d.gfx.internal.Color")
local Occluder <const> = require("tecs2d.gfx.internal.Occluder")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")
local band <const> = require("bit").band
local C <const> = require("ffi")

-- Compile tilechunk shaders
local lg <const> = love.graphics
local TILECHUNK_SHADERS <const> = "tecs2d/gfx/internal/tilechunk/"
local tileChunkRenderSource <const> = shaderUtils.insertAfterPragma(
    shaderUtils.loadShader("tilechunk", TILECHUNK_SHADERS),
    shaderUtils.RENDER_COMMON .. shaderUtils.TILE_COMMON .. shaderUtils.DEPTH_COMMON)
local tileChunkRenderShader <const> = lg.newShader(tileChunkRenderSource)
local tileChunkCullShader <const> = lg.newComputeShader(
    shaderUtils.loadShader("tilechunk_cull", TILECHUNK_SHADERS))
local tileChunkShadowMaskShader <const> = lg.newShader(shaderUtils.insertAfterPragma(
    shaderUtils.loadShadowMaskShader("shadow_mask_tilechunk"),
    shaderUtils.TILE_COMMON))

local Transform <const> = tecs.builtins.Transform

-- Color record type for casting from archetype
local record ColorData
    r: number
    g: number
    b: number
    a: number
end

-- Occluder record type for casting from archetype
local record OccluderData
    height: number
    alphaThreshold: number
end

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.tileChunk")

local CHUNK_SIZE <const> = 16  -- 16x16 tiles per chunk

local record tileChunk
    --- TileChunk component for 16x16 tile grids.
    --- Each chunk is rendered as a single GPU draw instance.
    record TileChunk is tecs.Component
        --- Tileset texture for UV lookup
        tileset: love.graphics.Texture

        --- Optional: normal map for lighting
        normalMap: love.graphics.Texture

        --- Optional: emission/glow map
        emissionMap: love.graphics.Texture

        --- Optional: ORM map for PBR lighting (R=AO, G=roughness, B=metallic)
        ormMap: love.graphics.Texture

        --- Tile dimensions in pixels
        tileWidth: number
        tileHeight: number

        --- Number of columns in the tileset (for UV math)
        columns: integer

        --- 256 tile IDs (16x16 grid), 0 = empty/skip
        tiles: {integer}

        --- Internal: cached texture array layer index
        _textureIndex: integer

        --- Internal: per-tile occluder heights from tileset (used once during registration)
        _occluderHeights: {integer: number}

        --- Internal: tileset's firstgid for GID to local ID conversion
        _firstgid: integer

        --- Internal: stable GPU slot assigned by the renderer's slot
        --- manager. -1 until the slot management observer runs.
        _gpuSlot: integer

        new: function(config: TileChunkConfig): TileChunk
    end

    --- Marker component for chunks that need GPU sync.
    --- Automatically added when TileChunk is spawned; add it again after modifying tiles.
    DirtyTileChunk: tecs.Component

    --- Configuration for creating a TileChunk
    record TileChunkConfig
        tileset: love.graphics.Texture
        normalMap: love.graphics.Texture   -- Optional: normal map for lighting
        emissionMap: love.graphics.Texture -- Optional: emission/glow map
        ormMap: love.graphics.Texture -- Optional: ORM map (R=AO, G=roughness, B=metallic)
        tileWidth: number
        tileHeight: number
        columns: integer
        tiles: {integer}
        occluderHeights: {integer: number} -- Optional: per-tile occluder heights from tileset
        firstgid: integer -- Optional: tileset's firstgid for GID to local ID conversion
    end

    --- The chunk size (16x16)
    CHUNK_SIZE: integer

    plugin: function(world: tecs.World)
end

local TileChunk <const> = tileChunk.TileChunk
tileChunk.CHUNK_SIZE = CHUNK_SIZE

-- Tag component for dirty tracking (no data, just marks entities for GPU sync)
tileChunk.DirtyTileChunk = tecs.newTagComponent({name = "DirtyTileChunk"})
local DirtyTileChunk <const> = tileChunk.DirtyTileChunk

-- Register TileChunk as a proper ECS component
tecs.newComponent({
    name = "TileChunk",
    container = TileChunk,
    new = function(data: {string: any}): tileChunk.TileChunk
        local config = data as tileChunk.TileChunkConfig
        local tiles = config.tiles or {}
        -- Ensure 256 tiles. Fill only the holes: users build tiles
        -- tables sparsely (`tiles[row * 16 + col + 1] = id`), and `#`
        -- stops at the first hole, so filling from `#tiles + 1` would
        -- silently zero every entry past it.
        for i = 1, 256 do
            if tiles[i] == nil then
                tiles[i] = 0
            end
        end
        return {
            tileset = config.tileset,
            normalMap = config.normalMap,
            emissionMap = config.emissionMap,
            ormMap = config.ormMap,
            tileWidth = config.tileWidth or 32,
            tileHeight = config.tileHeight or 32,
            columns = config.columns or 16,
            tiles = tiles,
            _textureIndex = -1,  -- Not yet registered
            _occluderHeights = config.occluderHeights,  -- May be nil
            _firstgid = config.firstgid or 1,  -- Default to 1 if not provided
            _gpuSlot = -1,  -- Assigned by SlotManagement observer
        } as tileChunk.TileChunk
    end,
    -- TileChunk always needs DirtyTileChunk on first add so the GPU
    -- buffer sync picks it up. Declarative via `requires` -- the
    -- archetype transition merges both in one move, and re-adding
    -- during snapshot restore is idempotent (the required tag is
    -- skipped when already present).
    requires = { DirtyTileChunk },
})

-- FFI struct for GPU buffer header (matches first 16 floats of GPUTileChunkInstance)
local record TileChunkHeaderFFI
    x: number
    y: number
    tileWidth: number
    tileHeight: number
    layer: number
    z: number
    columns: number
    textureIndex: number  -- Texture array layer index
    r: number
    g: number
    b: number
    a: number
    occluderHeight: number  -- Shadow casting height (0 = no shadows)
    _padLM: number          -- Padding, keeps the 16-float struct layout
    hasOccluders: number    -- 1.0 if chunk has any occluding tiles, 0.0 otherwise
    _pad: number
end

-- Helper to write uint32 array to FFI pointer (bypasses Teal type checking)
-- Offset is 64 bytes (4 vec4s: posSize, layerInfo, color, occluderInfo)
local writeTileData: function(dataPtr: C.CData, slotOffset: integer, tiles: {integer})
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local code = [[
        local ffi = require('ffi')
        return function(dataPtr, slotOffset, tiles)
            local tilePtr = ffi.cast('uint32_t*', ffi.cast('char*', dataPtr) + slotOffset + 64)
            for i = 0, 255 do
                tilePtr[i] = tiles[i + 1] or 0
            end
        end
    ]]
    local fn = (loadfn as function(string): function(): any)(code)()
    writeTileData = fn as function(C.CData, integer, {integer})
end

-- Pointer arithmetic helper. LuaJIT supports `cdata + integer` natively
-- on pointer cdata, but Teal's checker disallows it. Compile via load()
-- once at module scope.
local ffiOffsetPtr: function(ptr: C.CData, offset: integer): C.CData
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local code = "local ffi = require('ffi'); return function(ptr, offset) return ffi.cast('char*', ptr) + offset end"
    local fn = (loadfn as function(string): function(): any)(code)()
    ffiOffsetPtr = fn as function(C.CData, integer): C.CData
end

function tileChunk.plugin(world: tecs.World)
    local pipelineInstance <const> = world.resources[pipelinekey.PIPELINE as tecs.Key<gpuTypes.PipelineInternal>]
    if not pipelineInstance then
        LOGGER:error("No render pipeline found in world resources")
        return
    end

    local renderer = pipelineInstance:getRenderer()
    if not renderer then
        LOGGER:error("No GPU renderer available")
        return
    end

    local gpuRenderer = renderer as gpuTypes.Renderer
    local DEFAULT_CAPACITY <const> = 256
    local initialCapacity = gpuRenderer.config.sizeHints["tilechunks"] or DEFAULT_CAPACITY

    ---------------------------------------------------------------------------
    -- Plugin-owned input buffer.
    --
    -- Tilechunk's per-frame upload signal lives at the ECS level (the
    -- `DirtyTileChunk` tag query), so a per-slot dirty bitmap would be
    -- redundant; there's nothing to gate on below the tag. The storage
    -- is a plain ByteData + love.graphics.Buffer pair, with a small
    -- slot manager on top for stable per-chunk indices.
    --
    -- Writes during sync go: write fields into `shadowPtr[slot]`, write
    -- 256 tile uint32s via `writeTileData`, then issue a single
    -- `setArrayData(byteData, slot+1, slot+1, 1)` for that slot. No
    -- batched dirty range; the dirty count per frame is "however many
    -- chunks the user marked dirty", which is small in typical use.
    ---------------------------------------------------------------------------
    local elementSize <const> = C.sizeof(gpuTypes.TILECHUNK_CTYPE) as integer

    local function newShadow(cap: integer): love.data.ByteData, C.CData
        local bd = love.data.newByteData(cap * elementSize)
        local ptr = C.cast(gpuTypes.TILECHUNK_CTYPE .. "*", bd:getFFIPointer()) as C.CData
        return bd, ptr
    end

    local function newGpuHandle(cap: integer): love.graphics.Buffer
        return lg.newBuffer(gpuTypes.TILECHUNK_FORMAT, cap,
            {usage = "dynamic", shaderstorage = true})
    end

    local capacity = initialCapacity
    local byteData, shadowPtr = newShadow(capacity)
    local inputBufferRef: renderplugin.InputBufferRef = {
        handle = newGpuHandle(capacity),
    }
    local slotManager = SlotManager.new()

    local indirectBuffer = lg.newBuffer({{format = "uint32"}}, 4, {usage = "dynamic", shaderstorage = true, indirectarguments = true})
    local shadowIndirectBuffer = lg.newBuffer({{format = "uint32"}}, 4, {usage = "dynamic", shaderstorage = true, indirectarguments = true})

    -- Growable output buffers (replaced on growth, shared via stable table ref).
    -- The cull writes compact TileChunkVis records; render passes read
    -- tile data from the input buffer via srcIndex.
    local growable: renderplugin.TileChunkGrowable = {
        outputBuffer = lg.newBuffer(gpuTypes.TILECHUNK_VIS_FORMAT, initialCapacity, {usage = "dynamic", shaderstorage = true}),
        shadowOutputBuffer = lg.newBuffer(gpuTypes.TILECHUNK_VIS_FORMAT, initialCapacity, {usage = "dynamic", shaderstorage = true}),
        textureSize = {1, 1},
        activeCount = 0,
    }

    -- Grow when the slot manager hands out an index past the current
    -- capacity. Grows 4x to keep reallocations rare.
    local function ensureCapacity(slot: integer)
        if slot < capacity then return end
        local newCap = capacity * 4
        if newCap < slot + 1 then newCap = slot + 1 end

        local newByteData, newShadowPtr = newShadow(newCap)
        C.copy(newShadowPtr as C.CData, shadowPtr as C.CData, capacity * elementSize)

        local newHandle = newGpuHandle(newCap)
        -- Copy over previously-uploaded slots so the new GPU buffer
        -- starts populated with the live data.
        if capacity > 0 then
            newHandle:setArrayData(newByteData, 1, 1, capacity)
        end

        -- In-flight GPU work may still read the replaced buffers;
        -- release them through the deferred retire list.
        retire.push(inputBufferRef.handle)
        retire.push(growable.outputBuffer)
        retire.push(growable.shadowOutputBuffer)

        byteData = newByteData
        shadowPtr = newShadowPtr
        inputBufferRef.handle = newHandle
        capacity = newCap

        -- Output / shadow output buffers must keep pace with the input.
        growable.outputBuffer = lg.newBuffer(gpuTypes.TILECHUNK_VIS_FORMAT, newCap, {usage = "dynamic", shaderstorage = true})
        growable.shadowOutputBuffer = lg.newBuffer(gpuTypes.TILECHUNK_VIS_FORMAT, newCap, {usage = "dynamic", shaderstorage = true})
    end

    -- Tileset registry state (plugin-owned, moved from asset_registry)
    local tilesetLayers: {love.graphics.Texture: integer} = {}
    local tilesetList: {love.graphics.Texture} = {}
    local tilesetNormalList: {love.graphics.Texture} = {}
    local tilesetEmissionList: {love.graphics.Texture} = {}
    local tilesetORMList: {love.graphics.Texture} = {}
    local tilesetHeightData: {{integer: number}} = {}
    local nextTilesetLayer = 0

    -- GPU texture array layer limit (texturelayers). Exceeding this at
    -- lg.newCanvas(type="array") is a runtime allocation failure, so we
    -- fail early with a clear message instead.
    local maxTextureLayers <const> = ((lg.getSystemLimits() as {string: integer}).texturelayers) or 256

    local function registerTileset(
        tileset: love.graphics.Texture,
        normalMap: love.graphics.Texture,
        emissionMap: love.graphics.Texture,
        ormMap: love.graphics.Texture,
        occluderHeights: {integer: number}
    ): integer
        -- Check if already registered
        local existingLayer = tilesetLayers[tileset]
        if existingLayer then
            return existingLayer
        end

        if nextTilesetLayer >= maxTextureLayers then
            error(string.format(
                "TileChunk tileset limit reached: GPU supports at most %d texture array layers, " ..
                "but a %d-th tileset was registered. Reduce the number of unique tilesets.",
                maxTextureLayers, nextTilesetLayer + 1))
        end

        -- Assign new layer index
        local layerIndex = nextTilesetLayer
        tilesetLayers[tileset] = layerIndex
        tilesetList[#tilesetList + 1] = tileset
        tilesetNormalList[#tilesetNormalList + 1] = normalMap
        tilesetEmissionList[#tilesetEmissionList + 1] = emissionMap
        tilesetORMList[#tilesetORMList + 1] = ormMap
        tilesetHeightData[#tilesetHeightData + 1] = occluderHeights or ({} as {integer: number})
        nextTilesetLayer = layerIndex + 1

        -- Rebuild texture arrays with all registered tilesets
        local numLayers = #tilesetList

        if numLayers > 0 then
            -- Find maximum dimensions across all tilesets
            local maxW: integer = 0
            local maxH: integer = 0
            for _, tex in ipairs(tilesetList) do
                local tw = tex:getWidth() as integer
                local th = tex:getHeight() as integer
                if tw > maxW then maxW = tw end
                if th > maxH then maxH = th end
            end
            growable.textureSize = {maxW, maxH}

            -- Create albedo array
            local arrayImage = lg.newCanvas(maxW, maxH, numLayers, {type = "array"})
            arrayImage:setFilter("nearest", "nearest")
            arrayImage:setWrap("clamp", "clamp")

            -- Create normal array
            local normalArray = lg.newCanvas(maxW, maxH, numLayers, {type = "array"})
            normalArray:setFilter("nearest", "nearest")
            normalArray:setWrap("clamp", "clamp")

            -- Create emission array
            local emissionArray = lg.newCanvas(maxW, maxH, numLayers, {type = "array"})
            emissionArray:setFilter("nearest", "nearest")
            emissionArray:setWrap("clamp", "clamp")

            -- Create ORM array
            local ormArray = lg.newCanvas(maxW, maxH, numLayers, {type = "array"})
            ormArray:setFilter("nearest", "nearest")
            ormArray:setWrap("clamp", "clamp")

            -- Copy each tileset into its layer
            for i, tex in ipairs(tilesetList) do
                -- Albedo
                lg.setCanvas({{arrayImage, layer = i}})
                lg.clear(0, 0, 0, 0)
                lg.setBlendMode("replace")
                lg.setColor(1, 1, 1, 1)
                lg.draw(tex as love.graphics.Drawable)

                -- Normal map (or flat normal)
                lg.setCanvas({{normalArray, layer = i}})
                local nmap = tilesetNormalList[i]
                if nmap then
                    lg.clear(0, 0, 0, 0)
                    lg.draw(nmap as love.graphics.Drawable)
                else
                    lg.clear(0.5, 0.5, 1.0, 1.0)
                end

                -- Emission map (or black/transparent)
                lg.setCanvas({{emissionArray, layer = i}})
                local emap = tilesetEmissionList[i]
                if emap then
                    lg.clear(0, 0, 0, 0)
                    lg.draw(emap as love.graphics.Drawable)
                else
                    lg.clear(0, 0, 0, 0)
                end

                -- ORM map (or default: AO=1, roughness=0.5, metallic=0)
                lg.setCanvas({{ormArray, layer = i}})
                local omap = tilesetORMList[i]
                if omap then
                    lg.clear(0, 0, 0, 0)
                    lg.draw(omap as love.graphics.Drawable)
                else
                    lg.clear(1.0, 0.5, 0.0, 1.0)
                end
            end

            -- Restore state
            lg.setCanvas()
            lg.setBlendMode("alpha")

            growable.textureArray = arrayImage as love.graphics.Texture
            growable.normalArray = normalArray as love.graphics.Texture
            growable.emissionArray = emissionArray as love.graphics.Texture
            growable.ormArray = ormArray as love.graphics.Texture

            -- Build 2D height lookup texture (row = tileset layer, col = local tile ID)
            local maxTileId = 0
            for _, heights in ipairs(tilesetHeightData) do
                if heights then
                    for tileId, _ in pairs(heights) do
                        if tileId > maxTileId then
                            maxTileId = tileId
                        end
                    end
                end
            end

            -- Create 2D height lookup (minimum 1x1 to avoid errors)
            local heightWidth = maxTileId > 0 and (maxTileId + 1) or 1
            local heightTexHeight = numLayers
            local heightImgData = love.image.newImageData(heightWidth, heightTexHeight, "r16f")

            -- Fill with height values (0 = no occluder)
            for row, heights in ipairs(tilesetHeightData) do
                if heights then
                    for tileId, height in pairs(heights) do
                        heightImgData:setPixel(tileId, row - 1, height, 0, 0, 0)
                    end
                end
            end

            local heightLookupTex = lg.newImage(heightImgData)
            heightLookupTex:setFilter("nearest", "nearest")
            heightLookupTex:setWrap("clamp", "clamp")
            growable.heightLookup = heightLookupTex as love.graphics.Texture
        end

        return layerIndex
    end

    -- Keep registerTileset accessible on the renderer for backwards compatibility
    gpuRenderer.registerTileset = function(
        _self: gpuTypes.Renderer,
        tileset: love.graphics.Texture,
        normalMap: love.graphics.Texture,
        emissionMap: love.graphics.Texture,
        ormMap: love.graphics.Texture,
        occluderHeights: {integer: number}
    ): integer
        return registerTileset(tileset, normalMap, emissionMap, ormMap, occluderHeights)
    end

    -- Register tilechunk render plugin.
    gpuRenderer:registerPlugin(renderplugin.create({
        renderShader = tileChunkRenderShader,
        cullShader = tileChunkCullShader,
        shadowMaskShader = tileChunkShadowMaskShader,
        inputBuffer = inputBufferRef,
        indirectBuffer = indirectBuffer,
        shadowIndirectBuffer = shadowIndirectBuffer,
        growable = growable,
    }))

    -- Tracks freed slots for the activeCount shrink-tail walk in
    -- onEntitiesRemoved. SlotManager's freelist itself isn't a set, so
    -- we keep a parallel set keyed by slot index.
    local freedSet: {integer: boolean} = {}

    -- Allocate a slot, growing the buffer if needed.
    local function allocateSlot(): integer
        local slot = slotManager:allocate()
        ensureCapacity(slot)
        freedSet[slot] = nil
        return slot
    end

    -- Free a slot: zero the shadow + push the zeroed bytes to the GPU
    -- so the cull shader skips this slot (`tw == 0 && th == 0`).
    -- Returning to the slotManager free-list lets future allocations
    -- reuse the slot.
    local function freeSlot(slot: integer)
        if freedSet[slot] then return end
        freedSet[slot] = true

        local offset = slot * elementSize
        local offsetPtr = ffiOffsetPtr(shadowPtr as C.CData, offset)
        C.fill(offsetPtr, elementSize, 0)
        inputBufferRef.handle:setArrayData(byteData, slot + 1, slot + 1, 1)

        slotManager:free(slot)
    end

    -- Slot management query: allocates a slot per spawned chunk, frees
    -- on removal. Stores the slot on the component itself so the sync
    -- system can read it without a side map.
    world:query({
        name = "tileChunk.SlotManagement",
        include = {TileChunk, Transform},
        onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local chunks = archetype:get(TileChunk) as {tileChunk.TileChunk}
            for row = firstRow, lastRow do
                local slot = allocateSlot()
                chunks[row]._gpuSlot = slot
                if slot + 1 > growable.activeCount then
                    growable.activeCount = slot + 1
                end
            end
        end,
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local chunks = archetype:get(TileChunk) as {tileChunk.TileChunk}
            for row = firstRow, lastRow do
                local chunk = chunks[row]
                local slot = chunk._gpuSlot
                if slot >= 0 then
                    freeSlot(slot)
                    chunk._gpuSlot = -1
                    -- Shrink the dispatch range when the top slot(s) are
                    -- freed. Holes below the top stay on the freelist
                    -- for reuse; we only shrink activeCount through the
                    -- contiguous freed tail so cull/render don't iterate
                    -- dead work indefinitely.
                    if slot + 1 == growable.activeCount then
                        local ac = growable.activeCount - 1
                        while ac > 0 and freedSet[ac - 1] do
                            ac = ac - 1
                        end
                        growable.activeCount = ac
                    end
                end
            end
        end
    })

    -- Dirty sync query: only matches chunks that need GPU update.
    -- O(0) when no chunks are dirty (the common case for static maps).
    local dirtyQuery = world:query({
        name = "tileChunk.DirtySync",
        include = {TileChunk, Transform, DirtyTileChunk},
    })

    -- Sync only dirty chunks to GPU buffer
    -- Reused across frames: entities to strip DirtyTileChunk from
    -- (can't remove a component during query iteration).
    local toClean: {integer} = {}
    world:addSystem({
        name = "tileChunk.GPUSync",
        phase = tecs.phases.PreRender,
        run = function()
            local toCleanCount = 0

            for archetype, len, entities in dirtyQuery:iter() do
                -- The sync writes through the renderer's GPU buffer, not
                -- back into the TileChunk column. Read with `:get` so we
                -- don't false-flag the component dirty.
                local chunks = archetype:get(TileChunk) as {tileChunk.TileChunk}
                local transforms = archetype:get(Transform)
                local colors = archetype:get(Color) as {ColorData}
                local occluders = archetype:get(Occluder) as {OccluderData}

                local headerView = shadowPtr as {integer: TileChunkHeaderFFI}

                for i = 1, len do
                    local entityId = entities[i]
                    local chunk = chunks[i]
                    local transform = transforms[i]

                    -- Get GPU slot (allocated by SlotManagement observer).
                    -- Defensive: if the slot management query fired late
                    -- relative to the dirty tag, allocate now.
                    local slot = chunk._gpuSlot
                    if slot < 0 then
                        slot = allocateSlot()
                        chunk._gpuSlot = slot
                        if slot + 1 > growable.activeCount then
                            growable.activeCount = slot + 1
                        end
                    end

                    -- Register tileset and cache the texture array layer index.
                    if chunk._textureIndex < 0 and chunk.tileset then
                        chunk._textureIndex = registerTileset(
                            chunk.tileset,
                            chunk.normalMap,
                            chunk.emissionMap,
                            chunk.ormMap,
                            chunk._occluderHeights
                        )
                    end

                    local r, g, b, a = 1.0, 1.0, 1.0, 1.0
                    if colors then
                        local color = colors[i]
                        r = color.r or 1
                        g = color.g or 1
                        b = color.b or 1
                        a = color.a or 1
                    end

                    -- Write header.
                    local header = headerView[slot]
                    header.x = transform.x
                    header.y = transform.y
                    header.tileWidth = chunk.tileWidth
                    header.tileHeight = chunk.tileHeight
                    header.layer = transform.layer or 1
                    header.z = transform.z or 0
                    header.columns = chunk.columns
                    header.textureIndex = chunk._textureIndex >= 0 and chunk._textureIndex or 0

                    header.r = r
                    header.g = g
                    header.b = b
                    header.a = a

                    -- Check if any tile in this chunk uses an occluder.
                    local hasOccluders = false
                    local occluderHeights = chunk._occluderHeights
                    if occluderHeights and next(occluderHeights) then
                        local tiles = chunk.tiles
                        local firstgid = chunk._firstgid
                        for ti = 1, 256 do
                            local gid = tiles[ti]
                            if gid and gid > 0 then
                                -- Tile values may carry Tiled flip flags in
                                -- the high bits; only the low bits identify
                                -- the tile for the occluder-height lookup.
                                local localId = band(gid, 0x1FFFFFFF) - firstgid
                                if localId >= 0 and occluderHeights[localId] then
                                    hasOccluders = true
                                    break
                                end
                            end
                        end
                    end

                    local occHeight: number = 0
                    if hasOccluders then
                        if occluders then
                            local occ = occluders[i]
                            occHeight = occ.height or 64
                        else
                            occHeight = 64
                        end
                    end

                    header.occluderHeight = occHeight
                    header._padLM = 0
                    header.hasOccluders = hasOccluders and 1.0 or 0.0
                    header._pad = 0

                    -- Write 256 tile IDs (1024 bytes) at offset 64 bytes
                    -- past the header.
                    local slotOffset = slot * elementSize
                    writeTileData(shadowPtr as C.CData, slotOffset, chunk.tiles)

                    -- Push this slot's full row (header + tile data) to
                    -- the GPU. One driver call per dirty chunk; in the
                    -- common case "few chunks change per frame" this is
                    -- cheap. The DirtyTileChunk tag query gates how many
                    -- chunks land here.
                    inputBufferRef.handle:setArrayData(byteData, slot + 1, slot + 1, 1)

                    toCleanCount = toCleanCount + 1
                    toClean[toCleanCount] = entityId
                end
            end

            -- Remove DirtyTileChunk from synced entities (moves to clean archetype)
            for i = 1, toCleanCount do
                world:remove(toClean[i], DirtyTileChunk)
                toClean[i] = nil
            end
        end
    })
end

return tileChunk
