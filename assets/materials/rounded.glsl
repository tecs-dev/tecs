// A rectangle with rounded corners. `param` is the radius, as a fraction of
// the quad, so half of it is a circle.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -sdRoundedBox(frag.local, vec2(0.5), frag.param);
    return result;
}
