#pragma language glsl4

// Drop shadow AO render shader.
// Reads from the drop shadow output buffer populated by the cull shader's triple-write.
// Writes to a standalone AO canvas (not G-buffer MRT).
// Output: AO factor (1.0 = no occlusion, 0.0 = full shadow).
// The lighting shader multiplies ambient by this AO value; dynamic lights are unaffected.
//
// Two-pass approach to prevent self-shadowing:
// Pass 1 (darken/min blend): draw drop shadows with ao < 1.0
// Pass 2 (lighten/max blend): draw source sprites with ao = 1.0 to stamp out character

struct SpriteData {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a (a = opacity)
    vec4 depthLayerGrid; // computed depth, layer, animColumnCount, animFrameHeight
    vec4 clipBounds;    // minX, minY, maxX, maxY (world coords)
    vec4 uvRect;        // uvX (base), uvY, uvW (single frame), uvH
    vec4 animData;      // frameIndex (computed by cull), totalDuration, frameCount, frameWidth
    vec4 rotScale;      // rotation, scaleX, scaleY, textureSlice
    vec4 pivot;         // pivotX, pivotY, spare, packed flags (uint bits)
};

layout(std430) readonly buffer DropShadowSpriteOutput {
    SpriteData sprites[];
};

// Instances past the cull shader's MaxDropShadows cap were never
// written (the atomic counter can overshoot the buffer); cull them.
uniform uint MaxDropShadows;

varying vec4 vColor;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying vec2 vTexCoord;
varying float vTextureSlice;

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 quadPos = QUAD_POSITIONS_UNIT[love_VertexID];

    int instanceID = love_InstanceID;
    if (uint(instanceID) >= MaxDropShadows) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }
    SpriteData s = sprites[instanceID];

    // Layer range filtering
    float layer = s.depthLayerGrid.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 pos = s.posSize.xy;
    vec2 size = s.posSize.zw;
    float rotation = s.rotScale.x;
    float scaleX = s.rotScale.y;
    float scaleY = s.rotScale.z;
    vec2 pivot = s.pivot.xy;

    // Screen-space flags (canonical packed layout, stored as uint bits)
    uint packed = floatBitsToUint(s.pivot.w);
    bool isScreenSpace = (packed & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (packed & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (packed & FLAG_VIRTUAL_COORDS) != 0u;

    // Transform unit quad with scale and rotation around pivot point
    vec2 local = quadPos - pivot;
    vec2 scaled = local * size * vec2(scaleX, scaleY);
    float c = cos(rotation);
    float sn = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * sn, scaled.x * sn + scaled.y * c);
    vec2 worldPos = pos + rotated;

    // Animation data
    float frameIndex = s.animData.x;
    float animFrameCount = s.animData.z;
    float animFrameWidth = s.animData.w;
    float animColumnCount = s.depthLayerGrid.z;
    float animFrameHeight = s.depthLayerGrid.w;

    frameIndex = clamp(frameIndex, 0.0, animFrameCount - 1.0);

    // Compute animated UV coordinates
    vec2 uvOffset;
    if (animColumnCount > 0.0) {
        float col = mod(frameIndex, animColumnCount);
        float row = floor(frameIndex / animColumnCount);
        uvOffset = vec2(s.uvRect.x + col * animFrameWidth, s.uvRect.y + row * animFrameHeight);
    } else {
        uvOffset = vec2(s.uvRect.x + frameIndex * animFrameWidth, s.uvRect.y);
    }
    vec2 uvSize = s.uvRect.zw;
    vTexCoord = uvOffset + quadPos * uvSize;

    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = s.depthLayerGrid.x * result.w;

    vColor = s.color;
    vWorldPos = worldPos;
    vClipBounds = s.clipBounds;
    vTextureSlice = s.rotScale.w;
    return result;
}
#endif

#ifdef PIXEL
uniform ArrayImage MainTex;
uniform float AOOverride; // -1 = use computed AO, >= 0 = use this value

void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    // Sample texture for alpha only (determine silhouette shape)
    vec3 texCoord3D = vec3(vTexCoord, vTextureSlice);
    vec4 texColor = Texel(MainTex, texCoord3D);

    if (texColor.a < 0.01) discard;

    float ao;
    if (AOOverride >= 0.0) {
        ao = AOOverride;  // Stamp-out pass: 1.0 = restore no-occlusion
    } else {
        ao = 1.0 - vColor.a;  // Shadow pass: opacity -> occlusion
    }
    love_Canvases[0] = vec4(ao, 0.0, 0.0, 1.0);
}
#endif
