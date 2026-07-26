# Cross-engine 2D sprite throughput benchmark

One scene, two engines: Tecs and Bevy. The question is narrow: how many
moving, animated sprites can each engine push per frame?

The scene contract is in [SPEC.md](./SPEC.md). Read it first, because the
fairness of the numbers depends on every engine rendering the identical
workload. The short version:

- 1280x720, vsync off, opaque black clear.
- N sprites from the same 8-frame 32x35 sheet (`assets/running.png`).
- Half the sprites are on-screen (drawn), half are parked off-screen (culled), so
  one run covers both the draw path and the cull path. The camera zooms to fit
  the visible half, which holds total on-screen coverage roughly constant across
  N and isolates per-sprite cost.
- Every sprite moves every frame and animates at 10 fps.
- Measure mean frame time over a 5 s window after a 2 s warmup. Report `mean_ms`,
  `fps`, and 1%-low fps.

## Layout

```
benches/cross-engine/
  SPEC.md            the scene contract
  run.sh             sweep harness, writes results.csv
  assets/            the shared sprite sheet
  tecs/              symlink to examples/sprite-throughput (see note)
  bevy/              Cargo project (Bevy 0.15)
```

The Tecs implementation lives at `examples/sprite-throughput/` so it can reuse
the example build tooling and asset symlinks. It runs via
`make example-sprite-throughput`. The Bevy implementation is self-contained
here.

## Running

### All available engines

```bash
cd benches/cross-engine
./run.sh
```

This sweeps Tecs and Bevy across the default counts and writes `results.csv`.

Knobs (environment variables):

```bash
COUNTS="10000 100000 1000000" ./run.sh   # custom sweep
ENGINES="tecs bevy" ./run.sh             # subset of engines
BENCH_MOVE=0 ./run.sh                     # static variant (animate in place)
BENCH_WARMUP=3 BENCH_MEASURE=8 ./run.sh   # longer windows
```

### Tecs only

```bash
make example-sprite-throughput ENTITIES=1000000
# prints: RESULT,tecs,1000000,<frames>,<mean_ms>,<fps>,<low1_fps>
```

The Tecs example also accepts diagnostic env vars: `BENCH_ZOOM` (override the fit
zoom), `BENCH_SPLIT=0` (all sprites visible, no culled half), `BENCH_MCP=1`
(start the MCP server for screenshots and `get_fps`), and `BENCH_W` / `BENCH_H` /
`BENCH_VH` / `BENCH_LIGHTING` (window and pipeline overrides).
`BENCH_INTERPOLATE=1` moves the Tecs workload in `FixedUpdate` and enables GPU
Transform interpolation. Set `BENCH_FIXED=1` independently to keep movement in
`FixedUpdate` while interpolation is disabled for an isolated A/B comparison.

### Bevy only

Requires a Rust toolchain. Bevy 0.15's dependency tree wants rustc 1.88 or newer.
On an older toolchain, either run `rustup update stable` or keep the pinned
`image` crate in `Cargo.lock` (this repo pins `image = 0.25.5`, which builds on
rustc 1.86).

```bash
cd benches/cross-engine/bevy
cargo run --release -- 1000000
```

`cargo run` sets the asset root. If you run the built binary directly, set
`BEVY_ASSET_ROOT` to the project dir so `assets/running.png` resolves:
`BEVY_ASSET_ROOT=$PWD ./target/release/sprite-throughput-bevy 1000000`.

## Reading the output

`results.csv`:

```
engine,count,frames,mean_ms,fps,low1_fps
tecs,1000000,XXX,X.XXXX,XXX.XX,XX.XX
bevy,1000000,XXX,X.XXXX,XXX.XX,XX.XX
```

A row of zeros means that engine produced no `RESULT` line at that count (crash,
out of memory, or no sustained window). That is a data point, so record it.

## Caveats

Read these before quoting a number.

The all-moving sweep measures engine plus host language together. Both engines
move every sprite every frame in their host language: Tecs in LuaJIT and Bevy in
Rust. Run `BENCH_MOVE=0` for the render-bound number that isolates the renderer.
Report both.

Animation is each engine's idiom. Tecs animates on the GPU from a time uniform
with no per-sprite CPU cost. Bevy core has no built-in sprite animation, so it
advances the atlas index on the CPU per sprite per frame.

Camera zoom matters a lot. The fit-to-visible camera puts the whole visible grid
in the frustum, so the renderer processes far more sprites per frame than a
zoom-1 scene where the frustum rejects almost everything. Compare only rows
captured at the same zoom and on the same machine.

Numbers are machine-specific (GPU, driver, OS). Only compare rows from the same
run on the same machine.
