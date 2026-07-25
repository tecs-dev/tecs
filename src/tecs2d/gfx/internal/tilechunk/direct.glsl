#pragma language glsl4

// CPU-built SpriteBatch fallback for tileset atlases that do not fit the
// texture-array path. Each batch contains one 16x16 chunk and samples the
// original atlas directly.

uniform vec4 ChunkPositionSize; // x, y, tile width, tile height
uniform vec2 ChunkLayerZ;
uniform vec4 ChunkColor;
uniform bool HasNormalMap;
uniform bool HasEmissionMap;
uniform bool HasORMMap;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    float layer = ChunkLayerZ.x;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 worldPos = ChunkPositionSize.xy + vertex_position.xy;
    vec2 screenPos = (worldPos - CameraPos) * CameraZoom
        + ScreenHalf + CameraSubPixel;
    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);

    // SpriteBatch color G stores the tile's bottom row as a fraction of
    // the 16-row chunk. This keeps Y sorting stable through tile flips.
    float bottomY = ChunkPositionSize.y
        + VertexColor.g * ChunkPositionSize.w * 16.0;
    float depth = computeDepth(
        layer,
        ChunkLayerZ.y,
        worldPos.x,
        bottomY,
        0u
    );
    result.z = depth * result.w;
    return result;
}
#endif

#ifdef PIXEL
uniform Image MainTex;
uniform Image NormalTex;
uniform Image EmissionTex;
uniform Image ORMTex;

void effect() {
    vec4 albedo = Texel(MainTex, VaryingTexCoord.xy) * ChunkColor;
    if (albedo.a < 0.01) {
        discard;
    }

    vec3 normal = vec3(0.5, 0.5, 1.0);
    if (HasNormalMap) {
        vec4 normalSample = Texel(NormalTex, VaryingTexCoord.xy);
        if (normalSample.a > 0.01) {
            normal = normalSample.rgb;
        }
    }

    vec4 emission = HasEmissionMap
        ? Texel(EmissionTex, VaryingTexCoord.xy)
        : vec4(0.0);
    vec4 orm = HasORMMap
        ? Texel(ORMTex, VaryingTexCoord.xy)
        : DEFAULT_ORM;

    love_Canvases[0] = albedo;
    love_Canvases[1] = vec4(
        normal,
        isUnlitLayer(ChunkLayerZ.x) ? 0.0 : 1.0
    );
    love_Canvases[2] = orm;
    love_Canvases[3] = emission;
}
#endif
