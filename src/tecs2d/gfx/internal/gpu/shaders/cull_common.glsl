// Common uniforms and functions for all cull shaders
// This file is prepended to shape-specific cull shaders
// Layer checks, sort modes, and computeDepth are provided by depth_common.glsl

#pragma language glsl4

layout(local_size_x = 256) in;

layout(std430) buffer IndirectArgs {
    uint args[];
};

// Camera and cull parameters (uploaded once per frame, shared across all cull dispatches)
// Fields are flat vec4/uvec4 to match LOVE2D buffer format entries 1:1.
struct CullParamsData {
    vec4 _cullViewport;
    vec4 _cullCamZoom;
    vec4 _cullDepthVirtual;
    vec4 _cullScreenPad;
    uvec4 _cullMasks;
    vec4 _px0; vec4 _px1; vec4 _px2; vec4 _px3;
    vec4 _py0; vec4 _py1; vec4 _py2; vec4 _py3;
    vec4 _sm0; vec4 _sm1; vec4 _sm2; vec4 _sm3;
};

layout(std430) readonly buffer CullParams {
    CullParamsData _cullParams[];
};

// Camera macros
#define CameraViewport _cullParams[0]._cullViewport
#define CameraPos _cullParams[0]._cullCamZoom.xy
#define CameraZoom _cullParams[0]._cullCamZoom.z
#define MaxLayer _cullParams[0]._cullCamZoom.w
#define MaxZ _cullParams[0]._cullDepthVirtual.x
#define MaxY _cullParams[0]._cullDepthVirtual.y
#define VirtualSize _cullParams[0]._cullDepthVirtual.zw
#define ScreenSize _cullParams[0]._cullScreenPad.xy
#define CameraLayerMask floatBitsToUint(_cullParams[0]._cullScreenPad.z)
#define ScreenSpaceMask _cullParams[0]._cullMasks.x
#define IgnoreZoomMask _cullParams[0]._cullMasks.y
#define VirtualCoordsMask _cullParams[0]._cullMasks.z
#define UnlitMask _cullParams[0]._cullMasks.w
#define ParallaxX mat4(_cullParams[0]._px0, _cullParams[0]._px1, _cullParams[0]._px2, _cullParams[0]._px3)
#define ParallaxY mat4(_cullParams[0]._py0, _cullParams[0]._py1, _cullParams[0]._py2, _cullParams[0]._py3)
#define SortModes mat4(_cullParams[0]._sm0, _cullParams[0]._sm1, _cullParams[0]._sm2, _cullParams[0]._sm3)

// Check if a layer is visible to the current camera (bit N-1 = layer N)
bool isCameraLayerVisible(float layer) {
    uint layerIdx = uint(layer) - 1u;
    return ((CameraLayerMask >> layerIdx) & 1u) == 1u;
}

// Get parallax factors for a layer (mat4 stores 16 values: col*4+row = layer-1)
vec2 getParallaxFactor(float layer) {
    int idx = int(layer) - 1;
    int col = idx / 4;
    int row = idx % 4;
    mat4 px = ParallaxX;
    mat4 py = ParallaxY;
    return vec2(px[col][row], py[col][row]);
}

// Get the cull bounds for screen-space layers based on virtualCoords setting
vec2 getScreenSpaceCullSize(bool usesVirtualCoords) {
    return usesVirtualCoords ? VirtualSize : ScreenSize;
}

// Encode screen-space flags as uint for shaders that use integer flags
// Returns: bit 16 = screenSpace, bit 17 = ignoreZoom, bit 18 = virtualCoords
uint encodeScreenSpaceFlagsUint(bool isScreenSpace, bool ignoresZoom, bool usesVirtualCoords) {
    return (isScreenSpace ? 0x10000u : 0u) | (ignoresZoom ? 0x20000u : 0u) | (usesVirtualCoords ? 0x40000u : 0u);
}

// ---------- Shared source-component SSBOs ----------
// std430 layouts mirror the cdefs in gpu/std430.tl. Every shape cull
// binds Transform plus these optional components; when a component is
// absent from the archetype the host binds a dummy buffer and leaves
// the ComponentMask bit clear, so the reads stay dispatch-uniform.

