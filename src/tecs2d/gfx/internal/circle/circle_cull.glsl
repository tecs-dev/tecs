// Circle culling compute shader -- renderer-owned shadow-column path.
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Each dispatch binds the source-
// component SSBOs for that archetype and reads them by archetype-row
// index (gl_GlobalInvocationID.x is the row-within-archetype, 0-based).
//
// Output buffers (CircleOutput, CircleShadowOutput,
// MaterialParamsOutput, IndirectArgs, ShadowIndirectArgs) are SHARED
// across all circle archetypes; the atomicAdd on the indirect counter
// gives a globally-unique output index for each visible entity.

// ---------- Shape-specific source SSBOs ----------

struct Std430Circle {
    // (radius, lineWidth) -- packed to match the BufferFormat's
    // single floatvec2 member. LÖVE 12 enforces struct field count
    // == BufferFormat member count.
    vec2 radiusLineWidth;
};
layout(std430) readonly buffer CircleInput {
    Std430Circle circles[];
};

struct Std430Occluder {
    vec2 heightAlpha;  // (height, alphaThreshold)
};
layout(std430) readonly buffer OccluderInput {
    Std430Occluder occluders[];
};

struct Std430LayoutBox {
    vec4 whOffsetXY;     // width, height, offsetX, offsetY
    vec4 originSrcPad;   // originX, originY, sourceComponentId(uint), _pad
};
layout(std430) readonly buffer LayoutBoxInput {
    Std430LayoutBox layoutBoxes[];
};

// ---------- Output buffers (shared across dispatches) ----------

struct CircleOut {
    vec4 posRadius;              // x, y, radius, packed flags (uint bits)
    vec4 color;
    vec4 depthLayerLineFlags;    // depth, layer, lineWidth, spare
    vec4 clipBounds;
};
// IndirectArgs (uint args[]) is declared in cull_common.glsl which is
// prepended by shaders.loadCullShader; we just use `args[]` directly.
layout(std430) writeonly buffer CircleOutput {
    CircleOut circlesOut[];
};
layout(std430) writeonly buffer CircleShadowOutput {
    CircleOut circlesShadowOut[];
};
layout(std430) buffer ShadowIndirectArgs {
    uint shadowArgs[];
};

uniform float ShadowMargin;

// ---------- Shape-specific component readers ----------

float readOccluderHeight(uint row) {
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        return occluders[row].heightAlpha.x;
    }
    return 0.0;
}

vec2 readLayoutBoxOffset(uint row) {
    if ((ComponentMask & COMP_LAYOUTBOX) != 0u) {
        return layoutBoxes[row].whOffsetXY.zw;
    }
    return vec2(0.0, 0.0);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    Std430Transform t = transforms[row];
    Std430Circle c = circles[row];

    float x = t.x;
    float y = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float scaleX = t.scaleX;
    float scaleY = t.scaleY;
    float uniformScale = (scaleX + scaleY) * 0.5;
    float r = c.radiusLineWidth.x * uniformScale;
    float lineWidth = c.radiusLineWidth.y;

    // StaticFlags carries per-archetype tag bits (e.g. FLAG_UNLIT from
    // the Unlit tag). Occluder presence is folded in below.
    uint flags = StaticFlags;
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        flags = flags | FLAG_OCCLUDER;
    }
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);

    // LayoutBox offset shifts the rendered position relative to the
    // Transform; UI circles use this to rebase from a top-left origin
    // (Transform.x/y at the layout box origin, offset + radius to
    // recenter at the circle's center). Non-UI circles have Transform
    // at the circle center already, so the shift only applies when
    // LayoutBox is actually on the archetype -- gating on COMP_LAYOUTBOX
    // matches the legacy `circle/sync.tl` behavior.
    if ((ComponentMask & COMP_LAYOUTBOX) != 0u) {
        vec2 layoutOffset = readLayoutBoxOffset(row);
        x += layoutOffset.x + r;
        y += layoutOffset.y + r;
    }

    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    float cullR = r;
    if ((flags & FLAG_OCCLUDER) != 0u) {
        cullR += ShadowMargin;
    }
    vec4 bounds = vec4(x - cullR, y - cullR, x + cullR, y + cullR);

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = (r > 0.0);
    if (!isScreenSpace) {
        sizeOK = sizeOK && (r * 2.0 * CameraZoom >= 1.0);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = y + r;
    float depth = computeDepth(layer, z, x, bottomY, row);

    if (isUnlitLayer(layer)) {
        flags = flags | FLAG_UNLIT;
    }

    uint materialId = readMaterialId(row);
    uint packed = packRenderFlags(flags, isScreenSpace, ignoresZoom, usesVirtualCoords, BlendId, materialId);

    float outX = x + pOff.x;
    float outY = y + pOff.y;

    CircleOut o;
    o.posRadius = vec4(outX, outY, r, uintBitsToFloat(packed));
    o.color = color;
    o.depthLayerLineFlags = vec4(depth, layer, lineWidth, 0.0);
    o.clipBounds = clip;

    circlesOut[outIdx] = o;

    // Forward material params per output instance.
    materialParamsOut[outIdx] = readMaterialParams(row);

    // Dual-write to shadow buffer if occluder.
    if ((flags & FLAG_OCCLUDER) != 0u) {
        uint shadowIdx = atomicAdd(shadowArgs[1], 1u);
        circlesShadowOut[shadowIdx].posRadius = o.posRadius;
        circlesShadowOut[shadowIdx].color = vec4(o.color.rgb, readOccluderHeight(row));
        circlesShadowOut[shadowIdx].depthLayerLineFlags = vec4(o.depthLayerLineFlags.xy, 0.0, 0.0);
        circlesShadowOut[shadowIdx].clipBounds = o.clipBounds;
    }
}
