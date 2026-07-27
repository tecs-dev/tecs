// The contract a material implements.
//
// A material decides what colour a fragment is and whether the fragment
// exists at all. It does not decide where the geometry is: that is the
// instance's transform, which is the same for every material, which is why
// they can all share one batch, one cull and one draw.

struct MaterialInput {
    // Position within the quad, -0.5 to 0.5 on both axes. A distance field is
    // evaluated against this.
    vec2 local;
    // Atlas coordinates and array layer, for a material that samples.
    vec3 uv;
    // The instance's tint.
    vec4 color;
    // The instance's material parameter, 0 to 1. What it means is the
    // material's business; a rounded rectangle reads it as a corner radius.
    float param;
};

struct MaterialOutput {
    vec4 albedo;
    // Zero leaves the fragment out of the lighting pass entirely, so it draws
    // at its own colour. Whether a thing emits is what it is rather than where
    // it is, so the material answers here; the layer it sits on answers too,
    // and a fragment is lit only where both say it should be.
    float lit;
    // At or below zero the fragment is discarded. Coverage rather than alpha
    // because the G-buffer pass writes with replace rather than blend, so a
    // partly covered fragment would overwrite what is behind it instead of
    // blending into it.
    float coverage;
};

// Signed distance to a rounded box, negative inside. Here rather than in each
// material that wants it, since a rectangle, a circle and a capsule are the
// same function at different radii.
float sdRoundedBox(vec2 p, vec2 extent, float radius) {
    vec2 q = abs(p) - extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}
