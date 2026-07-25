--- std430 layouts and canonical→shadow translations for every component
--- the shadow-column path needs. Each entry is a `LayoutDescriptor`
--- with the (elementSize, ctype, BufferFormat, translate) tuple a
--- shadow_buffer needs to construct a per-archetype shadow.
---
--- Naming convention: ctype names are prefixed `Std430` to avoid clashing
--- with the canonical FFI structs. BufferFormats mirror the GLSL block
--- layout that the cull shader expects.

local C <const> = require("ffi")

local record LayoutDescriptor
    elementSize: integer
    shadowCtype: string
    format: love.graphics.BufferFormat
    translate: function(C.CData, C.CData, integer, integer)
    --- True when the canonical column layout is byte-identical to std430,
    --- so the column can be uploaded straight to the SSBO with no repack.
    identity: boolean
end

-- All std430 layouts are vec4-aligned so that arrays-of-structs follow the
-- std430 stride rule (struct stride = max-member alignment, rounded up to
-- vec4 if any member is vec4-aligned). Per-row sizes are commented inline.
C.cdef[[
    // Transform: 28 bytes, byte-identical to CanonicalTransform so the upload
    // uses the identity bulk-memcpy path instead of a per-row field repack.
    // layer stays int32 (matching the component); the cull shaders cast it to
    // float at the few sites that need it.
    typedef struct {
        float x, y, z;
        int32_t layer;
        float rotation, scaleX, scaleY;
    } Std430Transform;

    // Color: 16 bytes. Canonical (4 float) already matches std430 vec4.
    typedef struct {
        float r, g, b, a;
    } Std430Color;

    // ClipBounds: 16 bytes. Canonical (4 float) already matches std430 vec4.
    typedef struct {
        float minX, minY, maxX, maxY;
    } Std430ClipBounds;

    // Material: 32 bytes. Canonical is 20 bytes (int32 + 4 float); pad to
    // vec4-aligned so SSBO array stride is 32.
    typedef struct {
        uint32_t materialId;
        float p0, p1, p2;     // vec4
        float p3;
        float _pad0, _pad1, _pad2;  // vec4
    } Std430Material;

    // LayoutBox: 32 bytes. Only offsetX/offsetY are read by the cull shader for
    // circles, but mirror the full record so a future shader pass can read
    // dimensions and origin without re-mirroring.
    typedef struct {
        float width, height, offsetX, offsetY;     // vec4
        float originX, originY;
        uint32_t sourceComponentId;
        uint32_t inheritsOrigin;                     // vec4
    } Std430LayoutBox;

    // Circle: 8 bytes. radius + lineWidth = 8 bytes; std430 array
    // stride for `vec2` (or `float[2]`) is 8, no padding needed.
    typedef struct {
        float radius, lineWidth;
    } Std430Circle;

    // Occluder: 8 bytes. Canonical (2 float) maps directly to vec2
    // stride; struct alignment is 4-byte, no padding needed.
    typedef struct {
        float height, alphaThreshold;
    } Std430Occluder;

    // Rectangle: 12 bytes (3 floats). All-scalar struct; std430 stride
    // is the natural 4-byte alignment, no vec3/vec4 forcing larger.
    typedef struct {
        float width, height, lineWidth;
    } Std430Rectangle;

    // Pivot: 16 bytes. Canonical (2 float = 8 bytes) padded to vec4 so
    // SSBO array stride is 16. The cull shader reads (x, y).
    typedef struct {
        float x, y, _pad0, _pad1;
    } Std430Pivot;

    // RoundedCorners: 16 bytes. Canonical (2 float = 8 bytes) padded to
    // vec4 stride. The cull shader reads (rx, ry).
    typedef struct {
        float rx, ry, _pad0, _pad1;
    } Std430RoundedCorners;

    // Ellipse: 12 bytes (3 floats). All-scalar struct, 4-byte stride.
    typedef struct {
        float radiusX, radiusY, lineWidth;
    } Std430Ellipse;

    // Arc: 20 bytes (5 floats). All-scalar struct so std430 stride is
    // the natural 4-byte alignment; no vec4 access in the shader.
    typedef struct {
        float radiusX, radiusY, startAngle, endAngle, lineWidth;
    } Std430Arc;

    // Line: 20 bytes (5 floats). All-scalar struct, 4-byte stride; no
    // vec4 access in the shader.
    typedef struct {
        float x1, y1, x2, y2, width;
    } Std430Line;

    // TextEffects: 68 bytes (17 floats). All-scalar std430 struct;
    // stride is the natural sum of float members (4-byte alignment,
    // no vec3/vec4 members forcing larger alignment). Canonical FFI
    // struct has the same field order; identity memcpy is safe.
    typedef struct {
        float outlineWidth;
        float outlineR, outlineG, outlineB, outlineA;
        float glowRadius;
        float glowR, glowG, glowB, glowA;
        float shadowOffsetX, shadowOffsetY;
        float shadowBlur;
        float shadowR, shadowG, shadowB, shadowA;
    } Std430TextEffects;

    // Text: 40 bytes (10 × 4). All-scalar std430 struct so stride is
    // the natural 4-byte alignment, no vec4 padding. The cull shader
    // sees `charCountFontId` as a single uint and unpacks it manually
    // (lo half = charCount, hi half = fontId) to match the canonical
    // uint16+uint16 layout.
    typedef struct {
        uint32_t slabOffset;
        uint32_t charCountFontId;  // lo: charCount, hi: fontId
        uint32_t textId;
        uint32_t glyphBlockId;
        uint32_t gpuStartIdx;
        uint32_t fontLayer;
        float    pivotOffsetX;
        float    pivotOffsetY;
        float    width;
        float    height;
    } Std430Text;

    // Sprite: 24 bytes. Six 4-byte fields matching the canonical FFI
    // component (spriteId, _entity, animStartTime, pausedFrame,
    // _pauseAtFrame, pauseDepth). Identity memcpy.
    typedef struct {
        int32_t  spriteId;
        uint32_t entityId;          // canonical: `_entity` owner token
        float    animStartTime;
        int32_t  pausedFrame;
        int32_t  pauseAtFrame;      // canonical: `_pauseAtFrame`
        int32_t  pauseDepth;
    } Std430Sprite;

// RepeatedSprite: 16 bytes. Canonical uses 1-byte `bool` for repeat
    // flags (LuaJIT FFI's auto-coercing `_Bool`); std430 upcasts to
    // 4-byte uint via field translate. Layouts therefore differ in
    // size, so this can't use identity memcpy.
    typedef struct {
        uint32_t repeatX;
        uint32_t repeatY;
        float    width;
        float    height;
    } Std430RepeatedSprite;

    // DropShadow: 8 bytes. Two floats; canonical and std430 are
    // byte-identical. Identity memcpy.
    typedef struct {
        float height;
        float opacity;
    } Std430DropShadow;

    // SpriteData: 72 bytes (18 floats). Renderer-internal derived
    // metadata that sync writes per dirty entity (resolved frame UV,
    // animation params from the sheet, packed textureSlice with layer
    // index + generation, playback direction and the tag's first
    // sheet frame). Field-identical to CanonicalSpriteData; identity
    // memcpy.
    typedef struct {
        float pivotX, pivotY;
        float width, height;
        float uvX, uvY, uvW, uvH;
        float animTotalDuration;
        float animFrameCount;
        float animFrameWidth;
        float animColumnCount;
        float animFrameHeight;
        float animTimingOffset;
        float textureSlice;        // packed: layer index + generation
        float animDirection;       // 0 forward, 1 reverse, 2 pingpong
        float animFirstFrame;      // tag's first sheet frame, 0-based
        float spriteId;            // instance id last synced (CPU-side)
    } Std430SpriteData;

    // Mesh: 4 bytes. The cull shader reads `definitionId` per row to
    // skip rows whose mesh definition doesn't match the current
    // dispatch's target definition. Field-identical to CanonicalMesh
    // (int32 vs uint32 reinterpretation, same bytes). Identity memcpy.
    typedef struct {
        uint32_t definitionId;
    } Std430Mesh;
]]

