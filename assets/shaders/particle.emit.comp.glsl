#version 450
// Advances each emitter's schedule and reserves the slots it asked for.
//
// One thread per emitter, which is three orders of magnitude fewer than one
// per slot: the work here is a schedule and an accumulator, and there is one
// of each per emitter however many particles it is about to produce. What the
// reserved block is filled with is `particle.spawn.comp.glsl`, dispatched over
// the pool so a burst of four thousand is four thousand threads rather than
// one thread going round four thousand times.
//
// Allocation is an `atomicAdd` on the emitter's own cursor. Order is not
// observable: a slot is handed out once and held for the particle's whole
// life, so two particles' relative draw order is fixed from the moment both
// exist and the scene cannot shimmer the way an atomic compaction would make
// it. There is also no contention today, one thread per emitter being what
// this dispatch is; the atomic is what keeps it correct when emission is
// spread over more threads than that.
layout(local_size_x = 64) in;

#define PARTICLE_SET 0
#define PARTICLE_EFFECT_BINDING 0
#define PARTICLE_EMITTER_BINDING 1
#include "particle.glsl"

layout(set = 1, binding = 0) buffer Runtime { uint value[]; } runtime;

layout(set = 2, binding = 0) uniform Particles {
    // The world's fixed step count, the ceiling on steps one frame advances,
    // seconds per fixed step, and how far through the current step this frame
    // falls. An emitter's own clock is on its record, because a held emitter
    // has to stand still while this one goes on.
    vec4 timing;
    // Instance index the pool's run begins at, slots the pool holds, and
    // emitters live.
    vec4 pool;
} params;

void main() {
    int emitter = int(gl_GlobalInvocationID.x);
    if (emitter >= int(params.pool.z)) { return; }

    int base = particleEmitterBase(emitter);
    int at = emitter * PARTICLE_EMITTER_STATE_UINTS;

    // A restart is a new generation, and it resets everything the emitter had
    // accumulated: the serial the random draws are keyed on, the fraction of a
    // particle carried, and which scheduled bursts have already fired. That is
    // what makes a restart reproducible rather than merely repeated.
    uint generation = uint(emitters.value[base + EMITTER_GENERATION]);
    if (runtime.value[at + RUNTIME_GENERATION] != generation) {
        runtime.value[at + RUNTIME_GENERATION] = generation;
        runtime.value[at + RUNTIME_CURSOR] = 0u;
        runtime.value[at + RUNTIME_ACCUMULATOR] = floatBitsToUint(0.0);
        runtime.value[at + RUNTIME_BURSTS_FIRED] = 0u;
        runtime.value[at + RUNTIME_CYCLE] = 0u;
    }

    runtime.value[at + RUNTIME_SPAWN_COUNT] = 0u;

    float slots = emitters.value[base + EMITTER_SLOT_COUNT];
    float steps = emitters.value[base + EMITTER_STEPS];
    // Nothing is emitted on a frame that crossed no step boundary, a queued
    // burst included. Emission lands on step boundaries or it is not a fixed
    // step simulation, and a burst placed between two of them would depend on
    // how many frames the display happened to draw.
    if (slots <= 0.0 || steps <= 0.0) { return; }
    if (emitters.value[base + EMITTER_PLAYING] == 0.0) { return; }

    int effect = particleEffectBase(emitters.value[base + EMITTER_EFFECT]);
    float rate = effects.value[effect + EFFECT_RATE]
        * emitters.value[base + EMITTER_RATE_SCALE];
    float duration = effects.value[effect + EFFECT_DURATION];
    float looping = effects.value[effect + EFFECT_LOOPING];
    float delay = effects.value[effect + EFFECT_DELAY];
    int bursts = int(effects.value[effect + EFFECT_BURST_COUNT]);

    float dt = params.timing.z * emitters.value[base + EMITTER_TIME_SCALE];
    float startStep = emitters.value[base + EMITTER_START_STEP];
    float clock = emitters.value[base + EMITTER_CLOCK];

    float carry = uintBitsToFloat(runtime.value[at + RUNTIME_ACCUMULATOR]);
    uint fired = runtime.value[at + RUNTIME_BURSTS_FIRED];
    uint cycleAt = runtime.value[at + RUNTIME_CYCLE];
    float spawn = 0.0;

    for (int step = 1; step <= int(steps); step++) {
        float age = (clock - steps + float(step) - startStep) * dt;
        if (age < delay) { continue; }

        float cycleTime = age - delay;
        float cycle = 0.0;
        if (duration > 0.0) {
            if (looping != 0.0) {
                cycle = floor(cycleTime / duration);
                cycleTime -= cycle * duration;
            } else if (cycleTime >= duration) {
                continue;
            }
        }
        // A loop's second pass reruns its bursts, which is what makes a
        // repeating firework repeat rather than fire once and then only trail.
        if (uint(cycle) != cycleAt) {
            cycleAt = uint(cycle);
            fired = 0u;
        }

        if (rate > 0.0) {
            // The accumulator carries a fraction of one particle, never a
            // backlog of seconds, because the subtraction below leaves it
            // below one whatever the rate was when it was last added to. So
            // the clamp a CPU system needs, to stop a raised rate discharging
            // everything it had banked in one step, is structural here.
            carry += rate * dt;
            float whole = floor(carry);
            carry -= whole;
            spawn += whole;
        }

        for (int index = 0; index < EFFECT_MAX_BURSTS; index++) {
            if (index >= bursts) { break; }
            uint bit = 1u << uint(index);
            if ((fired & bit) != 0u) { continue; }
            if (cycleTime < effects.value[effect + EFFECT_BURSTS + index * 2]) {
                continue;
            }
            fired |= bit;
            spawn += effects.value[effect + EFFECT_BURSTS + index * 2 + 1];
        }
    }

    // A burst asked for from the host, which is a no-op on a stopped emitter
    // because this returned above.
    spawn += emitters.value[base + EMITTER_BURST];

    // Truncated to what fits rather than refused. The emitter's own range is
    // the cap the API promised, and no other emitter can reach into it.
    spawn = min(spawn, slots);

    runtime.value[at + RUNTIME_ACCUMULATOR] = floatBitsToUint(carry);
    runtime.value[at + RUNTIME_BURSTS_FIRED] = fired;
    runtime.value[at + RUNTIME_CYCLE] = cycleAt;
    if (spawn <= 0.0) { return; }

    runtime.value[at + RUNTIME_SPAWN_CURSOR] =
        atomicAdd(runtime.value[at + RUNTIME_CURSOR], uint(spawn));
    runtime.value[at + RUNTIME_SPAWN_COUNT] = uint(spawn);
}
