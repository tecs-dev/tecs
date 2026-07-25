#pragma language glsl4

// Shadow-mask companion for the direct TileChunk SpriteBatch fallback.
// SpriteBatch color R carries the normalized per-tile occluder height.

uniform vec2 ChunkPosition;
uniform float AlphaThreshold;

varying float OccluderHeight;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    OccluderHeight = VertexColor.r;
    if (OccluderHeight < 0.001) {
        return vec4(-10000.0, -10000.0, 0.0, 1.0);
    }

    vec2 worldPos = ChunkPosition + vertex_position.xy;
    return transform_projection * vec4(
        shadowMaskToScreen(worldPos),
        0.0,
        1.0
    );
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screenCoord) {
    if (OccluderHeight < 0.001 || Texel(tex, uv).a < AlphaThreshold) {
        discard;
    }
    return encodeOccluder(OccluderHeight);
}
#endif
