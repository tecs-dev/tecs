// A triangle inscribed in the quad: its apex at the middle of the -Y edge,
// which is up on screen for an unrotated entity, and its base the whole +Y
// edge.
//
// The one shape here that takes no parameter. The quad's scale already sets its
// width and height independently and rotation aims it, which is everything a
// triangle has; giving the parameter a meaning would only be a second way to
// say what the transform says.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;

    // Three half-planes, folded about X so the two slanted sides are one. The
    // normals are unit length, so the largest of the three is a distance.
    vec2 folded = vec2(abs(frag.local.x), frag.local.y);
    // The slanted side runs from the apex at (0, -0.5) to (0.5, 0.5), so its
    // outward normal is (2, -1) normalised.
    float side = dot(normalize(vec2(2.0, -1.0)), folded - vec2(0.0, -0.5));
    float base = folded.y - 0.5;
    result.coverage = -max(side, base);

    result.lit = 1.0;
    return result;
}
