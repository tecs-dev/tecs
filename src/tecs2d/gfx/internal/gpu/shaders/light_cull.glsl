#pragma language glsl4

layout(local_size_x = 256) in;

#define MAX_LIGHTS_PER_TILE 128u

// Input light data (matches LightInstance FFI struct - 64 bytes)
// Supports both point lights (cosConeAngle = 1.0) and spotlights (cosConeAngle < 1.0)
struct LightIn {
    vec4 posHeight;       // x, y, height, radius
    vec4 intensityColor;  // intensity, r, g, b
    vec4 spotParams;      // spotDirX, spotDirY, cosConeAngle, cosInnerConeAngle
    vec4 extraParams;     // penumbra, cookieSlice, cookieScaleRotX, cookieScaleRotY
};

layout(std430) readonly buffer LightInput {
    LightIn lightsIn[];
};

// Output: compacted visible lights (same format)
layout(std430) writeonly buffer LightOutput {
    LightIn lightsOut[];
};

// Atomic counter for visible light count (must be unsized array for Metal)
layout(std430) buffer VisibleCount {
    uint counts[];
};

// Per-tile light counts (reset to 0 before dispatch)
layout(std430) buffer TileLightCounts {
    uint tileCounts[];
};

// Per-tile light index lists (flat: tile * MAX_LIGHTS_PER_TILE + slot)
layout(std430) buffer TileLightIndices {
    uint tileIndices[];
};

uniform uint TotalLights;
uniform vec4 CameraViewport;  // minX, minY, maxX, maxY (world coords, padded for cull)
uniform vec4 TileViewport;    // minX, minY, maxX, maxY (world coords, unpadded for tile mapping)
uniform float ShadowMargin;   // Extra margin for off-screen lights casting shadows
uniform ivec2 TileGridDims;   // (numTilesX, numTilesY)

void computemain() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= TotalLights) return;

    LightIn light = lightsIn[idx];

    vec2 pos = light.posHeight.xy;
    float radius = light.posHeight.w;

    // Expand culling radius to account for shadows cast by off-screen lights
    // A light just off-screen can still cast shadows onto visible pixels
    float cullRadius = radius + ShadowMargin;

    // Camera bounds (viewport is already minX, minY, maxX, maxY)
    float camMinX = CameraViewport.x;
    float camMinY = CameraViewport.y;
    float camMaxX = CameraViewport.z;
    float camMaxY = CameraViewport.w;

    // AABB-circle intersection: is the light's expanded influence visible?
    bool visible = pos.x + cullRadius > camMinX &&
                   pos.x - cullRadius < camMaxX &&
                   pos.y + cullRadius > camMinY &&
                   pos.y - cullRadius < camMaxY;

    if (visible) {
        // Atomically get the next output slot
        uint visIdx = atomicAdd(counts[0], 1u);
        lightsOut[visIdx] = light;

        // Tile assignment: use actual light radius (not shadow-expanded cullRadius).
        // The shadow margin keeps off-screen lights visible for shadow casting, but
        // tile assignment should only cover tiles the light can actually illuminate.
        // Using cullRadius floods edge tiles with distant off-screen lights that
        // contribute no illumination, wasting tile slots and causing dark artifacts.
        float tileRadius = radius;
        vec2 vpMin = TileViewport.xy;
        vec2 vpSize = TileViewport.zw - TileViewport.xy;
        vec2 screenCenter = (pos - vpMin) / vpSize;
        vec2 screenRadius = vec2(tileRadius) / vpSize;

        ivec2 minTile = max(ivec2(0), ivec2((screenCenter - screenRadius) * vec2(TileGridDims)));
        ivec2 maxTile = min(TileGridDims - 1, ivec2((screenCenter + screenRadius) * vec2(TileGridDims)));

        for (int ty = minTile.y; ty <= maxTile.y; ty++) {
            for (int tx = minTile.x; tx <= maxTile.x; tx++) {
                uint tileIdx = uint(ty * TileGridDims.x + tx);
                uint slot = atomicAdd(tileCounts[tileIdx], 1u);
                if (slot < MAX_LIGHTS_PER_TILE) {
                    tileIndices[tileIdx * MAX_LIGHTS_PER_TILE + slot] = visIdx;
                }
            }
        }
    }
}
