// A glyph, from a multi-channel signed distance field.
//
// The median of the three channels is the signed distance to the outline, in
// the field's own units. Scaling it by how many screen pixels one of those
// units covers is what keeps the outline exact at any size: the quad grows and
// the threshold stays on the curve rather than on a texel boundary, which is
// the whole reason text is a field here and not a bitmap.
//
// `param` carries the field's range as a fraction of an atlas cell, so one
// material serves fonts generated at different ranges.

float glyphMedian(vec3 field) {
    return max(min(field.r, field.g), min(max(field.r, field.g), field.b));
}

// Bilinear reconstruction, done here because the shared sampler reads nearest
// and the median has to be taken after interpolation: taking it first
// collapses three channels into one and throws away the corners they encode,
// which is exactly where a glyph has its sharp features.
vec3 glyphField(vec3 coordinate) {
    vec2 size = vec2(textureSize(images, 0).xy);
    vec2 texel = coordinate.xy * size - 0.5;
    vec2 base = floor(texel);
    vec2 fraction = texel - base;
    vec2 origin = (base + 0.5) / size;
    vec2 stride = 1.0 / size;
    float layer = coordinate.z;

    vec3 a = texture(images, vec3(origin, layer)).rgb;
    vec3 b = texture(images, vec3(origin.x + stride.x, origin.y, layer)).rgb;
    vec3 c = texture(images, vec3(origin.x, origin.y + stride.y, layer)).rgb;
    vec3 d = texture(images, vec3(origin + stride, layer)).rgb;
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();

    float inside = glyphMedian(glyphField(frag.uv)) - 0.5;

    // Screen pixels the field's range spans here. fwidth is how far the atlas
    // coordinate moves across one pixel, so its reciprocal is the atlas scale
    // on screen. Held at one pixel: below that the field cannot resolve an
    // edge, and a narrower width only sharpens noise.
    vec2 texelsPerPixel = 1.0 / fwidth(frag.uv.xy);
    float screenRange = max(0.5 * dot(vec2(frag.param), texelsPerPixel), 1.0);

    // The edge lands in alpha, which the lighting pass carries through, while
    // coverage stays the unscaled distance so membership is decided by the
    // outline itself rather than by how large the glyph happens to be drawn.
    float edge = clamp(inside * screenRange + 0.5, 0.0, 1.0);
    result.albedo = vec4(frag.color.rgb, frag.color.a * edge);
    result.coverage = inside;
    // Text draws at its own color. A caption that a scene's lights happen to
    // leave in the dark reads as broken rather than as unlit, and text is
    // written to be read. A label that should take the light is a material of
    // its own, which is what `materials.addRoot` is for.
    result.lit = 0.0;
    return result;
}
