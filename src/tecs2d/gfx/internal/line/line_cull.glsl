// Line culling compute shader — renderer-owned shadow-column path.
// Common code is prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Source-component SSBOs are bound
// directly; optional components fall back to dummy buffers gated by
// `ComponentMask`. Output `LineData` matches the legacy render shader's
// expected layout — see `line.glsl`.

// ---------- Source-component SSBOs ----------

struct Std430Transform {
    vec4 xyzLayer;       // x, y, z, layerFloat
    vec4 rotScalePad;    // rotation, scaleX, scaleY, _pad0
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

struct Std430Line {
    float x1;
    float y1;
    float x2;
    float y2;
    float width;
};
layout(std430) readonly buffer LineInput {
    Std430Line linesIn[];
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
    Std430ClipBounds clipBoundsArr[];
};

struct Std430Material {
    vec4 idP012;
    vec4 p3Pad;
};
layout(std430) readonly buffer MaterialInput {
    Std430Material materials[];
};

// ---------- Output buffers ----------
//
// IMPORTANT: This struct must match `LineData` declared in `line.glsl`
// (the render shader). Field shape and packing must match the legacy
// `line_cull.glsl` exactly so the existing render shader keeps working
// unchanged.

struct LineOut {
    vec4 points;                 // x1, y1, x2, y2
    vec4 color;                  // r, g, b, a
    vec4 depthLayerLineFlags;    // depth, layer, lineWidth, flags (as float)
    vec4 centerRot;              // centerX, centerY, rotation, screenSpaceFlags
    vec4 clipBounds;             // minX, minY, maxX, maxY
};
layout(std430) writeonly buffer LineOutput {
    LineOut linesOut[];
};
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

// Canonical component-mask bits (shared across all shapes; 0x4 reserved).
const uint COMP_COLOR        = 0x1u;
const uint COMP_CLIPBOUNDS   = 0x2u;
const uint COMP_MATERIAL     = 0x10u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
// BlendId is dispatch-uniform: every entity in this archetype shares
// the same blend mode (archetype identity = blend identity in this
// renderer). The host sets it from `blend.groupBy(archetype)` before
// each dispatch.
uniform uint BlendId;
// StaticFlags: per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag).
uniform uint StaticFlags;

// ---------- Helpers ----------

vec4 readColor(uint row) {
    if ((ComponentMask & COMP_COLOR) != 0u) {
        return colors[row].rgba;
    }
    return vec4(1.0, 1.0, 1.0, 1.0);
}

vec4 readClipBounds(uint row) {
    if ((ComponentMask & COMP_CLIPBOUNDS) != 0u) {
        return clipBoundsArr[row].minMaxXY;
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

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Line ln = linesIn[row];

    float tx = t.xyzLayer.x;
    float ty = t.xyzLayer.y;
    float z = t.xyzLayer.z;
    float layer = t.xyzLayer.w;
    if (!isCameraLayerVisible(layer)) return;

    float rotation = t.rotScalePad.x;
    float scaleX = t.rotScalePad.y;
    float scaleY = t.rotScalePad.z;

    // World endpoints: entity position + local endpoint * scale.
    // Mirrors the legacy CPU sync (line/sync.tl:177-180).
    float x1 = tx + ln.x1 * scaleX;
    float y1 = ty + ln.y1 * scaleY;
    float x2 = tx + ln.x2 * scaleX;
    float y2 = ty + ln.y2 * scaleY;

    float lineWidth = ln.width;

    uint baseFlags = StaticFlags;
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);

    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Compute bounding box for line (include line width for thickness).
    float halfWidth = lineWidth * 0.5;
    float left = min(x1, x2) - halfWidth;
    float right = max(x1, x2) + halfWidth;
    float top = min(y1, y2) - halfWidth;
    float bottom = max(y1, y2) + halfWidth;

    // Line length for sub-pixel culling.
    float dx = x2 - x1;
    float dy = y2 - y1;
    float lineLen = sqrt(dx * dx + dy * dy);

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (lineLen > 0.0 || lineWidth > 0.0) &&
                  (right > 0.0) && (left < cullSize.x) &&
                  (bottom > 0.0) && (top < cullSize.y);
    } else {
        vec2 parallax = getParallaxFactor(layer);
        float parallaxOffsetX = CameraPos.x * (1.0 - parallax.x);
        float parallaxOffsetY = CameraPos.y * (1.0 - parallax.y);
        float adjLeft = left + parallaxOffsetX;
        float adjRight = right + parallaxOffsetX;
        float adjTop = top + parallaxOffsetY;
        float adjBottom = bottom + parallaxOffsetY;

        float screenLength = max(lineLen, lineWidth) * CameraZoom;
        visible = (lineLen > 0.0 || lineWidth > 0.0) &&
                  (screenLength >= 1.0) &&
                  (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                  (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
    }

    if (!visible) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = max(y1, y2);
    float preCenterX = (x1 + x2) * 0.5;
    float depth = computeDepth(layer, z, preCenterX, bottomY, row);

    uint outFlags = baseFlags;
    if (isUnlitLayer(layer)) {
        outFlags = outFlags | 1u;  // FLAG_UNLIT = 0x1
    }
    // Encode blendId in bits 20-23, materialId in bits 24-31 — matches
    // legacy line_cull.glsl encoding so the render shader keeps working.
    uint materialId = readMaterialId(row);
    outFlags = outFlags | (BlendId << 20u) | (materialId << 24u);

    // Apply parallax offset to output endpoints (for rendering).
    float outX1 = x1;
    float outY1 = y1;
    float outX2 = x2;
    float outY2 = y2;
    if (!isScreenSpace) {
        vec2 parallax = getParallaxFactor(layer);
        float offsetX = CameraPos.x * (1.0 - parallax.x);
        float offsetY = CameraPos.y * (1.0 - parallax.y);
        outX1 += offsetX;
        outY1 += offsetY;
        outX2 += offsetX;
        outY2 += offsetY;
    }

    float centerX = (outX1 + outX2) * 0.5;
    float centerY = (outY1 + outY2) * 0.5;

    // centerRot.w carries screen-space encoding (1.0/2.0/4.0 bitmask)
    // — render shader reads it the same way.
    float screenSpaceFlag = encodeScreenSpaceFlags(isScreenSpace, ignoresZoom, usesVirtualCoords);

    materialParamsOut[outIdx] = readMaterialParams(row);

    linesOut[outIdx].points = vec4(outX1, outY1, outX2, outY2);
    linesOut[outIdx].color = color;
    linesOut[outIdx].depthLayerLineFlags = vec4(depth, layer, lineWidth, float(outFlags));
    linesOut[outIdx].centerRot = vec4(centerX, centerY, rotation, screenSpaceFlag);
    linesOut[outIdx].clipBounds = clip;
}
