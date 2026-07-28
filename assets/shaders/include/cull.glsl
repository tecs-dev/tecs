// Shared between the passes that write the visible lists and the passes that
// read them. The values have to agree across all of them, and they did not have
// to before: each pass declared its own copy, so a change to one was a silent
// disagreement rather than a compile error.

// Three lists come out of one scan: what the G-buffer rasterises, what the
// forward pass blends over the composited image, and what casts a shadow. A
// slot therefore carries a rank per lane rather than a single rank, and all
// three fit in the word the mark pass already writes: a rank is an offset
// within a workgroup of 256, and the shadow lane's is that times its fan-out.
const uint LANE_BITS = 10u;
const uint LANE_MASK = 0x3FFu;

// Written into a lane an instance is not in, either because the view rejected
// it or because another lane claimed it. The mask itself, so it is a value no
// rank can reach: the largest a lane produces is 255 times the shadow lane's
// fan-out, which is 1020 at a fan-out of four. Past a fan-out of four the lane
// overflows and a rank would have to come from somewhere other than this word.
const uint CULLED = 0x3FFu;

// Which lane a pass is filling, as an index rather than a shift, so one shader
// fills any of the three and the shift stays this file's arithmetic.
const uint LANE_OPAQUE = 0u;
const uint LANE_BLEND = 1u;
const uint LANE_CAST = 2u;

// Where a lane's rank sits inside the packed slot.
uint laneShift(uint lane) { return lane * LANE_BITS; }

// The role an instance was extracted with, read from the bound the cull already
// streams.
//
// A half extent is a length, so neither of its signs carries anything, and the
// two of them say which of four things an instance is. That the four are
// exclusive is the point rather than a limitation: a blended instance never
// reaches the G-buffer, so a hard silhouette of it would be a lie, and the one
// scene the previous engine shipped that used both features kept occluders and
// drop-shadow casters disjoint on purpose, because making every tree an
// occluder merges them under the mask's max blend into one mat of darkness.
//
// The alternative is reading a flag off the instance itself, which is a
// sixty-four byte gather for one bit on every instance in the world every
// frame, drawn or not, and avoiding exactly that is why the bound is kept apart
// from the instance at all.
bool cullNegativeZ(vec4 box) { return floatBitsToUint(box.z) >= 0x80000000u; }
bool cullNegativeW(vec4 box) { return floatBitsToUint(box.w) >= 0x80000000u; }

// Routed to the forward pass rather than to the G-buffer.
bool cullBlended(vec4 box) { return cullNegativeZ(box) && !cullNegativeW(box); }

// Draws into the occluder mask or the drop-shadow target, which is the one lane
// that tests against a rectangle wider than the view.
bool cullCasts(vec4 box) { return cullNegativeW(box); }

// Blocks light: its silhouette goes into the shared mask that every light
// marches against.
bool cullOccluder(vec4 box) { return cullNegativeW(box) && !cullNegativeZ(box); }

// Throws a stretched copy of itself along the ground away from each light, which
// darkens what it lands on and blocks nothing.
bool cullDropShadow(vec4 box) { return cullNegativeW(box) && cullNegativeZ(box); }
