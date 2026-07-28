// What an effect, an emitter and a particle are, shared by the three passes
// that make particles happen.
//
// Three compute shaders read these records: one advances each emitter's
// schedule, one initializes the particles that schedule asked for, and one
// integrates every live particle and writes its instance. They have to agree
// on every offset, so the offsets are stated once here rather than three
// times.
//
// The host half is src/tecs/gfx/particles.tl, which writes all three buffers
// and holds the same numbers. The pair only works while they agree, and the
// spec that holds them to it is spec/particles_spec.lua.
//
// The caller supplies the sets and bindings, because a read-only buffer's
// index differs per pass: define PARTICLE_SET and the three binding macros
// before including this file. `particle.simulate.comp.glsl` is the worked
// example.
//
// Note for anyone editing these comments: includes are expanded by a textual
// pass over the whole file before anything parses it, so an include directive
// written in a comment here is an include of this file by itself, and the
// expander reports it as a cycle. Say the name, do not write the directive.

#ifndef PARTICLE_SET
#error "define PARTICLE_SET before including particle.glsl"
#endif
#ifndef PARTICLE_EFFECT_BINDING
#error "define PARTICLE_EFFECT_BINDING before including particle.glsl"
#endif
#ifndef PARTICLE_EMITTER_BINDING
#error "define PARTICLE_EMITTER_BINDING before including particle.glsl"
#endif

layout(set = PARTICLE_SET, binding = PARTICLE_EFFECT_BINDING) readonly buffer Effects {
    // Fixed-size effect records, then the curve and gradient samples they
    // point at. One buffer rather than two, for the reason the frame table is
    // one: a lookup table belongs beside the thing that names it, and a second
    // buffer would be a second binding in every pass that reads either.
    float value[];
} effects;

layout(set = PARTICLE_SET, binding = PARTICLE_EMITTER_BINDING) readonly buffer Emitters {
    float value[];
} emitters;

// Floats per effect record. `EFFECT_FLOATS` in src/tecs/gfx/particles.tl is
// the same number.
const int PARTICLE_EFFECT_FLOATS = 64;

// Where each field sits within one effect record.
const int EFFECT_RATE = 0;
const int EFFECT_DURATION = 1;
const int EFFECT_LOOPING = 2;
const int EFFECT_DELAY = 3;
const int EFFECT_OVERFLOW = 4;
const int EFFECT_BURST_COUNT = 5;
const int EFFECT_SHAPE = 6;
const int EFFECT_SHAPE_WIDTH = 7;
const int EFFECT_SHAPE_HEIGHT = 8;
const int EFFECT_SHAPE_ARC = 9;
const int EFFECT_SHAPE_ROTATION = 10;
const int EFFECT_DISTRIBUTION = 11;
const int EFFECT_DIRECTION = 12;
const int EFFECT_SPREAD = 13;
const int EFFECT_SPACE = 14;
const int EFFECT_INHERIT = 15;
// Four bursts, each a time within the cycle and a count.
const int EFFECT_BURSTS = 16;
const int EFFECT_MAX_BURSTS = 4;
const int EFFECT_LIFETIME_MIN = 24;
const int EFFECT_LIFETIME_MAX = 25;
const int EFFECT_SPEED_MIN = 26;
const int EFFECT_SPEED_MAX = 27;
const int EFFECT_SIZE_MIN = 28;
const int EFFECT_SIZE_MAX = 29;
const int EFFECT_ROTATION_MIN = 30;
const int EFFECT_ROTATION_MAX = 31;
const int EFFECT_ANGULAR_MIN = 32;
const int EFFECT_ANGULAR_MAX = 33;
const int EFFECT_ACCEL_X_MIN = 34;
const int EFFECT_ACCEL_X_MAX = 35;
const int EFFECT_ACCEL_Y_MIN = 36;
const int EFFECT_ACCEL_Y_MAX = 37;
const int EFFECT_DRAG = 38;
const int EFFECT_RADIAL_MIN = 39;
const int EFFECT_RADIAL_MAX = 40;
const int EFFECT_TANGENTIAL_MIN = 41;
const int EFFECT_TANGENTIAL_MAX = 42;
const int EFFECT_SIZE_CURVE = 43;
const int EFFECT_COLOR_GRADIENT = 44;
const int EFFECT_COLOR_R = 45;
const int EFFECT_COLOR_G = 46;
const int EFFECT_COLOR_B = 47;
const int EFFECT_COLOR_A = 48;
const int EFFECT_U0 = 49;
const int EFFECT_V0 = 50;
const int EFFECT_U1 = 51;
const int EFFECT_V1 = 52;
const int EFFECT_SLOT = 53;
const int EFFECT_MATERIAL = 54;
const int EFFECT_DEPTH = 55;
const int EFFECT_UNBOUNDED = 56;
const int EFFECT_PLAYBACK = 57;
const int EFFECT_PLAYBACK_TICKS = 58;
const int EFFECT_PIVOT_X = 59;
const int EFFECT_PIVOT_Y = 60;
const int EFFECT_ALIGNMENT = 61;
const int EFFECT_STRETCH = 62;
const int EFFECT_OUTWARD = 63;

