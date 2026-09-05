// A rectangle with rounded corners. `param` is the radius, as a fraction of the
// quad, so half of it is a circle.

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;
    result.coverage = -sdRoundedBox(frag.local, vec2<f32>(0.5), frag.param);
    result.lit = 1.0;
    return result;
}
