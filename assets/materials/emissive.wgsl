// The quad, giving off its own color rather than only reflecting light.
//
// The lighting resolve adds emission on top of whatever the lighting produced,
// past the ambient, past every light and past the drop shadow, so a surface that
// emits is as bright in the dark as it is under a lamp. That is the whole of
// what makes a glowing sign a sign, and nothing else in the material set can
// produce it: every other material leaves the emission attachment at zero.
//
// `param` is how much it gives off, from nothing at zero to its full color at
// one. It is separate from the albedo, which stays what the surface looks like
// when a light falls on it: a lamp's glass is grey and glows warm.

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    let texel = textureSample(image, imageSampler, frag.uv);
    result.albedo = texel * frag.color;
    result.emission = vec4<f32>(result.albedo.rgb, frag.param);
    result.coverage = select(texel.a - 0.5, texel.a, frag.blended);
    return result;
}
