---
name: love2d-bench
description: Add a Love2D performance bench scenario or measure a performance change with make bench-love. Use when validating an optimization, investigating frame cost or GC pressure, or adding a steady-state scenario for a subsystem.
---

# Benchmark Love2D performance changes

`make bench-love` runs scenario apps under real Love and reports steady-state
frame time and per-frame Lua allocation. Scenarios are plain Lua files in
`benches/love2d/app/scenarios/*.lua`; results land in
`benches/love2d/results/<scenario>.json`.

```bash
make bench-love SCENARIO=shapes            # one scenario, min of 3 runs
make bench-love                            # all scenarios
make bench-love SCENARIO=lights RUNS=5 FRAMES=600 WARMUP=200
```

## Reading the metrics

- `frameMs.p50/p95` — full wall-clock frame (First phase to First phase).
- `cpuMs.p50` — First phase to just-before-present; resolves CPU work when
  frames are GPU-bound. Neither resolves effects under ~0.3ms.
- `allocKbPerFrame` — exact Lua allocation with the GC stopped. The precise
  metric for scratch-table/closure/cdata-boxing work; wins here are GC-pressure
  wins even when frame time doesn't move.

## Methodology (violating these produces fake results)

1. **Compare back-to-back, never against saved numbers.** Machine state drifts
   within hours; a stale baseline once showed a fake 30% win. Protocol:
   `git stash push src/ && make bench-love SCENARIO=x` then
   `git stash pop && make bench-love SCENARIO=x`.
2. The runner takes the **min of 3 runs** because JIT trace formation is
   bimodal across processes (a blacklisted trace never recovers within a run;
   extra warmup does not help — 120 warmup frames is already past the knee).
3. Scale the scenario until the target code is visible (`TECS_BENCH_LIGHTS`
   and `TECS_BENCH_TEXTS` style env knobs), and verify the scenario actually
   exercises the code path — several past "optimizations" targeted walks the
   scenario never ran.
4. **If a change benches neutral, revert it.** Contiguous FFI column walks JIT
   to ~2ns/row; per-batch GPU calls run once per frame under instancing. This
   class always benches neutral. Keep only measured wins.

## Writing a scenario

A scenario returns `{render = {...}, meta = {...}, setup = function(world),
tick = function(world, frame)|nil}`; see `scenarios/shapes.lua`. Rules:

- Deterministic layout (`math.randomseed(42)`).
- Steady state by default: after setup, no CPU-side changes — that is what
  dirty-gating optimizations skip. Use `tick` only for deliberately dynamic
  variants, gated behind an env var.
- Set `render.sizeHints` above the entity count so buffer growth does not
  pollute warmup.
- Beware `Date`-free scenario code and the Lua trap
  `cond and nil or f` (always `f`).

## Known cost model (measured in this repo)

- The alloc floor per frame comes from render scratch; large wins historically
  came from stateless iterators, reused scratch tables, and dirty-gating whole
  passes (UI layout: 23 -> 2.5 KB/frame).
- `world:walkUp`-style per-row callbacks abort JIT traces; interpreted loops
  box ~24 bytes per FFI index. Fix by gating the whole pass on
  `world:dirtyArchetypes()` (carryover sampler pattern in
  `ui/internal/layout_dirty.tl`), not by micro-optimizing inside the loop.
- GPU passes (tile cull, lighting, mask blur) dominate lit scenes; CPU-side
  micro-optimizations under them are usually unmeasurable.
