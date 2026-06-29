// Rectangle culling compute shader — renderer-owned shadow-column path.
// Common code is prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Each dispatch binds the source-
// component SSBOs for that archetype and reads them by archetype-row
// index (gl_GlobalInvocationID.x is the row-within-archetype, 0-based).
// Optional components are handled by `ComponentMask` — if a bit is
// clear the corresponding SSBO is bound to a zero-buffer, but the
// helper functions short-circuit to a hardcoded default.
//
// Output buffers (RectOutput, RectShadowOutput, MaterialParamsOutput,
// IndirectArgs, ShadowIndirectArgs) are SHARED across all rectangle
// archetypes; the atomicAdd on the indirect counter gives a globally
// unique output index for each visible entity.

// ---------- Source-component SSBOs ----------

struct Std430Transform {
    float x, y, z;
    int layerInt;
    float rotation, scaleX, scaleY;
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

struct Std430Rectangle {
    // LÖVE 12 BufferFormat requires struct field count == format member
    // count. The format is three individual floats, so the struct is too.
    float width;
    float height;
    float lineWidth;
};
layout(std430) readonly buffer RectangleInput {
    Std430Rectangle rectangles[];
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

struct Std430Occluder {
    vec2 heightAlpha;  // (height, alphaThreshold)
};
layout(std430) readonly buffer OccluderInput {
    Std430Occluder occluders[];
};

struct Std430Material {
    // (materialId-bits-as-float, p0, p1, p2). Use floatBitsToUint on
    // .x to recover the materialId.
    vec4 idP012;
    // (p3, _pad, _pad, _pad).
    vec4 p3Pad;
};
layout(std430) readonly buffer MaterialInput {
    Std430Material materials[];
};

struct Std430LayoutBox {
    vec4 whOffsetXY;     // width, height, offsetX, offsetY
    vec4 originSrcPad;   // originX, originY, sourceComponentId(uint), _pad
};
layout(std430) readonly buffer LayoutBoxInput {
    Std430LayoutBox layoutBoxes[];
};

struct Std430Pivot {
    vec4 xyPad;          // x, y, _pad, _pad
};
layout(std430) readonly buffer PivotInput {
    Std430Pivot pivots[];
};

struct Std430RoundedCorners {
    vec4 rxryPad;        // rx, ry, _pad, _pad
};
layout(std430) readonly buffer RoundedCornersInput {
    Std430RoundedCorners roundedCorners[];
};

// ---------- Output buffers (shared across dispatches) ----------
//
// IMPORTANT: This struct is shared with rectangle.glsl (the render
// shader). Field shape and packing must match rect_cull.glsl exactly.

struct RectOut {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a
    vec4 layerZRotLine; // layer, z, rotation, lineWidth
    vec4 cornerScale;   // rx, ry, scaleX, scaleY
    vec4 clipBounds;    // minX, minY, maxX, maxY
    uvec4 flags;        // flags, depth (as uint bits), pivotX (as uint bits), pivotY (as uint bits)
};
// IndirectArgs (uint args[]) is declared in cull_common.glsl which is
// prepended by shaders.loadCullShader; we just use `args[]` directly.
layout(std430) writeonly buffer RectOutput {
    RectOut rectsOut[];
};
layout(std430) writeonly buffer RectShadowOutput {
    RectOut rectsShadowOut[];
};
layout(std430) buffer ShadowIndirectArgs {
    uint shadowArgs[];
};
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

const uint COMP_COLOR           = 0x1u;
const uint COMP_CLIPBOUNDS      = 0x2u;
const uint COMP_OCCLUDER        = 0x8u;
const uint COMP_MATERIAL        = 0x10u;
const uint COMP_LAYOUTBOX       = 0x20u;
const uint COMP_PIVOT           = 0x40u;
const uint COMP_ROUNDEDCORNERS  = 0x80u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
uniform float ShadowMargin;
// BlendId is dispatch-uniform: every entity in this archetype shares
// the same blend mode (archetype identity = blend identity in this
// renderer). The host sets it from `blend.groupBy(archetype)` before
// each dispatch.
uniform uint BlendId;
// StaticFlags: per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag).
uniform uint StaticFlags;

// ---------- Existing flag constants ----------
const uint FLAG_FILLED = 0x2u;
const uint FLAG_OCCLUDER = 0x100u;

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
    return vec4(-3.4e38, -3.4e38, 3.4e38, 3.4e38);  // unbounded
}

float readOccluderHeight(uint row) {
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        return occluders[row].heightAlpha.x;
    }
    return 0.0;
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

vec2 readLayoutBoxOffset(uint row) {
    if ((ComponentMask & COMP_LAYOUTBOX) != 0u) {
        return layoutBoxes[row].whOffsetXY.zw;
    }
    return vec2(0.0, 0.0);
}

// Pivot fallback chain (matches legacy rectangle/sync.tl:279-298):
//   explicit Pivot component → LayoutBox origin → (0.5, 0.5).
vec2 readPivot(uint row) {
    if ((ComponentMask & COMP_PIVOT) != 0u) {
        return pivots[row].xyPad.xy;
    }
    if ((ComponentMask & COMP_LAYOUTBOX) != 0u) {
        return layoutBoxes[row].originSrcPad.xy;
    }
    return vec2(0.5, 0.5);
}

vec2 readRoundedCorners(uint row) {
    if ((ComponentMask & COMP_ROUNDEDCORNERS) != 0u) {
        return roundedCorners[row].rxryPad.xy;
    }
    return vec2(0.0, 0.0);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Rectangle rc = rectangles[row];

    float x = t.x;
    float y = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float rotation = t.rotation;
    float scaleX = t.scaleX;
    float scaleY = t.scaleY;

    float width = rc.width;
    float height = rc.height;
    float lineWidth = rc.lineWidth;

    // SDF math assumes non-negative half extents; legacy sync took the
    // magnitude of scaledWidth/scaledHeight (rectangle/sync.tl:206-211).
    float scaledW = width * scaleX;
    float scaledH = height * scaleY;
    if (scaledW < 0.0) scaledW = -scaledW;
    if (scaledH < 0.0) scaledH = -scaledH;

    // LayoutBox offset (rebases UI rectangles to a top-left origin).
    vec2 layoutOffset = readLayoutBoxOffset(row);
    x += layoutOffset.x;
    y += layoutOffset.y;

    // Build output flags. StaticFlags carries per-archetype tag bits;
    // FLAG_FILLED is set when lineWidth is 0 (legacy
    // rectangle/sync.tl:215).
    uint baseFlags = StaticFlags;
    if (lineWidth == 0.0) {
        baseFlags = baseFlags | FLAG_FILLED;
    }
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        baseFlags = baseFlags | FLAG_OCCLUDER;
    }

    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);
    vec2 pivot = readPivot(row);
    float pivotX = pivot.x;
    float pivotY = pivot.y;
    vec2 rxRy = readRoundedCorners(row);
    float rx = rxRy.x;
    float ry = rxRy.y;

    // Layer-class queries.
    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Compute rectangle center accounting for pivot. Transform position
    // sits at the pivot point; center is offset from it.
    float centerX = x + scaledW * (0.5 - pivotX);
    float centerY = y + scaledH * (0.5 - pivotY);

    // Conservative bounding box for rotated rectangle: half-diagonal
    // gives guaranteed coverage.
    float halfDiag = sqrt(scaledW * scaledW + scaledH * scaledH) * 0.5;

    // Expand culling bounds for occluders (raymarched shadows extend
    // beyond the entity).
    if ((baseFlags & FLAG_OCCLUDER) != 0u) {
        halfDiag += ShadowMargin;
    }

    float left = centerX - halfDiag;
    float top = centerY - halfDiag;
    float right = centerX + halfDiag;
    float bottom = centerY + halfDiag;

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (scaledW > 0.0) && (scaledH > 0.0) &&
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

        float screenW = scaledW * CameraZoom;
        float screenH = scaledH * CameraZoom;
        visible = (scaledW > 0.0) && (scaledH > 0.0) &&
                  (screenW >= 1.0 || screenH >= 1.0) &&
                  (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                  (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
    }

    if (!visible) return;

    uint outIdx = atomicAdd(args[1], 1u);

    // Apply parallax offset to output position (for rendering).
    float outX = x;
    float outY = y;
    if (!isScreenSpace) {
        vec2 parallax = getParallaxFactor(layer);
        outX += CameraPos.x * (1.0 - parallax.x);
        outY += CameraPos.y * (1.0 - parallax.y);
    }

    // Build output struct. posSize carries pre-scaled dimensions; the
    // scale lanes in cornerScale stay 1.0 because scale is already
    // baked in (matching legacy rect_cull.glsl:165).
    RectOut r;
    r.posSize = vec4(outX, outY, scaledW, scaledH);
    r.color = color;
    r.layerZRotLine = vec4(layer, z, rotation, lineWidth);
    r.cornerScale = vec4(rx, ry, 1.0, 1.0);
    r.clipBounds = clip;

    // Stable depth tie-breaker — use the archetype row index (matches
    // circle_cull.glsl:257; tie-breaker stability is
    // per-archetype, which is the same constraint the original code
    // had with global slot indices).
    float actualBottom = y + scaledH * (1.0 - pivotY);
    float depth = computeDepth(layer, z, x, actualBottom, row);

    uint outFlags = baseFlags;
    if (isUnlitLayer(layer)) {
        outFlags = outFlags | 1u;  // FLAG_UNLIT = 0x1
    }

    // Encode screen-space flags + blendId + materialId in the same
    // upper-bit packing as legacy rect_cull.glsl:179-185. blendId is
    // dispatch-uniform; materialId comes from the Material shadow.
    uint screenSpaceFlags = encodeScreenSpaceFlagsUint(isScreenSpace, ignoresZoom, usesVirtualCoords);
    uint materialId = readMaterialId(row);
    r.flags = uvec4(
        outFlags | screenSpaceFlags | (BlendId << 20u) | (materialId << 24u),
        floatBitsToUint(depth),
        floatBitsToUint(pivotX),
        floatBitsToUint(pivotY)
    );

    rectsOut[outIdx] = r;

    // Forward material params per output instance.
    materialParamsOut[outIdx] = readMaterialParams(row);

    // Dual-write to shadow buffer if occluder.
    if ((outFlags & FLAG_OCCLUDER) != 0u) {
        uint shadowIdx = atomicAdd(shadowArgs[1], 1u);
        rectsShadowOut[shadowIdx].posSize = r.posSize;
        rectsShadowOut[shadowIdx].color = vec4(r.color.rgb, readOccluderHeight(row));
        rectsShadowOut[shadowIdx].layerZRotLine = vec4(r.layerZRotLine.xyz, 0.0);
        rectsShadowOut[shadowIdx].cornerScale = r.cornerScale;
        rectsShadowOut[shadowIdx].clipBounds = r.clipBounds;
        rectsShadowOut[shadowIdx].flags = r.flags;
    }
}
