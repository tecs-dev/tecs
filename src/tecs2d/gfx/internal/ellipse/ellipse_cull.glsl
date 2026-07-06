// Ellipse culling compute shader -- renderer-owned shadow-column path.
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Source-component SSBOs are bound
// directly; optional components fall back to dummy buffers gated by
// `ComponentMask`. Output `EllipseData` matches the render shader's
// expected layout -- see `ellipse.glsl`.
//
// Ellipse blend modes route through per-blend batch buffers (see
// shape_utils renderGBufferBlend), not in-shader blend filtering, so
// the packed flags carry blend id 0.

// ---------- Shape-specific source SSBOs ----------

struct Std430Ellipse {
    float radiusX;
    float radiusY;
    float lineWidth;
};
layout(std430) readonly buffer EllipseInput {
    Std430Ellipse ellipsesIn[];
};

struct Std430Pivot {
    vec4 xyPad;          // x, y, _pad, _pad
};
layout(std430) readonly buffer PivotInput {
    Std430Pivot pivots[];
};

// ---------- Output buffers ----------

struct EllipseOut {
    vec4 posRadii;
    vec4 color;
    vec4 depthLayerLineFlags;    // depth, layer, lineWidth, spare
    vec4 clipBounds;
    vec4 pivot;                  // pivotX, pivotY, rotation, packed flags (uint bits)
};
layout(std430) writeonly buffer EllipseOutput {
    EllipseOut ellipsesOut[];
};

// ---------- Shape-specific component readers ----------

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
    Std430Ellipse e = ellipsesIn[row];

    float x = t.x;
    float y = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float scaleX = t.scaleX;
    float scaleY = t.scaleY;
    float rotation = t.rotation;

    // Pre-scale radii to mirror the legacy CPU-side scaling. Negative
    // scale produces invalid bounds; take the magnitude.
    float rx = e.radiusX * scaleX;
    float ry = e.radiusY * scaleY;
    if (rx < 0.0) rx = -rx;
    if (ry < 0.0) ry = -ry;
    float lineWidth = e.lineWidth;

    uint flags = StaticFlags;
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);
    vec2 pivot = readPivot(row);

    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Conservative bounding circle = max(rx, ry).
    float maxRadius = max(rx, ry);
    vec4 bounds = vec4(x - maxRadius, y - maxRadius, x + maxRadius, y + maxRadius);

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = (rx > 0.0) && (ry > 0.0);
    if (!isScreenSpace) {
        sizeOK = sizeOK && (rx * 2.0 * CameraZoom >= 1.0 || ry * 2.0 * CameraZoom >= 1.0);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = y + ry;
    float depth = computeDepth(layer, z, x, bottomY, row);

    if (isUnlitLayer(layer)) {
        flags = flags | FLAG_UNLIT;
    }

    uint materialId = readMaterialId(row);
    uint packed = packRenderFlags(flags, isScreenSpace, ignoresZoom, usesVirtualCoords, 0u, materialId);

    float outX = x + pOff.x;
    float outY = y + pOff.y;

    materialParamsOut[outIdx] = readMaterialParams(row);

    ellipsesOut[outIdx].posRadii = vec4(outX, outY, rx, ry);
    ellipsesOut[outIdx].color = color;
    ellipsesOut[outIdx].depthLayerLineFlags = vec4(depth, layer, lineWidth, 0.0);
    ellipsesOut[outIdx].clipBounds = clip;
    ellipsesOut[outIdx].pivot = vec4(pivot.x, pivot.y, rotation, uintBitsToFloat(packed));
}
