// Arc culling compute shader — renderer-owned shadow-column path.
// Common code is prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Source-component SSBOs are bound
// directly; optional components fall back to dummy buffers gated by
// `ComponentMask`. Output `ArcData` matches the legacy render shader's
// expected layout — see `arc.glsl`.

// ---------- Source-component SSBOs ----------

struct Std430Transform {
    vec4 xyzLayer;       // x, y, z, layerFloat
    vec4 rotScalePad;    // rotation, scaleX, scaleY, _pad0
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

struct Std430Arc {
    float radiusX;
    float radiusY;
    float startAngle;
    float endAngle;
    float lineWidth;
};
layout(std430) readonly buffer ArcInput {
    Std430Arc arcsIn[];
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

struct Std430Pivot {
    vec4 xyPad;          // x, y, _pad, _pad
};
layout(std430) readonly buffer PivotInput {
    Std430Pivot pivots[];
};

// ---------- Output buffers ----------

struct ArcOut {
    vec4 posRadii;
    vec4 color;
    vec4 depthLayerLineFlags;
    vec4 angles;                 // startAngle, endAngle, rotation, pad
    vec4 clipBounds;
    vec4 pivot;                  // pivotX, pivotY, pad, screenSpaceAndMaterial
};
layout(std430) writeonly buffer ArcOutput {
    ArcOut arcsOut[];
};
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

// Canonical component-mask bits (shared across all shapes; 0x4 reserved).
const uint COMP_COLOR        = 0x1u;
const uint COMP_CLIPBOUNDS   = 0x2u;
const uint COMP_MATERIAL     = 0x10u;
const uint COMP_PIVOT        = 0x40u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
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

vec2 readPivot(uint row) {
    if ((ComponentMask & COMP_PIVOT) != 0u) {
        return pivots[row].xyPad.xy;
    }
    return vec2(0.5, 0.5);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Arc a = arcsIn[row];

    float x = t.xyzLayer.x;
    float y = t.xyzLayer.y;
    float z = t.xyzLayer.z;
    float layer = t.xyzLayer.w;
    if (!isCameraLayerVisible(layer)) return;

    float scaleX = t.rotScalePad.y;
    float scaleY = t.rotScalePad.z;
    float rotation = t.rotScalePad.x;

    // Pre-scale radii to mirror the legacy CPU-side scaling. Negative
    // scale produces invalid bounds; take the magnitude.
    float rx = a.radiusX * scaleX;
    float ry = a.radiusY * scaleY;
    if (rx < 0.0) rx = -rx;
    if (ry < 0.0) ry = -ry;
    float startAngle = a.startAngle;
    float endAngle = a.endAngle;
    float lineWidth = a.lineWidth;

    uint flags = StaticFlags;
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);
    vec2 pivot = readPivot(row);

    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Conservative bounding box from full-ellipse extents.
    float left = x - rx;
    float right = x + rx;
    float top = y - ry;
    float bottom = y + ry;

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (rx > 0.0) && (ry > 0.0) &&
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

        float screenW = rx * 2.0 * CameraZoom;
        float screenH = ry * 2.0 * CameraZoom;
        visible = (rx > 0.0) && (ry > 0.0) &&
                  (screenW >= 1.0 || screenH >= 1.0) &&
                  (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                  (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
    }

    if (!visible) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = y + ry;
    float depth = computeDepth(layer, z, x, bottomY, row);

    float outFlags = float(flags);
    if (isUnlitLayer(layer)) {
        outFlags = float(uint(outFlags) | 1u);  // FLAG_UNLIT = 0x1
    }

    float outX = x;
    float outY = y;
    if (!isScreenSpace) {
        vec2 parallax = getParallaxFactor(layer);
        outX += CameraPos.x * (1.0 - parallax.x);
        outY += CameraPos.y * (1.0 - parallax.y);
    }

    // pivot.w packs screen-space flags + materialId, matching the
    // legacy arc_cull.glsl encoding so the render shader keeps
    // working unchanged.
    uint screenSpaceFlags = encodeScreenSpaceFlagsUint(isScreenSpace, ignoresZoom, usesVirtualCoords);
    uint materialId = readMaterialId(row);
    float screenSpaceAndMaterial = float(screenSpaceFlags | (materialId << 8u));

    materialParamsOut[outIdx] = readMaterialParams(row);

    arcsOut[outIdx].posRadii = vec4(outX, outY, rx, ry);
    arcsOut[outIdx].color = color;
    arcsOut[outIdx].depthLayerLineFlags = vec4(depth, layer, lineWidth, outFlags);
    arcsOut[outIdx].angles = vec4(startAngle, endAngle, rotation, 0.0);
    arcsOut[outIdx].clipBounds = clip;
    arcsOut[outIdx].pivot = vec4(pivot.x, pivot.y, 0.0, screenSpaceAndMaterial);
}
