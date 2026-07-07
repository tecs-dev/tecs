// Text culling compute shader (renderer-owned shadow-column path).
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
//
// One dispatch per text archetype. Each dispatch binds the source-
// component SSBOs (Transform, Text, plus optional Color, ClipBounds,
// Material, TextEffects) and reads them by archetype-row index
// (gl_GlobalInvocationID.x = row-within-archetype, 0-based).
//
// Output buffers are SHARED across all text archetypes:
//   - TextHeaderOutput[]: per-entity packed render header (128 bytes).
//   - VisibleGlyphOutput[]: per-glyph instance entry { headerIdx,
//     glyphIdx } produced by expanding each visible entity into N
//     glyph instances. The render shader iterates these as gl_InstanceID.
//   - MaterialParamsOutput[]: per-entity material params, indexed by
//     the same `headerIdx` the visible glyph references.
//
// Indirect args layout:
//   args[0] = vertex count (set by host; 6 for two triangles)
//   args[1] = instance count (atomic, glyph total; drives the draw)
//   args[2] = first vertex   (constant 0)
//   args[3] = first instance (constant 0)
//   args[4] = entity count   (atomic, header output count; internal)

// ---------- Shape-specific source SSBOs ----------

// Std430Text mirrors the canonical 40-byte Text record exactly. The
// two uint16 fields (charCount, fontId) pack into a single uint slot
// (lo half = charCount, hi half = fontId).
struct Std430Text {
    uint slabOffset;
    uint charCountFontId;
    uint textId;
    uint glyphBlockId;
    uint gpuStartIdx;
    uint fontLayer;       // bit 31 = SDF flag, bits 0-30 = atlas index
    float pivotOffsetX;
    float pivotOffsetY;
    float width;
    float height;
};
layout(std430) readonly buffer TextInput {
    Std430Text texts[];
};

// TextEffects: 17 scalar floats. All-scalar so the std430 array
// stride is the natural 68 bytes, matching the FFI struct and the
// BufferFormat in std430.tl; vec4 members would round the stride up
// to 80 and misalign every row past the first.
struct Std430TextEffects {
    float outlineWidth;
    float outlineR, outlineG, outlineB, outlineA;
    float glowRadius;
    float glowR, glowG, glowB, glowA;
    float shadowOffsetX, shadowOffsetY;
    float shadowBlur;
    float shadowR, shadowG, shadowB, shadowA;
};
layout(std430) readonly buffer TextEffectsInput {
    Std430TextEffects effects[];
};

// ---------- Output buffers (shared across dispatches) ----------

// Mirrors TEXT_HEADER_FORMAT (128 bytes, 8 vec4 lanes). Field layout
// must match the text render shader's TextHeader struct.
struct TextHeaderOut {
    vec4 posLayer;       // x, y, z, layer
    vec4 rotScaleFlags;  // rotation, scaleX, scaleY, flags
    vec4 color;          // r, g, b, a
    vec4 clipBounds;     // minX, minY, maxX, maxY
    vec4 fontMeta;       // fontLayer, glyphStartIdx, glyphCount, textWidth
    vec4 extraMeta;      // textHeight, pivotOffsetX, pivotOffsetY, packed blend+material (uint bits)
    vec4 effects1;       // outlineColor, glowColor, shadowColor, shadowOffset (packed)
    vec4 effects2;       // outlineWidth, glowRadius, shadowBlur, spare
};
layout(std430) writeonly buffer TextHeaderOutput {
    TextHeaderOut headersOut[];
};

struct VisibleGlyph {
    uint headerIndex;
    uint glyphIndex;
};
layout(std430) writeonly buffer VisibleGlyphOutput {
    VisibleGlyph visibleGlyphsOut[];
};

// ---------- Shape flag constants ----------
const uint FLAG_MSDF = 0x10u;
const uint FONT_LAYER_SDF_BIT = 0x80000000u;

// ---------- Effects-vec packers ----------
// Mirror the packUnorm4x8 / packHalf2x16 flow the render shader
// decodes.

struct EffectsPack {
    vec4 effects1;
    vec4 effects2;
};

