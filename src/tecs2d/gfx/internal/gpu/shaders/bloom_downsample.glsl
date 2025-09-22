#pragma language glsl4

// Dual Kawase 5-tap downsample for bloom.
// Center sample at 4x weight + 4 diagonal corners at 1x, divide by 8.
// First pass reads emission (rgb * a premultiply + soft threshold).
// Subsequent passes read RGB only (already premultiplied).

uniform vec2 HalfTexelSize; // 0.5 / source texture dimensions
uniform float Offset;       // Filter radius (from bloom.radius)
uniform float Threshold;    // Brightness threshold (soft knee)
uniform int FirstPass;      // 1 = first pass (premultiply emission), 0 = subsequent

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    return transform_projection * vertex_position;
}
#endif

#ifdef PIXEL

// Soft threshold: smoothly ramps from 0 at (threshold - knee) to 1 at (threshold + knee)
vec3 applyThreshold(vec3 color, float threshold) {
    float brightness = max(color.r, max(color.g, color.b));
    float knee = threshold * 0.5;
    float soft = brightness - threshold + knee;
    soft = clamp(soft / (2.0 * knee + 0.0001), 0.0, 1.0);
    soft = soft * soft;
    float contribution = max(soft, step(threshold, brightness));
    return color * contribution;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec2 ht = HalfTexelSize * Offset;

    vec3 center, tl, tr, bl, br;

    if (FirstPass == 1) {
        // Premultiply emission rgb * a
        vec4 em = Texel(tex, uv);
        center = em.rgb * em.a;
        em = Texel(tex, uv + vec2(-1.0, -1.0) * ht); tl = em.rgb * em.a;
        em = Texel(tex, uv + vec2( 1.0, -1.0) * ht); tr = em.rgb * em.a;
        em = Texel(tex, uv + vec2(-1.0,  1.0) * ht); bl = em.rgb * em.a;
        em = Texel(tex, uv + vec2( 1.0,  1.0) * ht); br = em.rgb * em.a;
    } else {
        center = Texel(tex, uv).rgb;
        tl = Texel(tex, uv + vec2(-1.0, -1.0) * ht).rgb;
        tr = Texel(tex, uv + vec2( 1.0, -1.0) * ht).rgb;
        bl = Texel(tex, uv + vec2(-1.0,  1.0) * ht).rgb;
        br = Texel(tex, uv + vec2( 1.0,  1.0) * ht).rgb;
    }

    // Dual Kawase: center * 4 + corners * 1, divide by 8
    vec3 result = (center * 4.0 + tl + tr + bl + br) * 0.125;

    // Apply threshold on first pass only
    if (FirstPass == 1 && Threshold > 0.0) {
        result = applyThreshold(result, Threshold);
    }

    return vec4(result, 1.0);
}
#endif
