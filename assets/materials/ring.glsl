// A circle with a hole. `param` is the hole's radius as a fraction of the outer
// one, so zero is a disc, a half is a broad band and most of one is a hairline.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;

    // The band is a circle of the mean radius, thickened by half the
    // difference: the distance to it is the distance to the ring.
    float inner = 0.5 * frag.param;
    float middle = 0.5 * (0.5 + inner);
    float thickness = 0.5 * (0.5 - inner);
    result.coverage = thickness - abs(length(frag.local) - middle);

    result.lit = 1.0;
    return result;
}
