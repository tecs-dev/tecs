// The contract a material implements.
//
// A material decides what color a fragment is and whether the fragment
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
    // Whether the fragment reaches a pass that blends it, which is the forward
    // pass and no other. A material that resolves an edge by discarding, because
    // replace cannot hold partial coverage, keeps the edge in alpha instead when
    // this is set. Nothing else in the contract depends on the lane: a material
    // decides what color a fragment is, and this is the one thing about the
    // fragment's destination it cannot decide without being told.
    bool blended;
};

struct MaterialOutput {
    vec4 albedo;
    // Which way the surface faces, in the quad's own space: X and Y along the
    // quad's own axes and +Z out of it, towards the viewer. The fragment
    // shader turns it by the instance's rotation and scale, so a material says
    // what its shape means and never what the entity is doing with it.
    //
    // Flat is the honest default, and `materialDefaults` supplies it. A 2D
    // sprite genuinely has no normal: it is a picture of a surface rather than
    // a surface, and inventing a curve for it would light every sprite as
    // though it bulged towards the viewer. So this is per material rather than
    // per texture, and a material claims a shape only where its own silhouette
    // is one: a circle is a dome because a circle is what a dome looks like,
    // and a rectangle is flat because a rectangle is what a wall looks like.
    // A sprite that really does want a normal per texel wants a normal map,
    // which is a sidecar image and a different piece of work.
    vec3 normal;
    // Surface properties the lighting resolve reads: red is ambient
    // occlusion, green is roughness, blue is metallic, and alpha is reserved.
    //
    // Ambient occlusion multiplies ambient light and nothing a point light
    // contributes. Metallic-roughness mesh pixels consume the next two
    // channels through Cook-Torrance. Sprite pixels intentionally retain
    // Lambert diffuse lighting and ignore them. The neutral default is fully
    // unoccluded, medium roughness and non-metallic.
    vec4 orm;
    // Zero leaves the fragment out of the lighting pass entirely, so it draws
    // at its own color. Whether a thing takes light is what it is rather than
    // where it is, so the material answers here; the layer it sits on answers
    // too, and a fragment is lit only where both say it should be.
    float lit;
    // Light the surface gives off rather than receives: rgb its color, alpha
    // how much of it. The resolve adds the product on top of whatever lighting
    // produced, so it survives darkness and an occluder's shadow both, and a
    // lamp in a lit room is lit and glowing at once.
    //
    // A color and a strength rather than one premultiplied color, because the
    // attachment is eight bits a channel: premultiplying a dim warm glow
    // quantises its hue away, while these keep eight bits of each. Zero is the
    // default and every built-in material takes it, so a scene emits only where
    // something says it does.
    vec4 emission;
    // At or below zero the fragment is discarded. Coverage rather than alpha
    // because the G-buffer pass writes with replace rather than blend, so a
    // partly covered fragment would overwrite what is behind it instead of
    // blending into it.
    float coverage;
};

// What a material starts from, so a field it never mentions has a value.
//
// Every material begins here rather than declaring a bare `MaterialOutput`,
// which is what lets the contract grow a field without every material in every
// root having to learn about it on the same day. The albedo and the coverage
// are placeholders a material is expected to overwrite; the normal, ORM, the
// lit flag and the emission are answers in their own right.
MaterialOutput materialDefaults() {
    MaterialOutput result;
    result.albedo = vec4(1.0);
    result.normal = vec3(0.0, 0.0, 1.0);
    result.orm = vec4(1.0, 0.5, 0.0, 1.0);
    result.lit = 1.0;
    result.emission = vec4(0.0);
    result.coverage = 1.0;
    return result;
}

// The normal of a dome over a flat field, from how far out the fragment is.
//
// `rim` is the fragment's position across the shape's own radius, zero at the
// middle and unit length at the silhouette, so a circle passes its local
// coordinate doubled and an ellipse divides by its two radii. What comes back
// is already unit length: the height is the leg that makes it so, which is
// also what makes the surface a hemisphere rather than a cone.
vec3 domeNormal(vec2 rim) {
    return vec3(rim, sqrt(max(1.0 - dot(rim, rim), 0.0)));
}

// Signed distance to a rounded box, negative inside. Here rather than in each
// material that wants it, since a rectangle, a circle and a capsule are the
// same function at different radii.
float sdRoundedBox(vec2 p, vec2 extent, float radius) {
    vec2 q = abs(p) - extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}
