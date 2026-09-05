// The contract a material implements.
//
// A material decides what color a fragment is and whether the fragment exists
// at all. It does not decide where the geometry is: that is the instance's
// transform, which is the same for every material, which is why they can all
// share one cull, one compaction and one draw.

struct MaterialInput {
    // Position within the quad, -0.5 to 0.5 on both axes. A distance field is
    // evaluated against this.
    local: vec2<f32>,
    // Image coordinates, for a material that samples.
    uv: vec2<f32>,
    // The instance's tint.
    color: vec4<f32>,
    // The instance's material parameter, 0 to 1. What it means is the
    // material's business; a rounded rectangle reads it as a corner radius.
    param: f32,
    // Whether the fragment reaches a pass that blends it, which is the forward
    // pass and no other. A material that resolves an edge by discarding,
    // because replace cannot hold partial coverage, keeps the edge in alpha
    // instead when this is set.
    blended: bool,
}

struct MaterialOutput {
    albedo: vec4<f32>,
    // Which way the surface faces, in the quad's own space: X and Y along the
    // quad's own axes and +Z out of it, towards the viewer. The fragment shader
    // turns it by the instance's rotation, so a material says what its shape
    // means and never what the entity is doing with it.
    //
    // Flat is the honest default. A 2D sprite genuinely has no normal: it is a
    // picture of a surface rather than a surface, and inventing a curve for it
    // would light every sprite as though it bulged towards the viewer. So a
    // material claims a shape only where its own silhouette is one: a circle is
    // a dome because a circle is what a dome looks like, and a rectangle is
    // flat because a rectangle is what a wall looks like.
    normal: vec3<f32>,
    // Surface properties the lighting resolve reads: red is ambient occlusion,
    // green is roughness, blue is metallic, and alpha is reserved. The neutral
    // default is fully unoccluded, medium roughness and non-metallic.
    orm: vec4<f32>,
    // Zero leaves the fragment out of the lighting pass entirely, so it draws
    // at its own color. Whether a thing takes light is what it is rather than
    // where it is, so the material answers here.
    lit: f32,
    // Light the surface gives off rather than receives: rgb its color, alpha
    // how much of it. The resolve adds the product on top of whatever lighting
    // produced, so it survives darkness and a shadow both.
    //
    // A color and a strength rather than one premultiplied color, because the
    // attachment is eight bits a channel: premultiplying a dim warm glow
    // quantises its hue away.
    emission: vec4<f32>,
    // At or below zero the fragment is discarded. Coverage rather than alpha
    // because the G-buffer pass writes with replace rather than blend, so a
    // partly covered fragment would overwrite what is behind it instead of
    // blending into it.
    coverage: f32,
}

// What a material starts from, so a field it never mentions has a value.
//
// Every material begins here rather than declaring a bare `MaterialOutput`,
// which is what lets the contract grow a field without every material in every
// root having to learn about it on the same day.
fn materialDefaults() -> MaterialOutput {
    var result: MaterialOutput;
    result.albedo = vec4<f32>(1.0);
    result.normal = vec3<f32>(0.0, 0.0, 1.0);
    result.orm = vec4<f32>(1.0, 0.5, 0.0, 1.0);
    result.lit = 1.0;
    result.emission = vec4<f32>(0.0);
    result.coverage = 1.0;
    return result;
}

// The normal of a dome over a flat field, from how far out the fragment is.
//
// `rim` is the fragment's position across the shape's own radius, zero at the
// middle and unit length at the silhouette, so a circle passes its local
// coordinate doubled and an ellipse divides by its two radii. What comes back
// is already unit length: the height is the leg that makes it so, which is also
// what makes the surface a hemisphere rather than a cone.
fn domeNormal(rim: vec2<f32>) -> vec3<f32> {
    return vec3<f32>(rim, sqrt(max(1.0 - dot(rim, rim), 0.0)));
}

// Signed distance to a rounded box, negative inside. Here rather than in each
// material that wants it, since a rectangle, a circle and a capsule are the
// same function at different radii.
fn sdRoundedBox(p: vec2<f32>, extent: vec2<f32>, radius: f32) -> f32 {
    let q = abs(p) - extent + radius;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@group(1) @binding(0) var image: texture_2d<f32>;
@group(1) @binding(1) var imageSampler: sampler;
