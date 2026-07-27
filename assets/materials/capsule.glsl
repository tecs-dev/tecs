// A stadium: a bar the full width of the quad, with semicircular caps. `param`
// is its thickness as a fraction of the quad's height, so at one the caps meet
// and it is a circle. Rotation stands it on end.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;

    // Distance to the segment the caps are centred on. Folding X collapses the
    // two caps into one and leaves the flat middle at zero, so a single length
    // covers all three parts of the shape.
    float radius = 0.5 * frag.param;
    vec2 offset = vec2(max(abs(frag.local.x) - (0.5 - radius), 0.0),
                       frag.local.y);
    result.coverage = radius - length(offset);

    result.lit = 1.0;
    return result;
}