// Floats per emitter record, and where each field sits.
const int PARTICLE_EMITTER_FLOATS = 24;
const int EMITTER_EFFECT = 0;
const int EMITTER_SLOT_BASE = 1;
const int EMITTER_SLOT_COUNT = 2;
const int EMITTER_PLAYING = 3;
const int EMITTER_SEED = 4;
const int EMITTER_GENERATION = 5;
const int EMITTER_START_STEP = 6;
const int EMITTER_CLEAR_STEP = 7;
const int EMITTER_PREV_X = 8;
const int EMITTER_PREV_Y = 9;
const int EMITTER_X = 10;
const int EMITTER_Y = 11;
const int EMITTER_ROTATION = 12;
const int EMITTER_RATE_SCALE = 13;
const int EMITTER_SIZE_SCALE = 14;
const int EMITTER_TIME_SCALE = 15;
const int EMITTER_TINT_R = 16;
const int EMITTER_TINT_G = 17;
const int EMITTER_TINT_B = 18;
const int EMITTER_TINT_A = 19;
const int EMITTER_BURST = 20;
// The emitter's own step count, and how many of them it advanced this frame.
//
// Its own rather than the world's, because an emitter that is paused, held by
// the entity's `Paused` tag or stopped has to stand still while the world goes
// on drawing frames. The host advances this only on the frames the emitter is
// running, so every age measured from it holds across a pause without anything
// having to be shifted afterwards.
const int EMITTER_CLOCK = 21;
const int EMITTER_STEPS = 22;

// Floats of per-particle state, and where each sits. This buffer is private to
// the GPU: nothing reads it back and the vertex shader never sees it. What the
// vertex shader sees is the instance the simulate pass writes beside it.
const int PARTICLE_STATE_FLOATS = 8;
const int STATE_X = 0;
const int STATE_Y = 1;
const int STATE_VX = 2;
const int STATE_VY = 3;
const int STATE_BIRTH = 4;
const int STATE_LIFETIME = 5;
const int STATE_SERIAL = 6;
const int STATE_GENERATION = 7;

// Uints of per-emitter runtime state, written by the emit pass and read by the
// two after it. Kept apart from the emitter record because the host owns that
// one and would overwrite these every time it uploaded a playback change.
const int PARTICLE_EMITTER_STATE_UINTS = 8;
const int RUNTIME_CURSOR = 0;
const int RUNTIME_ACCUMULATOR = 1;
const int RUNTIME_SPAWN_CURSOR = 2;
const int RUNTIME_SPAWN_COUNT = 3;
const int RUNTIME_BURSTS_FIRED = 4;
const int RUNTIME_GENERATION = 5;
const int RUNTIME_CYCLE = 6;

// Samples one compiled curve or gradient holds. A gradient holds four floats
// per sample and a curve one.
const int PARTICLE_CURVE_SAMPLES = 32;

// Spawn shapes, as `EFFECT_SHAPE` holds them.
const float SHAPE_POINT = 0.0;
const float SHAPE_LINE = 1.0;
const float SHAPE_RECTANGLE = 2.0;
const float SHAPE_RECTANGLE_EDGE = 3.0;
const float SHAPE_DISC = 4.0;
const float SHAPE_RING = 5.0;
const float SHAPE_CONE = 6.0;

// Where a particle goes when the pool is full, as `EFFECT_OVERFLOW` holds it.
const float OVERFLOW_DROP = 0.0;

// Center of a slot nothing is drawing. `instancelayout.HIDDEN` in
// src/tecs/gpu/instancelayout.tl is the same number, and the mark pass rejects
// a bound out here before the draw sees it.
const float PARTICLE_HIDDEN = 1e30;
const float PARTICLE_HIDDEN_DEPTH = 0.999;
const float PARTICLE_UNBOUNDED = 1e30;