struct Std430Transform {
    float x, y, z;
    int layerInt;
    float rotation, scaleX, scaleY;
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
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
    Std430ClipBounds clipBoundsIn[];
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

// Per-visible-instance material params, written in output order.
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------
// Canonical bits; must match modifier_binding.MASK (gpu/modifier_binding.tl).
const uint COMP_COLOR          = 0x1u;
const uint COMP_CLIPBOUNDS     = 0x2u;
const uint COMP_OCCLUDER       = 0x8u;
const uint COMP_MATERIAL       = 0x10u;
const uint COMP_LAYOUTBOX      = 0x20u;
const uint COMP_PIVOT          = 0x40u;
const uint COMP_ROUNDEDCORNERS = 0x80u;
const uint COMP_DROPSHADOW     = 0x100u;
const uint COMP_REPEATEDSPRITE = 0x200u;
const uint COMP_SPRITEDATA     = 0x400u;  // sprite cull binds it unconditionally; bit kept for mask parity
const uint COMP_TEXTEFFECTS    = 0x800u;

// ---------- Shared flag bits (must match types.tl) ----------
const uint FLAG_UNLIT    = 0x1u;
const uint FLAG_OCCLUDER = 0x100u;

// ---------- Per-dispatch uniforms ----------
uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
// BlendId is dispatch-uniform: every entity in an archetype shares the
// same blend mode (archetype identity = blend identity). The host sets
// it from blend.groupBy(archetype) before each dispatch.
uniform uint BlendId;
// StaticFlags: per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag).
uniform uint StaticFlags;

// ---------- Optional-component readers ----------

vec4 readColor(uint row) {
    if ((ComponentMask & COMP_COLOR) != 0u) {
        return colors[row].rgba;
    }
    return vec4(1.0, 1.0, 1.0, 1.0);
}

vec4 readClipBounds(uint row) {
    if ((ComponentMask & COMP_CLIPBOUNDS) != 0u) {
        return clipBoundsIn[row].minMaxXY;
    }
    return vec4(-3.4e38, -3.4e38, 3.4e38, 3.4e38);  // unbounded
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

// ---------- Shared cull helpers ----------

// Camera-relative offset a layer's parallax factor applies to world
// positions. Zero when the parallax factor is 1.
vec2 getParallaxOffset(float layer) {
    vec2 parallax = getParallaxFactor(layer);
    return CameraPos * (vec2(1.0) - parallax);
}

// AABB-vs-viewport test shared by every shape cull. bounds is
// (left, top, right, bottom) in world space; parallaxOff is the
// getParallaxOffset result for world-space layers and vec2(0) for
// screen-space layers.
bool cullBoundsVisible(vec4 bounds, bool isScreenSpace, bool usesVirtualCoords, vec2 parallaxOff) {
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        return (bounds.z > 0.0) && (bounds.x < cullSize.x) &&
               (bounds.w > 0.0) && (bounds.y < cullSize.y);
    }
    return (bounds.z + parallaxOff.x > CameraViewport.x) &&
           (bounds.x + parallaxOff.x < CameraViewport.z) &&
           (bounds.w + parallaxOff.y > CameraViewport.y) &&
           (bounds.y + parallaxOff.y < CameraViewport.w);
}

// Canonical packed render-flags layout, shared by every shape:
//   bits 0-15  shape flags (FLAG_UNLIT etc.)
//   bits 16-18 screen-space class (encodeScreenSpaceFlagsUint)
//   bits 20-23 blend id
//   bits 24-31 material id
// Store the result bit-exact (uintBitsToFloat for float lanes); a
// float() conversion rounds integers above 2^24 and corrupts the low
// flag bits.
uint packRenderFlags(uint flags, bool isScreenSpace, bool ignoresZoom, bool usesVirtualCoords, uint blendId, uint materialId) {
    return flags
        | encodeScreenSpaceFlagsUint(isScreenSpace, ignoresZoom, usesVirtualCoords)
        | (blendId << 20u)
        | (materialId << 24u);
}

