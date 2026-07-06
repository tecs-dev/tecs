#pragma language glsl4

struct SpriteData {
    vec4 posSize;       // x, y, width, height
    vec4 color;         // r, g, b, a
    vec4 depthLayerGrid; // computed depth, layer, animColumnCount, animFrameHeight
    vec4 clipBounds;    // minX, minY, maxX, maxY (world coords)
    vec4 uvRect;        // uvX (base), uvY, uvW (single frame), uvH
    vec4 animData;      // frameIndex (computed by cull), totalDuration, frameCount, frameWidth
    vec4 rotScale;      // rotation, scaleX, scaleY, textureSlice
    vec4 pivot;         // pivotX, pivotY, spare, packed flags (uint bits)
};

// FLAG_UNLIT, pass uniforms, and pass-filter helpers come from
// render_common.glsl.
const uint FLAG_REPEAT_X = 0x2u;
const uint FLAG_REPEAT_Y = 0x4u;

layout(std430) readonly buffer SpriteOutput {
    SpriteData sprites[];
};

varying vec4 vColor;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying vec2 vTexCoord;       // Per-instance texture coordinates
varying vec4 vUVRect;         // UV base (xy) and size (zw) for tiling
varying vec2 vBaseUVSize;     // Base UV size (for tiling: single tile's UV extent)
varying float vFlags;         // RenderFlags bitmask
varying float vTextureSlice;  // Texture array slice index

#ifdef VERTEX

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // Generate vertex position from VertexID (for drawFromShaderIndirect)
    // love_VertexID is 0-5 for each instance when vertexCount=6 in indirect buffer
    vec2 quadPos = QUAD_POSITIONS_UNIT[love_VertexID];

    int instanceID = love_InstanceID;
    SpriteData s = sprites[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = s.depthLayerGrid.y;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering (canonical packed layout).
    uint packed = floatBitsToUint(s.pivot.w);
    if (blendPassFiltered(packed) || materialPassFiltered(packed)) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Transform position is the pivot point in world space (like rectangle shader)
    vec2 pos = s.posSize.xy;
    vec2 size = s.posSize.zw;     // UNSCALED size
    float rotation = s.rotScale.x;
    float scaleX = s.rotScale.y;
    float scaleY = s.rotScale.z;
    vec2 pivot = s.pivot.xy;      // Pivot point (0,0 = top-left, 0.5,0.5 = center, 1,1 = bottom-right)
    bool isScreenSpace = (packed & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (packed & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (packed & FLAG_VIRTUAL_COORDS) != 0u;

    // Transform unit quad with scale and rotation around pivot point (matching rectangle shader)
    vec2 local = quadPos - pivot;  // Offset from pivot (0,0 to 1,1 quad → pivot-relative)
    // Apply scale
    vec2 scaled = local * size * vec2(scaleX, scaleY);
    // Apply rotation
    float c = cos(rotation);
    float sn = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * sn, scaled.x * sn + scaled.y * c);
    // Translate to world position (pivot point is at transform position)
    vec2 worldPos = pos + rotated;

    // Animation data (frame index computed by cull shader using timing buffer)
    float frameIndex = s.animData.x;      // Pre-computed frame index
    float animFrameCount = s.animData.z;
    float animFrameWidth = s.animData.w;
    float animColumnCount = s.depthLayerGrid.z;  // frames per row (0 = single row strip)
    float animFrameHeight = s.depthLayerGrid.w;  // height of one frame in UV space

    // Clamp frame index (should already be valid from cull shader)
    frameIndex = clamp(frameIndex, 0.0, animFrameCount - 1.0);

    // Compute animated UV coordinates with grid support
    // Grid layout: frames wrap to next row after animColumnCount frames
    vec2 uvOffset;
    if (animColumnCount > 0.0) {
        // Grid layout: compute row and column
        float col = mod(frameIndex, animColumnCount);
        float row = floor(frameIndex / animColumnCount);
        uvOffset = vec2(s.uvRect.x + col * animFrameWidth, s.uvRect.y + row * animFrameHeight);
    } else {
        // Horizontal strip: simple offset (backwards compatible)
        uvOffset = vec2(s.uvRect.x + frameIndex * animFrameWidth, s.uvRect.y);
    }
    vec2 uvSize = s.uvRect.zw;
    vTexCoord = uvOffset + quadPos * uvSize;
    vUVRect = vec4(uvOffset, uvSize);  // Pass UV rect for tiling in pixel shader

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = s.depthLayerGrid.x * result.w;

    vColor = s.color;
    vWorldPos = worldPos;
    vClipBounds = s.clipBounds;
    // Fragment only needs the low flag bits; they fit a float exactly.
    vFlags = float(packed & 0xFFFFu);
    // Pass base UV size for tiling (animFrameWidth/Height store base UV for non-animated sprites)
    vBaseUVSize = vec2(s.animData.w, s.depthLayerGrid.w);
    vTextureSlice = s.rotScale.w;  // texture array slice index
    return result;
}
#endif

#ifdef PIXEL
uniform ArrayImage MainTex;
uniform ArrayImage NormalTex;
uniform ArrayImage EmissionTex;
uniform ArrayImage ORMTex;

void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    // Check repeat flags
    uint flags = uint(vFlags);
    bool repeatX = (flags & FLAG_REPEAT_X) != 0u;
    bool repeatY = (flags & FLAG_REPEAT_Y) != 0u;

    // Compute final UV (apply tiling if repeat flags set)
    vec2 texCoord = vTexCoord;
    if (repeatX || repeatY) {
        // Convert to local UV space using BASE UV size (not scaled)
        // vBaseUVSize contains the single-tile UV extent (e.g., 1.0 for full texture)
        // vTexCoord spans multiple tiles (0..N*baseUV), so dividing by baseUV gives 0..N
        vec2 localUV = (vTexCoord - vUVRect.xy) / vBaseUVSize;
        // Apply fract() to tile (wraps 0..N back to 0..1)
        if (repeatX) localUV.x = fract(localUV.x);
        if (repeatY) localUV.y = fract(localUV.y);
        // Convert back to texture UV space using base size
        texCoord = localUV * vBaseUVSize + vUVRect.xy;
    }

    // Sample texture array using per-instance UV and slice index
    vec3 texCoord3D = vec3(texCoord, vTextureSlice);
    vec4 texColor = Texel(MainTex, texCoord3D);
    vec4 finalColor = texColor * vColor;

    if (finalColor.a < 0.01) discard;

    // Check unlit flag
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;

    // Sample normal map - alpha > 0.01 means "has normal data"
    vec4 normalSample = Texel(NormalTex, texCoord3D);
    vec3 normal = normalSample.a > 0.01
        ? normalSample.rgb
        : vec3(0.5, 0.5, 1.0);

    // Sample emission map (output separately, added after lighting)
    vec4 emission = Texel(EmissionTex, texCoord3D);

    // Sample ORM map: R = AO, G = roughness, B = metallic
    vec4 orm = Texel(ORMTex, texCoord3D);

    // -- MATERIAL_BEGIN --
    // G-Buffer outputs
    love_Canvases[0] = finalColor;                       // Albedo
    love_Canvases[1] = vec4(normal, litMarker);          // Normal + lit marker
    love_Canvases[2] = orm;                              // ORM (AO, roughness, metallic)
    love_Canvases[3] = emission;                         // Emission (added after lighting)
    // -- MATERIAL_END --
}
#endif
