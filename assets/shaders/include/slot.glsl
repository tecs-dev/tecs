// What an instance's `origin.z` says, shared by every vertex shader that reads
// one.
//
// Three fields in one float, because the alternative is sixteen more bytes on
// every instance in the world to say something almost none of them have
// anything to say about. `instancelayout.packSlot` writes it and the three
// constants below are its `LAYER_SLOTS`, `CLIPS` and `HEIGHTS`; the pair only
// works while they agree. Every value the packing produces is a whole number
// well inside the range a float represents integers exactly over, so all three
// come back out exactly.

// Texture-array layers, and the stride the clip region sits above them at.
const float LAYER_SLOTS = 64.0;
// Clip regions counting region zero, and the stride the cast height sits above
// them at.
const float CLIP_SLOTS = 256.0;
const float HEIGHT_STRIDE = LAYER_SLOTS * CLIP_SLOTS;
// Steps a cast height is quantised to.
const float HEIGHT_STEPS = 255.0;

float slotLayer(float packed) { return mod(packed, LAYER_SLOTS); }

int slotClip(float packed) {
    return int(mod(floor(packed / LAYER_SLOTS), CLIP_SLOTS));
}

// Height above the surface the instance casts from, zero to one. What an
// occluder's silhouette is written into the mask at, and what a drop shadow's
// length is taken from.
float slotHeight(float packed) {
    return floor(packed / HEIGHT_STRIDE) / HEIGHT_STEPS;
}
