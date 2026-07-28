// Shared between the passes that write the visible lists and the passes that
// read them. The values have to agree across all of them, and they did not have
// to before: each pass declared its own copy, so a change to one was a silent
// disagreement rather than a compile error.

// Two lists come out of one scan: what the G-buffer rasterises and what the
// forward pass blends over the composited image. A slot therefore carries a
// rank per lane rather than a single rank. Both fit because a rank is an offset
// within a workgroup of 256 and can never reach the sentinel below.
const uint LANE_MASK = 0xFFFFu;

// Written into a lane an instance is not in, either because the view rejected
// it or because the other lane claimed it.
const uint CULLED = 0xFFFFu;

// Where each lane's rank sits inside the packed slot. `compact` is told which
// one it is filling rather than deciding, so one shader fills both.
const uint LANE_OPAQUE = 0u;
const uint LANE_BLEND = 16u;

// Which lane an instance is in, read from the bound the cull already streams.
//
// A half extent is a length, so its sign carries nothing: extraction negates
// the first of the two to say the instance is blended, and every reader takes
// the magnitude. The alternative is reading the instance's own alpha here,
// which is a sixty-four byte gather for one float on every instance in the
// world every frame, drawn or not, and avoiding exactly that is why the bound
// is kept apart from the instance at all.
bool cullBlended(vec4 box) {
    return floatBitsToUint(box.z) >= 0x80000000u;
}
