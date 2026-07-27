#version 450
// Fills the slots the emit pass reserved.
//
// One thread per pool slot, so a burst costs as many threads as it has
// particles rather than one thread going round that many times. A slot works
// out whether it is a target arithmetically: its emitter reserved a
// contiguous, wrapping block of its own range, so the distance from the
// block's start decides both membership and which serial this particle is.
//
// Nothing here is ordered against anything else. Two threads never write one
// slot, because the block is a range of distinct slots, and a slot's serial is
// derived rather than allocated.
layout(local_size_x = 64) in;

#define PARTICLE_SET 0
#define PARTICLE_EFFECT_BINDING 0
#define PARTICLE_EMITTER_BINDING 1
#include "particle.glsl"

layout(set = 0, binding = 2) readonly buffer Owners { uint value[]; } owners;
layout(set = 0, binding = 3) readonly buffer Runtime { uint value[]; } runtime;

layout(set = 1, binding = 0) buffer States { float value[]; } states;

layout(set = 2, binding = 0) uniform Particles {
    vec4 timing;
    vec4 pool;
} params;

// Turns a vector by an angle. Written out rather than built as a mat2, because
// the two callers below each want one of them and a matrix would be built for
// both.
vec2 particleTurn(vec2 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

void main() {
    uint slot = gl_GlobalInvocationID.x;
    if (slot >= uint(params.pool.y)) { return; }

    uint owner = owners.value[slot];
    if (owner == 0u) { return; }

    int emitter = int(owner) - 1;
    int at = emitter * PARTICLE_EMITTER_STATE_UINTS;
    uint count = runtime.value[at + RUNTIME_SPAWN_COUNT];
    if (count == 0u) { return; }

    int base = particleEmitterBase(emitter);
    uint range = uint(emitters.value[base + EMITTER_SLOT_COUNT]);
    uint cursor = runtime.value[at + RUNTIME_SPAWN_CURSOR];
    // Where in the emitter's range this frame's block starts, and how far into
    // it this slot falls. The cursor only ever rises, so the modulo is what
    // wraps a long-running emitter back over its own oldest particles, which
    // is the replace-the-oldest policy expressed as arithmetic rather than as
    // a search.
    uint offset = (slot - uint(emitters.value[base + EMITTER_SLOT_BASE])
        + range - cursor % range) % range;
    if (offset >= count) { return; }

    uint serial = cursor + offset;
    int effect = particleEffectBase(emitters.value[base + EMITTER_EFFECT]);
    float seed = emitters.value[base + EMITTER_SEED];
    float generation = emitters.value[base + EMITTER_GENERATION];
    float number = float(serial);

    float lifetime = particleRange(effects.value[effect + EFFECT_LIFETIME_MIN],
        effects.value[effect + EFFECT_LIFETIME_MAX],
        seed, generation, number, LANE_LIFETIME);
    if (lifetime <= 0.0) { return; }

    int state = int(slot) * PARTICLE_STATE_FLOATS;
    // The emitter's own clock, so everything measured from a birth step holds
    // across a pause rather than ageing through it.
    float clock = emitters.value[base + EMITTER_CLOCK];
    float steps = emitters.value[base + EMITTER_STEPS];
    float timestep = params.timing.z * emitters.value[base + EMITTER_TIME_SCALE];

    // Drop rather than replace, when the effect asked for it: the slot the
    // cursor came round to still holds a particle that has not finished, so
    // this emission is the one that gives way. The serial is spent either way,
    // which is what keeps the sequence reproducible whichever policy is on.
    if (effects.value[effect + EFFECT_OVERFLOW] == OVERFLOW_DROP) {
        float held = states.value[state + STATE_LIFETIME];
        if (held > 0.0
            && (clock - states.value[state + STATE_BIRTH]) * timestep < held) {
            return;
        }
    }

    // Spread across the steps this frame covered, so a frame that fell behind
    // lays its particles down the window it missed rather than stacking them
    // all on its last step.
    float birth = clock - steps + 1.0
        + floor(float(offset) * steps / float(count));

    // And spread along the path the emitter travelled, by this emission's own
    // fraction of the frame. Without it a fast emitter lays clumps at frame
    // boundaries, which is the most visible artefact a trail has.
    float along = (float(offset) + 0.5) / float(count);
    vec2 previous = vec2(emitters.value[base + EMITTER_PREV_X],
                         emitters.value[base + EMITTER_PREV_Y]);
    vec2 current = vec2(emitters.value[base + EMITTER_X],
                        emitters.value[base + EMITTER_Y]);
    vec2 origin = mix(previous, current, along);
    float facing = emitters.value[base + EMITTER_ROTATION];

    // Where in the shape, and which way that place points, both in the shape's
    // own frame. One switch, so a shape with a meaningful outward normal can
    // offer it and one without falls back on the effect's direction, and one
    // rotation afterwards turns the area and the normal together.
    float shape = effects.value[effect + EFFECT_SHAPE];
    float width = effects.value[effect + EFFECT_SHAPE_WIDTH];
    float height = effects.value[effect + EFFECT_SHAPE_HEIGHT];
    float arc = effects.value[effect + EFFECT_SHAPE_ARC];
    float normal = effects.value[effect + EFFECT_DISTRIBUTION];

    float a = particleRandom(seed, generation, number, LANE_SHAPE_A);
    float b = normal != 0.0
        ? particleNormal(seed, generation, number, LANE_SHAPE_B)
        : particleRandom(seed, generation, number, LANE_SHAPE_B);

    vec2 place = vec2(0.0);
    float outward = effects.value[effect + EFFECT_DIRECTION];
    if (shape == SHAPE_LINE) {
        place = vec2((a - 0.5) * width, 0.0);
    } else if (shape == SHAPE_RECTANGLE) {
        place = vec2((a - 0.5) * width, (b - 0.5) * height);
    } else if (shape == SHAPE_RECTANGLE_EDGE) {
        // One draw picks the side and how far along it, which keeps the two
        // perpendicular pairs evenly weighted without a second hash.
        float side = floor(a * 4.0);
        float run = fract(a * 4.0);
        if (side < 1.0) {
            place = vec2((run - 0.5) * width, -0.5 * height);
        } else if (side < 2.0) {
            place = vec2((run - 0.5) * width, 0.5 * height);
        } else if (side < 3.0) {
            place = vec2(-0.5 * width, (run - 0.5) * height);
        } else {
            place = vec2(0.5 * width, (run - 0.5) * height);
        }
        outward = atan(place.y, place.x);
    } else if (shape == SHAPE_DISC || shape == SHAPE_RING
               || shape == SHAPE_CONE) {
        float angle = (a - 0.5) * arc;
        // The square root is what spreads an area sample evenly. Without it
        // the middle of a disc is crowded, because equal steps in radius
        // cover unequal areas.
        float radius = shape == SHAPE_DISC ? width * sqrt(b)
            : (shape == SHAPE_RING ? width : 0.0);
        place = vec2(cos(angle), sin(angle)) * radius;
        outward = angle;
    }

    if (effects.value[effect + EFFECT_OUTWARD] == 0.0) {
        outward = effects.value[effect + EFFECT_DIRECTION];
    }

    // The area's own rotation, applied to every shape rather than folded into
    // the two that sample an angle, so turning a rectangle and turning a disc
    // mean the same thing. It turns the area and the outward normal together
    // and leaves the effect's own `direction` alone, which is what makes the
    // two independent.
    float turned = facing + effects.value[effect + EFFECT_SHAPE_ROTATION];

    // The full cone centred on the launch direction, which is what `spread`
    // means here and in the reference this follows. Half of it is the other
    // plausible reading and getting it wrong is silent.
    float launch = turned + outward
        + (particleRandom(seed, generation, number, LANE_SPREAD) - 0.5)
            * effects.value[effect + EFFECT_SPREAD];
    float speed = particleRange(effects.value[effect + EFFECT_SPEED_MIN],
        effects.value[effect + EFFECT_SPEED_MAX],
        seed, generation, number, LANE_SPEED);
    vec2 velocity = vec2(cos(launch), sin(launch)) * speed;

    vec2 placed = particleTurn(place, turned);
    if (effects.value[effect + EFFECT_SPACE] == 0.0) {
        // Local space: the state is kept relative to the emitter and the
        // simulate pass adds the emitter's position back when it writes the
        // instance, so the field follows the emitter without anything having
        // to move every particle when it does.
        place = placed;
    } else {
        place = origin + placed;
        // Inherited velocity only means something in world space. In local
        // space the particle is already carried by the emitter, so adding it
        // would carry it twice.
        float inherit = effects.value[effect + EFFECT_INHERIT];
        if (inherit != 0.0 && steps > 0.0) {
            velocity += (current - previous) / (steps * timestep) * inherit;
        }
    }

    states.value[state + STATE_X] = place.x;
    states.value[state + STATE_Y] = place.y;
    states.value[state + STATE_VX] = velocity.x;
    states.value[state + STATE_VY] = velocity.y;
    states.value[state + STATE_BIRTH] = birth;
    states.value[state + STATE_LIFETIME] = lifetime;
    states.value[state + STATE_SERIAL] = number;
    states.value[state + STATE_GENERATION] = generation;
}
