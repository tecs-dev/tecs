// What an instance's `origin.z` says, shared by every vertex shader that reads
// one.
//
// Four fields in one float, because the alternative is sixteen more bytes on
// every instance in the world to say something almost none of them have
// anything to say about. `instancelayout.packSlot` writes it and the four
// constants below are its `LAYER_SLOTS`, `CLIPS`, `HEIGHTS` and `BLENDS`; the
// pair only works while they agree. Every value the packing produces is a whole
// number inside the range a float represents integers exactly over, so all four
// come back out exactly.
//
// Each is prefixed, because this file is included into shaders that declare
// constants and uniform arrays of their own and a plain name here collided with
// one of them.

// Texture-array layers, and the stride the clip region sits above them at.
const float SLOT_LAYERS = 64.0;
// Clip regions counting region zero, and the stride the cast height sits above
// them at. The two fragment shaders that read the region table declare the same
// count as `CLIP_SLOTS`, for their uniform array's length rather than for this
// arithmetic, and this one is named apart from theirs because a shader may
// include this file and declare that array.
const float SLOT_CLIPS = 256.0;
const float HEIGHT_STRIDE = SLOT_LAYERS * SLOT_CLIPS;
// Steps a cast height is quantised to.
const float HEIGHT_STEPS = 255.0;
// Blend modes, and the stride they sit above the cast height at.
const float SLOT_BLENDS = 2.0;
const float BLEND_STRIDE = HEIGHT_STRIDE * (HEIGHT_STEPS + 1.0);

// The modes `slotBlend` answers, and `BLEND_IDS` in
// src/tecs/gpu/instancelayout.tl.
const int BLEND_ALPHA = 0;
const int BLEND_ADDITIVE = 1;

float slotLayer(float packed) { return mod(packed, SLOT_LAYERS); }

int slotClip(float packed) {
    return int(mod(floor(packed / SLOT_LAYERS), SLOT_CLIPS));
}

// Height above the surface the instance casts from, zero to one. What an
// occluder's silhouette is written into the mask at, and what a drop shadow's
// length is taken from.
float slotHeight(float packed) {
    return mod(floor(packed / HEIGHT_STRIDE), HEIGHT_STEPS + 1.0) / HEIGHT_STEPS;
}

// How the forward pass combines this instance with the image it is drawn over.
// Read by that pass and by nothing else: the three roles that reach the G-buffer
// write with replace and have nothing to combine.
int slotBlend(float packed) {
    return int(mod(floor(packed / BLEND_STRIDE), SLOT_BLENDS));
}
