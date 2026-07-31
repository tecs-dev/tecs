// A glyph from SDL_ttf's single-channel signed distance field.

// Bilinear reconstruction, done here because the shared sampler reads nearest
// so the field reconstructs its alpha here.
float glyphField(vec3 coordinate) {
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

    // Derivatives make the transition one screen pixel wide at every scale.
    float distance = glyphField(frag.uv) - 0.5;
    float width = max(fwidth(distance), 1.0 / 255.0);

    // A small outward bias keeps a one-pixel stem from vanishing when a UI
    // screenshot is reduced. Expressing it through the derivative makes it a
    // fraction of one screen pixel rather than a font-size-dependent weight.
    float inside = distance + width * 0.35;
    float edge = smoothstep(-width, width, inside);
    result.albedo = vec4(frag.color.rgb, frag.color.a * edge);
    result.coverage = inside;
    // Text draws at its own color. A caption that a scene's lights happen to
    // leave in the dark reads as broken rather than as unlit, and text is
    // written to be read. A label that should take the light is a material of
    // its own, which is what `materials.addRoot` is for.
    result.lit = 0.0;
    return result;
}
