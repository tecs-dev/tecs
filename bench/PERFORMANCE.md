# CPU performance acceptance

Run `cargo xtask bench acceptance` on an otherwise idle reference machine.
The initial reference is an Apple M5 Pro, 48 GiB, macOS 26.6. Record power
source and low-power mode with the results. These are local CPU budgets;
Linux and Windows need their own recorded runs before claiming acceptance.
The ordinary CI and `verify` gates do not run timing thresholds.

The command builds release native libraries and uses Cargo's exact artifact
paths, overriding library environment variables. Nupp runs at `-O2`.
Inherited `BENCH_*` settings are cleared. Each workload runs in three fresh
processes, with 900 measured frames after warmup. Every repetition must pass
every p95 limit. p50, p95, p99, mean, maximum and all individual observations
are retained in `out/validation/performance/acceptance.json`, beside stdout
and stderr for each run. Compiler identity, revision, dirty state, architecture
and native artifact paths are recorded. Build and load time are outside the
sample window. Do not run another benchmark or build alongside acceptance.

| Workload             | Warmup | Stage                                         | p95 budget (ms) |
| -------------------- | -----: | --------------------------------------------- | --------------: |
| 4,000 shapes         |    120 | update / extract / combined CPU frame         |       1 / 3 / 4 |
| 1,000 bodies         |    600 | commands + ECS / native batch / sync / update | 2 / 3 / 0.5 / 5 |
| 4,000 bodies, stress |    600 | commands + ECS / native batch / sync / update | 8 / 20 / 1 / 25 |

The normal allocations reserve 4 ms for shape update/extraction and 5 ms for
physics out of a 16.67 ms frame, leaving 7.67 ms for other game work and GPU/
host work. Separate benchmarks do not prove that a combined game meets that
budget. The stress case allocates 25 ms of a 33.33 ms frame: it is a **30 Hz
CPU workload**, not a claim that 4,000 active bodies sustain 60 Hz.

Shapes use seed 42, 2,000 circles and 2,000 rounded rectangles, actual material
ids, a 1280x720 field and viewport, and translation every 1/60-second frame.
All 4,000 instances must be present in the packet. Physics uses the same seed,
a closed 1280x720 container, eight waves 45 frames apart, four blowers, the
default body/contact parameters and requested worker count zero (the native
solver clamps it to one actual worker). Every frame advances
one fixed step. Spawn/setup and all waves finish before measured frames.

`native batch` measures `Simulation.step`: preparing the batch, executing the
Rust solver, draining any resized result buffers and clearing commands.
`sync` brackets transform synchronization. `commands+ecs` is the remainder,
including command construction, public entity lookups, blowers, publication,
transform history and ECS phase bookkeeping. These durations partition each
update, but the independently calculated percentiles cannot be added.

For an extraction profile, set `BENCH_PROFILE=/absolute/path/profile.txt`
when running `cargo xtask bench shapes`. Sampling starts after warmup; zones
separate collection, ordering, lights and encoding. Profiling changes timing,
so use the profile to locate costs and unprofiled runs for acceptance.

Historical benchmarks remain on TECS commit `70549c8e`. Build that checkout
with its pinned Rust/Teal/SDL dependencies and run its `shapes` and `physics`
benchmarks with the same counts, dimensions, warmup, sample count and requested workers.
Compare `simulate`, `extract`, `physics.step` and `physics.sync` as appropriate.
Its `frame` includes a real presented window; Nupp's shapes `frame` includes
only update and extraction. Physics solver versions and ECS/API boundaries
also differ; the comparison measures the migration, not language speed alone.

## Initial result, 2026-09-06 UTC

[Recorded summaries](results/macos-arm64-2026-09-06.json) cover clean TECS
`1d25f64f`, Nupp `53536175` (`0.0.3-dev`), and the historical release. All nine
acceptance runs passed. Ranges below span the three separate repetitions;
they are not pooled percentiles. All values are milliseconds.

| Workload / stage                           |      Nupp p50 |      Nupp p95 | Historical p50 | Historical p95 |
| ------------------------------------------ | ------------: | ------------: | -------------: | -------------: |
| 4,000 shapes / extraction                  |   0.251–0.482 |   0.358–0.815 |          0.013 |    0.017–0.018 |
| 4,000 shapes / combined CPU                |   0.280–0.586 |   0.494–0.969 |              — |              — |
| 1,000 bodies / update (`simulate` in Teal) |   1.450–1.504 |   2.303–2.421 |    2.368–2.400 |    3.329–3.409 |
| 4,000 bodies / update (`simulate` in Teal) | 15.776–15.935 | 19.525–19.711 |  13.671–13.741 |  14.792–15.073 |

The scalar Nupp encoder, run against the same corrected shape fixture,
measured 10.856–19.905 ms p50 and 33.914–42.906 ms p95. Reusable Nupp arrays,
bulk instance writes and retaining draw order when its inputs are unchanged
remove that bottleneck. Returned packet strings remain independent snapshots.
The historical extractor is still substantially cheaper. Nupp also has more
CPU overhead in the 4,000-body update; passing the budgets does not claim
performance parity or a 60 Hz result for the stress case.

Physics p95 in the final stress runs splits into 5.142–5.389 ms for commands
plus ECS work, 14.748–14.793 ms for the native batch, and 0.291–0.326 ms for
synchronization. These percentile ranges are not additive. A requested solver
width of zero resolves to one worker on both implementations, and the runner
now verifies the effective width and four native substeps.

The historical build required temporary CMake/Ninja and its pinned Teal rocks,
a runtime-shader-compiler build switch, and the pinned dependency library path.
No historical engine or benchmark source was changed. The original shape
window still pays presentation time, so its full frame is deliberately absent
from the comparison. Both physics fixtures now share the spawn geometry,
random-number consumption and wave timing; ECS representations, public call
boundaries and compiler builds remain different.
