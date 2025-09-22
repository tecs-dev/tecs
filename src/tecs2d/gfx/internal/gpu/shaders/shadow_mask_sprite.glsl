#pragma language glsl4

// Sprite shadow mask shader
// Reads from shadow-only buffer populated by sprite cull shader's dual-write.
// Renders sprite silhouettes to shadow mask using alpha channel.

struct SpriteData {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a (a = occluderHeight from cull shader)
    vec4 depthLayerGrid; // computed depth, layer, animColumnCount, animFrameHeight
    vec4 clipBounds;    // minX, minY, maxX, maxY (world coords)
    vec4 uvRect;        // uvX (base), uvY, uvW (single frame), uvH
    vec4 animData;      // frameIndex (computed by cull), totalDuration, frameCount, frameWidth
    vec4 rotScale;      // rotation, scaleX, scaleY, unused (for shadow output)
    vec4 pivot;         // pivotX, pivotY, flags, screenSpaceFlags
};

layout(std430) readonly buffer SpriteShadowOutput {
    SpriteData sprites[];
};


uniform mat4 ShadowViewProj;
uniform float AlphaThreshold;  // Default 0.5, configurable per-batch

varying vec2 vTexCoord;
varying vec4 vUVRect;
varying float vOccluderHeight;
varying float vTextureSlice;

#ifdef VERTEX
// Quad vertex positions (2 triangles, CCW winding)
const vec2 QUAD_POSITIONS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),  // First triangle
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)   // Second triangle
);

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 quadPos = QUAD_POSITIONS[love_VertexID];

    int instanceID = love_InstanceID;
    SpriteData s = sprites[instanceID];

    vec2 pos = s.posSize.xy;
    vec2 size = s.posSize.zw;
    float rotation = s.rotScale.x;
    float scaleX = s.rotScale.y;
    float scaleY = s.rotScale.z;
    vec2 pivot = s.pivot.xy;

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

    // Clamp frame index
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
    vUVRect = vec4(uvOffset, uvSize);
    vOccluderHeight = s.color.a;  // occluderHeight was encoded in color.a by cull shader
    vTextureSlice = s.pivot.z;  // textureSlice for ArrayImage sampling

    vec2 screenPos = (ShadowViewProj * vec4(worldPos, 0.0, 1.0)).xy;

    return transform_projection * vec4(screenPos, 0.0, 1.0);
}
#endif

#ifdef PIXEL
uniform ArrayImage SpriteMainTex;

uniform vec2 TextureSize;  // Size of texture array slice in pixels

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    // Clamp texture coordinates to UV rect with half-pixel inset to avoid edge bleeding
    vec2 halfPixel = 0.5 / TextureSize;
    vec2 uvMin = vUVRect.xy + halfPixel;
    vec2 uvMax = vUVRect.xy + vUVRect.zw - halfPixel;
    vec2 clampedUV = clamp(vTexCoord, uvMin, uvMax);

    // Sample texture array using slice index
    vec4 texColor = Texel(SpriteMainTex, vec3(clampedUV, vTextureSlice));

    // Alpha test - discard if below threshold
    if (texColor.a < AlphaThreshold) discard;

    // Encode occluder height in red channel:
    // 0.0 = no occluder (all lights pass)
    // 1.0 = max height (blocks all lights)
    // Using MAX blend: tallest occluder wins
    // Height is already normalized 0-1 from ECS data
    float normalizedHeight = clamp(vOccluderHeight, 0.0, 1.0);

    // G=1 marks actual occluder pixels (distinguished from blur halo by lighting shader)
    return vec4(normalizedHeight, 1.0, 0.0, 1.0);
}
#endif
