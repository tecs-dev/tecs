---
name: love2d-integration-test
description: Create or extend a Love2D integration test (lovespec) that boots a real Love app and drives it over the MCP HTTP server. Use when adding coverage for rendering, input, physics, audio, or any tecs2d subsystem behavior that needs a live engine.
---

# Create a Love2D integration test

Integration specs live in `spec/integration/*_lovespec.tl` (the suffix keeps
them out of the fast `make test` suite). Each spec boots a fixture app under a
real Love 12 binary, then drives it through the MCP HTTP server: run Lua inside
the app, sample framebuffer pixels, and call any MCP tool. The suite runs
blocking in CI on macOS runners.

## Commands

```bash
make test-love FILE_MATCH='my_feature'   # one spec file (matches my_feature.*_lovespec)
make test-love MATCH='pattern'           # filter test names within files
make test-love                           # full suite
```

App logs land in `build/test_deps/love_test_logs/<app>-<port>.log`; read them
first when a call times out or the app dies (engine stack traces go there).

## Picking a fixture app

Apps live in `spec/integration/apps/<name>/` (`main.tl` + `conf.tl`, compiled
into `build/test_deps/...`). Prefer an existing app and spawn all content via
`run_lua`; only add an app when the *render config* must differ:

- `shapes` — blank deferred scene, full ambient, world coords map 1:1 to the
  320x240 screen, camera fixed, lerp off. Two test materials are registered:
  `_G.tecsFlatMaterial` (albedo = params.xyz) and `_G.tecsGlowMaterial`
  (emission = params.xyz * params.w). The default choice.
- `lighting` — white surface, near-black ambient (0.02), deferred lighting.
  For anything asserting light/shadow/AO brightness deltas.
- `tiledphysics` — inline tilemap + physics world with gravity.
- `compliance`, `sprites`, `retro`, `screenlayers`, `layereffects` — see their
  headers.

The Makefile symlinks `build/tecs`, `build/tecs2d`, assets-worker `internal/`,
and `examples/shared/assets` (fonts, sprites, the MSDF atlas) into every app.

## Spec skeleton

```teal
require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local W <const> = 320.0
local H <const> = 240.0

describe("my feature", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsMyEntity = world:spawn(
                Transform(160, 120, 0, 1), gfx.Rectangle(20, 20), gfx.Color(1, 0, 0, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the thing", function()
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, {{160 / W, 120 / H}})[1]
            if p[1] > 0.8 and p[2] < 0.2 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "marker never rendered red")
    end)
end)
```

Harness API: `fixture.start(appDir)`, `fixture.stop(app)`,
`fixture.runLua(app, code)` (returns stringified values — compare `"true"`,
`tonumber(...)`), `fixture.probePixels(app, {{fx, fy}, ...})` (normalized
coords, returns `{r, g, b}` 0..1), `fixture.eventually(seconds, fn)` (polls
until non-nil). Arbitrary MCP tools: `app.client:call(tool, args, timeout?)`
returns the unwrapped result and raises on error; `tryCall` returns the RAW
envelope (result fields are NOT at the top level) plus an error — use a
pcall'd `call` when polling across a server outage.

## Core patterns

**Assert with `eventually`, always.** Rendering lags a mutation by 1-2 frames.
Poll for the expected state; only assert instantaneous reads after an
eventually established the frame settled. Include the last-seen value in the
failure message.

**One-frame windows need an in-app recorder.** Anything that is true for a
single frame (input press edges, `isPressed` action edges, event deliveries)
is invisible to cross-process polling. Install a recorder system via run_lua
that samples every frame into `_G`, then poll the accumulated counters:

```lua
_G.rec = {edges = 0}
world:addSystem({name = "test.Recorder", phase = tecs.phases.Update,
    run = function()
        if input.isKeyPressed("space") then _G.rec.edges = _G.rec.edges + 1 end
    end})
```

Asserting `edges == 1` after 300ms of frames pins "fires on exactly one frame".

**Measure, don't assume, screen positions.** When anchoring/projection math is
involved (parallax offsets, text layout, camera transforms), scan a row/box of
probe points and locate or count matches instead of betting on one pixel.
`sample_pixels` accepts at most 256 points per call. For camera specs, compute
the probe point with the app's own `cam:toScreen(...)` so the assertion checks
CPU math against GPU output.

**Probe placement.** SDF edges are anti-aliased: probe half a stroke inside an
outline, never on the boundary. Background is black; pick channel-distinct
colors (pure R/G/B/magenta/cyan/yellow) so predicates are one comparison.

**State injection.** `world:getMut(id, Comp)` marks dirty and propagates;
direct writes via `world:get` on FFI components need
`world:markComponentDirty`. `send_love_event` drives keyboard/mouse/wheel
(input is event-driven, so polled input state follows). Gamepads: attach an
SDL3 virtual device via the FFI shim in `gamepad_lovespec.tl` — a real device
above SDL; copy that shim.

## Gotchas (each cost a debugging session)

- **Save-dir files**: `love.filesystem.write` persists across runs; remove
  fixture files in setup AND teardown. The tiled/asset loaders resolve under
  the `assets/` root — write to a save-dir `assets/` folder
  (`love.filesystem.createDirectory("assets")`); the save dir shadows the
  game dir for reads.
- **run_lua executes in RenderFirst** (after PostUpdate). Effects appear next
  frame; `eventually` absorbs this.
- **`cond and nil or f` is always `f`** — a scenario "static mode" bug that
  poisoned hours of measurements. Write `(not cond) and f or nil`.
- **Restart specs**: kernel TIME_WAIT can hold the MCP port ~30s; the server
  rebinds in the background. Poll with a pcall'd `call` for up to 40s.
- Tween builders need a finalizer before apply:
  `:to(...)/:adjust(...)` then `:once()` or `:loop(n)` then
  `:apply(world, id)`. `:to` is absolute, `:adjust` relative, `loop(n)` = n
  repeats AFTER the initial play. `TweenComplete` is emitted to address 0
  with the entity in the payload.
- TileChunk edits: mutate `chunk.tiles` then `world:set(id, gfx.DirtyTileChunk)`.
- Drop shadows support sprites and Images; text effects need the MSDF font
  (`assets/firacode-nerd-msdf.json`).
- `world:batchSpawn` skips FFI defaults — set every field in the callback.
- Never `break`/early-return inside `query:iter()` (leaks the deferred scope);
  loop to completion with a flag.

When a spec fails against intended behavior, treat it as a real finding: the
suites in this repo have caught shipping bugs in blend modes, mesh materials,
tiled flips, and MCP restart. Verify against docs before "fixing" the test.
