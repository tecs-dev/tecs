#version 450
// Integrates every live particle and writes the instance the scene draws it as.
//
// One thread per pool slot. A particle is an instance like any other once this
// has run, so nothing downstream is taught about particles: the mark pass
// tests the bound written here, the scan totals it, the compact pass places it
// in the visible list, and the one indirect draw consumes it. A slot with no
// live particle writes the hidden bound, which is the same thing a reserved
// slot nothing owns has always written, and the mark pass rejects it before
// the draw sees it.
//
// The integration is whole fixed steps and nothing else, so two machines fed
// the same steps hold the same field however many frames either drew. What
// makes it look smooth on a display faster than the step is the last term of
// the position written below: an extrapolation along the particle's own
// velocity, applied to the instance and never to the state, so it cannot feed
// back and the simulation stays reproducible.
layout(local_size_x = 64) in;

#define PARTICLE_SET 0
#define PARTICLE_EFFECT_BINDING 0
#define PARTICLE_EMITTER_BINDING 1
#include "particle.glsl"

layout(set = 0, binding = 2) readonly buffer Owners { uint value[]; } owners;

layout(set = 1, binding = 0) buffer States { float value[]; } states;

// The same sixteen floats every other instance carries, in the same order.
// `Instance` in assets/shaders/instance.vert.glsl is the same struct and the
// pair only works while they agree.
struct Instance {
    vec4 xform;
    vec4 origin;
    vec4 color;
    vec4 uvRect;
};

layout(set = 1, binding = 1) buffer Instances { Instance item[]; } instances;
layout(set = 1, binding = 2) buffer Bounds { vec4 item[]; } bounds;

layout(set = 2, binding = 0) uniform Particles {
    // The world's fixed step count, the ceiling on steps one frame advances,
    // seconds per fixed step, and how far through the current step this frame
    // falls.
    vec4 timing;
    // Instance index the pool's run begins at, slots the pool holds, and
    // emitters live.
    vec4 pool;
} params;

// Puts a slot where no view can see it. The instance is zeroed and its depth
// parked at the back of its band, so a view that somehow reached out here
// would find something that occludes nothing.
void particleHide(uint slot) {
    uint index = uint(params.pool.x) + slot;
    instances.item[index].xform = vec4(0.0, 0.0, 0.0, PARTICLE_HIDDEN_DEPTH);
    instances.item[index].origin = vec4(0.0);
    instances.item[index].color = vec4(0.0);
    instances.item[index].uvRect = vec4(0.0);
    bounds.item[index] = vec4(PARTICLE_HIDDEN, PARTICLE_HIDDEN, 0.0, 0.0);
}

