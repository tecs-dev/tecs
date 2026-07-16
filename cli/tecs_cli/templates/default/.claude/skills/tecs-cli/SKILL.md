---
name: tecs-cli
description: Drive this Tecs2D project with the tecs CLI — type-check, build, run, test, package — and the MCP bridge tools. Load BEFORE driving or verifying the running game (start_game, run_lua, cmd_*, screenshots, input injection) and for any build/test/run/package workflow — it holds the verification playbook and its pitfalls.
---

# Tecs CLI workflow

Run everything from the project root (the directory with `tlconfig.lua`).

**Read before you write.** Before writing code against a subsystem you haven't used yet this
session — input, rendering/layers, freeze/step, snapshots — read its pitfalls first: the
tecs-conventions skill's relevant bullets and, for input specifically, `tecs docs tecs2d/input`
("Latch-based input"). One minute of reading beats twenty of live debugging a silent no-op.
And when verifying *behavior*, pick the channel by scope: one interactive freeze→tape→step→assert
pass through the MCP tools is the right tool for verifying a handful of mechanics once (a one-shot
"does it work" check); write a `tecs integ` spec (batched, deterministic, `fixture.eventually`
built in) when the same behaviors will be checked repeatedly or the drive session grows past a
couple dozen calls — per-call latency adds up fast.

## Core loop

- `tecs check`: type-check `src/`. Run after every source edit; it must pass before finishing a
  task. Add `--json` for machine-readable diagnostics; unknown-field and signature-mismatch
  diagnostics carry a `hint` naming the exact `tecs api` lookup — follow it instead of guessing.
- `tecs build`: compile to `build/`. A running game hot-reloads a successful build automatically,
  so prefer building over restarting the game.
- `tecs run`: build, then launch the game with the cached LÖVE runtime.
- `tecs integ`: compile and run `spec/` with the bundled busted runner. See the
  integration-testing skill.
- `tecs dist [love|macos|windows]`: package the game into `dist/`. The MCP server and debugger
  disable themselves in these builds unless constructed with `{enableInDist = true}`.
- `tecs docs`: the offline mirror of the framework documentation. `tecs docs` lists the doc tree;
  `tecs docs <page>` prints a page (e.g. `tecs docs tecs2d/rendering/shapes`). Look the API up
  here instead of reading vendored sources under `src/vendor/`.
- `tecs api <symbol>`: exact API signatures — the framework surface plus your own project symbols
  (type-checked on demand from `src/`). `tecs api` lists modules; `tecs api <module>` its symbols;
  `tecs api <module>.<Type>` a Teal `record` block; `tecs api <Type>:<method>` one method; a bare
  name resolves in your project. Fan out with several symbols; `--json` for structured records,
  `--fields <keys>` to return only what you need — for a component the constructor is the
  usual question, and `tecs api Text Rectangle --fields constructor` answers it in one line
  each instead of a page of renderer-internal fields. **For any signature, field, or constructor
  question, `tecs api` first** — tens of tokens vs. thousands for a full docs page; save
  `tecs docs` pages for concepts. Don't re-verify what `tecs check` already proves: write the
  code, check it, and let the diagnostics (with their `tecs api` hints) catch a wrong signature.

## MCP bridge

`.mcp.json` (Claude Code) and `.codex/config.toml` (Codex) run `tecs mcp`, a stdio bridge that
works even before the game exists. Prefer these MCP tools over shell commands when connected:

- Toolchain as tools: `check`, `build`, `api`, `integ`, `dist`.
- Game lifecycle: `start_game`, `stop_game`, `restart_game`, `game_status`, `game_logs`
  (the log tool still works after a crash).
- It proxies the running game's own tools.

`tecs docs` and `tecs api` (CLI) — and the `api` MCP tool — are available anytime, before
the game is built and before `start_game`. Only in-game tools (`run_lua`, `screenshot`, `cmd_*`)
require `start_game`. Prefer `build` over `restart_game` for code changes, since the running game
hot-reloads.

**The `mcp__tecs__*` tools may be deferred, not absent** — clients defer large MCP toolsets
behind tool search. Search for `mcp__tecs__` before falling back, and prefer those tools when
present. If they are genuinely unavailable (common when the project was created in this
session — clients read `.mcp.json` only at startup), do not hand-roll a JSON-RPC client: use
`tecs call` as the client. `tecs call --list` names the running game's tools;
`tecs call <tool> '<json-args>'` invokes one (e.g. `tecs call cmd_fetch '{"expr":"Transform"}'`).
Start the game with `tecs run` first. Never kill the game process by hand — `restart_game`,
`tecs call cmd_restart`, or hot reload via `build` avoid the slow re-prep a raw kill causes.

## The canonical verification session

The game should almost never free-run while you verify it. Take control of time once, keep it,
and make every observation deterministic:

1. **Boot already frozen.** `start_game '{"frozen":true}'` holds the game at frame zero — no
   race against a fast game. Then `ping` (check `build.built` — you're talking to the code you
   just built?). Add `cmd_rewind_start` only if you'll let the game run live at some point;
   a fully frozen stage→step→assert session has nothing for the ring to protect. From here,
   the world advances only when you say so; `cmd_freeze '{"on":false}'` releases it when done.
