// Shared pieces for the per-shape shadow mask shaders (circle, rect,
// sprite, tilechunk). Injected after the #pragma line by
// shaders.loadShadowMaskShader; do not load this standalone.

// World -> shadow-mask-canvas transform, built by the renderer with the
// same setOrthographic parameters the lighting pass uses to invert it.
uniform mat4 ShadowViewProj;

#ifdef VERTEX
// Quad vertex positions (2 triangles, CCW winding). love_VertexID is
// 0-5 per instance when vertexCount=6 in the indirect buffer.
const vec2 MASK_QUAD_UNIT[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);
const vec2 MASK_QUAD_CENTERED[6] = vec2[6](
    vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
    vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0)
);

vec2 shadowMaskToScreen(vec2 worldPos) {
    return (ShadowViewProj * vec4(worldPos, 0.0, 1.0)).xy;
}
#endif

#ifdef PIXEL
// Encode an occluder fragment for the shadow mask:
//   R = occluder height (0 = all lights pass, 1 = blocks all lights;
//       MAX blend means the tallest occluder wins)
//   G = 1 marks actual occluder pixels (distinguished from the blur
//       halo by the lighting shader)
vec4 encodeOccluder(float height) {
    return vec4(clamp(height, 0.0, 1.0), 1.0, 0.0, 1.0);
}
#endif
