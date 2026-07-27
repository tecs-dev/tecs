// An ellipse filling the quad's width. `param` is its height as a fraction of
// the quad's, so one is the quad's full extent and a non-square scale then
// draws a genuine ellipse rather than a squashed disc.
//
// A circle already stretches with the quad, so a shape that only did that would
// be the circle under another name. The parameter is what this adds: an entity
// scaled evenly, which is most of them, can still be an ellipse, and tweening
// the parameter squashes it without touching the transform.

// Signed distance to an axis-aligned ellipse, negative inside. The implicit
// form divided by its own gradient, which puts the zero exactly on the curve
// and makes the falloff a distance rather than a ratio, so an edge is the same
// width at any size. The exact distance is a quartic root and this is within a
// fraction of a pixel of it everywhere the edge is.
float ellipseDistance(vec2 point, vec2 radii) {
    float scaled = length(point / radii);
    float gradient = length(point / (radii * radii));
    return (scaled - 1.0) * scaled / max(gradient, 1e-6);
}

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    // A height of exactly zero divides by it, and the result compares false
    // against the discard, so the quad would fill rather than empty. Held at a
    // hairline instead, which is what a vanishing ellipse should look like.
    vec2 radii = vec2(0.5, max(0.5 * frag.param, 1e-4));
    result.coverage = -ellipseDistance(frag.local, radii);
    // The circle's dome, squashed the way the silhouette is: dividing by the
    // two radii puts the rim at unit length on both axes, so a wide flat
    // ellipse domes gently across and steeply up rather than bulging into a
    // sphere that its own outline does not describe.
    result.normal = domeNormal(frag.local / radii);
    result.lit = 1.0;
    return result;
}