2. **Analyze.** Read the frozen world until you understand what reaching the goal requires:
   `cmd_resources '{"name":"game.state"}'`, `cmd_fetch '{"expr":"<components>"}'`, `run_lua`
   returning a table. No screenshots yet.
3. **Stage the world, then act through the real input path.** You have full authority to
   mutate world state (`cmd_set`/`cmd_spawn`/`run_lua`) to make the goal *cheap to reach* —
   that is staging, not cheating. The rule: everything **except** the mechanism under test may
   be arranged; the mechanism itself must run for real. Testing "eating grows the snake"? Move
   the food one cell ahead — but the eat must happen via a real stepped frame, and if steering
   is under test, the turn must come from `cmd_input_tape`, not a direction-field write.
4. **Advance deliberately and re-read.** `cmd_step '{"n":<small>}'`, then read state in a
   follow-up call (step is async) and compare against what you predicted. Adjust the plan —
   queue the next inputs, step again. Small increments beat one big leap: each step is a
   checkpoint where a wrong prediction is caught within frames of its cause.
5. **Repeat 2–4 until the goal state is proven**, then one bounded screenshot if visuals matter,
   and `cmd_freeze '{"on":false}'` only when you're done.

**Escalate goals as a ladder, not a marathon.** Prove the minimal staged case first (one apple,
one cell away), then re-stage a harder configuration (two apples; an obstacle on the path; the
goal across the board, steered entirely by taped inputs) and prove that. Each rung verifies
exactly one new thing, so a failure indicts one mechanism — one long organic run "verifies"
everything at once and diagnoses nothing when it fails.

Letting the game run live is for soak tests and "feel" checks — it is not a verification method,
because anything observed while racing the clock has to be re-proven deterministically anyway.

Using the game tools:

- **`send_love_event`** takes a single LÖVE event plus its args: `{event = "keypressed",
  args = ["space", "space", false]}` — not an `events: [...]` array.
- **`run_lua`** runs `function(world) ... end` and returns values as **JSON by default** — return a
  table (e.g. `return {count = n, score = s}`) for a cheap structured read. Pass `lua = true` for the
  raw Lua `tostring` form. The result is an envelope `{returned, values}`: `values` is an array of
  your return values in order, so `return snake.length` reads back as `values[0]` (not the bare
  value). The code is **sandboxed**: love2d APIs, the ECS world, and `require("tecs2d.…")` work, but
  the filesystem (`io`, `os.execute`) and module loading (`require("io")`, `load`) are blocked;
  `love.filesystem` save-dir writes work for data files but refuse `.lua`/`.tl` paths.
  **State persists across calls**: stash a handle once (`_G.mgr = world.resources[...]`) and reuse
  it in later calls — no need to re-derive it every time.
  `modules("game")` reaches a loaded module's **exports** — but file-local functions are
  unreachable, so anything verification needs to call (a reset, a step function) must be
  exported from the module, stored in a named resource, or registered as a `cmd_*` debug
  command via `commands.register`.
- **Iterate entities** with `world:query({include = {Component}}):iter()` (there is no
  `world:each`); see `tecs docs tecs/queries`.
- **Verify with data, not pixels.** Read state by NAME instead of inferring it from geometry:
  `cmd_fetch '{"expr":"Enemy -Dead"}'` returns matching entities *with component data*;
  `cmd_resources` lists named resources and `cmd_resources '{"name":"game.state"}'` reads one;
  `cmd_lua_modules`/`cmd_lua_exports` inspect loaded modules. Inside `run_lua`,
  `modules("components.food")` hands you your own component records to query with, and
  `require("tecs").findKey("game.state")` resolves named resource keys. For this to work, always
  name your context keys: `tecs.newKey("game.state")`. When you do need pixels, use
  `sample_pixels` or a clipped `cmd_screenshot` rather than a full-frame `screenshot`. In
  `tecs integ` specs, screenshots / `probePixels` are fine.
- **Assert build identity before trusting any read.** `ping` returns `build` ({name, built,
  dev}); if `build.built` predates your latest `tecs build`, you are talking to a STALE process
  (e.g. a zombie still holding port 19999) and every observation is against old code. Make it
  the first call of any driving session (`game_status` reports the same via the bridge).
- **The default gameplay-verification loop is freeze → stage → step → assert.** Not a debugging
  fallback — start here for anything time-sensitive (auto-death timers, movement ticks,
  spawns): `cmd_freeze` → stage the exact scenario (`cmd_set`/`cmd_spawn` or `run_lua`) →
  `cmd_step '{"n":N}'` → assert via a `run_lua` state read (e.g. return `{score, len, over}`)
  → `cmd_freeze '{"on":false}'`. Remove time from the equation FIRST; screenshot-racing a live
  game wastes a capture per attempt and still proves nothing deterministically. **`cmd_step` is
  asynchronous**: it returns when the frames are *scheduled*; they tick over the next loop
  iterations — so read state in a follow-up call (or `fixture.eventually` in integ specs),
  never in the same breath as the step. **Stepped frames carry a deterministic dt of 1/fps**
  (echoed as `step_dt`), so `n` frames advance exactly `n/fps` gameplay seconds — to cross a
  0.12s timer at 60fps, step 8; or pass `dt` to cover it in fewer frames
  (`'{"n":1,"dt":0.12}'`). Recipe for
  "does eating grow the snake": freeze → place food one cell ahead of the head → step across
  one tick → assert the new length via `cmd_resources '{"name":"game.state"}'` or `cmd_fetch`.
