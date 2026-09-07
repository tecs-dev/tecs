---
description: "Measure completed native shape frames and entity capacity"
---

# Rendering benchmarks

## Explore the scene

Open the benchmark in a window to change how many shapes the camera sees:

```sh
BENCH_COUNT=4000000 BENCH_SHAPE=circle nupp task bench render --interactive
```

- Scroll the mouse wheel or trackpad to zoom in and out.
- Hold WASD or the arrow keys to pan.
- Press R or Home to restore the initial view of the whole grid.

The title shows the GPU's visible shape count, the total shape count, FPS and
average milliseconds per frame. Zooming in shows fewer, larger shapes; zooming
out shows more. Camera movement preserves the entities in the scene. Counts
refresh asynchronously from the GPU, so they can lag behind camera movement.

Interactive benchmarks disable VSync with `Immediate` presentation when
supported. Otherwise they use nonblocking `Mailbox` presentation, which can
render faster than the display. A surface supporting only synchronized FIFO
presentation is rejected. The host prints the chosen mode.

The interactive frame rate includes window presentation and excludes initial
scene setup. It counts submitted frames and uses elapsed wall time, including
the cost of its statistics. It does not write a timing report. Use the fixed
offscreen run below for repeatable measurements.

Interactive mode reserves one entity for the camera, leaving 4,194,302 shape
slots. Four million shapes fit. The offscreen mode can use every entity slot.

## Measure complete frames

`nupp task bench render` builds an optimized Nupp shape component and release
Rust host, then measures actual frames on an offscreen GPU target. It includes world update,
packet extraction, upload, culling, indirect draws, lighting resolve and GPU
completion. Every shape lies inside the view.

```sh
nupp task bench render
BENCH_COUNT=4000000 BENCH_SHAPE=circle nupp task bench render
BENCH_COUNT=4194303 BENCH_SHAPE=rectangle nupp task bench render
```

The default is 100,000 static rectangles, ten warmup frames and 60 measured
frames. Set `BENCH_SHAPE` to a name in [Shapes](shapes.md), `rectangle` for the
untextured default, or `all` for a mixed field. `BENCH_MOTION=moving` rotates
every entity each frame. `static` retains instance data after the first frame,
so clean frames do no instance collection, packing, validation or upload.
Camera-only movement updates the view and GPU culling. Dirty archetype runs
produce partial uploads; changes that reorder or relayout the scene send a
complete update.

```sh
BENCH_COUNT=1000000 BENCH_SHAPE=rounded BENCH_MOTION=moving nupp task bench render \
    --benchmark-warmup 10 --benchmark-samples 60 \
    --benchmark-output out/validation/performance/rounded-moving.json
```

The report defaults to `out/validation/performance/render.json` and retains
all observations plus p50, p95, p99, mean and maximum durations. The final
GPU indirect-draw count must equal the requested shape count; its readback is
outside the timed sample. The output
also records the instance count, packet size, target dimensions, shape,
motion and instance bytes uploaded in each measured frame. The host prints the GPU adapter and storage-buffer limit.

## What each timing means

| Stage                 | Work                                                            |
| --------------------- | --------------------------------------------------------------- |
| `update`              | A completed application/world update                            |
| `extract`             | Image commands and render-packet construction                   |
| `render_and_gpu_wait` | Packet validation, uploads, command recording and GPU execution |
| `completed_frame`     | Sum of those three durations for one frame                      |

The host waits for the GPU after each submitted frame. These are serial
completed-frame wall times, not GPU timestamp queries or unrestricted
throughput. Window presentation, desktop occlusion and setup/spawn are outside
the measurement. It uses the same culling, material, geometry and lighting
pipelines as a windowed game. Do not add separately
computed stage percentiles; the report computes each complete frame first.

`--headless` performs no GPU rendering and is refused for this benchmark.
Interrupted runs fail rather than reporting a partial run as complete.

## Capacity and workload

A world defaults to 1,048,576 slots and can request `tecs.ecs.MAX_ENTITIES`,
which is 4,194,303. Slot zero is reserved. The benchmark reserves no entity for
a camera or HUD, so the exact maximum is available for shape entities.

The instance buffer uses 80 bytes per shape and rounds its capacity to a power
of two. At the limit it needs 335,544,320 bytes, in addition to culling buffers,
frame targets, CPU records and packet copies. The host requests the adapter's
supported buffer limits and rejects a scene that exceeds them.

The grid keeps all instances in view and uses opaque, nonoverlapping quads.
At four million instances in a 1280×720 target, quads are smaller than a pixel.
This measures instance capacity; it does not imply that four million large,
translucent, overlapping shapes will have the same cost. No lights, shadows,
bloom, sprites or physics are installed in this workload.

## CPU-only benchmark

`nupp task bench shapes` remains the moving circle/rounded-rectangle CPU fixture.
It measures update and packet extraction without a GPU. Its `frame` row cannot
be compared to a presented frame. The native `render` benchmark supplies that
missing measurement.

## Retained rendering results

