// The default: the quad, sampled from the image array.
//
// An entity with no Sprite still lands here and samples the white layer, so
// textured and untextured geometry share one path.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = 1.0;
    return result;
}
