// A five-pointed star with a tip at the quad's -Y axis, which is up on screen
// for an unrotated entity. `param` is the radius of the valleys between the
// tips as a fraction of the tips' own, so a small value is a sharp star and a
// large one approaches a ten-sided polygon.
//
// Here because it is the shape a 2D game reaches for that no combination of the
// others produces: a rating, a pickup, a sparkle. The point count is fixed
// because a count is not a ratio, and the parameter is a ratio; how deep the
// valleys cut is the part of a star that is continuous, and it is the part
// worth tweening.

// Signed distance to the nearest edge, negative inside. The point is folded
// into one tip's sector and mirrored across its axis, so ten edges are one
// segment from a tip to the valley beside it.
float starDistance(vec2 point, float outer, float inner) {
    float sector = 3.14159265 / 5.0;
    // Measured from -Y so a tip points up.
    float angle = atan(point.x, -point.y);
    angle = mod(angle + sector, 2.0 * sector) - sector;
    vec2 folded = length(point) * vec2(cos(angle), abs(sin(angle)));

    vec2 tip = vec2(outer, 0.0);
    vec2 edge = inner * vec2(cos(sector), sin(sector)) - tip;
    vec2 offset = folded - tip;
    float along = clamp(dot(offset, edge) / dot(edge, edge), 0.0, 1.0);
    // The cross product is positive on the side the centre is on, so it is the
    // sign the distance takes.
    float side = sign(edge.x * offset.y - edge.y * offset.x);
    return -side * length(offset - edge * along);
}

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -starDistance(frag.local, 0.5, 0.5 * frag.param);
    result.lit = 1.0;
    return result;
}