After restoring the original renderer's packed runs, persistent buffers and dirty-range
uploads, the same M5 Pro / Metal setup measured the following. Each static case has
five warmup frames and 60 measured frames; the moving case has 30 measured frames.
Every row passed the exact GPU draw-count check. Durations are milliseconds.

| Shape     | Instances | Motion | Instance upload/frame | Extraction p50 | Completed frame p50 | Completed frame p95 |
| --------- | --------: | ------ | --------------------: | -------------: | ------------------: | ------------------: |
| rectangle | 4,000,000 | static |                   0 B |           0.35 |               15.59 |               15.94 |
| circle    | 4,000,000 | static |                   0 B |           0.31 |               15.50 |               15.79 |
| rectangle | 4,194,303 | static |                   0 B |           0.28 |               16.02 |               16.52 |
| circle    |   100,000 | moving |           8,000,000 B |          30.73 |               37.56 |               41.50 |

The static four-million-shape cases meet the **16.67 ms completed-frame budget**
in these runs. This is a retained-scene result: no instance collection, packing,
validation or upload occurs on clean frames, while GPU culling and drawing still run.
The packet is 1,332 bytes rather than roughly 320 MB.

The entity ceiling has little headroom. An earlier exploratory run reached
22.02 ms at p95; both that run and the final measurements are retained in the
[raw results](https://github.com/tecs-dev/tecs/blob/main/bench/results/render-retained-macos-arm64-2026-09-06.json).
These figures do not establish 60 FPS for fully moving scenes: rotating every
entity rewrites every instance, and even the 100,000-circle moving case exceeds
the budget. Sparse updates skip clean archetype runs; one changed entity in its
own run uploads 80 bytes.

## Original capacity baseline

Measured on 2026-09-06 with an Apple M5 Pro, 48 GiB, macOS 26.6 and Metal,
using Nupp `e3247bea` at `-O2` and a release Rust host, before restoring the
original renderer's retained-data path. Every row passed the GPU
draw-count check. These are one run per case, with five warmup frames;
100,000-instance cases have 60 samples, larger rectangle/circle cases have 30,
and other shapes have ten. All durations below are milliseconds.

| Shape     | Instances | Extraction p50 | Render + GPU wait p50 | Completed frame p50 | Completed frame p95 |
| --------- | --------: | -------------: | --------------------: | ------------------: | ------------------: |
| rectangle |   100,000 |           19.4 |                   5.4 |                25.1 |                28.5 |
| rectangle | 1,000,000 |          187.5 |                  22.7 |               210.2 |               225.2 |
| rectangle | 4,000,000 |          787.8 |                  79.3 |               869.6 |               918.0 |
| rectangle | 4,194,303 |          766.6 |                  77.7 |               843.9 |               859.3 |
| circle    |   100,000 |           17.6 |                   5.3 |                23.4 |                26.9 |
| circle    | 1,000,000 |          179.5 |                  18.8 |               199.6 |               210.2 |
| circle    | 4,000,000 |          752.9 |                  72.0 |               825.1 |               855.4 |
| circle    | 4,194,303 |          810.9 |                  83.7 |               895.2 |               912.1 |

The remaining geometric materials also drew **4,194,303 instances each**:

| Shape    | Completed frame p50 | Completed frame p95 |
| -------- | ------------------: | ------------------: |
| capsule  |               817.9 |               830.2 |
| ellipse  |               891.9 |               936.5 |
| frame    |               816.7 |               822.1 |
| line     |              1032.8 |              1050.6 |
| pie      |               849.8 |               863.5 |
| ring     |               832.7 |               836.9 |
| rounded  |               875.0 |               910.1 |
| star     |               882.8 |               906.7 |
| triangle |              1201.5 |              1458.3 |

The performance target is **four million shapes at 60 FPS**, a budget of
16.67 ms per frame. These baseline results miss it substantially: 869.6 ms is
about 1.15 FPS. CPU extraction dominates, and rendering plus GPU completion
also exceeds the entire frame budget. The retained results above measure the restored path.

[Raw samples and machine/build metadata](https://github.com/tecs-dev/tecs/blob/main/bench/results/render-macos-arm64-2026-09-06.json)
retain all observations, compiler identity and artifact hashes.

## Graphics restoration validation

On 2026-09-07, the restored renderer completed all four million visible static
instances with zero instance uploads per measured frame. The Apple M5 Pro Metal
run used the release host, a Nupp component built at `-O2`, a 1280 by 720 target,
ten warmup frames and sixty measured frames. These serial offscreen timings
include GPU completion and exclude swapchain and desktop presentation.

| Shape     | Instances | Completed frame p50 | Completed frame p95 | Instance upload/frame |
| --------- | --------: | ------------------: | ------------------: | --------------------: |
| Rectangle | 4,000,000 |            13.99 ms |            14.42 ms |               0 bytes |
| Circle    | 4,000,000 |            14.18 ms |            14.65 ms |               0 bytes |

Both p95 results are below the 16.67 ms budget for 60 FPS for this workload.
The complete samples are in
[the validation report](https://github.com/tecs-dev/tecs/blob/main/bench/results/gfx-parity-macos-arm64-2026-09-07.json).