void main() {
    uint slot = gl_GlobalInvocationID.x;
    if (slot >= uint(params.pool.y)) { return; }

    uint owner = owners.value[slot];
    if (owner == 0u) { particleHide(slot); return; }

    int emitter = particleEmitterBase(int(owner) - 1);
    int state = int(slot) * PARTICLE_STATE_FLOATS;

    float lifetime = states.value[state + STATE_LIFETIME];
    if (lifetime <= 0.0) { particleHide(slot); return; }

    float birth = states.value[state + STATE_BIRTH];
    // Cleared: everything born before the step the host asked to clear on is
    // gone, which is a comparison rather than a pass over the range.
    if (birth < emitters.value[emitter + EMITTER_CLEAR_STEP]) {
        particleHide(slot);
        return;
    }

    // The emitter's own clock, which stands still while it is paused, held or
    // stopped. Every age below is measured from it, so a pause holds the field
    // where it was rather than ageing it through the frames the world drew.
    float clock = emitters.value[emitter + EMITTER_CLOCK];
    float elapsed = clock - birth;
    if (elapsed < 0.0) { particleHide(slot); return; }

    float timestep = params.timing.z
        * emitters.value[emitter + EMITTER_TIME_SCALE];
    float age = elapsed * timestep;
    if (age >= lifetime) { particleHide(slot); return; }

    int effect = particleEffectBase(emitters.value[emitter + EMITTER_EFFECT]);
    float seed = emitters.value[emitter + EMITTER_SEED];
    float generation = states.value[state + STATE_GENERATION];
    float number = states.value[state + STATE_SERIAL];

    vec2 position = vec2(states.value[state + STATE_X],
                         states.value[state + STATE_Y]);
    vec2 velocity = vec2(states.value[state + STATE_VX],
                         states.value[state + STATE_VY]);

    // Redrawn from the hash every frame rather than stored. Seven draws is
    // thirty-odd instructions against seven floats of memory traffic per
    // particle per frame, and it is what keeps the state at eight floats.
    vec2 constant = vec2(
        particleRange(effects.value[effect + EFFECT_ACCEL_X_MIN],
            effects.value[effect + EFFECT_ACCEL_X_MAX],
            seed, generation, number, LANE_ACCEL_X),
        particleRange(effects.value[effect + EFFECT_ACCEL_Y_MIN],
            effects.value[effect + EFFECT_ACCEL_Y_MAX],
            seed, generation, number, LANE_ACCEL_Y));
    float radial = particleRange(effects.value[effect + EFFECT_RADIAL_MIN],
        effects.value[effect + EFFECT_RADIAL_MAX],
        seed, generation, number, LANE_RADIAL);
    float tangential = particleRange(
        effects.value[effect + EFFECT_TANGENTIAL_MIN],
        effects.value[effect + EFFECT_TANGENTIAL_MAX],
        seed, generation, number, LANE_TANGENTIAL);
    float drag = effects.value[effect + EFFECT_DRAG];

    float follows = effects.value[effect + EFFECT_SPACE] == 0.0 ? 1.0 : 0.0;
    vec2 carried = vec2(emitters.value[emitter + EMITTER_X],
                        emitters.value[emitter + EMITTER_Y]);
    // What radial and tangential acceleration are measured from. In local
    // space the state is already relative to the emitter, so the center is the
    // origin; in world space it is wherever the emitter is now.
    vec2 center = follows != 0.0 ? vec2(0.0) : carried;

    // A particle born this frame is integrated from its own step rather than
    // from the frame's, which is what stops a frame that fell behind ageing a
    // particle it has only just created.
    int count = int(min(min(emitters.value[emitter + EMITTER_STEPS], elapsed),
        params.timing.y));
    for (int step = 0; step < count; step++) {
        vec2 offset = position - center;
        float distance = length(offset);
        vec2 away = distance > 1e-6 ? offset / distance : vec2(0.0);
        velocity += (constant + away * radial
            + vec2(-away.y, away.x) * tangential) * timestep;
        // Damping per second, which composes correctly with any step because
        // it is applied as a ratio of the step rather than as a multiplier
        // someone has to rescale.
        velocity *= 1.0 / (1.0 + drag * timestep);
        position += velocity * timestep;
    }
    states.value[state + STATE_X] = position.x;
    states.value[state + STATE_Y] = position.y;
    states.value[state + STATE_VX] = velocity.x;
    states.value[state + STATE_VY] = velocity.y;

    float t = age / lifetime;
    float size = particleRange(effects.value[effect + EFFECT_SIZE_MIN],
        effects.value[effect + EFFECT_SIZE_MAX],
        seed, generation, number, LANE_SIZE)
        * particleCurve(effects.value[effect + EFFECT_SIZE_CURVE], t)
        * emitters.value[emitter + EMITTER_SIZE_SCALE];
    float rotation = particleRange(effects.value[effect + EFFECT_ROTATION_MIN],
        effects.value[effect + EFFECT_ROTATION_MAX],
        seed, generation, number, LANE_ROTATION)
        + particleRange(effects.value[effect + EFFECT_ANGULAR_MIN],
            effects.value[effect + EFFECT_ANGULAR_MAX],
            seed, generation, number, LANE_ANGULAR) * age;

    float scaleX = size;
    float scaleY = size;
    if (effects.value[effect + EFFECT_ALIGNMENT] != 0.0) {
        // Added to the particle's own rotation rather than replacing it, which
        // is the reference's answer: a spinning spark aligned to its path
        // still spins.
        rotation += atan(velocity.y, velocity.x);
        scaleX *= effects.value[effect + EFFECT_STRETCH];
    }

    vec2 drawn = position + carried * follows
        + velocity * (params.timing.w * timestep);

    float c = cos(rotation);
    float s = sin(rotation);
    // The quad hangs off the pivot rather than turning about its middle, and
    // the shift is folded in here for the same reason extraction folds an
    // entity's in: moving the middle by -basis * pivot places every corner
    // exactly where offsetting the corner would, for no extra bytes.
    vec2 pivot = vec2(effects.value[effect + EFFECT_PIVOT_X] - 0.5,
                      effects.value[effect + EFFECT_PIVOT_Y] - 0.5);
    drawn -= vec2(c * scaleX * pivot.x - s * scaleY * pivot.y,
                  s * scaleX * pivot.x + c * scaleY * pivot.y);

    vec4 tint = vec4(effects.value[effect + EFFECT_COLOR_R],
                     effects.value[effect + EFFECT_COLOR_G],
                     effects.value[effect + EFFECT_COLOR_B],
                     effects.value[effect + EFFECT_COLOR_A])
        * particleGradient(effects.value[effect + EFFECT_COLOR_GRADIENT], t)
        * vec4(emitters.value[emitter + EMITTER_TINT_R],
               emitters.value[emitter + EMITTER_TINT_G],
               emitters.value[emitter + EMITTER_TINT_B],
               emitters.value[emitter + EMITTER_TINT_A]);

    vec4 region = vec4(effects.value[effect + EFFECT_U0],
                       effects.value[effect + EFFECT_V0],
                       effects.value[effect + EFFECT_U1],
                       effects.value[effect + EFFECT_V1]);
    float playback = effects.value[effect + EFFECT_PLAYBACK];
    if (playback > 0.0) {
        // The playback encoding the frame table already defines, and no second
        // table: the identifier negated, the step playback began on, the ticks
        // it advances per step, and no looping. The rate is the cycle divided
        // by this particle's own life, so a randomized lifetime randomizes the
        // playback speed and the animation lands on its last frame exactly as
        // the particle expires.
        //
        // The start is given in the world's steps rather than the emitter's,
        // because the vertex shader resolves against the world's clock and has
        // no way to know this emitter was ever held. Rewritten every frame, so
        // a start that has to move by the steps a pause swallowed simply does.
        region = vec4(-playback, params.timing.x - elapsed,
            effects.value[effect + EFFECT_PLAYBACK_TICKS] * timestep / lifetime,
            0.0);
    }

    uint index = uint(params.pool.x) + slot;
    instances.item[index].xform = vec4(rotation, scaleX, scaleY,
        effects.value[effect + EFFECT_DEPTH]);
    instances.item[index].origin = vec4(drawn,
        effects.value[effect + EFFECT_SLOT],
        effects.value[effect + EFFECT_MATERIAL]);
    instances.item[index].color = tint;
    instances.item[index].uvRect = region;

    // Half extents about the quad's middle, which is what `extentOf` in
    // src/tecs/gpu/instancelayout.tl computes: each axis its own scale
    // unrotated, and half the sum of both once it turns, which is looser than
    // the true extent and never smaller. Culling per particle rather than per
    // emitter falls out of writing this beside the instance, and it is exact
    // in a way a conservative emitter bound could not be.
    vec2 extent;
    if (effects.value[effect + EFFECT_UNBOUNDED] != 0.0) {
        extent = vec2(PARTICLE_UNBOUNDED);
    } else if (rotation == 0.0) {
        extent = vec2(0.5 * abs(scaleX), 0.5 * abs(scaleY));
    } else {
        extent = vec2(0.5 * (abs(scaleX) + abs(scaleY)));
    }
    bounds.item[index] = vec4(drawn, extent);
}
