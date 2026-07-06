--- Texture Bucket Manager
--- Global singleton that manages size-bucketed texture arrays for efficient sprite batching.
--- Each bucket contains arrays of texture arrays, allocated on-demand.
--- Sprites are assigned to buckets based on their texture size.

local lg <const> = love.graphics
local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.bucket_manager")

-- Bucket tier enumeration
local enum BucketTier
    "Tiny"      -- 16x16
    "Small"     -- 64x64
    "Medium"    -- 256x256
    "Large"     -- 512x512
    "XL"        -- 1024x1024
    "XXL"       -- 2048x2048
end

local record bucket_manager
    --- Bucket tier enum
    type Tier = BucketTier

    --- Bucket configuration
    record BucketConfig
        size: integer           -- Texture size (width = height)
        layersPerArray: integer -- Max layers per texture array
    end

    --- Allocation result
    record Allocation
        tier: BucketTier
        arrayIndex: integer     -- 1-based index into bucket's arrays
        layerIndex: integer     -- 1-based layer within array
        generation: integer     -- Generation counter for staleness detection
    end

    --- Single texture array with metadata
    record TextureArray
        albedo: love.graphics.Canvas
        normal: love.graphics.Canvas
        emission: love.graphics.Canvas
        orm: love.graphics.Canvas
        freeList: {integer}         -- Available layer indices
        usedCount: integer          -- Number of layers in use
        generations: {integer}      -- Generation per layer (for staleness)
        generationsBuffer: love.graphics.Buffer  -- GPU buffer for cull shader
        generationsByteData: love.data.ByteData  -- Reusable byte data for updates
    end

    --- A bucket manages multiple texture arrays of the same size
    record Bucket
        config: BucketConfig
        arrays: {TextureArray}
        --- Mapping from sheetId to allocation (for lookup/removal)
        sheetAllocations: {integer: Allocation}
    end

    --- The global bucket manager
    record Manager
        buckets: {BucketTier: Bucket}
        allAllocations: {integer: Allocation}  -- Global cache: sheetId -> allocation

        --- Allocate a texture into the appropriate bucket.
        --- Returns allocation info or nil if texture is oversized.
        allocate: function(Manager, sheetId: integer, albedo: love.graphics.Image, normal?: love.graphics.Image, emission?: love.graphics.Image, orm?: love.graphics.Image): Allocation

        --- Remove a texture allocation, returning its layer to the free list.
        remove: function(Manager, sheetId: integer): boolean

        --- Get existing allocation for a sheet (nil if not allocated).
        getAllocation: function(Manager, sheetId: integer): Allocation

        --- Get the texture arrays for a bucket tier.
        getArrays: function(Manager, tier: BucketTier): {TextureArray}

        --- Get bucket config for a tier.
        getConfig: function(Manager, tier: BucketTier): BucketConfig

        --- Check if a sheet is allocated.
        isAllocated: function(Manager, sheetId: integer): boolean

        --- Get UV scale for a texture in a bucket (textureSize / bucketSize).
        getUVScale: function(Manager, sheetId: integer, textureWidth: integer, textureHeight: integer): number, number

        --- Determine which bucket tier a texture should use.
        getTierForSize: function(Manager, width: integer, height: integer): BucketTier
    end

    --- Bucket configurations (size -> config)
    CONFIGS: {BucketTier: BucketConfig}

    --- Tier order for size lookup
    TIER_ORDER: {BucketTier}

    --- Create the global manager (call once at startup)
    init: function(): Manager

    --- Get the global manager instance
    get: function(): Manager
end

-- Bucket configurations
bucket_manager.CONFIGS = {
    Tiny = {
        size = 16,
        layersPerArray = 512,
    },
    Small = {
        size = 64,
        layersPerArray = 256,
    },
    Medium = {
        size = 256,
        layersPerArray = 128,
    },
    Large = {
        size = 512,
        layersPerArray = 64,
    },
    XL = {
        size = 1024,
        layersPerArray = 32,
    },
    XXL = {
        size = 2048,
        layersPerArray = 4,
    },
}

