---
name: love2d-debug-rendering
description: Diagnose rendering problems in a live tecs2d game over the MCP HTTP server — missing or ghost content, wrong positions, stale visuals, frame glitches, and perf. Use when something looks wrong on screen and you need to find which layer of the pipeline is lying.
---

# Debug rendering with MCP probes

Every running tecs2d game with the MCP plugin exposes an HTTP server; the
port is in the window title (`(MCP:53000)`) or the launch logs. If the tecs
MCP server is configured in this session, call the `mcp__tecs__*` tools
directly; otherwise POST JSON-RPC to `http://localhost:<port>/mcp`:

```bash
curl -s -X POST localhost:PORT/mcp -H 'Content-Type: application/json' -d \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"cmd_stats","arguments":{}}}'
```

Integration-test apps log to `build/test_deps/love_test_logs/`; a dead app
(timeouts, connection refused) means an engine crash — read the log's stack
trace before probing anything.

## The triage ladder

Work down the pipeline until CPU truth and GPU output disagree; the layer
where they diverge is the bug.

1. **`screenshot` / `sample_pixels`** — what is actually on screen.
   `sample_pixels` takes up to 256 `{x, y}` points (`normalized: true` for
   0..1 fractions) and returns RGBA. To *locate* content, scan a grid or row
   and search for the expected channel signature rather than betting on one
   pixel.
2. **`cmd_fetch` / `cmd_info` / `cmd_stats`** — CPU-side truth. Is the entity
   alive, what are its Transform/Color/layer values, do counts match
   expectations?
3. **`run_lua`** — arbitrary inspection inside the app. The big three:

   ```lua
   -- Where should this render? (CPU camera math vs GPU output)
   local gfx = require("tecs2d.gfx")
   local cam = world.resources[gfx.PIPELINE]:getCamera()
   return cam:toScreen(worldX, worldY)
   ```

   ```lua
   -- What is dirty this frame? (sync/dirty-model bugs)
   local out = {}
   for arch in world:dirtyArchetypes() do
       local names = {}
       for comp in pairs(arch.columns) do
           if arch:isComponentDirty(comp) then names[#names + 1] = tostring(comp.componentName) end
       end
       out[#out + 1] = table.concat(names, ",")
   end
   return table.concat(out, " | ")
   ```

   Run this on consecutive frames: a static scene with recurring dirty marks
   means an unconditional `getMut` is defeating dirty gates somewhere.
4. **`cmd_camera_world` + `cmd_fetch` with `x`/`y`/`w`/`h` bounds** — "what
   entity is at this pixel"; the inverse of step 3's toScreen check.
5. **`cmd_freeze` + `cmd_step`** — freeze a transient glitch. Freeze, screenshot,
   `cmd_step {frames: 1}`, screenshot again; rendering continues while frozen so
   probes stay live. `cmd_camera_timescale` slows animations for observation.
6. **`cmd_systems_stop` / `cmd_systems_start`** — bisect which system produces
   an artifact by disabling systems (get names from `cmd_systems_list`).
7. **`cmd_draw_rect` / `cmd_draw_circle` / `cmd_draw_line` / `cmd_draw_text`** —
   overlay expected geometry (world coordinates; pass `entity` to pin to a moving
   entity). Draw where something *should* be and compare with where it renders.
   `cmd_draw_clear` (by `tag` or `id`, or everything) cleans up.
8. **`cmd_profile`** — per-system timings when the symptom is cost rather
   than correctness. For deeper perf work, switch to the `love2d-bench` skill.

## Diagnosis recipes

**Content missing.** Alive (`cmd_fetch`)? → in view (`toScreen` on its
Transform)? → layer visible and inside the camera's layer mask
(`isLayerVisibility`, camera `layerMask`)? → probe at the computed pixel. If
CPU says visible but pixels disagree: check the dirty path — cdata writes
through `world:get` need `world:markComponentDirty`; `batchSpawn` skips FFI
defaults (a zeroed Transform renders at layer 0, which no camera shows).

**Ghost/stale content** (moved or despawned but still rendering). This is the
dirty-model gap class: something changed without marking dirty, so a cached
GPU buffer, the shadow mask, or a gated pass kept old data. The dirty dump
plus one forced change (nudge the entity via `getMut`) usually reveals which
consumer fails to refresh.

**Wrong position.** Compare `cam:toScreen(world)` against a pixel scan for
the content. If they agree, the spawn data is wrong; if they disagree,
suspect the transform chain: parallax applies `cam * (1 - factor)` on both
axes, screen-space layers ignore the camera, pixel mode letterboxes with
integer scaling, and Y-flip mismatches show as mirrored offsets.

**Wrong color/brightness.** Bisect the lighting stack: `setAmbientLight(1,1,1)`
via run_lua removes lighting from the equation; toggling `Unlit` on the
entity isolates the G-buffer vs compose; blend-tagged entities render in the
forward pass after lighting.

**Flicker/one-frame glitches.** freeze + single-step with a screenshot per
frame; then bisect systems with `cmd_systems_stop`.

## Gotchas

- `run_lua` executes in RenderFirst, after PostUpdate: mutations render next
  frame, and their dirty marks are cleared at frame end (PostUpdate-gated
  systems see them through the layout_dirty carryover sampler).
- `cmd_freeze` disables gameplay phases but MCP and rendering keep running —
  probing while frozen is the point. `cmd_camera_timescale` with scale 0 is
  different: systems still tick with zero dt.
- Screenshot responses are deferred (the connection is held until the frame
  captures); allow a longer timeout than other tools.
- Probes read the final composited frame: post-compose passes (forward blend,
  screen phase, layer effects) are included.
