// The default: the quad, sampled from its image.
//
// An entity with no `Sprite` still lands here and samples the white fallback,
// so textured and untextured geometry share one path.

fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    let texel = textureSample(image, imageSampler, frag.uv);
    result.albedo = texel * frag.color;

    // Membership is the texture's silhouette, not the quad's. This pass writes
    // depth, so a fragment that survives rejects whatever is behind it: a
    // cut-out sprite that covered its whole quad would hide the scene inside
    // its bounding rectangle as well as painting it.
    //
    // Tested on the texel's own alpha rather than on the product, so the tint
    // stays a color: an entity with no `Sprite` samples the opaque white
    // fallback and draws whatever its tint alpha is.
    //
    // Half is the threshold wherever coverage is a yes or no. A pass that
    // writes with replace lands a texel kept at low alpha at full strength as a
    // dark fringe, and one dropped at high alpha eats into the silhouette, so
    // the halfway point is the split that puts the edge where the artwork drew
    // it.
    //
    // The forward pass blends, so there is nothing to split there: a texel is
    // part of the shape wherever the artwork put any ink at all, and how much
    // of it lands is the alpha above. That is the whole difference between a
    // smoke puff drawn at a third alpha throughout and the same puff vanishing
    // because every texel of it fell below the cut.
    result.coverage = select(texel.a - 0.5, texel.a, frag.blended);
    result.lit = 1.0;
    return result;
}
