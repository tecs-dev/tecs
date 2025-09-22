--- Shared types and helpers for shape GPU sync systems.
--- Reduces duplication across circle, rectangle, ellipse, arc, and line syncs.

local tecs <const> = require("tecs")
local gpuBuffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local blend <const> = require("tecs2d.gfx.internal.blend")

local bit <const> = require("bit")
local bor <const> = bit.bor
local lshift <const> = bit.lshift

local type GPUBuffer = gpuBuffer.GPUBuffer

--- Shared records for component data access.
local record shape_sync_base
    --- Color component data layout
    record ColorData
        r: number
        g: number
        b: number
        a: number
    end

    --- ClipBounds component data layout
    record ClipBoundsData
        minX: number
        minY: number
        maxX: number
        maxY: number
    end

    --- Occluder component data layout
    record OccluderData
        alphaThreshold: number
        height: number
    end

    --- LayoutBox component data layout (for UI shapes)
    record LayoutBoxData
        width: number
        height: number
        offsetX: number
        offsetY: number
        originX: number
        originY: number
    end

    --- Pivot component data layout
    record PivotData
        x: number
        y: number
    end

    --- Blend group tracking for forward pass rendering
    record BlendGroup
        blendId: integer
        blendMode: love.graphics.BlendMode
        blendAlphaMode: love.graphics.BlendAlphaMode
    end

    --- Material group tracking for material variant dispatch
    record MaterialGroup
        materialId: integer
    end

    --- Material component data layout
    record MaterialData
        materialId: integer
        p0: number
        p1: number
        p2: number
        p3: number
    end

    --- FFI record for material params (matches GPUMaterialParams - 16 bytes)
    record MaterialParamsFFI
        p0: number
        p1: number
        p2: number
        p3: number
    end

    --- Sync record interface: fields that shape_utils and forward_blend read from sync modules.
    --- All shape sync modules (CircleSync, RectSync, etc.) must implement this interface.
    interface SyncRecord
        hasAlphaBlend: boolean
        blendGroups: {BlendGroup}
        blendGroupCount: integer
        materialGroups: {MaterialGroup}
        materialGroupCount: integer
        materialParamsBuffer: GPUBuffer
    end

    --- Metadata interface for color sync (shapes must have these fields)
    record ColorSyncTarget
        r: number
        g: number
        b: number
        a: number
    end

    --- Metadata interface for clip bounds sync
    record ClipBoundsSyncTarget
        clipMinX: number
        clipMinY: number
        clipMaxX: number
        clipMaxY: number
    end

    --- Metadata interface for occluder sync
    record OccluderSyncTarget
        occluderHeight: number
    end

    --- Metadata interface for pivot sync
    record PivotSyncTarget
        pivotX: number
        pivotY: number
    end

    --- Constants
    NO_CLIP_MIN: number
    NO_CLIP_MAX: number
    FLAG_OCCLUDER: integer
    FLAG_FILLED: integer
    FLAG_UNLIT: integer

    --- Blend info structure (matches blend module's BlendInfo)
    record BlendInfoEntry
        mode: love.graphics.BlendMode
        alphaMode: love.graphics.BlendAlphaMode
    end

    --- Blend mode lookup tables (re-exported for convenience)
    blendAll: {tecs.Component}
    blendInfo: {tecs.Component: BlendInfoEntry}

    --- Sync color from component array to metadata target.
    --- If no color component or nil at index, writes white (1,1,1,1).
    syncColor: function(meta: ColorSyncTarget, colors: {ColorData}, i: integer)

    --- Sync clip bounds from component array to metadata target.
    --- If no clip bounds or nil at index, writes infinite bounds.
    syncClipBounds: function(meta: ClipBoundsSyncTarget, clipBoundsArr: {ClipBoundsData}, i: integer)

    --- Sync occluder data from component array to metadata target.
    --- If no occluder or nil at index, writes zeros.
    syncOccluder: function(meta: OccluderSyncTarget, occluders: {OccluderData}, i: integer)

    --- Sync pivot from component array to metadata target.
    --- If no pivot or nil at index, writes (0, 0).
    syncPivot: function(meta: PivotSyncTarget, pivots: {PivotData}, i: integer)

    --- Track a blend group, returns updated count.
    --- Call for each non-zero blendId encountered during sync.
    trackBlendGroup: function(
        blendGroups: {BlendGroup},
        currentCount: integer,
        blendId: integer
    ): integer

    --- Track a material group, returns updated count.
    --- Call for each non-zero materialId encountered during sync.
    --- Deduplicates: only adds if materialId not already tracked.
    trackMaterialGroup: function(
        materialGroups: {MaterialGroup},
        currentCount: integer,
        materialId: integer
    ): integer

    --- Ensure both buffers have capacity for the given slot.
    ensureCapacity: function(transformBuffer: GPUBuffer, metadataBuffer: GPUBuffer, requiredSlot: integer): boolean

    --- Build flags from precomputed tag presence and optional occluder
    --- presence. `unlit` is the result of an archetype-level check
    --- (`archetype.columns[Unlit] ~= nil`); `hasOccluder` reflects an
    --- explicit Occluder component on the entity.
    buildFlags: function(
        unlit: boolean,
        hasOccluder: boolean,
        extraFlags?: integer
    ): integer

    --- Pack materialId into blendId: lower 4 bits = blendId, bits 4-11 = materialId.
    --- Returns the packed value and the extracted materialId.
    packMaterialId: function(blendId: integer, materials: {MaterialData}, i: integer): integer, integer

    --- Write material params to a lazily-created params buffer (dirty sync path).
    --- Creates the buffer if nil, grows if needed.
    --- Returns the (possibly new) params buffer.
    writeMaterialParams: function(
        paramsBuffer: GPUBuffer,
        referenceBuffer: GPUBuffer,
        mat: MaterialData,
        slot: integer
    ): GPUBuffer

    --- Sync material params on the per-frame hot path (buffer already exists).
    --- Writes params if buffer exists and slot is in range.
    syncMaterialParams: function(paramsBuffer: GPUBuffer, mat: MaterialData, slot: integer)

end

-- Constants
shape_sync_base.NO_CLIP_MIN = -1e9
shape_sync_base.NO_CLIP_MAX = 1e9
shape_sync_base.FLAG_OCCLUDER = gpuTypes.FLAG_OCCLUDER
shape_sync_base.FLAG_FILLED = gpuTypes.FLAG_FILLED
shape_sync_base.FLAG_UNLIT = gpuTypes.FLAG_UNLIT

-- Re-export blend lookup tables (cast to match our record type)
shape_sync_base.blendAll = blend.ALL
shape_sync_base.blendInfo = blend.INFO as {tecs.Component: shape_sync_base.BlendInfoEntry}

-- Local constants for hot path
local NO_CLIP_MIN <const> = shape_sync_base.NO_CLIP_MIN
local NO_CLIP_MAX <const> = shape_sync_base.NO_CLIP_MAX
local FLAG_OCCLUDER <const> = shape_sync_base.FLAG_OCCLUDER
local FLAG_UNLIT <const> = shape_sync_base.FLAG_UNLIT
local blendAll <const> = blend.ALL
local blendInfo <const> = blend.INFO

function shape_sync_base.syncColor(
    meta: shape_sync_base.ColorSyncTarget,
    colors: {shape_sync_base.ColorData},
    i: integer
)
    if colors then
        local c = colors[i]
        if c then
            meta.r = c.r or 1
            meta.g = c.g or 1
            meta.b = c.b or 1
            meta.a = c.a or 1
            return
        end
    end
    meta.r, meta.g, meta.b, meta.a = 1, 1, 1, 1
end

function shape_sync_base.syncClipBounds(
    meta: shape_sync_base.ClipBoundsSyncTarget,
    clipBoundsArr: {shape_sync_base.ClipBoundsData},
    i: integer
)
    if clipBoundsArr then
        local clip = clipBoundsArr[i]
        if clip then
            meta.clipMinX = clip.minX
            meta.clipMinY = clip.minY
            meta.clipMaxX = clip.maxX
            meta.clipMaxY = clip.maxY
            return
        end
    end
    meta.clipMinX = NO_CLIP_MIN
    meta.clipMinY = NO_CLIP_MIN
    meta.clipMaxX = NO_CLIP_MAX
    meta.clipMaxY = NO_CLIP_MAX
end

function shape_sync_base.syncOccluder(
    meta: shape_sync_base.OccluderSyncTarget,
    occluders: {shape_sync_base.OccluderData},
    i: integer
)
    if occluders then
        local occ = occluders[i]
        if occ then
            meta.occluderHeight = occ.height or 0
            return
        end
    end
    meta.occluderHeight = 0
end

function shape_sync_base.syncPivot(meta: shape_sync_base.PivotSyncTarget, pivots: {shape_sync_base.PivotData}, i: integer)
    if pivots then
        local p = pivots[i]
        if p then
            meta.pivotX = p.x or 0
            meta.pivotY = p.y or 0
            return
        end
    end
    meta.pivotX = 0
    meta.pivotY = 0
end

function shape_sync_base.trackBlendGroup(
    blendGroups: {shape_sync_base.BlendGroup},
    currentCount: integer,
    blendId: integer
): integer
    -- Deduplicate: check if already tracked
    for i = 1, currentCount do
        if blendGroups[i].blendId == blendId then
            return currentCount
        end
    end
    local newCount = currentCount + 1
    local info = blendInfo[blendAll[blendId]]
    local group = blendGroups[newCount]
    if not group then
        group = {} as shape_sync_base.BlendGroup
        blendGroups[newCount] = group
    end
    group.blendId = blendId
    group.blendMode = info.mode
    group.blendAlphaMode = info.alphaMode
    return newCount
end

function shape_sync_base.trackMaterialGroup(
    materialGroups: {shape_sync_base.MaterialGroup},
    currentCount: integer,
    materialId: integer
): integer
    -- Deduplicate: check if already tracked
    for i = 1, currentCount do
        if materialGroups[i].materialId == materialId then
            return currentCount
        end
    end
    local newCount = currentCount + 1
    local group = materialGroups[newCount]
    if not group then
        group = {} as shape_sync_base.MaterialGroup
        materialGroups[newCount] = group
    end
    group.materialId = materialId
    return newCount
end

function shape_sync_base.ensureCapacity(transformBuffer: GPUBuffer, metadataBuffer: GPUBuffer, requiredSlot: integer): boolean
    local requiredCapacity = requiredSlot + 1
    if transformBuffer.capacity >= requiredCapacity and metadataBuffer.capacity >= requiredCapacity then
        return false
    end
    while transformBuffer.capacity < requiredCapacity do
        transformBuffer:grow()
    end
    while metadataBuffer.capacity < requiredCapacity do
        metadataBuffer:grow()
    end
    return true
end

function shape_sync_base.buildFlags(
    unlit: boolean,
    hasOccluder: boolean,
    extraFlags?: integer
): integer
    local flags = extraFlags or 0
    if unlit then
        flags = bor(flags, FLAG_UNLIT)
    end
    if hasOccluder then
        flags = bor(flags, FLAG_OCCLUDER)
    end
    return flags
end

function shape_sync_base.packMaterialId(
    blendId: integer,
    materials: {shape_sync_base.MaterialData},
    i: integer
): integer, integer
    local matId = 0
    if materials then
        local mat = materials[i]
        matId = mat.materialId or 0
    end
    -- Pack: lower 4 bits = blendId, bits 4-11 = matId (8 bits for matId).
    return bor(blendId, lshift(matId, 4)), matId
end

function shape_sync_base.writeMaterialParams(
    paramsBuffer: GPUBuffer,
    referenceBuffer: GPUBuffer,
    mat: shape_sync_base.MaterialData,
    slot: integer
): GPUBuffer
    if not paramsBuffer then
        paramsBuffer = gpuBuffer.new(
            gpuTypes.MATERIAL_PARAMS_FORMAT,
            referenceBuffer.capacity,
            gpuTypes.MATERIAL_PARAMS_CTYPE
        )
    end
    while paramsBuffer.capacity < slot + 1 do
        paramsBuffer:grow()
    end
    local paramsPtr = paramsBuffer.dataPtr as {integer: shape_sync_base.MaterialParamsFFI}
    local p = paramsPtr[slot]
    p.p0 = mat.p0
    p.p1 = mat.p1
    p.p2 = mat.p2
    p.p3 = mat.p3
    paramsBuffer:markDirtyRange(slot, slot)
    return paramsBuffer
end

function shape_sync_base.syncMaterialParams(
    paramsBuffer: GPUBuffer,
    mat: shape_sync_base.MaterialData,
    slot: integer
)
    if paramsBuffer and slot < paramsBuffer.capacity then
        local paramsPtr = paramsBuffer.dataPtr as {integer: shape_sync_base.MaterialParamsFFI}
        local p = paramsPtr[slot]
        p.p0 = mat.p0
        p.p1 = mat.p1
        p.p2 = mat.p2
        p.p3 = mat.p3
        paramsBuffer:markDirtyRange(slot, slot)
    end
end

return shape_sync_base
