// A directly rasterized grayscale glyph from SDL_ttf.

// The shared image sampler reads nearest. Reconstruct the coverage here so a
// hinted glyph retains its antialiased edge without growing a second sampler.
float alphaGlyphCoverage(vec3 coordinate) {
    vec2 size = vec2(textureSize(images, 0).xy);
    vec2 texel = coordinate.xy * size - 0.5;
    vec2 base = floor(texel);
    vec2 fraction = texel - base;
    vec2 origin = (base + 0.5) / size;
    vec2 stride = 1.0 / size;
    float layer = coordinate.z;

    float a = texture(images, vec3(origin, layer)).a;
    float b = texture(images, vec3(origin.x + stride.x, origin.y, layer)).a;
    float c = texture(images, vec3(origin.x, origin.y + stride.y, layer)).a;
    float d = texture(images, vec3(origin + stride, layer)).a;
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    float coverage = alphaGlyphCoverage(frag.uv);
    result.albedo = vec4(frag.color.rgb, frag.color.a * coverage);
    result.coverage = coverage;
    result.lit = 0.0;
    return result;
}
