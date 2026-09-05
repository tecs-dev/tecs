// A circle with a hole. `param` is the hole's radius as a fraction of the outer
// one, so zero is a disc, a half is a broad band and most of one is a hairline.

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;

    // The band is a circle of the mean radius, thickened by half the
    // difference: the distance to it is the distance to the ring.
    let inner = 0.5 * frag.param;
    let middle = 0.5 * (0.5 + inner);
    let thickness = 0.5 * (0.5 - inner);
    result.coverage = thickness - abs(length(frag.local) - middle);

    result.lit = 1.0;
    return result;
}
