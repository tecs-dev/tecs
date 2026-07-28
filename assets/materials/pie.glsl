// A wedge of a circle, opening about the quad's -Y axis, which is up on screen
// for an unrotated entity. `param` is the sweep as a fraction of a full turn,
// so a quarter is a quadrant and rotation aims it.

// Signed distance to the wedge, negative inside: the disc, cut by the two
// half-planes the aperture opens between. The sweep is symmetric, so folding X
// leaves one plane to test.
float pieDistance(vec2 point, float halfAperture, float radius) {
    // Y is negated so the wedge opens upwards on screen.
    vec2 folded = vec2(abs(point.x), -point.y);
    vec2 edge = vec2(sin(halfAperture), cos(halfAperture));
    float disc = length(folded) - radius;
    // Distance to the straight side, which is the segment from the center out
    // to the rim along the aperture.
    float side = length(folded - edge * clamp(dot(folded, edge), 0.0, radius));
    return max(disc, side * sign(edge.y * folded.x - edge.x * folded.y));
}

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -pieDistance(frag.local, 3.14159265 * frag.param, 0.5);
    result.lit = 1.0;
    return result;
}
