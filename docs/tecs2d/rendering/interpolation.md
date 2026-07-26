---
description: "GPU interpolation of fixed-step Transform samples, default behavior, physics integration, costs, and limitations"
outline: deep
---

# Transform Interpolation

Tecs2D interpolates supported GPU-rendered entities between consecutive
fixed-step `Transform` samples. This keeps rendering smooth when simulation
runs less frequently than rendering, including physics and gameplay systems in
`FixedUpdate`.

Interpolation is enabled by default. It requires no marker component and no
changes to the system that writes `Transform`.

```teal
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    run = function()
        local transform = world:getMut(player, tecs.builtins.Transform)
        transform.x = transform.x + 4
    end,
})
```

The ECS value remains the latest authoritative fixed-step value. Interpolation
changes only the transform consumed by rendering.

## How It Works

For every supported archetype whose `Transform` changes during one fixed
iteration between rendered frames, the renderer retains the previous
presentation sample and uploads the new fixed sample:

```text
previous fixed sample → current fixed sample
```

On each rendered frame, the GPU cull shader blends those samples using the
world's fixed-step alpha. Culling and render output therefore consume the same
interpolated transform.

Fixed iterations only record that the column changed. The renderer performs
the upload once in `PreRender`, regardless of how many iterations ran.

If a frame performs multiple fixed iterations to catch up, the renderer
uploads the final authoritative value once and snaps for that frame. This
prevents a slow frame from multiplying whole-column uploads and creating a
feedback loop. A frame with no fixed iteration simply advances alpha between
the existing samples without uploading the column again.

New rows seed the previous sample from the current value, so newly spawned
entities do not interpolate from the origin.

## Interpolated Fields

The renderer interpolates:

- `Transform.x`
- `Transform.y`
- `Transform.rotation`, using the shortest angular path

It does not interpolate `z`, `layer`, `scaleX`, or `scaleY`.

This applies to sprites, lines, circles, arcs, ellipses, rectangles, text, and
meshes. `Image`, tile chunks, particles, physics debug drawing, and custom draw
calls consume their current presentation data directly.

## Physics

Physics does not perform presentation smoothing. After every Box2D step, it
copies the exact body position and rotation into `Transform` during
`FixedPostUpdate`.

Physics-driven supported renderables therefore follow the normal renderer
interpolation path without physics-specific configuration.

The physics plugin has no interpolation, extrapolation, or smoothing option.

## Writes Outside Fixed Phases

A `Transform` mutation outside the fixed loop has immediate, snap semantics.
The renderer does not blend toward variable-rate writes. This keeps normal
`Update` animation, editor changes, and direct presentation adjustments
responsive.

A discontinuity written inside a fixed phase is indistinguishable from
ordinary fixed-step movement and interpolates for one interval. This includes
teleports, portals, and respawns. There is currently no per-entity fixed-step
snap API.

## Disabling Interpolation

Disable interpolation for an entire render pipeline with
`disableInterpolation`:

```teal
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        disableInterpolation = true,
    },
})
```

The option defaults to `false`; interpolation is active when it is omitted.
Disabling it avoids all interpolation tracking and previous-sample buffers for
that pipeline.

## Costs and Tradeoffs

Interpolation adds one fixed interval of visual latency, an additional GPU
buffer read, and a lazily allocated previous-Transform buffer (28 bytes per
allocated row in each participating renderer).

Uploads are column-granular but coalesced to one final fixed sample per
rendered frame. Catch-up frames snap instead of uploading every fixed sample.
Static archetypes allocate no previous buffer, and the renderer performs no
per-entity Lua scan.

Code reading `Transform` sees the authoritative simulation value, which is one
sample ahead of presentation.

## Demo

Run the comparison demo:

```bash
make example-interpolation
```

It renders at 60 Hz while simulation advances at 5 Hz. The upper built-in
sprite uses automatic GPU interpolation; the lower custom draw shows the raw
authoritative samples that custom presentation code receives.
