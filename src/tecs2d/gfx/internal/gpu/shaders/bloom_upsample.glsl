#pragma language glsl4

// Dual Kawase 8-tap upsample for bloom.
// 4 diagonal corners at 2x weight + 4 axis-aligned edges at 1x weight, divide by 12.
// Additively blends the upsampled lower mip onto the current mip level.

uniform vec2 HalfTexelSize; // 0.5 / source texture dimensions
uniform float Offset;       // Filter radius (from bloom.radius)

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    return transform_projection * vertex_position;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec2 ht = HalfTexelSize * Offset;

    vec3 result = vec3(0.0);

    // 4 diagonal corners (2x weight each)
    result += Texel(tex, uv + vec2(-1.0, -1.0) * ht).rgb * 2.0;
    result += Texel(tex, uv + vec2( 1.0, -1.0) * ht).rgb * 2.0;
    result += Texel(tex, uv + vec2(-1.0,  1.0) * ht).rgb * 2.0;
    result += Texel(tex, uv + vec2( 1.0,  1.0) * ht).rgb * 2.0;

    // 4 axis-aligned edges at 2x offset (1x weight each)
    result += Texel(tex, uv + vec2( 0.0, -2.0) * ht).rgb;
    result += Texel(tex, uv + vec2(-2.0,  0.0) * ht).rgb;
    result += Texel(tex, uv + vec2( 2.0,  0.0) * ht).rgb;
    result += Texel(tex, uv + vec2( 0.0,  2.0) * ht).rgb;

    result /= 12.0;

    return vec4(result, 1.0);
}
#endif
