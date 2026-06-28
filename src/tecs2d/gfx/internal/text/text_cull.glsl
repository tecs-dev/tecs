// Text culling compute shader (renderer-owned shadow-column path).
// Common code is prepended from cull_common.glsl.
//
// One dispatch per text archetype. Each dispatch binds the source-
// component SSBOs (Transform, Text, plus optional Color, ClipBounds,
// RenderFlags, Material, TextEffects) and reads them by archetype-row
// index (gl_GlobalInvocationID.x = row-within-archetype, 0-based).
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

// ---------- Source-component SSBOs ----------
// std430 layouts mirror the cdefs in `gpu/std430.tl`. Padding fields
// are written as zero by the CPU translator and are read but unused.

struct Std430Transform {
    vec4 xyzLayer;       // x, y, z, layerFloat
    vec4 rotScalePad;    // rotation, scaleX, scaleY, _pad0
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

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

struct Std430Color {
    vec4 rgba;
};
layout(std430) readonly buffer ColorInput {
    Std430Color colors[];
};

struct Std430ClipBounds {
    vec4 minMaxXY;       // minX, minY, maxX, maxY
};
layout(std430) readonly buffer ClipBoundsInput {
    Std430ClipBounds clipBounds[];
};

struct Std430Material {
    vec4 idP012;          // (materialId-bits-as-float, p0, p1, p2)
    vec4 p3Pad;           // (p3, _pad, _pad, _pad)
};
layout(std430) readonly buffer MaterialInput {
    Std430Material materials[];
};

// TextEffects: 17 floats grouped into 4 vec4 + 1 trailing float to
// match the BufferFormat declared in std430.tl.
struct Std430TextEffects {
    vec4 outlineWRGB;     // outlineWidth, outlineR, outlineG, outlineB
    vec4 oAGlowRRG;       // outlineA, glowRadius, glowR, glowG
    vec4 glowBAShadowXY;  // glowB, glowA, shadowOffsetX, shadowOffsetY
    vec4 shBRGB;          // shadowBlur, shadowR, shadowG, shadowB
    float shadowA;
};
layout(std430) readonly buffer TextEffectsInput {
    Std430TextEffects effects[];
};

// ---------- Output buffers (shared across dispatches) ----------

// Mirrors the legacy TEXT_HEADER_FORMAT (128 bytes, 8 vec4 lanes).
// Field layout is preserved bit-identical so the existing text render
// shader can consume either source during the migration.
struct TextHeaderOut {
    vec4 posLayer;       // x, y, z, layer
    vec4 rotScaleFlags;  // rotation, scaleX, scaleY, flags
    vec4 color;          // r, g, b, a
    vec4 clipBounds;     // minX, minY, maxX, maxY
    vec4 fontMeta;       // fontLayer, glyphStartIdx, glyphCount, textWidth
    vec4 extraMeta;      // textHeight, pivotOffsetX, pivotOffsetY, blendId
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

layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

// Canonical bits — must match modifier_binding.MASK (gpu/modifier_binding.tl).
const uint COMP_COLOR        = 0x01u;
const uint COMP_CLIPBOUNDS   = 0x02u;
const uint COMP_MATERIAL     = 0x10u;
const uint COMP_TEXTEFFECTS  = 0x800u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
// BlendId is dispatch-uniform: every entity in this archetype shares
// the same blend mode. The host sets it from `blend.groupBy(archetype)`
// before each dispatch.
uniform uint BlendId;
// StaticFlags: per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag).
uniform uint StaticFlags;

// ---------- Existing flag constants ----------
const uint FLAG_MSDF = 0x10u;
const uint FONT_LAYER_SDF_BIT = 0x80000000u;

// ---------- Helpers for optional components ----------

vec4 readColor(uint row) {
    if ((ComponentMask & COMP_COLOR) != 0u) {
        return colors[row].rgba;
    }
    return vec4(1.0, 1.0, 1.0, 1.0);
}

vec4 readClipBounds(uint row) {
    if ((ComponentMask & COMP_CLIPBOUNDS) != 0u) {
        return clipBounds[row].minMaxXY;
    }
    return vec4(-3.4e38, -3.4e38, 3.4e38, 3.4e38);
}

uint readMaterialId(uint row) {
    if ((ComponentMask & COMP_MATERIAL) != 0u) {
        return floatBitsToUint(materials[row].idP012.x);
    }
    return 0u;
}

vec4 readMaterialParams(uint row) {
    if ((ComponentMask & COMP_MATERIAL) != 0u) {
        Std430Material m = materials[row];
        return vec4(m.idP012.y, m.idP012.z, m.idP012.w, m.p3Pad.x);
    }
    return vec4(0.0);
}

// Effects-vec packers. Mirror the CPU side's packUnorm4x8 / packHalf2x16
// flow so the render shader can decode identically regardless of which
// path produced the header.
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
    float outlineWidth = e.outlineWRGB.x;
    float outlineR     = e.outlineWRGB.y;
    float outlineG     = e.outlineWRGB.z;
    float outlineB     = e.outlineWRGB.w;
    float outlineA     = e.oAGlowRRG.x;
    float glowRadius   = e.oAGlowRRG.y;
    float glowR        = e.oAGlowRRG.z;
    float glowG        = e.oAGlowRRG.w;
    float glowB        = e.glowBAShadowXY.x;
    float glowA        = e.glowBAShadowXY.y;
    float shadowOffX   = e.glowBAShadowXY.z;
    float shadowOffY   = e.glowBAShadowXY.w;
    float shadowBlur   = e.shBRGB.x;
    float shadowR      = e.shBRGB.y;
    float shadowG      = e.shBRGB.z;
    float shadowB      = e.shBRGB.w;
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