- **Verify the real input path with `cmd_input_tape`, not by poking state.** It queues literal
  LÖVE events against the gameplay-frame clock — `cmd_input_tape '{"events":[{"at":1,"event":
  "keypressed","args":["up"]},{"at":2,"event":"keyreleased","args":["up"]}]}'` then
  `cmd_step '{"n":3}'` — and each row dispatches through the actual input pipeline
  (`tecs2d.input`, Tecs events, `love.*` callbacks) on its scheduled frame, so
  `isKeyPressed`-driven logic is exercised for real, deterministically, while frozen. Model
  releases as their own rows; the step result echoes `will_fire`/`held`, and bare
  `cmd_input_tape` reports what actually fired and anything still held (`clear=true` releases
  it). Args are forgiving like `send_love_event`. It also works from the debugger console:
  `input_tape {{at=1, event="keypressed", args={"up"}}}`.
- **Watch world events instead of polling for them.** Wire an observer to a logger once via
  `run_lua`, then read it incrementally through `get_logs` — the game pushes into the buffer,
  you read only what's new:

  ```lua
  -- run_lua, once per session:
  local ev  = require("tecs2d.events")
  local log = require("tecs.utils.logging").getLogger("agent.events")
  world:observe(0, ev.KeyPressed, function(e) log:info("key %s", e.key) end)
  -- your own events reach scope via modules("..."):
  world:observe(0, modules("events").ScoreChanged,
      function(e) log:info("score %d", e.value) end)
  ```

  Then poll `get_logs '{"contains":"agent.events","after":<last seq>}'` (the result's `latest`
  is your next cursor). `world:observe(entityId, ...)` scopes to one entity and is auto-cleaned
  when it despawns. Keep messages terse — the log ring holds 500 lines.
- **Start a rewind session before letting the game run live/unfrozen:**
  `cmd_rewind_start '{"interval":2,"cap":30}'`. The snapshot ring AND the input/dt recorder only
  cover moments that happen *while it runs*, so a session started after the bug is useless. If
  every verification happens frozen via stage→step→assert (typical for a greenfield build), you
  can skip it — there is no live play to protect.
- **Time travel comes in two verbs — teleport vs re-run:**
  - `cmd_rewind_load '{"ref":"latest"}'` (or `'{"ago":10}'`) restores that entry's world state,
    nothing else. From there the game runs forward *live* — new inputs, new timeline.
  - `cmd_rewind_replay '{"ref":"latest"}'` (freeze first: `cmd_freeze '{"on":true}'`) restores
    the entry AND re-runs everything recorded after it — every input event on its original
    frame, with its original dt, RNG state included — through the real input path. It ends
    still frozen: follow with `cmd_step '{"n":1}'` to walk frame-by-frame into the moment you
    care about, reading state as you go. Deterministic bug repro without writing a driver.
  - Both pause ring capture (reason "loaded"); `cmd_rewind_resume` when you're done in the past.
    Touching live input during a replay isn't blocked — it just forks a new timeline.
- **Verify each subsystem once, with state; screenshot once, at the end.** Prove eat/grow/
  collide/reset in a single frozen pass of state assertions, then take ONE bounded screenshot
  (a region, or `sample_pixels`) as the final "does it look right" check — full frames cost
  1-2k tokens each and persist in context forever.
- **Budget cosmetic iteration.** Commit palette/layout up front; do not enter a
  build→screenshot→tweak loop over colors or alpha — it converges slowly and each cycle costs
  a rebuild plus a capture.
- **If the `tecs` MCP tools disconnect after `start_game`** (a client mis-reconciling the tool
  list), attach to the running game's HTTP MCP directly: `game_status` reports the port, then POST
  JSON-RPC to `http://127.0.0.1:<port>/mcp`. The `:19999` endpoint is also how you attach to a
  dist build launched with `enableInDist`.

## Dependencies

Vendor pure-Lua rocks with LuaRocks into the project tree:

```sh
luarocks install --tree src/vendor --lua-version=5.1 <rock>
```

Install the matching `<rock>-tl-type` rock too so `tecs check` keeps passing. Only pure-Lua rocks
work — the runtime is LÖVE's LuaJIT with no C toolchain. `src/vendor/` is regenerated and
gitignored, so record installed rocks somewhere repeatable.

## Facts worth knowing

- `build/tecs_buildinfo.lua` records name, timestamp, tool versions, and a `dev` flag; read it at
  runtime with `require("tecs2d.buildinfo")`.
- `TECS_MCP_PORT` picks the game's MCP port; harnesses assign a free one.
- `build/` and `src/vendor/` are generated; never edit them by hand.
