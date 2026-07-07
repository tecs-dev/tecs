--- Sprite Instance Registry (FFI-based)
---
--- Module-level registry for sprite instances stored as FFI structs.
--- Uses ChunkedArray for stable pointers.

local ffi <const> = require("ffi")
local ChunkedArray <const> = require("tecs.internal.ffi.StableChunkedArray")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")

-- Define the FFI struct
ffi.cdef[[
typedef struct {
    int32_t sheetId;
    int32_t tagId;
    float speed;
    bool centered;
    int32_t sliceId;
    float pivotX;
    float pivotY;
    float width;
    float height;
    float uvX;
    float uvY;
    float uvW;
    float uvH;
    float animTotalDuration;
    int32_t animTimingOffset;
    int32_t animFrameCount;
    float animFrameWidth;
    int32_t animColumnCount;
    float animFrameHeight;
    int32_t animDirection;
    int32_t animFirstFrame;
    float cachedPivotX;
    float cachedPivotY;
    int32_t cachedFrame;
    int32_t refCount;
} SpriteInstanceFFI;
]]

local record instance
    --- SpriteInstance holds shared template data. Multiple entities can reference one instance.
    record SpriteInstance
        -- Configuration
        sheetId: integer
        tagId: integer
        speed: number
        centered: boolean
        sliceId: integer

        -- Computed from config
        pivotX: number
        pivotY: number
        width: number
        height: number
        uvX: number
        uvY: number
        uvW: number
        uvH: number
        animTotalDuration: number
        animTimingOffset: integer
        animFrameCount: integer
        animFrameWidth: number
        animColumnCount: integer
        animFrameHeight: number
        --- Playback direction (0 forward, 1 reverse, 2 pingpong). Timing
        --- entries are registered in play order; the cull shader maps the
        --- timeline index back to a display frame using this.
        animDirection: integer
        --- The tag's first sheet frame, 0-based. Lets the render shaders
        --- compute sheet-absolute grid positions so tags that start
        --- mid-row wrap to the next row instead of off the sheet edge.
        animFirstFrame: integer

        -- Cached pivot for frame-dependent pivot calculation
        cachedPivotX: number
        cachedPivotY: number
        cachedFrame: integer

        -- Reference counting
        refCount: integer
    end

    get: function(spriteId: integer): SpriteInstance
    allocId: function(): integer
    freeId: function(id: integer)
    set: function(spriteId: integer, inst: SpriteInstance)
    remove: function(spriteId: integer)
    getSheet: function(inst: SpriteInstance): sprite_sheet.SpriteSheet
    findCached: function(sheetId: integer, tagId: integer, speed: number, centered: boolean, sliceId: integer): integer
    cache: function(sheetId: integer, tagId: integer, speed: number, centered: boolean, sliceId: integer, spriteId: integer)
    uncache: function(sheetId: integer, tagId: integer, speed: number, centered: boolean, sliceId: integer)
    setWorld: function(world: any)
    getWorld: function(): any
end

-- Chunked FFI storage
local instances = ChunkedArray.new("SpriteInstanceFFI", 256)

-- Cache for instance reuse: nested tables with integer keys
local instanceCache: {integer: {integer: {integer: {integer: {integer: integer}}}}} = {}

local function speedToKey(speed: number): integer
    return math.floor(speed * 1000 + 0.5)
end

function instance.findCached(
    sheetId: integer,
    tagId: integer,
    speed: number,
    centered: boolean,
    sliceId: integer
): integer
    local l1 = instanceCache[sheetId]
    if not l1 then return nil end
    local l2 = l1[tagId]
    if not l2 then return nil end
    local l3 = l2[speedToKey(speed)]
    if not l3 then return nil end
    local l4 = l3[centered and 1 or 0]
    if not l4 then return nil end
    return l4[sliceId]
end

function instance.cache(
    sheetId: integer,
    tagId: integer,
    speed: number,
    centered: boolean,
    sliceId: integer,
    spriteId: integer
)
    local l1 = instanceCache[sheetId]
    if not l1 then
        l1 = {}
        instanceCache[sheetId] = l1
    end
    local l2 = l1[tagId]
    if not l2 then
        l2 = {}
        l1[tagId] = l2
    end
    local speedKey = speedToKey(speed)
    local l3 = l2[speedKey]
    if not l3 then
        l3 = {}
        l2[speedKey] = l3
    end
    local centeredKey = centered and 1 or 0
    local l4 = l3[centeredKey]
    if not l4 then
        l4 = {}
        l3[centeredKey] = l4
    end
    l4[sliceId] = spriteId
end

function instance.uncache(
    sheetId: integer,
    tagId: integer,
    speed: number,
    centered: boolean,
    sliceId: integer
)
    local l1 = instanceCache[sheetId]
    if not l1 then return end
    local l2 = l1[tagId]
    if not l2 then return end
    local l3 = l2[speedToKey(speed)]
    if not l3 then return end
    local l4 = l3[centered and 1 or 0]
    if not l4 then return end
    l4[sliceId] = nil
end

function instance.allocId(): integer
    return instances:alloc()
end

function instance.freeId(id: integer)
    instances:free(id)
end

function instance.get(spriteId: integer): instance.SpriteInstance
    local inst = instances:get(spriteId) as instance.SpriteInstance
    if inst and inst.refCount > 0 then
        return inst
    end
    return nil
end

function instance.set(spriteId: integer, inst: instance.SpriteInstance)
    local dst = instances:get(spriteId) as instance.SpriteInstance
    dst.sheetId = inst.sheetId
    dst.tagId = inst.tagId
    dst.speed = inst.speed
    dst.centered = inst.centered
    dst.sliceId = inst.sliceId
    dst.pivotX = inst.pivotX
    dst.pivotY = inst.pivotY
    dst.width = inst.width
    dst.height = inst.height
    dst.uvX = inst.uvX
    dst.uvY = inst.uvY
    dst.uvW = inst.uvW
    dst.uvH = inst.uvH
    dst.animTotalDuration = inst.animTotalDuration
    dst.animTimingOffset = inst.animTimingOffset
    dst.animFrameCount = inst.animFrameCount
    dst.animFrameWidth = inst.animFrameWidth
    dst.animColumnCount = inst.animColumnCount
    dst.animFrameHeight = inst.animFrameHeight
    dst.animDirection = inst.animDirection
    dst.animFirstFrame = inst.animFirstFrame
    dst.cachedPivotX = inst.cachedPivotX
    dst.cachedPivotY = inst.cachedPivotY
    dst.cachedFrame = inst.cachedFrame
    dst.refCount = inst.refCount
end

function instance.remove(spriteId: integer)
    local inst = instances:get(spriteId) as instance.SpriteInstance
    if inst then
        inst.refCount = 0
    end
end

function instance.getSheet(inst: instance.SpriteInstance): sprite_sheet.SpriteSheet
    return sprite_sheet.SpriteSheet.getById(inst.sheetId)
end

-- Module-level world reference for Sprite methods
local currentWorld: any = nil

function instance.setWorld(world: any)
    currentWorld = world
end

function instance.getWorld(): any
    return currentWorld
end

return instance