    float x = t.xyzLayer.x;
    float y = t.xyzLayer.y;
    float z = t.xyzLayer.z;
    float layer = t.xyzLayer.w;
    if (!isCameraLayerVisible(layer)) return;

    float textWidth  = td.width;
    float textHeight = td.height;
    uint glyphCount  = td.charCountFontId & 0xFFFFu;
    if (glyphCount == 0u || textWidth <= 0.0 || textHeight <= 0.0) return;

    float rotation = t.rotScalePad.x;
    float scaleX   = t.rotScalePad.y;
    float scaleY   = t.rotScalePad.z;
    float cosRot = cos(rotation);
    float sinRot = sin(rotation);

    float pivotOffsetX = td.pivotOffsetX;
    float pivotOffsetY = td.pivotOffsetY;

    bool isScreenSpace     = isScreenSpaceLayer(layer);
    bool ignoresZoom       = isIgnoreZoomLayer(layer);
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

    float left   = x + minOffX;
    float right  = x + maxOffX;
    float top    = y + minOffY;
    float bottom = y + maxOffY;

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (right > 0.0) && (left < cullSize.x)
               && (bottom > 0.0) && (top < cullSize.y);
    } else {
        vec2 parallax = getParallaxFactor(layer);
        float parallaxOffsetX = CameraPos.x * (1.0 - parallax.x);
        float parallaxOffsetY = CameraPos.y * (1.0 - parallax.y);
        float adjLeft   = left   + parallaxOffsetX;
        float adjRight  = right  + parallaxOffsetX;
        float adjTop    = top    + parallaxOffsetY;
        float adjBottom = bottom + parallaxOffsetY;

        float screenW = textWidth  * scaleX * CameraZoom;
        float screenH = textHeight * scaleY * CameraZoom;
        if (screenW < 0.5 && screenH < 0.5) {
            visible = false;
        } else {
            visible = (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z)
                   && (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
        }
    }

    if (!visible) return;

    // Resolve flag bits: per-archetype tag bits (StaticFlags, e.g.
    // FLAG_UNLIT for the Unlit tag) + auto-MSDF (from fontLayer's SDF
    // bit). Match the slot path's `sync.tl:initEntityGlyphs` flag
    // pipeline so the render shader sees the same flag set regardless
    // of which cull path produced the header.
    uint flags = StaticFlags;
    if ((td.fontLayer & FONT_LAYER_SDF_BIT) != 0u) {
        flags = flags | FLAG_MSDF;
    }
    uint fontLayerIdx = td.fontLayer & 0x7FFFFFFFu;

    // Pack blendId+materialId the same way the slot path does (bits 0-3
    // = blendId, bits 4-11 = materialId). The render shader reads the
    // packed value from `extraMeta.w`.
    uint materialId = readMaterialId(row);
    float packedBlend = float(BlendId + materialId * 16u);

    // Reserve a header output slot.
    uint outIdx = atomicAdd(args[4], 1u);

    // Pack the header. Layout MUST match TEXT_HEADER_FORMAT (8 vec4s,
    // 128 bytes) — see `gfx/internal/gpu/types.tl:TEXT_HEADER_FORMAT`
    // and the legacy `text/sync.tl` writer.
    EffectsPack ep = readEffectsPacked(row);

    TextHeaderOut h;
    h.posLayer       = vec4(x, y, z, layer);
    h.rotScaleFlags  = vec4(rotation, scaleX, scaleY, float(flags));
    h.color          = readColor(row);
    h.clipBounds     = readClipBounds(row);
    h.fontMeta       = vec4(float(fontLayerIdx), float(td.gpuStartIdx), float(glyphCount), textWidth);
    h.extraMeta      = vec4(textHeight, pivotOffsetX, pivotOffsetY, packedBlend);
    h.effects1       = ep.effects1;
    h.effects2       = ep.effects2;
    headersOut[outIdx] = h;

    // Forward material params per output instance.
    materialParamsOut[outIdx] = readMaterialParams(row);

    // Reserve a contiguous run of glyph output slots — one atomicAdd
    // per entity instead of per glyph. Mirrors the slot path's batch
    // reservation in `text_cull.glsl:atomicAdd(args[1], glyphCount)`.
    uint glyphBase = atomicAdd(args[1], glyphCount);
    uint glyphStart = td.gpuStartIdx;
    for (uint i = 0u; i < glyphCount; i++) {
        VisibleGlyph vg;
        vg.headerIndex = outIdx;
        vg.glyphIndex  = glyphStart + i;
        visibleGlyphsOut[glyphBase + i] = vg;
    }
}