-- Tier order from smallest to largest (for size lookup)
bucket_manager.TIER_ORDER = {"Tiny", "Small", "Medium", "Large", "XL", "XXL"}

-- Global singleton instance
local globalManager: bucket_manager.Manager = nil

local Manager <const> = bucket_manager.Manager
local MANAGER_MT <const>: metatable<Manager> = { __index = Manager }

--- Get the GPU's maximum texture array layers
local function getMaxTextureLayers(): integer
    local limits = lg.getSystemLimits()
    return (limits as {string: integer}).texturelayers or 256
end

--- Create a new texture array for a bucket
local function createTextureArray(size: integer, numLayers: integer): bucket_manager.TextureArray
    -- Create albedo array
    local albedo = lg.newCanvas(size, size, numLayers, {
        type = "array",
        format = "rgba8",
        mipmaps = "none",
    })
    (albedo as love.graphics.Texture):setFilter("nearest", "nearest")
    (albedo as love.graphics.Texture):setWrap("clampzero", "clampzero")

    -- Create normal array
    local normal = lg.newCanvas(size, size, numLayers, {
        type = "array",
        format = "rgba8",
        mipmaps = "none",
    })
    (normal as love.graphics.Texture):setFilter("nearest", "nearest")
    (normal as love.graphics.Texture):setWrap("clampzero", "clampzero")

    -- Create emission array
    local emission = lg.newCanvas(size, size, numLayers, {
        type = "array",
        format = "rgba8",
        mipmaps = "none",
    })
    (emission as love.graphics.Texture):setFilter("nearest", "nearest")
    (emission as love.graphics.Texture):setWrap("clampzero", "clampzero")

    -- Create ORM array (R=AO, G=roughness, B=metallic)
    local orm = lg.newCanvas(size, size, numLayers, {
        type = "array",
        format = "rgba8",
        mipmaps = "none",
    })
    (orm as love.graphics.Texture):setFilter("nearest", "nearest")
    (orm as love.graphics.Texture):setWrap("clampzero", "clampzero")

    -- Initialize free list with all layers (1-indexed)
    local freeList: {integer} = {}
    local generations: {integer} = {}
    for i = numLayers, 1, -1 do
        freeList[#freeList + 1] = i
        generations[i] = 0
    end

    -- Clear normal array to flat normal, ORM array to defaults
    local prevCanvas = lg.getCanvas()
    for layer = 1, numLayers do
        lg.setCanvas({{normal, layer = layer}})
        lg.clear(0.5, 0.5, 1.0, 1.0)
        lg.setCanvas({{orm, layer = layer}})
        lg.clear(1.0, 0.5, 0.0, 1.0)  -- AO=1, roughness=0.5, metallic=0
    end
    lg.setCanvas(prevCanvas)

    -- Create GPU buffer for generations (for cull shader)
    local genByteData = love.data.newByteData(numLayers * 4)
    local genBufferFormat: love.graphics.BufferFormat = {{format = "float"}}
    local genBuffer = lg.newBuffer(genBufferFormat, numLayers, { usage = "dynamic", shaderstorage = true })
    -- Initialize all generations to 0
    local ffi = require("ffi")
    local genPtr = ffi.cast("float*", genByteData:getFFIPointer()) as {integer: number}
    for i = 1, numLayers do
        genPtr[i - 1] = 0
    end
    genBuffer:setArrayData(genByteData)

    return {
        albedo = albedo,
        normal = normal,
        emission = emission,
        orm = orm,
        freeList = freeList,
        usedCount = 0,
        generations = generations,
        generationsBuffer = genBuffer,
        generationsByteData = genByteData,
    }
end

--- Upload an image to a specific layer of an array texture
local function uploadToLayer(canvas: love.graphics.Canvas, layer: integer, image: love.graphics.Image)
    local prevCanvas = lg.getCanvas()
    lg.setCanvas({{canvas, layer = layer}})
    lg.clear(0, 0, 0, 0)
    lg.setBlendMode("replace", "premultiplied")
    lg.draw(image, 0, 0)
    lg.setBlendMode("alpha")
    lg.setCanvas(prevCanvas)
end

--- Upload flat normal to a layer
local function uploadFlatNormal(canvas: love.graphics.Canvas, layer: integer)
    local prevCanvas = lg.getCanvas()
    lg.setCanvas({{canvas, layer = layer}})
    lg.clear(0.5, 0.5, 1.0, 1.0)
    lg.setCanvas(prevCanvas)
end

--- Upload black to a layer
local function uploadBlack(canvas: love.graphics.Canvas, layer: integer)
    local prevCanvas = lg.getCanvas()
    lg.setCanvas({{canvas, layer = layer}})
    lg.clear(0, 0, 0, 0)
    lg.setCanvas(prevCanvas)
end

--- Upload default ORM values to a layer (AO=1, roughness=0.5, metallic=0)
local function uploadDefaultORM(canvas: love.graphics.Canvas, layer: integer)
    local prevCanvas = lg.getCanvas()
    lg.setCanvas({{canvas, layer = layer}})
    lg.clear(1.0, 0.5, 0.0, 1.0)
    lg.setCanvas(prevCanvas)
end

function Manager:getTierForSize(width: integer, height: integer): BucketTier
    local maxDim = math.max(width, height)
    for _, tier in ipairs(bucket_manager.TIER_ORDER) do
        local config = bucket_manager.CONFIGS[tier]
        if maxDim <= config.size then
            return tier
        end
    end
    return nil  -- Oversized, no bucket fits
end

function Manager:allocate(
    sheetId: integer,
    albedo: love.graphics.Image,
    normal?: love.graphics.Image,
    emission?: love.graphics.Image,
    orm?: love.graphics.Image
): bucket_manager.Allocation
    -- Check if already allocated
    for _, bucket in pairs(self.buckets) do
        local existing = bucket.sheetAllocations[sheetId]
        if existing then
            return existing
        end
    end

    -- Determine bucket tier
    local w, h = (albedo as love.graphics.Texture):getDimensions()
    local tier = self:getTierForSize(w as integer, h as integer)
    if not tier then
        -- Oversized texture, cannot allocate
        LOGGER:warn("Texture %d (%dx%d) exceeds max bucket size (2048), use DirectSprite", sheetId, w, h)
        return nil
    end

    local bucket = self.buckets[tier]
    -- Use bucket.config (not CONFIGS[tier]) so the GPU texturelayers limit
    -- clamped at init time is honored. CONFIGS[tier] is the unclamped
    -- base config; using it directly would request oversize arrays on
    -- hardware with lower limits.
    local config = bucket.config

    -- Find an array with a free layer
    for arrayIdx, texArray in ipairs(bucket.arrays) do
        if #texArray.freeList > 0 then
            local layerIdx = table.remove(texArray.freeList)
            texArray.usedCount = texArray.usedCount + 1

            -- Upload textures
            uploadToLayer(texArray.albedo, layerIdx, albedo)
            if normal then
                uploadToLayer(texArray.normal, layerIdx, normal)
            else
                uploadFlatNormal(texArray.normal, layerIdx)
            end
            if emission then
                uploadToLayer(texArray.emission, layerIdx, emission)
            else
                uploadBlack(texArray.emission, layerIdx)
            end
            if orm then
                uploadToLayer(texArray.orm, layerIdx, orm)
            else
                uploadDefaultORM(texArray.orm, layerIdx)
            end

            local allocation: bucket_manager.Allocation = {
                tier = tier,
                arrayIndex = arrayIdx,
                layerIndex = layerIdx,
                generation = texArray.generations[layerIdx],
            }
            bucket.sheetAllocations[sheetId] = allocation
            self.allAllocations[sheetId] = allocation  -- Global cache
            return allocation
        end
    end

    -- No free layers in existing arrays, allocate a new array
    local newArray = createTextureArray(config.size, config.layersPerArray)
    bucket.arrays[#bucket.arrays + 1] = newArray

    -- Allocate from new array
    local layerIdx = table.remove(newArray.freeList)
    newArray.usedCount = newArray.usedCount + 1

    -- Upload textures
    uploadToLayer(newArray.albedo, layerIdx, albedo)
    if normal then
        uploadToLayer(newArray.normal, layerIdx, normal)
    else
        uploadFlatNormal(newArray.normal, layerIdx)
    end
    if emission then
        uploadToLayer(newArray.emission, layerIdx, emission)
    else
        uploadBlack(newArray.emission, layerIdx)
    end
    if orm then
        uploadToLayer(newArray.orm, layerIdx, orm)
    else
        uploadDefaultORM(newArray.orm, layerIdx)
    end

    local allocation: bucket_manager.Allocation = {
        tier = tier,
        arrayIndex = #bucket.arrays,
        layerIndex = layerIdx,
        generation = newArray.generations[layerIdx],
    }
    bucket.sheetAllocations[sheetId] = allocation
    self.allAllocations[sheetId] = allocation  -- Global cache
    return allocation
end

--- Update the GPU generations buffer from the Lua table
local function updateGenerationsBuffer(texArray: bucket_manager.TextureArray)
    local ffi = require("ffi")
    local genPtr = ffi.cast("float*", texArray.generationsByteData:getFFIPointer()) as {integer: number}
    local generations = texArray.generations
    for i = 1, #generations do
        genPtr[i - 1] = generations[i]
    end
    texArray.generationsBuffer:setArrayData(texArray.generationsByteData)
end

function Manager:remove(sheetId: integer): boolean
    local allocation = self.allAllocations[sheetId]
    if not allocation then
        return false
    end

    local bucket = self.buckets[allocation.tier]
    local texArray = bucket.arrays[allocation.arrayIndex]
    if texArray then
        -- Return layer to free list
        texArray.freeList[#texArray.freeList + 1] = allocation.layerIndex
        texArray.usedCount = texArray.usedCount - 1
        -- Increment generation to invalidate any stale references.
        -- Wrap at 65536 to match the 16-bit SlicePackingBits used by the
        -- cull shader. Using 256 here would alias after 256 reuses and
        -- resurrect stale sprite references pointing at evicted textures.
        texArray.generations[allocation.layerIndex] = (texArray.generations[allocation.layerIndex] + 1) % 65536
        -- Update GPU buffer
        updateGenerationsBuffer(texArray)
    end
    bucket.sheetAllocations[sheetId] = nil
    self.allAllocations[sheetId] = nil
    return true
end

function Manager:getAllocation(sheetId: integer): bucket_manager.Allocation
    -- O(1) lookup via global cache
    return self.allAllocations[sheetId]
end

function Manager:getArrays(tier: BucketTier): {bucket_manager.TextureArray}
    local bucket = self.buckets[tier]
    return bucket and bucket.arrays or {}
end

function Manager:getConfig(tier: BucketTier): bucket_manager.BucketConfig
    return bucket_manager.CONFIGS[tier]
end

function Manager:isAllocated(sheetId: integer): boolean
    return self:getAllocation(sheetId) ~= nil
end

function Manager:getUVScale(sheetId: integer, textureWidth: integer, textureHeight: integer): number, number
    local allocation = self:getAllocation(sheetId)
    if not allocation then
        return 1.0, 1.0
    end
    local config = bucket_manager.CONFIGS[allocation.tier]
    return textureWidth / config.size, textureHeight / config.size
end

function bucket_manager.init(): bucket_manager.Manager
    if globalManager then
        return globalManager
    end

    local buckets: {BucketTier: bucket_manager.Bucket} = {}

    -- Cap layers per array to GPU limit
    local maxLayers = getMaxTextureLayers()

    -- Initialize empty buckets (arrays allocated on-demand)
    for _, tier in ipairs(bucket_manager.TIER_ORDER) do
        local baseConfig = bucket_manager.CONFIGS[tier]
        buckets[tier] = {
            config = {
                size = baseConfig.size,
                layersPerArray = math.min(baseConfig.layersPerArray, maxLayers),
            },
            arrays = {},
            sheetAllocations = {},
        }
    end

    globalManager = setmetatable({
        buckets = buckets,
        allAllocations = {},
    }, MANAGER_MT)

    return globalManager
end

function bucket_manager.get(): bucket_manager.Manager
    if not globalManager then
        return bucket_manager.init()
    end
    return globalManager
end

return bucket_manager