-- Teal records matching the FFI structs above. Used to give field-typed
-- access through `cast(...) as {integer: Record}` indexing, same pattern
-- as `circle/sync.tl:165`. Declared as `record` (not type alias) so the
-- field types are visible to the type checker.

local record Std430MaterialR
    materialId: integer
    p0: number
    p1: number
    p2: number
    p3: number
    _pad0: number
    _pad1: number
    _pad2: number
end

local record Std430LayoutBoxR
    width: number
    height: number
    offsetX: number
    offsetY: number
    originX: number
    originY: number
    sourceComponentId: integer
    inheritsOrigin: integer
end

local record Std430PivotR
    x: number
    y: number
    _pad0: number
    _pad1: number
end

local record Std430RoundedCornersR
    rx: number
    ry: number
    _pad0: number
    _pad1: number
end

local record Std430RepeatedSpriteR
    repeatX: integer
    repeatY: integer
    width: number
    height: number
end

-- Canonical FFI struct names match the field-tuple-derived names from
-- newFFIComponent. We re-declare them here as opaque arrays so we can
-- cast incoming canonical pointers without depending on the original
-- ctype handles (which aren't easily accessible from the shadow module).
C.cdef[[
    typedef struct {
        float x, y, z;
        int32_t layer;
        float rotation, scaleX, scaleY;
    } CanonicalTransform;

    typedef struct {
        float r, g, b, a;
    } CanonicalColor;

    typedef struct {
        float minX, minY, maxX, maxY;
    } CanonicalClipBounds;

    typedef struct {
        int32_t materialId;
        float p0, p1, p2, p3;
    } CanonicalMaterial;

    typedef struct {
        float width, height, offsetX, offsetY;
        float originX, originY;
        int32_t sourceComponentId;
        int32_t inheritsOrigin;
    } CanonicalLayoutBox;

    typedef struct {
        float radius, lineWidth;
    } CanonicalCircle;

    typedef struct {
        float height, alphaThreshold;
    } CanonicalOccluder;

    // Canonical Rectangle: 12 bytes (3 floats). Field-identical to
    // Std430Rectangle, so identity memcpy is correct.
    typedef struct {
        float width, height, lineWidth;
    } CanonicalRectangle;

    typedef struct {
        float x, y;
    } CanonicalPivot;

    typedef struct {
        float rx, ry;
    } CanonicalRoundedCorners;

    // Canonical Arc: 20 bytes (5 floats). Field-identical to
    // Std430Arc, so identity memcpy is correct.
    typedef struct {
        float radiusX, radiusY, startAngle, endAngle;
        float lineWidth;
    } CanonicalArc;

    // Canonical Line: 20 bytes (5 floats). Field-identical to
    // Std430Line, so identity memcpy is correct.
    typedef struct {
        float x1, y1, x2, y2;
        float width;
    } CanonicalLine;

    // Canonical TextEffects: 17 floats = 68 bytes. Field-identical to
    // Std430TextEffects, so identity memcpy is correct.
    typedef struct {
        float outlineWidth;
        float outlineR, outlineG, outlineB, outlineA;
        float glowRadius;
        float glowR, glowG, glowB, glowA;
        float shadowOffsetX, shadowOffsetY;
        float shadowBlur;
        float shadowR, shadowG, shadowB, shadowA;
    } CanonicalTextEffects;

    // Canonical Text: 40 bytes. Two uint16 fields (charCount, fontId)
    // sit at offsets 4-7 and pack into a single 4-byte word in memory;
    // when read as the std430 shadow's `charCountFontId: uint32`, the
    // little-endian byte order maps charCount to the low half and
    // fontId to the high half. Identity memcpy preserves this.
    typedef struct {
        uint32_t slabOffset;
        uint16_t charCount;
        uint16_t fontId;
        uint32_t textId;
        uint32_t glyphBlockId;
        uint32_t gpuStartIdx;
        uint32_t fontLayer;
        float    pivotOffsetX;
        float    pivotOffsetY;
        float    width;
        float    height;
    } CanonicalText;

    // Canonical Sprite: 24 bytes. Field-identical to Std430Sprite.
    typedef struct {
        int32_t  spriteId;
        uint32_t entityId;
        float    animStartTime;
        int32_t  pausedFrame;
        int32_t  pauseAtFrame;
        int32_t  pauseDepth;
    } CanonicalSprite;

// Canonical RepeatedSprite: 12 bytes. Two `bool` (1 byte each, with
    // 2 bytes of struct-alignment padding before the floats) plus two
    // floats. NOT byte-identical to Std430RepeatedSprite (which upcasts
    // bool→uint), so the translate is field-by-field.
    typedef struct {
        uint8_t  repeatX;
        uint8_t  repeatY;
        // 2 bytes alignment padding (LuaJIT FFI follows C struct rules;
        // float at offset 4 needs 4-byte alignment).
        float    width;
        float    height;
    } CanonicalRepeatedSprite;

    // Canonical DropShadow: 8 bytes. Field-identical to Std430DropShadow.
    typedef struct {
        float height;
        float opacity;
    } CanonicalDropShadow;

    // Canonical SpriteData: 72 bytes. Field-identical to Std430SpriteData.
    typedef struct {
        float pivotX, pivotY;
        float width, height;
        float uvX, uvY, uvW, uvH;
        float animTotalDuration;
        float animFrameCount;
        float animFrameWidth;
        float animColumnCount;
        float animFrameHeight;
        float animTimingOffset;
        float textureSlice;
        float animDirection;
        float animFirstFrame;
        float spriteId;
    } CanonicalSpriteData;

    // Canonical Mesh: 4 bytes. Single int32 field (renamed from FFI's
    // `_definitionId` for std430 compatibility). int32 vs uint32 is a
    // reinterpretation; identity memcpy preserves the bytes.
    typedef struct {
        int32_t definitionId;
    } CanonicalMesh;
]]


local record CanonicalMaterialR
    materialId: integer
    p0: number
    p1: number
    p2: number
    p3: number
end

local record CanonicalLayoutBoxR
    width: number
    height: number
    offsetX: number
    offsetY: number
    originX: number
    originY: number
    sourceComponentId: integer
    inheritsOrigin: integer
end

local record CanonicalPivotR
    x: number
    y: number
end

local record CanonicalRoundedCornersR
    rx: number
    ry: number
end

local cast <const> = C.cast
local copy <const> = C.copy
local sizeof <const> = C.sizeof

local TRANSFORM_STD_SIZE        <const> = sizeof("Std430Transform") as integer
local COLOR_STD_SIZE            <const> = sizeof("Std430Color") as integer
local CLIPBOUNDS_STD_SIZE       <const> = sizeof("Std430ClipBounds") as integer
local MATERIAL_STD_SIZE         <const> = sizeof("Std430Material") as integer
local LAYOUTBOX_STD_SIZE        <const> = sizeof("Std430LayoutBox") as integer
local CIRCLE_STD_SIZE           <const> = sizeof("Std430Circle") as integer
local OCCLUDER_STD_SIZE         <const> = sizeof("Std430Occluder") as integer
local RECTANGLE_STD_SIZE        <const> = sizeof("Std430Rectangle") as integer
local PIVOT_STD_SIZE            <const> = sizeof("Std430Pivot") as integer
local ROUNDED_CORNERS_STD_SIZE  <const> = sizeof("Std430RoundedCorners") as integer
local ELLIPSE_STD_SIZE          <const> = sizeof("Std430Ellipse") as integer
local ARC_STD_SIZE              <const> = sizeof("Std430Arc") as integer
local LINE_STD_SIZE             <const> = sizeof("Std430Line") as integer
local TEXTEFFECTS_STD_SIZE      <const> = sizeof("Std430TextEffects") as integer
local TEXT_STD_SIZE             <const> = sizeof("Std430Text") as integer
local SPRITE_STD_SIZE           <const> = sizeof("Std430Sprite") as integer
local REPEATEDSPRITE_STD_SIZE   <const> = sizeof("Std430RepeatedSprite") as integer
local DROPSHADOW_STD_SIZE       <const> = sizeof("Std430DropShadow") as integer
local SPRITEDATA_STD_SIZE       <const> = sizeof("Std430SpriteData") as integer
local MESH_STD_SIZE             <const> = sizeof("Std430Mesh") as integer

-------------------------------------------------------------------------------
-- Translation functions
--
-- All translates iterate `firstRow..lastRow` (1-indexed inclusive) and
-- copy the canonical bytes into the std430 shadow at the same row index.
-- Row index 0 is reserved padding (matches the FFI column convention).
-------------------------------------------------------------------------------

-- Transform uses the identity bulk-memcpy path (defined below); its std430
-- layout matches CanonicalTransform byte-for-byte.

-- Identity-layout translates: canonical bytes already match std430. Use a
-- single bulk memcpy instead of per-row field copies. Caller passes raw
-- pointers; we offset via FFI pointer arithmetic.
--
-- Pointer arithmetic is wrapped in `load()` to bypass Teal's checker, the
-- same pattern as `gpu/buffer.tl:211-217`.
local ffiOffsetPtr: function(C.CData, integer): C.CData
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local code = "local ffi = require('ffi'); return function(ptr, offset) return ffi.cast('char*', ptr) + offset end"
    local fn = (loadfn as function(string): function(): any)(code)()
    ffiOffsetPtr = fn as function(C.CData, integer): C.CData
end

-- Functions produced by `translateIdentity` are tagged here so `makeLayout`
-- can mark the layout `identity` without each call site repeating the flag.
local identityTranslates <const> = setmetatable({}, {__mode = "k"}) as {any: boolean}

local function translateIdentity(elementSize: integer): function(C.CData, C.CData, integer, integer)
    local fn = function(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
        if lastRow < firstRow then return end
        local count = lastRow - firstRow + 1
        local offset = firstRow * elementSize
        copy(ffiOffsetPtr(shadowRaw, offset), ffiOffsetPtr(canonicalRaw, offset), count * elementSize)
    end
    identityTranslates[fn] = true
    return fn
end

local translateTransform   <const> = translateIdentity(TRANSFORM_STD_SIZE)
local translateColor       <const> = translateIdentity(COLOR_STD_SIZE)
local translateClipBounds  <const> = translateIdentity(CLIPBOUNDS_STD_SIZE)
local translateOccluder    <const> = translateIdentity(OCCLUDER_STD_SIZE)

local function translateMaterial(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
    local can = cast("CanonicalMaterial*", canonicalRaw) as {integer: CanonicalMaterialR}
    local sha = cast("Std430Material*", shadowRaw) as {integer: Std430MaterialR}
    for r = firstRow, lastRow do
        local c = can[r]
        local s = sha[r]
        s.materialId = c.materialId
        s.p0 = c.p0
        s.p1 = c.p1
        s.p2 = c.p2
        s.p3 = c.p3
        s._pad0 = 0
        s._pad1 = 0
        s._pad2 = 0
    end
end

local function translateLayoutBox(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
    local can = cast("CanonicalLayoutBox*", canonicalRaw) as {integer: CanonicalLayoutBoxR}
    local sha = cast("Std430LayoutBox*", shadowRaw) as {integer: Std430LayoutBoxR}
    for r = firstRow, lastRow do
        local c = can[r]
        local s = sha[r]
        s.width = c.width
        s.height = c.height
        s.offsetX = c.offsetX
        s.offsetY = c.offsetY
        s.originX = c.originX
        s.originY = c.originY
        s.sourceComponentId = c.sourceComponentId
        s.inheritsOrigin = c.inheritsOrigin
    end
end

-- Canonical Circle and Std430Circle are byte-identical (2 floats =
-- 8 bytes, std430 vec2 stride is 8). Use identity memcpy.
local translateCircle <const> = translateIdentity(CIRCLE_STD_SIZE)

-- Canonical Rectangle and Std430Rectangle are field-identical 3-float
-- structs (12 bytes). Identity memcpy.
local translateRectangle <const> = translateIdentity(RECTANGLE_STD_SIZE)

-- Canonical Ellipse and Std430Ellipse are field-identical 3-float
-- structs (12 bytes). Identity memcpy.
local translateEllipse <const> = translateIdentity(ELLIPSE_STD_SIZE)

-- Canonical Pivot is 8 bytes; std430 stride is 16. Per-row copy with
-- the trailing two lanes cleared.
local function translatePivot(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
    local can = cast("CanonicalPivot*", canonicalRaw) as {integer: CanonicalPivotR}
    local sha = cast("Std430Pivot*", shadowRaw) as {integer: Std430PivotR}
    for r = firstRow, lastRow do
        local c = can[r]
        local s = sha[r]
        s.x = c.x
        s.y = c.y
        s._pad0 = 0
        s._pad1 = 0
    end
end

-- Canonical Arc and Std430Arc are field-identical 5-float structs
-- (20 bytes). Identity memcpy.
local translateArc <const> = translateIdentity(ARC_STD_SIZE)

-- Canonical Line and Std430Line are field-identical 5-float structs
-- (20 bytes). Identity memcpy.
local translateLine <const> = translateIdentity(LINE_STD_SIZE)

-- Canonical TextEffects is field-identical to Std430TextEffects (both
-- 17 floats = 68 bytes). Identity memcpy.
local translateTextEffects <const> = translateIdentity(TEXTEFFECTS_STD_SIZE)

-- Canonical Text and Std430Text are byte-identical at 40 bytes; the two
-- uint16 fields (charCount, fontId) pack into the std430 uint32 slot
-- (charCountFontId) via little-endian byte order. Identity memcpy.
local translateText <const> = translateIdentity(TEXT_STD_SIZE)

-- Canonical Sprite and Std430Sprite are byte-identical 24-byte structs
-- (six 4-byte fields). Identity memcpy.
local translateSprite <const> = translateIdentity(SPRITE_STD_SIZE)

-- Canonical DropShadow and Std430DropShadow are byte-identical 8 bytes.
-- Identity memcpy.
local translateDropShadow <const> = translateIdentity(DROPSHADOW_STD_SIZE)

-- Canonical SpriteData and Std430SpriteData are byte-identical 72 bytes
-- (18 floats). Identity memcpy.
local translateSpriteData <const> = translateIdentity(SPRITEDATA_STD_SIZE)

-- Canonical Mesh and Std430Mesh are byte-identical 4 bytes (int32 vs
-- uint32 is a reinterpretation, same bytes). Identity memcpy.
local translateMesh <const> = translateIdentity(MESH_STD_SIZE)

-- Canonical RepeatedSprite uses 1-byte `bool` fields; std430 upcasts to
-- 4-byte uint. Per-row field copy: read FFI bools (LuaJIT auto-coerces
-- to Lua boolean), write `1` or `0` into the std430 uint slot.
local function translateRepeatedSprite(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
    local can = cast("CanonicalRepeatedSprite*", canonicalRaw) as {integer: {string: any}}
    local sha = cast("Std430RepeatedSprite*", shadowRaw) as {integer: Std430RepeatedSpriteR}
    for r = firstRow, lastRow do
        local c = can[r]
        local s = sha[r]
        s.repeatX = (c.repeatX as boolean) and 1 or 0
        s.repeatY = (c.repeatY as boolean) and 1 or 0
        s.width = c.width as number
        s.height = c.height as number
    end
end

-- Canonical RoundedCorners is 8 bytes; std430 stride is 16.
local function translateRoundedCorners(canonicalRaw: C.CData, shadowRaw: C.CData, firstRow: integer, lastRow: integer)
    local can = cast("CanonicalRoundedCorners*", canonicalRaw) as {integer: CanonicalRoundedCornersR}
    local sha = cast("Std430RoundedCorners*", shadowRaw) as {integer: Std430RoundedCornersR}
    for r = firstRow, lastRow do
        local c = can[r]
        local s = sha[r]
        s.rx = c.rx
        s.ry = c.ry
        s._pad0 = 0
        s._pad1 = 0
    end
end

-------------------------------------------------------------------------------
-- BufferFormat declarations
--
-- Each format mirrors the std430 struct so `lg.newBuffer(format, n, ...)`
-- and the GLSL SSBO declaration agree on layout. Love's BufferFormat is a
-- list of `{name, format}` entries; element stride matches the struct.
-------------------------------------------------------------------------------

local TRANSFORM_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},   -- x
    {format = "float"},   -- y
    {format = "float"},   -- z
    {format = "int32"},   -- layer
    {format = "float"},   -- rotation
    {format = "float"},   -- scaleX
    {format = "float"},   -- scaleY
}

local COLOR_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- r, g, b, a
}

local CLIPBOUNDS_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- minX, minY, maxX, maxY
}

local MATERIAL_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- materialId (bits) | p0 | p1 | p2
    {format = "floatvec4"},  -- p3 | pad | pad | pad
}

local LAYOUTBOX_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- width, height, offsetX, offsetY
    {format = "floatvec4"},  -- originX, originY, sourceComponentId/inheritsOrigin (bits)
}

