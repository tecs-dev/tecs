// The quad's outline: a rectangle with a rectangular hole. `param` is the
// border's thickness as a fraction of the quad's half extent, so at one it is
// solid.
//
// The rectangle's answer to the ring, and what a panel edge, a selection box or
// a health bar's surround is. Drawing one as four quads costs four entities and
// puts a seam at each corner.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result;
    result.albedo = texture(images, frag.uv) * frag.color;

    float thickness = 0.5 * frag.param;
    float outer = sdRoundedBox(frag.local, vec2(0.5), 0.0);
    float inner = sdRoundedBox(frag.local, vec2(0.5 - thickness), 0.0);
    // Inside the quad and outside the hole, which is the nearer of the two
    // boundaries once the hole's distance is turned inside out.
    result.coverage = min(-outer, inner);

    result.lit = 1.0;
    return result;
}
