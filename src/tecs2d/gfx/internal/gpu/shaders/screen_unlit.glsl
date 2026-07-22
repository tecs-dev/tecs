#pragma language glsl4

// Unlit composite for the screen render phase. Screen layers are always
// unlit, so instead of running the deferred lighting shader (whose every
// pixel would take the unlit early-exit anyway), this reproduces that
// exit exactly: discard uncovered pixels and preserve fractional edge
// coverage from the G-buffer.

uniform Image ScreenEmission;

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 albedo = Texel(tex, uv);
    if (albedo.a < 0.01) discard;
    vec4 emission = Texel(ScreenEmission, uv);
    return vec4(albedo.rgb + emission.rgb * emission.a, albedo.a);
}