EffectsPack readEffectsPacked(uint row) {
    EffectsPack ep;
    ep.effects1 = vec4(0.0);
    ep.effects2 = vec4(0.0);
    if ((ComponentMask & COMP_TEXTEFFECTS) == 0u) {
        return ep;
    }
    Std430TextEffects e = effects[row];
    float outlineWidth = e.outlineWidth;
    float outlineR     = e.outlineR;
    float outlineG     = e.outlineG;
    float outlineB     = e.outlineB;
    float outlineA     = e.outlineA;
    float glowRadius   = e.glowRadius;
    float glowR        = e.glowR;
    float glowG        = e.glowG;
    float glowB        = e.glowB;
    float glowA        = e.glowA;
    float shadowOffX   = e.shadowOffsetX;
    float shadowOffY   = e.shadowOffsetY;
    float shadowBlur   = e.shadowBlur;
    float shadowR      = e.shadowR;
    float shadowG      = e.shadowG;
    float shadowB      = e.shadowB;
    float shadowA_     = e.shadowA;

    bool effectsActive = (outlineWidth > 0.0) || (glowRadius > 0.0)
        || (shadowOffX != 0.0) || (shadowOffY != 0.0) || (shadowBlur > 0.0);
    if (!effectsActive) {
        return ep;
    }

    uint outlinePacked = packUnorm4x8(vec4(outlineR, outlineG, outlineB, outlineA));
    uint glowPacked    = packUnorm4x8(vec4(glowR,    glowG,    glowB,    glowA));
    uint shadowPacked  = packUnorm4x8(vec4(shadowR,  shadowG,  shadowB,  shadowA_));
    uint shadowOffsetPacked = packHalf2x16(vec2(shadowOffX, shadowOffY));

    ep.effects1 = vec4(
        uintBitsToFloat(outlinePacked),
        uintBitsToFloat(glowPacked),
        uintBitsToFloat(shadowPacked),
        uintBitsToFloat(shadowOffsetPacked)
    );
    ep.effects2 = vec4(outlineWidth, glowRadius, shadowBlur, 0.0);
    return ep;
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Text td = texts[row];

    float x = t.x;
    float y = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float textWidth  = td.width;
    float textHeight = td.height;
    uint glyphCount  = td.charCountFontId & 0xFFFFu;
    if (glyphCount == 0u || textWidth <= 0.0 || textHeight <= 0.0) return;

    float rotation = t.rotation;
    float scaleX   = t.scaleX;
    float scaleY   = t.scaleY;
    float cosRot = cos(rotation);
    float sinRot = sin(rotation);

    float pivotOffsetX = td.pivotOffsetX;
    float pivotOffsetY = td.pivotOffsetY;

    bool isScreenSpace     = isScreenSpaceLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Bounding box of the rotated text quad, relative to entity position.
    float minX = -pivotOffsetX * scaleX;
    float maxX = (textWidth - pivotOffsetX) * scaleX;
    float minY = -pivotOffsetY * scaleY;
    float maxY = (textHeight - pivotOffsetY) * scaleY;

    float c1x = minX * cosRot - minY * sinRot;
    float c1y = minX * sinRot + minY * cosRot;
    float c2x = maxX * cosRot - minY * sinRot;
    float c2y = maxX * sinRot + minY * cosRot;
    float c3x = maxX * cosRot - maxY * sinRot;
    float c3y = maxX * sinRot + maxY * cosRot;
    float c4x = minX * cosRot - maxY * sinRot;
    float c4y = minX * sinRot + maxY * cosRot;

    float minOffX = min(min(c1x, c2x), min(c3x, c4x));
    float maxOffX = max(max(c1x, c2x), max(c3x, c4x));
    float minOffY = min(min(c1y, c2y), min(c3y, c4y));
    float maxOffY = max(max(c1y, c2y), max(c3y, c4y));

    vec4 bounds = vec4(x + minOffX, y + minOffY, x + maxOffX, y + maxOffY);

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = true;
    if (!isScreenSpace) {
        float screenW = textWidth  * scaleX * CameraZoom;
        float screenH = textHeight * scaleY * CameraZoom;
        sizeOK = (screenW >= 0.5 || screenH >= 0.5);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    // Resolve flag bits: per-archetype tag bits (StaticFlags, e.g.
    // FLAG_UNLIT for the Unlit tag) + auto-MSDF (from fontLayer's SDF
    // bit).
    uint flags = StaticFlags;
    if ((td.fontLayer & FONT_LAYER_SDF_BIT) != 0u) {
        flags = flags | FLAG_MSDF;
    }
    uint fontLayerIdx = td.fontLayer & 0x7FFFFFFFu;

    // Canonical blend+material packing (bits 20-23 / 24-31), stored
    // bit-exact. The render shader reads it from `extraMeta.w`.
    uint materialId = readMaterialId(row);
    uint packedBlend = packRenderFlags(0u, false, false, false, BlendId, materialId);

    // Reserve a header output slot.
    uint outIdx = atomicAdd(args[4], 1u);

    // Pack the header. Layout MUST match TEXT_HEADER_FORMAT (8 vec4s,
    // 128 bytes) -- see `gfx/internal/gpu/types.tl:TEXT_HEADER_FORMAT`.
    EffectsPack ep = readEffectsPacked(row);

    TextHeaderOut h;
    h.posLayer       = vec4(x, y, z, layer);
    h.rotScaleFlags  = vec4(rotation, scaleX, scaleY, float(flags));
    h.color          = readColor(row);
    h.clipBounds     = readClipBounds(row);
    h.fontMeta       = vec4(float(fontLayerIdx), float(td.gpuStartIdx), float(glyphCount), textWidth);
    h.extraMeta      = vec4(textHeight, pivotOffsetX, pivotOffsetY, uintBitsToFloat(packedBlend));
    h.effects1       = ep.effects1;
    h.effects2       = ep.effects2;
    headersOut[outIdx] = h;

    // Forward material params per output instance.
    materialParamsOut[outIdx] = readMaterialParams(row);

    // Reserve a contiguous run of glyph output slots -- one atomicAdd
    // per entity instead of per glyph.
    uint glyphBase = atomicAdd(args[1], glyphCount);
    uint glyphStart = td.gpuStartIdx;
    for (uint i = 0u; i < glyphCount; i++) {
        VisibleGlyph vg;
        vg.headerIndex = outIdx;
        vg.glyphIndex  = glyphStart + i;
        visibleGlyphsOut[glyphBase + i] = vg;
    }
}
