// Common render parameters and layer filtering for all render shaders.
// Provides camera, screen, depth, and mask data via a single SSBO.
// LayerRange stays as a per-pass uniform (set differently for each render pass).

// Render parameters (uploaded once per render phase, shared across all render dispatches)
// Fields are flat vec4/uvec4 to match LOVE2D buffer format entries 1:1.
struct RenderParamsData {
    vec4 _renCamZoom;
    vec4 _renScreenSub;
    vec4 _renVirtScreen;
    vec4 _renRenderDepth;
    uvec4 _renMasks;
    vec4 _sm0; vec4 _sm1; vec4 _sm2; vec4 _sm3;
    vec4 _vp0; vec4 _vp1; vec4 _vp2; vec4 _vp3;
    vec4 _iv0; vec4 _iv1; vec4 _iv2; vec4 _iv3;
};

layout(std430) readonly buffer RenderParams {
    RenderParamsData _renParams[];
};

// Camera macros
#define CameraPos _renParams[0]._renCamZoom.xy
#define CameraZoom _renParams[0]._renCamZoom.z
#define MaxLayer _renParams[0]._renCamZoom.w
#define ScreenHalf _renParams[0]._renScreenSub.xy
#define CameraSubPixel _renParams[0]._renScreenSub.zw
#define VirtualSize _renParams[0]._renVirtScreen.xy
#define ScreenSize _renParams[0]._renVirtScreen.zw
#define RenderSize _renParams[0]._renRenderDepth.xy
#define MaxZ _renParams[0]._renRenderDepth.z
#define MaxY _renParams[0]._renRenderDepth.w
#define ScreenSpaceMask _renParams[0]._renMasks.x
#define IgnoreZoomMask _renParams[0]._renMasks.y
#define VirtualCoordsMask _renParams[0]._renMasks.z
#define UnlitMask _renParams[0]._renMasks.w
#define SortModes mat4(_renParams[0]._sm0, _renParams[0]._sm1, _renParams[0]._sm2, _renParams[0]._sm3)
#define ViewProj mat4(_renParams[0]._vp0, _renParams[0]._vp1, _renParams[0]._vp2, _renParams[0]._vp3)
#define InvViewProj mat4(_renParams[0]._iv0, _renParams[0]._iv1, _renParams[0]._iv2, _renParams[0]._iv3)

// Layer range for multi-pass rendering with effects
// x = minLayer (inclusive), y = maxLayer (inclusive)
// When x = 0 and y = 65535, all layers are rendered (default/no filtering)
uniform vec2 LayerRange;

// Canonical packed render-flags layout, written by cull shaders via
// packRenderFlags: bits 0-15 shape flags, bits 16-18 screen-space
// class, bits 20-23 blend id, bits 24-31 material id. Packed lanes in
// float fields carry raw bits; decode with floatBitsToUint.
const uint FLAG_UNLIT          = 0x1u;
const uint FLAG_SCREEN_SPACE   = 0x10000u;
const uint FLAG_IGNORE_ZOOM    = 0x20000u;
const uint FLAG_VIRTUAL_COORDS = 0x40000u;

uniform int BlendModePass;    // -1 = render all; 0+ = only instances with this blend id
uniform int MaterialPass;     // -1 = default pass (material id 0 only); 0+ = only this material

// True when the current material pass should skip this instance.
bool materialPassFiltered(uint packed) {
    uint matId = (packed >> 24u) & 0xFFu;
    if (MaterialPass < 0) return matId != 0u;
    return int(matId) != MaterialPass;
}

// True when the current blend pass should skip this instance.
bool blendPassFiltered(uint packed) {
    return BlendModePass >= 0 && int((packed >> 20u) & 0xFu) != BlendModePass;
}

// Instanced-quad vertex positions (two triangles, CCW winding), indexed
// by love_VertexID with vertexCount=6 indirect draws. Unit variant
// spans 0..1 (pivot-based shapes); centered variant spans -1..1 (SDF
// shapes).
const vec2 QUAD_POSITIONS_UNIT[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);
const vec2 QUAD_POSITIONS_CENTERED[6] = vec2[6](
    vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
    vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0)
);

// Default ORM G-buffer output for content without material maps
// (AO = 1, roughness = 0.5, metallic = 0).
const vec4 DEFAULT_ORM = vec4(1.0, 0.5, 0.0, 1.0);

vec2 worldToScreen(vec2 worldPos, bool isScreenSpace, bool ignoresZoom, bool usesVirtualCoords) {
    if (isScreenSpace) {
        vec2 sourceSize = usesVirtualCoords ? VirtualSize : ScreenSize;
        vec2 pos = worldPos * (RenderSize / sourceSize);
        return ignoresZoom ? pos : pos * CameraZoom;
    }
    return (ViewProj * vec4(worldPos, 0.0, 1.0)).xy;
}

// Check if a world position is outside clip bounds (for fragment discard)
bool outsideClipBounds(vec2 worldPos, vec4 clipBounds) {
    return worldPos.x < clipBounds.x || worldPos.x > clipBounds.z ||
           worldPos.y < clipBounds.y || worldPos.y > clipBounds.w;
}

