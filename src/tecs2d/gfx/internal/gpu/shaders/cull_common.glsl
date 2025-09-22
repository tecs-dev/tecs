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

// Compute parallax-adjusted camera viewport for a layer
// For parallax > 1 (foreground), the effective camera position increases
// For parallax < 1 (background), the effective camera position decreases
// Formula: adjustedCam = cam * parallax
vec4 getParallaxViewport(float layer, vec2 halfSize) {
    vec2 parallax = getParallaxFactor(layer);
    vec2 adjustedCam = CameraPos * parallax;
    return vec4(
        adjustedCam.x - halfSize.x,
        adjustedCam.y - halfSize.y,
        adjustedCam.x + halfSize.x,
        adjustedCam.y + halfSize.y
    );
}

// Get the cull bounds for screen-space layers based on virtualCoords setting
vec2 getScreenSpaceCullSize(bool usesVirtualCoords) {
    return usesVirtualCoords ? VirtualSize : ScreenSize;
}

// Encode screen-space flags for render shader
// Returns: 1.0 = screenSpace, 2.0 = ignoreZoom, 4.0 = virtualCoords (can be combined)
float encodeScreenSpaceFlags(bool isScreenSpace, bool ignoresZoom, bool usesVirtualCoords) {
    return (isScreenSpace ? 1.0 : 0.0) + (ignoresZoom ? 2.0 : 0.0) + (usesVirtualCoords ? 4.0 : 0.0);
}

// Encode screen-space flags as uint for shaders that use integer flags
// Returns: bit 16 = screenSpace, bit 17 = ignoreZoom, bit 18 = virtualCoords
uint encodeScreenSpaceFlagsUint(bool isScreenSpace, bool ignoresZoom, bool usesVirtualCoords) {
    return (isScreenSpace ? 0x10000u : 0u) | (ignoresZoom ? 0x20000u : 0u) | (usesVirtualCoords ? 0x40000u : 0u);
}