local CIRCLE_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec2"},  -- radius, lineWidth
}

local OCCLUDER_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec2"},  -- height, alphaThreshold
}

local RECTANGLE_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- width
    {format = "float"},  -- height
    {format = "float"},  -- lineWidth
}

local PIVOT_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- x, y, _pad, _pad
}

local ROUNDED_CORNERS_FORMAT: love.graphics.BufferFormat = {
    {format = "floatvec4"},  -- rx, ry, _pad, _pad
}

local ELLIPSE_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- radiusX
    {format = "float"},  -- radiusY
    {format = "float"},  -- lineWidth
}

local ARC_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- radiusX
    {format = "float"},  -- radiusY
    {format = "float"},  -- startAngle
    {format = "float"},  -- endAngle
    {format = "float"},  -- lineWidth
}

local LINE_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- x1
    {format = "float"},  -- y1
    {format = "float"},  -- x2
    {format = "float"},  -- y2
    {format = "float"},  -- width
}

-- TextEffects: 68 bytes per row = 17 floats. Grouped into 4 vec4 lanes
-- + 1 trailing float to match the std430 struct stride exactly.
-- All-scalar lanes so the std430 array stride is the natural 68 bytes,
-- matching the FFI struct and the shader's all-scalar struct. A vec4
-- grouping would round the stride up to 80 and misalign every row
-- past the first.
local TEXTEFFECTS_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- outlineWidth
    {format = "float"},  -- outlineR
    {format = "float"},  -- outlineG
    {format = "float"},  -- outlineB
    {format = "float"},  -- outlineA
    {format = "float"},  -- glowRadius
    {format = "float"},  -- glowR
    {format = "float"},  -- glowG
    {format = "float"},  -- glowB
    {format = "float"},  -- glowA
    {format = "float"},  -- shadowOffsetX
    {format = "float"},  -- shadowOffsetY
    {format = "float"},  -- shadowBlur
    {format = "float"},  -- shadowR
    {format = "float"},  -- shadowG
    {format = "float"},  -- shadowB
    {format = "float"},  -- shadowA
}