// Lanes a particle's random draws come from. A lane per property, so adding a
// property does not shift the numbers every other property draws: an effect
// edited to randomize its rotation keeps the sizes it had.
const uint LANE_LIFETIME = 1u;
const uint LANE_SPEED = 2u;
const uint LANE_SPREAD = 3u;
const uint LANE_SIZE = 4u;
const uint LANE_ROTATION = 5u;
const uint LANE_ANGULAR = 6u;
const uint LANE_ACCEL_X = 7u;
const uint LANE_ACCEL_Y = 8u;
const uint LANE_RADIAL = 9u;
const uint LANE_TANGENTIAL = 10u;
const uint LANE_SHAPE_A = 11u;
const uint LANE_SHAPE_B = 12u;

// One round of a counter-based integer hash.
//
// Counter based rather than a generator carrying state, and that is the whole
// point: a particle's draws are a pure function of the seed, the generation,
// the serial and the lane, so nothing has to be stored and nothing shifts when
// an unrelated property is added. It is also what would let a restored emitter
// be caught up, since every particle it would have produced is recomputable.
uint particleHash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// A draw in zero to one for this particle on this lane.
//
// The top twenty-four bits, because that is what a float32 carries integers
// exactly over, so the division is exact and the result is uniform rather than
// clumped at the values the mantissa can reach.
float particleRandom(float seed, float generation, float serial, uint lane) {
    uint key = particleHash(uint(seed) * 0x9e3779b9u
        + uint(generation) * 0x85ebca6bu);
    return float(particleHash(key + uint(serial) * 0xc2b2ae35u + lane * 0x27d4eb2fu)
        >> 8) * (1.0 / 16777216.0);
}

// A draw between two bounds. Equal bounds are a constant and cost the same,
// which is what lets the authoring surface take a number or a range without
// the shader branching on which it was given.
float particleRange(float lo, float hi, float seed, float generation,
                    float serial, uint lane) {
    return lo + (hi - lo) * particleRandom(seed, generation, serial, lane);
}

// A draw shaped like a normal distribution, in zero to one.
//
// Three uniforms averaged, which is the cheap approximation: it has the right
// mean, it tails off, and it costs three hashes rather than a log and a
// sine. A smoke column reads as a column under it, which is what it is for.
float particleNormal(float seed, float generation, float serial, uint lane) {
    float sum = particleRandom(seed, generation, serial, lane)
        + particleRandom(seed, generation, serial, lane + 64u)
        + particleRandom(seed, generation, serial, lane + 128u);
    return sum * (1.0 / 3.0);
}

// One effect record's first float.
int particleEffectBase(float index) {
    return int(index) * PARTICLE_EFFECT_FLOATS;
}

// One emitter record's first float.
int particleEmitterBase(int index) {
    return index * PARTICLE_EMITTER_FLOATS;
}

// A compiled curve at a normalized age.
//
// `base` is an absolute offset into the effect buffer, or negative for an
// effect that named no curve, which reads as a flat one so the caller
// multiplies by it either way.
float particleCurve(float base, float t) {
    if (base < 0.0) { return 1.0; }
    float x = clamp(t, 0.0, 1.0) * float(PARTICLE_CURVE_SAMPLES - 1);
    int lo = int(floor(x));
    int hi = min(lo + 1, PARTICLE_CURVE_SAMPLES - 1);
    int at = int(base);
    return mix(effects.value[at + lo], effects.value[at + hi], x - float(lo));
}

// A compiled gradient at a normalized age, as straight RGBA.
//
// Negative for an effect that named no gradient, which reads as white so the
// caller multiplies by it either way. The alpha channel is carried and is
// inert: the geometry pass writes with replace, so nothing blends against it.
vec4 particleGradient(float base, float t) {
    if (base < 0.0) { return vec4(1.0); }
    float x = clamp(t, 0.0, 1.0) * float(PARTICLE_CURVE_SAMPLES - 1);
    int lo = int(floor(x));
    int hi = min(lo + 1, PARTICLE_CURVE_SAMPLES - 1);
    int at = int(base);
    int a = at + lo * 4;
    int b = at + hi * 4;
    return mix(vec4(effects.value[a], effects.value[a + 1],
                    effects.value[a + 2], effects.value[a + 3]),
               vec4(effects.value[b], effects.value[b + 1],
                    effects.value[b + 2], effects.value[b + 3]),
               x - float(lo));
}
