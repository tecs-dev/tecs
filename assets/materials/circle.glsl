// A circle inscribed in the quad.
//
// Evaluated rather than sampled, so it stays a circle at any scale instead of
// becoming a texture that pixelates, and costs no atlas space.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -(length(frag.local) - 0.5);
    return result;
}
