// A wedge of a circle, opening about the quad's -Y axis, which is up on screen
// for an unrotated entity. `param` is the sweep as a fraction of a full turn,
// so a quarter is a quadrant and rotation aims it.

// Signed distance to the wedge, negative inside: the disc, cut by the two
// half-planes the aperture opens between. The sweep is symmetric, so folding X
// leaves one plane to test.
fn pieDistance(point: vec2<f32>, halfAperture: f32, radius: f32) -> f32 {
    // Y is negated so the wedge opens upwards on screen.
    let folded = vec2<f32>(abs(point.x), -point.y);
    let edge = vec2<f32>(sin(halfAperture), cos(halfAperture));
    let disc = length(folded) - radius;
    // Distance to the straight side, which is the segment from the center out
    // to the rim along the aperture.
    let side = length(folded - edge * clamp(dot(folded, edge), 0.0, radius));
    return max(disc, side * sign(edge.y * folded.x - edge.x * folded.y));
}

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;
    result.coverage = -pieDistance(frag.local, 3.14159265 * frag.param, 0.5);
    result.lit = 1.0;
    return result;
}
