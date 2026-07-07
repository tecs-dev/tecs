// Line culling compute shader -- renderer-owned shadow-column path.
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Source-component SSBOs are bound
// directly; optional components fall back to dummy buffers gated by
// `ComponentMask`. Output `LineData` matches the render shader's
// expected layout -- see `line.glsl`.

// ---------- Shape-specific source SSBOs ----------

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

// ---------- Output buffers ----------
//
// IMPORTANT: This struct must match `LineData` declared in `line.glsl`
// (the render shader).

struct LineOut {
    vec4 points;                 // x1, y1, x2, y2
    vec4 color;                  // r, g, b, a
    vec4 depthLayerLineFlags;    // depth, layer, lineWidth, packed flags (uint bits)
    vec4 centerRot;              // centerX, centerY, rotation, pad
    vec4 clipBounds;             // minX, minY, maxX, maxY
};
layout(std430) writeonly buffer LineOutput {
    LineOut linesOut[];
};

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Line ln = linesIn[row];

    float tx = t.x;
    float ty = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float rotation = t.rotation;
    float scaleX = t.scaleX;
    float scaleY = t.scaleY;

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

    // Line length for sub-pixel culling and rotated bounds.
    float dx = x2 - x1;
    float dy = y2 - y1;
    float lineLen = sqrt(dx * dx + dy * dy);

    // Compute bounding box for line (include line width for thickness).
    // The render shader rotates the endpoints around the segment
    // midpoint, so a rotated line needs a bounding circle around the
    // midpoint; the tight endpoint AABB only holds when unrotated.
    float halfWidth = lineWidth * 0.5;
    vec4 bounds;
    if (rotation != 0.0) {
        float midX = (x1 + x2) * 0.5;
        float midY = (y1 + y2) * 0.5;
        float reach = lineLen * 0.5 + halfWidth;
        bounds = vec4(midX - reach, midY - reach, midX + reach, midY + reach);
    } else {
        bounds = vec4(
            min(x1, x2) - halfWidth, min(y1, y2) - halfWidth,
            max(x1, x2) + halfWidth, max(y1, y2) + halfWidth
        );
    }

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = (lineLen > 0.0 || lineWidth > 0.0);
    if (!isScreenSpace) {
        sizeOK = sizeOK && (max(lineLen, lineWidth) * CameraZoom >= 1.0);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = max(y1, y2);
    float preCenterX = (x1 + x2) * 0.5;
    float depth = computeDepth(layer, z, preCenterX, bottomY, row);

    uint outFlags = baseFlags;
    if (isUnlitLayer(layer)) {
        outFlags = outFlags | FLAG_UNLIT;
    }

    uint materialId = readMaterialId(row);
    uint packed = packRenderFlags(outFlags, isScreenSpace, ignoresZoom, usesVirtualCoords, BlendId, materialId);

    // Apply parallax offset to output endpoints (for rendering).
    float outX1 = x1 + pOff.x;
    float outY1 = y1 + pOff.y;
    float outX2 = x2 + pOff.x;
    float outY2 = y2 + pOff.y;

    float centerX = (outX1 + outX2) * 0.5;
    float centerY = (outY1 + outY2) * 0.5;

    materialParamsOut[outIdx] = readMaterialParams(row);

    linesOut[outIdx].points = vec4(outX1, outY1, outX2, outY2);
    linesOut[outIdx].color = color;
    linesOut[outIdx].depthLayerLineFlags = vec4(depth, layer, lineWidth, uintBitsToFloat(packed));
    linesOut[outIdx].centerRot = vec4(centerX, centerY, rotation, 0.0);
    linesOut[outIdx].clipBounds = clip;
}
