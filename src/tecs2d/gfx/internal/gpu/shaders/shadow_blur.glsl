#pragma language glsl4

// Separable Gaussian blur for shadow mask
// Two-pass (H then V): 9+9=18 taps vs 81 for a 2D 9x9 kernel

uniform vec2 TexelSize;      // 1.0 / texture dimensions
uniform float BlurRadius;    // Blur strength (in pixels)
uniform vec2 BlurDirection;  // (1,0) for horizontal, (0,1) for vertical

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    return transform_projection * vertex_position;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    // 9-tap 1D Gaussian blur of height channel (R)
    // Weights: [0.0162, 0.0540, 0.1218, 0.1872, 0.2416, 0.1872, 0.1218, 0.0540, 0.0162]
    // Sigma ~1.5, normalized to sum to 1.0
    const float w[5] = float[5](0.2416, 0.1872, 0.1218, 0.0540, 0.0162);

    vec2 step = BlurDirection * TexelSize * BlurRadius;
    float heightSum = Texel(tex, uv).r * w[0];
    for (int i = 1; i <= 4; i++) {
        vec2 offset = float(i) * step;
        heightSum += Texel(tex, uv + offset).r * w[i];
        heightSum += Texel(tex, uv - offset).r * w[i];
    }

    // Preserve G (occluder flag) from center pixel so the lighting shader
    // can distinguish actual occluder pixels from blur-halo pixels.
    float centerG = Texel(tex, uv).g;
    return vec4(heightSum, centerG, 0.0, 1.0);
}
#endif
