// A glyph from a single-channel signed distance field.

// Bilinear reconstruction, done here because the shared sampler may read
// nearest, so the field reconstructs its alpha rather than trusting the filter.
fn glyphField(coordinate: vec2<f32>) -> f32 {
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

    let inside = glyphField(frag.uv) - 0.5;

    // Derivatives make the transition one screen pixel wide at every scale.
    let width = max(fwidth(inside), 1.0 / 255.0);
    let edge = smoothstep(-width, width, inside);
    result.albedo = vec4<f32>(frag.color.rgb, frag.color.a * edge);
    result.coverage = inside;
    // Text draws at its own color. A caption that a scene's lights happen to
    // leave in the dark reads as broken rather than as unlit, and text is
    // written to be read. A label that should take the light is a material of
    // its own, which is what `materials.addRoot` is for.
    result.lit = 0.0;
    return result;
}
