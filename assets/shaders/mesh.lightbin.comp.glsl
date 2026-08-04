#version 450
// Conservatively bins optional 3D point and spot lights in screen space.
// The sphere defined by position and radius bounds both light kinds; a spot's
// cone can only touch fewer pixels, so no visible contribution is discarded.

layout(local_size_x = 64) in;

#include "lighting.glsl"

layout(set = 0, binding = 0) readonly buffer MeshLights {
    MeshLight item[];
} lights;

layout(set = 1, binding = 0) writeonly buffer TileCounts {
    uint count[];
} tiles;

layout(set = 1, binding = 1) writeonly buffer TileLights {
    uint index[];
} tileLights;

layout(set = 2, binding = 0) uniform Bin {
    mat4 viewProjection;
    vec4 params; // light count, viewport width, viewport height, reserved
} bin;

bool reachesTile(vec4 positionRadius, vec2 tileMinimum, vec2 tileMaximum) {
    vec4 clip = bin.viewProjection * vec4(positionRadius.xyz, 1.0);
    float radius = positionRadius.w;
    vec3 rowX = vec3(bin.viewProjection[0][0], bin.viewProjection[1][0], bin.viewProjection[2][0]);
    vec3 rowY = vec3(bin.viewProjection[0][1], bin.viewProjection[1][1], bin.viewProjection[2][1]);
    vec3 rowW = vec3(bin.viewProjection[0][3], bin.viewProjection[1][3], bin.viewProjection[2][3]);
    float varyingW = radius * length(rowW);

    // A sphere crossing the eye plane can project across the complete target.
    // Keeping it everywhere is conservative and bounded by the tile slot cap.
    if (clip.w <= varyingW + 1e-5) {
        return true;
    }

    float safeW = clip.w - varyingW;
    float extentX = (radius * length(rowX) * clip.w + abs(clip.x) * varyingW) / (clip.w * safeW);
    float extentY = (radius * length(rowY) * clip.w + abs(clip.y) * varyingW) / (clip.w * safeW);
    // SPIR-V fragment coordinates start at the framebuffer's top left, while
    // clip +Y points up. The tile reader uses gl_FragCoord in that top-left
    // space, so flip projected Y here before assigning the light to tiles.
    // Centered lights concealed this disagreement because 0.5 is its own
    // vertical mirror.
    vec2 center = vec2(clip.x, -clip.y) / clip.w * 0.5 + 0.5;
    vec2 extent = vec2(extentX, extentY) * 0.5;
    vec2 nearest = clamp(center, tileMinimum, tileMaximum);
    vec2 outside = abs(center - nearest);
    return outside.x <= extent.x && outside.y <= extent.y;
}

void main() {
    uint tile = gl_GlobalInvocationID.x;
    uint total = uint(LIGHT_TILES * LIGHT_TILES);
    if (tile >= total) { return; }

    vec2 cell = vec2(tile % uint(LIGHT_TILES), tile / uint(LIGHT_TILES));
    vec2 tileMinimum = cell / float(LIGHT_TILES);
    vec2 tileMaximum = (cell + 1.0) / float(LIGHT_TILES);
    uint base = tile * uint(LIGHT_TILE_SLOTS);
    uint kept = 0u;
    int count = int(bin.params.x);
    for (int index = 0; index < count; index++) {
        if (kept >= uint(LIGHT_TILE_SLOTS)) { break; }
        if (reachesTile(lights.item[index].positionRadius, tileMinimum, tileMaximum)) {
            tileLights.index[base + kept] = uint(index);
            kept++;
        }
    }
    tiles.count[tile] = kept;
}
