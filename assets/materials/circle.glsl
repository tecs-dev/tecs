// A circle inscribed in the quad.
//
// Evaluated rather than sampled, so it stays a circle at any scale instead of
// becoming a texture that pixelates, and costs no atlas space.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -(length(frag.local) - 0.5);
    // A dome, because a filled circle is what a dome looks like from directly
    // above and a flat disc under a moving light reads as a hole rather than
    // as a ball. The local coordinate runs to a half at the silhouette, so
    // doubling it is the fraction of the radius.
    result.normal = domeNormal(frag.local * 2.0);
    result.lit = 1.0;
    return result;
}
