// A stadium: a bar the full width of the quad, with semicircular caps. `param`
// is its thickness as a fraction of the quad's height, so at one the caps meet
// and it is a circle. Rotation stands it on end.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;

    // Distance to the segment the caps are centred on. Folding X collapses the
    // two caps into one and leaves the flat middle at zero, so a single length
    // covers all three parts of the shape.
    float radius = 0.5 * frag.param;
    vec2 offset = vec2(max(abs(frag.local.x) - (0.5 - radius), 0.0),
                       frag.local.y);
    result.coverage = radius - length(offset);

    // A cylinder with hemispherical caps, which is the capsule's silhouette
    // swept about its own segment. The fold that collapsed the two caps threw
    // the sign of X away and the normal needs it back, since a normal is a
    // direction rather than a distance: without it both caps would face the
    // same way and one of them would light from behind. Along the flat middle
    // the X offset is zero, so the surface bends only across the bar, which is
    // what makes a capsule read as a rod rather than as a stretched ball.
    vec2 rim = vec2(sign(frag.local.x) * offset.x, offset.y)
        / max(radius, 1e-6);
    result.normal = domeNormal(rim);

    result.lit = 1.0;
    return result;
}
