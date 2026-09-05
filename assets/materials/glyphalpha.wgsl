// A directly rasterized grayscale glyph.

// The shared image sampler may read nearest. Reconstruct the coverage here so a
// hinted glyph retains its antialiased edge without growing a second sampler.
fn alphaGlyphCoverage(coordinate: vec2<f32>) -> f32 {
    let size = vec2<f32>(textureDimensions(image, 0));
    let texel = coordinate * size - vec2<f32>(0.5);
    let base = floor(texel);
    let fraction = texel - base;
    let origin = (base + vec2<f32>(0.5)) / size;
    let stride = vec2<f32>(1.0) / size;

    let a = textureSampleLevel(image, imageSampler, origin, 0.0).a;
    let b = textureSampleLevel(image, imageSampler, vec2<f32>(origin.x + stride.x, origin.y), 0.0).a;
    let c = textureSampleLevel(image, imageSampler, vec2<f32>(origin.x, origin.y + stride.y), 0.0).a;
    let d = textureSampleLevel(image, imageSampler, origin + stride, 0.0).a;
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    let coverage = alphaGlyphCoverage(frag.uv);
    result.albedo = vec4<f32>(frag.color.rgb, frag.color.a * coverage);
    result.coverage = coverage;
    result.lit = 0.0;
    return result;
}
