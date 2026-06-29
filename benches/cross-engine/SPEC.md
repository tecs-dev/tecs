# Cross-engine 2D sprite throughput, benchmark spec

One scene, three engines (Tecs, Bevy, Defold), identical workload. The goal is a
single comparable number: frame time for N moving, animated sprites, swept across
N. This file is the contract. If an implementation deviates, that is a bug in the
implementation.

## Scene

| Parameter     | Value                                                          |
|---------------|----------------------------------------------------------------|
| Window        | 1280 x 720, windowed, not resizable                            |
| VSync         | off (measuring throughput, not display refresh)                |
| Clear         | opaque black every frame                                       |
| Sprite asset  | `assets/running.png` (96x105, 8 frames of 32x35, 3x3 grid)     |
| Frame rect    | frame `f` maps to `(x=(f%3)*32, y=floor(f/3)*35, w=32, h=35)`   |
| Sprite size   | native 32x35 world units, centered pivot, no per-sprite tint   |
| Count `N`     | passed per run (see Sweep)                                     |
| Split         | first `N/2` sprites are visible, the other `N/2` sit at world X `+1e7` (off-screen) |
| Visible grid  | square grid, `ceil(sqrt(N/2))` per side, spacing 40, centered on the origin |
| Camera        | 2D ortho, centered on the origin, zoomed to fit the visible grid into 90% of the window height |

The 50/50 split exists because the two naive framings are both degenerate. A
camera at 1:1 spawns N in a huge grid but only a few hundred land in the
viewport, so the rest are frustum-culled and the run measures spawn plus cull,
not draw. Zoom-to-fit-everything forces all N on screen, but past a point each
sprite is sub-pixel, and an engine that culls sub-pixel sprites (Tecs does) skips
them, so it again measures cull, not draw.

The split exercises both paths in one run. The visible half is a viewport-filling
grid that is actually rasterized, with total on-screen coverage held roughly
constant across N so fillrate stays fixed and per-sprite draw cost is isolated.
The culled half exercises each engine's visibility path on `N/2` instances per
frame. The engines differ here on purpose: Tecs and Bevy frustum-cull the
off-screen half, Defold does not cull sprites and submits them anyway, which is a
finding rather than a defect.

Above roughly 250k visible sprites the visible half itself crosses into sub-pixel
territory. When it does, a sub-pixel-culling engine reports closer to its cull
throughput. That crossover is real and belongs next to the number.

## Per-frame update (identical in every engine)

Each sprite `i` (0-based) orbits its grid base position `(bx_i, by_i)` on a
radius-16 circle at angular rate `OMEGA = 2.0`, with a per-sprite phase offset
`phase_i = i * 0.001`. Its position at time `t` is:

```
x_i         = bx_i + sin(OMEGA * t + phase_i) * 16
y_i         = by_i + cos(OMEGA * t + phase_i) * 16
animFrame_i = floor(t * 10 + i * 0.137) mod 8
```

Every sprite's transform changes every frame, which defeats any static-scene
dirty-skip fast path. Animation advances at 10 fps with a per-sprite phase
offset.

Because every sprite shares the same angular rate, the canonical implementation
advances the orbit by **incremental rotation** rather than calling `sin`/`cos`
per sprite per frame. Each sprite stores its offset vector, initialized to
`(sin(phase_i), cos(phase_i)) * 16`. Each frame computes the shared rotation once
(`c = cos(OMEGA * dt)`, `s = sin(OMEGA * dt)`) and rotates every offset by it:

```
ofx, ofy = ofx*c + ofy*s,  ofy*c - ofx*s
x_i, y_i = bx_i + ofx,      by_i + ofy
```

This reproduces the closed form exactly (modulo slow float drift, negligible over
a measure window) and keeps the per-sprite cost to a few multiplies, so the
movement loop does not become a transcendental-function benchmark. All three
implementations use it.

Animation is applied each engine's idiomatic way. Tecs animates on the GPU from a
time uniform with no per-sprite CPU cost. Defold plays an engine-driven looping
flipbook, also free per sprite. Bevy core has no built-in sprite animation, so it
advances the atlas index on the CPU per sprite per frame. This asymmetry is part
of what is measured, and the dominant cost at scale is the transform update plus
upload plus draw, which all three pay.

`BENCH_MOVE=0` skips the movement write (sprites animate in place) to expose each
engine's static-scene fast path. Default is moving.

## Measurement

1. Warmup: `BENCH_WARMUP` seconds (default 2.0). Discard all frames.
2. Measure: `BENCH_MEASURE` seconds (default 5.0). Record every frame's delta
   time.
3. Compute over the measure window: `mean_ms` (mean frame time), `fps`
   (`1000 / mean_ms`), and `low1_fps` (`1000 / p99_ms`).
4. Print one line, then exit:

   ```
   RESULT,<engine>,<count>,<frames>,<mean_ms>,<fps>,<low1_fps>
   ```

   `<engine>` is `tecs`, `bevy`, or `defold`. The harness reads lines matching
   `^RESULT,`.

## Sweep

Default counts:

```
10000 50000 100000 250000 500000 1000000 2000000
```

Defold's game-object-per-sprite model does not scale to the high end, so the
harness uses a reduced set for it. That ceiling is itself a finding.

## Out of scope

Lighting, shadows, and post-processing (Defold has no built-in deferred
lighting, so the comparison is sprites only). Spawn time, asset loading, and CPU
game logic beyond the fixed update above.
