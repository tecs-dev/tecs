// Resolving which frame an animation is showing, shared by every pass that
// draws one.
//
// More than one pass needs this and they are in different stages. The geometry
// vertex shader draws the sprite; an occluder pass takes a silhouette from the
// same texture at the same region; a drop-shadow pass draws a stretched copy of
// that silhouette; a lighting pass reads an animated cookie. All of them have
// to arrive at the same frame, and a shadow that lags the sprite by a frame
// reads as a stutter rather than as a bug.
//
// So the rule, and it is the whole reason this is a file rather than a function
// in one shader: resolve at the point of use, from the playback and the frame's
// clock. Never carry a resolved region from one pass to another. A buffer of
// regions written by one pass and read by the next is exactly the arrangement
// that lags, and it is the obvious optimisation to reach for.
//
// The guarantee is then structural. Every caller reads the same four floats
// from the same instance and is handed the same clock, published once per
// frame, so they compute the same answer because they are the same pure
// function of the same inputs.
//
// The caller supplies two things and this file reads nothing else. The four
// floats, because they do not live in the same place for every caller: a
// sprite's ride the instance's region fields and a light's would ride the light
// buffer. And the clock, because the geometry pass takes it from the layer
// uniform and a lighting pass has no layer uniform to take it from.
//
// The buffer's binding is a define rather than a constant here, because a
// storage buffer's index differs per pass. Define PLAYBACK_SET and
// PLAYBACK_BINDING to the set and binding the caller has spare, then include
// this file; `instance.vert.glsl` is the worked example.
//
// Note for anyone editing these comments: includes are expanded by a textual
// pass over the whole file before anything parses it, so an include directive
// written in a comment here is an include of this file by itself, and the
// expander reports it as a cycle. Say the name, do not write the directive.
//
// What the table holds is src/tecs/gfx/frametable.tl, which is the only thing
// that writes it.

#ifndef PLAYBACK_SET
#error "define PLAYBACK_SET before including playback.glsl"
#endif
#ifndef PLAYBACK_BINDING
#error "define PLAYBACK_BINDING before including playback.glsl"
#endif

layout(set = PLAYBACK_SET, binding = PLAYBACK_BINDING) readonly buffer Playbacks {
    float value[];
} playbacks;

// Floats per directory entry. `DIRECTORY_FLOATS` in
// src/tecs/gfx/frametable.tl is the same number and the pair only works while
// they agree.
const int PLAYBACK_DIRECTORY_FLOATS = 4;

// What a playback resolves to on the frame being drawn.
struct Playback {
    // u0, v0, u1, v1 within the array layer below.
    vec4 rect;
    // Array layer, in the namespace of whichever array image the caller
    // samples. A sprite's is the image array; a cookie's would be the cookie
    // array. Nothing here needs them to be the same numbering, because no
    // caller looks up a layer without already knowing its texture.
    //
    // Negative for a sheet bound to no image, which means keep the layer the
    // caller already had.
    float layer;
    // Offset from the playback's middle pivot, in fractions of the frame. Zero
    // unless a slice moves between frames, which is what makes the common case
    // cost two multiply-adds against a basis the caller already built.
    vec2 pivot;
};

// Whether these four floats carry a playback rather than a plain region.
//
// A region is never negative, so the sign of the first float discriminates for
// one comparison and no memory traffic. An instance that is not animated pays
// the comparison and nothing else.
bool isPlayback(vec4 encoded) {
    return encoded.x < 0.0;
}

// The frame a playback is showing, at a clock measured in whole fixed steps.
//
// `encoded` is the playback: its identifier negated, the step playback began
// on, the clip ticks it advances per fixed step, and whether it loops. A rate
// of zero means held, and the second float is then the tick to hold rather than
// the step it started on, which is how an entity freezes without the world's
// clock stopping.
//
// Three dependent reads and no loop, whatever the tag holds: the directory, the
// tick, and the entry the tick names.
Playback resolvePlayback(vec4 encoded, float clock) {
    int entry = (int(-encoded.x) - 1) * PLAYBACK_DIRECTORY_FLOATS;
    float tickBase = playbacks.value[entry + 1];
    float tickCount = playbacks.value[entry + 2];

    float rate = encoded.z;
    // Held, or running. The clock counts whole fixed steps and the difference
    // of two integers in a float is exact, so playback advances in step with
    // the simulation rather than with however many frames were drawn.
    float ticks = rate == 0.0 ? encoded.y : (clock - encoded.y) * rate;

    float at;
    if (encoded.w != 0.0) {
        // mod is non-negative for a positive divisor even where the numerator
        // is not, which is what makes a playback whose start is in the future
        // wrap into its cycle rather than index behind the table.
        at = mod(ticks, tickCount);
    } else {
        at = clamp(ticks, 0.0, tickCount - 1.0);
    }
    // mod can return its divisor for a numerator a hair below zero, so the
    // ceiling is applied to both paths rather than trusted from one.
    at = clamp(at, 0.0, tickCount - 1.0);

    int found = int(playbacks.value[int(tickBase) + int(at)]);

    Playback result;
    result.rect = vec4(playbacks.value[found], playbacks.value[found + 1],
                       playbacks.value[found + 2], playbacks.value[found + 3]);
    result.layer = playbacks.value[found + 4];
    result.pivot = vec2(playbacks.value[found + 5], playbacks.value[found + 6]);
    return result;
}
