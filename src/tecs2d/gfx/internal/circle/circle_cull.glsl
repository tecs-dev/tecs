// Circle culling compute shader -- renderer-owned shadow-column path.
// Common code is prepended from cull_common.glsl.
//
// One dispatch per (archetype, shape). Each dispatch binds the source-
// component SSBOs for that archetype and reads them by archetype-row
// index (gl_GlobalInvocationID.x is the row-within-archetype, 0-based).
// Optional components are handled by `ComponentMask` -- if a bit is
// clear the corresponding SSBO is bound to a zero-buffer (or its
// reads are guarded by the bit), so layout-uniform branches stay
// dispatch-uniform and the GPU treats them as free.
//
// Output buffers (CircleOutput, CircleShadowOutput,
// MaterialParamsOutput, IndirectArgs, ShadowIndirectArgs) are SHARED
// across all circle archetypes; the atomicAdd on the indirect counter
// gives a globally-unique output index for each visible entity.

// ---------- Source-component SSBOs ----------
// std430 layouts mirror the cdefs in `gpu/std430.tl`. Padding fields
// are written as zero by the CPU translator and are read but unused.

struct Std430Transform {
    float x, y, z;
    int layerInt;
    float rotation, scaleX, scaleY;
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

struct Std430Circle {
    // (radius, lineWidth) -- packed to match the BufferFormat's
    // single floatvec2 member. LÖVE 12 enforces struct field count
    // == BufferFormat member count.
    vec2 radiusLineWidth;
};
layout(std430) readonly buffer CircleInput {
    Std430Circle circles[];
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

// ---------- Output buffers (shared across dispatches) ----------

struct CircleOut {
    vec4 posRadius;
    vec4 color;
    vec4 depthLayerLineFlags;    // depth, layer, lineWidth, flags (as float)
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
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

const uint COMP_COLOR        = 0x1u;
const uint COMP_CLIPBOUNDS   = 0x2u;
const uint COMP_OCCLUDER     = 0x8u;
const uint COMP_MATERIAL     = 0x10u;
const uint COMP_LAYOUTBOX    = 0x20u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
uniform float ShadowMargin;
// BlendId is dispatch-uniform: every entity in this archetype shares
// the same blend mode (archetype identity = blend identity in this
// renderer). The host sets it from `blend.groupBy(archetype)` before
// each dispatch.
uniform uint BlendId;
// StaticFlags is a per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag). The host computes it in
// shadow_dispatch from the descriptor's tagFlags list.
uniform uint StaticFlags;

// ---------- Existing flag constants ----------
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
    float left = x - cullR;
    float right = x + cullR;
    float top = y - cullR;
    float bottom = y + cullR;

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (r > 0.0) &&
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

        float screenSize = r * 2.0 * CameraZoom;
        visible = (r > 0.0) &&
                  (screenSize >= 1.0) &&
                  (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                  (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
    }

    if (!visible) return;

    uint outIdx = atomicAdd(args[1], 1u);

    float bottomY = y + r;
    float depth = computeDepth(layer, z, x, bottomY, row);

    float outFlags = float(flags);
    if (isUnlitLayer(layer)) {
        outFlags = float(uint(outFlags) | 1u);  // FLAG_UNLIT = 0x1
    }

    // The legacy cull shader receives blendId+materialId pre-packed via
    // the metadata buffer. In the shadow path, blendId is dispatch-
    // uniform (BlendId uniform, set per archetype by the host) and
    // materialId comes from the Material shadow per row.
    uint materialId = readMaterialId(row);
    uint screenSpaceFlags = encodeScreenSpaceFlagsUint(isScreenSpace, ignoresZoom, usesVirtualCoords);
    float screenSpaceAndBlend = float(screenSpaceFlags | (BlendId << 4u) | (materialId << 8u));

    float outX = x;
    float outY = y;
    if (!isScreenSpace) {
        vec2 parallax = getParallaxFactor(layer);
        outX += CameraPos.x * (1.0 - parallax.x);
        outY += CameraPos.y * (1.0 - parallax.y);
    }

    CircleOut o;
    o.posRadius = vec4(outX, outY, r, screenSpaceAndBlend);
    o.color = color;
    o.depthLayerLineFlags = vec4(depth, layer, lineWidth, outFlags);
    o.clipBounds = clip;

    circlesOut[outIdx] = o;

    // Forward material params per output instance.
    materialParamsOut[outIdx] = readMaterialParams(row);

    // Dual-write to shadow buffer if occluder.
    if ((flags & FLAG_OCCLUDER) != 0u) {
        uint shadowIdx = atomicAdd(shadowArgs[1], 1u);
        circlesShadowOut[shadowIdx].posRadius = o.posRadius;
        circlesShadowOut[shadowIdx].color = vec4(o.color.rgb, readOccluderHeight(row));
        circlesShadowOut[shadowIdx].depthLayerLineFlags = vec4(o.depthLayerLineFlags.xy, 0.0, o.depthLayerLineFlags.w);
        circlesShadowOut[shadowIdx].clipBounds = o.clipBounds;
    }
}