-- Text: 40 bytes per row = 10 × 4-byte scalars. The first six slots
-- are uint32 (slab/glyph/font book-keeping); the trailing four are
-- floats (pivot offsets and cached width/height). Lane types are
-- declarative; the cull shader sees a packed struct and casts on read.
local TEXT_FORMAT: love.graphics.BufferFormat = {
    {format = "uint32"},  -- slabOffset
    {format = "uint32"},  -- charCount lo | fontId hi
    {format = "uint32"},  -- textId
    {format = "uint32"},  -- glyphBlockId
    {format = "uint32"},  -- gpuStartIdx
    {format = "uint32"},  -- fontLayer
    {format = "float"},   -- pivotOffsetX
    {format = "float"},   -- pivotOffsetY
    {format = "float"},   -- width
    {format = "float"},   -- height
}

-- Sprite: 24 bytes per row = 6 × 4-byte scalars. spriteId / entityId /
-- pausedFrame / pauseAtFrame / pauseDepth are int32; animStartTime is
-- float. The cull shader reinterprets via the Std430Sprite struct.
local SPRITE_FORMAT: love.graphics.BufferFormat = {
    {format = "int32"},   -- spriteId
    {format = "uint32"},  -- entityId owner token
    {format = "float"},   -- animStartTime
    {format = "int32"},   -- pausedFrame
    {format = "int32"},   -- pauseAtFrame
    {format = "int32"},   -- pauseDepth
}

