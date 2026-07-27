// The default: the quad, sampled from the image array.
//
// An entity with no Sprite still lands here and samples the white layer, so
// textured and untextured geometry share one path.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    vec4 texel = texture(images, frag.uv);
    result.albedo = texel * frag.color;

    // Membership is the texture's silhouette, not the quad's. This pass writes
    // depth, so a fragment that survives rejects whatever is behind it: a
    // cut-out sprite that covered its whole quad would hide the scene inside
    // its bounding rectangle as well as painting it.
    //
    // Tested on the texel's own alpha rather than on the product, so the tint
    // stays a colour: an entity with no Sprite samples the opaque white layer
    // and draws whatever its tint alpha is, exactly as an untextured quad
    // always has.
    //
    // Half is the threshold because coverage here is a yes or no. The pass
    // writes with replace, so a texel kept at low alpha lands at full strength
    // as a dark fringe rather than as a soft edge, and one dropped at high
    // alpha eats into the silhouette. The halfway point is the split that puts
    // the edge where the artwork drew it; smooth edges are the forward-blended
    // path's job.
    result.coverage = texel.a - 0.5;
    result.lit = 1.0;
    return result;
}
