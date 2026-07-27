// A thick line with round caps, drawn along the quad's diagonal. `param` is its
// thickness as a fraction of the quad.
//
// The diagonal rather than an axis, because that is what makes a line an
// entity: place it at the midpoint of the two points it joins and scale it by
// their signed difference, and it draws the segment between them. A negative
// scale mirrors the quad, which takes the diagonal with it, so either direction
// works without the material knowing which.
//
// The caps are pulled in by their own radius so a thick line stays inside its
// quad instead of being cut off at the corner.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;

    // Half the quad's diagonal, which is also the unit vector along it.
    const float DIAGONAL = 0.7071068;

    float radius = 0.5 * frag.param;
    vec2 end = vec2(DIAGONAL) * max(DIAGONAL - radius, 0.0);
    // The segment runs from -end to +end, so one clamp covers both halves.
    float along = clamp(dot(frag.local, end) / max(dot(end, end), 1e-6),
                        -1.0, 1.0);
    result.coverage = radius - length(frag.local - end * along);

    result.lit = 1.0;
    return result;
}