-- RepeatedSprite: 16 bytes per row. Two uint flag lanes followed by
-- two floats. Field types match the Std430RepeatedSprite struct after
-- bool-to-uint upcast in the translator.
local REPEATEDSPRITE_FORMAT: love.graphics.BufferFormat = {
    {format = "uint32"},  -- repeatX (0/1)
    {format = "uint32"},  -- repeatY (0/1)
    {format = "float"},   -- width
    {format = "float"},   -- height
}

-- DropShadow: 8 bytes per row. Two floats; matches Std430DropShadow.
local DROPSHADOW_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},   -- height
    {format = "float"},   -- opacity
}

-- Mesh: 4 bytes per row. Single uint32 (the resolved MeshDefinition id).
local MESH_FORMAT: love.graphics.BufferFormat = {
    {format = "uint32"},  -- definitionId
}

-- SpriteData: 72 bytes per row = 18 × float. All-scalar struct so
-- std430 stride is the natural 4-byte alignment.
local SPRITEDATA_FORMAT: love.graphics.BufferFormat = {
    {format = "float"},  -- pivotX
    {format = "float"},  -- pivotY
    {format = "float"},  -- width
    {format = "float"},  -- height
    {format = "float"},  -- uvX
    {format = "float"},  -- uvY
    {format = "float"},  -- uvW
    {format = "float"},  -- uvH
    {format = "float"},  -- animTotalDuration
    {format = "float"},  -- animFrameCount
    {format = "float"},  -- animFrameWidth
    {format = "float"},  -- animColumnCount
    {format = "float"},  -- animFrameHeight
    {format = "float"},  -- animTimingOffset
    {format = "float"},  -- textureSlice (packed)
    {format = "float"},  -- animDirection (0 forward, 1 reverse, 2 pingpong)
    {format = "float"},  -- animFirstFrame (tag's first sheet frame, 0-based)
    {format = "float"},  -- spriteId (instance id last synced, CPU-side)
}

-------------------------------------------------------------------------------
-- Public configs
-------------------------------------------------------------------------------

local record std430
    record Layouts
        Transform: LayoutDescriptor
        Color: LayoutDescriptor
        ClipBounds: LayoutDescriptor
        Material: LayoutDescriptor
        LayoutBox: LayoutDescriptor
        Circle: LayoutDescriptor
        Occluder: LayoutDescriptor
        Rectangle: LayoutDescriptor
        Pivot: LayoutDescriptor
        RoundedCorners: LayoutDescriptor
        Ellipse: LayoutDescriptor
        Arc: LayoutDescriptor
        Line: LayoutDescriptor
        TextEffects: LayoutDescriptor
        Text: LayoutDescriptor
        Sprite: LayoutDescriptor
        RepeatedSprite: LayoutDescriptor
        DropShadow: LayoutDescriptor
        SpriteData: LayoutDescriptor
        Mesh: LayoutDescriptor
    end

    layouts: Layouts

    --- Element sizes in bytes (exposed for tests and instrumentation).
    sizes: {string: integer}

    type Descriptor = LayoutDescriptor
end

local function makeLayout(
    elementSize: integer,
    shadowCtype: string,
    format: love.graphics.BufferFormat,
    translate: function(C.CData, C.CData, integer, integer)
): LayoutDescriptor
    return {
        elementSize = elementSize,
        shadowCtype = shadowCtype,
        format = format,
        translate = translate,
        identity = identityTranslates[translate] == true,
    }
end

std430.layouts = {
    Transform      = makeLayout(TRANSFORM_STD_SIZE,        "Std430Transform",       TRANSFORM_FORMAT,        translateTransform),
    Color          = makeLayout(COLOR_STD_SIZE,            "Std430Color",           COLOR_FORMAT,            translateColor),
    ClipBounds     = makeLayout(CLIPBOUNDS_STD_SIZE,       "Std430ClipBounds",      CLIPBOUNDS_FORMAT,       translateClipBounds),
    Material       = makeLayout(MATERIAL_STD_SIZE,         "Std430Material",        MATERIAL_FORMAT,         translateMaterial),
    LayoutBox      = makeLayout(LAYOUTBOX_STD_SIZE,        "Std430LayoutBox",       LAYOUTBOX_FORMAT,        translateLayoutBox),
    Circle         = makeLayout(CIRCLE_STD_SIZE,           "Std430Circle",          CIRCLE_FORMAT,           translateCircle),
    Occluder       = makeLayout(OCCLUDER_STD_SIZE,         "Std430Occluder",        OCCLUDER_FORMAT,         translateOccluder),
    Rectangle      = makeLayout(RECTANGLE_STD_SIZE,        "Std430Rectangle",       RECTANGLE_FORMAT,        translateRectangle),
    Pivot          = makeLayout(PIVOT_STD_SIZE,            "Std430Pivot",           PIVOT_FORMAT,            translatePivot),
    RoundedCorners = makeLayout(ROUNDED_CORNERS_STD_SIZE,  "Std430RoundedCorners",  ROUNDED_CORNERS_FORMAT,  translateRoundedCorners),
    Ellipse        = makeLayout(ELLIPSE_STD_SIZE,          "Std430Ellipse",         ELLIPSE_FORMAT,          translateEllipse),
    Arc            = makeLayout(ARC_STD_SIZE,              "Std430Arc",             ARC_FORMAT,              translateArc),
    Line           = makeLayout(LINE_STD_SIZE,             "Std430Line",            LINE_FORMAT,             translateLine),
    TextEffects    = makeLayout(TEXTEFFECTS_STD_SIZE,      "Std430TextEffects",     TEXTEFFECTS_FORMAT,      translateTextEffects),
    Text           = makeLayout(TEXT_STD_SIZE,             "Std430Text",            TEXT_FORMAT,             translateText),
    Sprite         = makeLayout(SPRITE_STD_SIZE,           "Std430Sprite",          SPRITE_FORMAT,           translateSprite),
    RepeatedSprite = makeLayout(REPEATEDSPRITE_STD_SIZE,   "Std430RepeatedSprite",  REPEATEDSPRITE_FORMAT,   translateRepeatedSprite),
    DropShadow     = makeLayout(DROPSHADOW_STD_SIZE,       "Std430DropShadow",      DROPSHADOW_FORMAT,       translateDropShadow),
    SpriteData     = makeLayout(SPRITEDATA_STD_SIZE,       "Std430SpriteData",      SPRITEDATA_FORMAT,       translateSpriteData),
    Mesh           = makeLayout(MESH_STD_SIZE,             "Std430Mesh",            MESH_FORMAT,             translateMesh),
}

std430.sizes = {
    Transform = TRANSFORM_STD_SIZE,
    Color = COLOR_STD_SIZE,
    ClipBounds = CLIPBOUNDS_STD_SIZE,
    Material = MATERIAL_STD_SIZE,
    LayoutBox = LAYOUTBOX_STD_SIZE,
    Circle = CIRCLE_STD_SIZE,
    Occluder = OCCLUDER_STD_SIZE,
    Rectangle = RECTANGLE_STD_SIZE,
    Pivot = PIVOT_STD_SIZE,
    RoundedCorners = ROUNDED_CORNERS_STD_SIZE,
    Ellipse = ELLIPSE_STD_SIZE,
    Arc = ARC_STD_SIZE,
    Line = LINE_STD_SIZE,
    TextEffects = TEXTEFFECTS_STD_SIZE,
    Text = TEXT_STD_SIZE,
    Sprite = SPRITE_STD_SIZE,
    RepeatedSprite = REPEATEDSPRITE_STD_SIZE,
    DropShadow = DROPSHADOW_STD_SIZE,
    SpriteData = SPRITEDATA_STD_SIZE,
    Mesh = MESH_STD_SIZE,
}

return std430
