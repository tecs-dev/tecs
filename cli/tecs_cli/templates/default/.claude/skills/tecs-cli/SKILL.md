---
name: tecs-cli
description: Drive this Tecs2D project with the tecs CLI — type-check, build, run, test, package — and the MCP bridge tools. Load BEFORE driving or verifying the running game (start_game, run_lua, cmd_*, screenshots, input injection) and for any build/test/run/package workflow — it holds the build workflow and the verification playbook. Advanced tools (rewind/replay, event watching) live in references.md next to this file.
---

# Tecs CLI workflow

Run everything from the project root (the directory with `tlconfig.lua`).

## Building a game from scratch

1. Read the starter `src/`, the user's requirements, and the tecs-conventions skill. Only read
   docs for subsystems you'll actually use (`tecs docs --search <pattern>` finds the page).
2. Identify the smallest complete gameplay loop: input → simulation → visible result →
   terminal/reset state. Implement that vertical slice before any polish.
3. **Design for verification before writing code.** Authoritative game state lives in a
   named-key resource (`tecs.newKey("game.state")`) or queryable components — never only in
   file-local closures (unreachable from tooling). **Export the components and queries you'll
   verify with** (module exports reachable via `modules("...")` from `run_lua`): a file-local
   component tag leaves you no handle to count or query your own entities — though
   `cmd_fetch '{"expr":"Brick","count_only":true}'` answers population checks by name either
   way. Give the game an explicit reset path. Make randomness seedable where determinism
   matters. You should be able to verify every mechanic from data without interpreting pixels.
4. Batch-query unfamiliar constructors (`tecs api <Comp> --fields constructor`), write the
   slice in one pass, then `tecs check` → `tecs build`.
5. Verify state transitions deterministically (the canonical session below), then one bounded
   live pass for feel/readability. Keep cosmetic iteration proportional to the request.

**Definition of done** — `tecs check` and `tecs build` pass; the game boots with no runtime
errors; the primary input path is proven through real (taped) input; the core loop produces
visible feedback; terminal/failure states and restart work where applicable; the important
state transitions were verified from data; the game got one bounded live-play/visual check;
no generated files (`build/`, `src/vendor/`) were edited.

## Core loop

- `tecs check`: type-check `src/`. Run after every source edit; it must pass before finishing a
  task. Add `--json` for machine-readable diagnostics; unknown-field and signature-mismatch
  diagnostics carry a `hint` naming the exact `tecs api` lookup — follow it instead of guessing.
- `tecs build`: compile to `build/`. A running game hot-reloads a successful build automatically,
  so prefer building over restarting the game.
- `tecs run`: build, then launch the game with the cached Love runtime.
- `tecs integ`: compile and run `spec/` with the bundled busted runner. See the
  integration-testing skill. Prefer one interactive verification pass for a handful of
  mechanics; write an integ spec when the same behaviors will be checked repeatedly or a drive
  session grows past a couple dozen calls.
- `tecs dist [love|macos|windows]`: package the game into `dist/`. The MCP server and debugger
  disable themselves in these builds unless constructed with `{enableInDist = true}`.
- `tecs docs`: offline framework documentation. `tecs docs <page>` prints a page;
  `tecs docs --search <pattern>` searches every page's content — prefer search over dumping
  the index.
- `tecs api <symbol>`: exact API signatures — the framework surface plus your own project symbols
  (type-checked on demand from `src/`). `tecs api` lists modules; `tecs api <module>` its symbols;
  `tecs api <module>.<Type>` a Teal `record` block; `tecs api <Type>:<method>` one method; a bare
  name resolves in your project. Fan out with several symbols; `--json` for structured records,
  `--fields <keys>` to return only what you need. **For any signature, field, or constructor
  question, `tecs api` first** — tens of tokens vs. thousands for a docs page. Don't re-verify
  what `tecs check` already proves, and trust the conventions skill for core ECS shapes (spawn
  variadics, getMut-at-write-site, resources indexing, `run(dt, world)`, phases) — spend
  `tecs api` on what it can't know, like component constructors.

## MCP bridge

`.mcp.json` (Claude Code) and `.codex/config.toml` (Codex) run `tecs mcp`, a stdio bridge that
works even before the game exists. **The channel split is by design:**

- **Toolchain (`check`, `build`, `api`, `docs`, `integ`, `dist`) → Bash `tecs ...`, always.**
  The CLI is the canonical toolchain interface — it answers in ~50–250ms warm and pipes into
  `head`/`grep`. These have NO MCP mirrors.
- **The running game → MCP tools.** Lifecycle (`start_game`, `stop_game`, `restart_game`,
  `game_status`, `game_logs` — the log tool survives crashes) plus every in-game tool
  (`ping`, `cmd_*`, `run_lua`, screenshots). No cheap CLI equal exists (`tecs call` spawns a
  process per call), and only the bridge supports the deferred one-call `cmd_step` flow.

**The `mcp__tecs__*` tools are usually deferred, not absent** — clients defer large MCP
toolsets behind tool search; that saves far more context than it costs. Load the standard
verification set in ONE search before driving:
`select:mcp__tecs__start_game,mcp__tecs__ping,mcp__tecs__cmd_freeze,mcp__tecs__cmd_step,mcp__tecs__run_lua,mcp__tecs__cmd_resources,mcp__tecs__cmd_fetch,mcp__tecs__cmd_screenshot,mcp__tecs__sample_pixels`
If they are genuinely unavailable (common when the project was created in this session —
clients read `.mcp.json` only at startup), do not hand-roll a JSON-RPC client: use
`tecs call` as the client (`tecs call --list`, then `tecs call <tool> '<json-args>'`; start
the game with `tecs run` first). Never kill the game process by hand — `restart_game`,
`tecs call cmd_restart`, or hot reload via `build` avoid the slow re-prep a raw kill causes,
and a broad `pkill love` also kills the stdio bridge.

## The canonical verification session

The game should almost never free-run while you verify *mechanics*. Take control of time once,
keep it, and make every observation deterministic:

1. **Boot already frozen.** `start_game '{"frozen":true}'` holds the game at frame zero. Then
   `ping` and check `build.built` against your latest build — a stale process (a zombie holding
   the port) silently validates old code. `build.built` reads the on-disk manifest, so it
   tracks hot reloads; if a change *still* seems missing after a reload, that's the
   snapshot-restore trap (Startup-only effects are overwritten) — `restart_game`. Frozen means
   **Startup has run but the first Update has not**: state the game fills per-frame (HUD text,
   computed fields) reads as zero/blank until you `cmd_step` 1. From here the world advances
   only when you say so.
2. **Analyze.** Read the frozen world until you understand what reaching the goal requires:
   `cmd_resources '{"name":"game.state"}'`, `cmd_fetch '{"expr":"<Component>"}'`, or a
   `run_lua` read. Stash the state handle once — it persists across calls:
   ```
   run_lua '{"code":"_G.state = world.resources[require(\"tecs\").findKey(\"game.state\")] return {mode=_G.state.mode}"}'
   ```
3. **Stage the world, then act through the real input path.** You have full authority to
   mutate state (`cmd_set`/`cmd_spawn`/`run_lua`) to make the goal *cheap to reach* — that is
   staging, not cheating. The rule: everything **except** the mechanism under test may be
   arranged; the mechanism itself must run for real. Testing an interaction? Place the actor
   and target adjacent — but the interaction must happen via a real stepped frame, and if
   input handling is under test, the input must come from taped events, not a field write.
   When a guard forces you to stage *around* it (writing a field directly because the guard
   rejects that input), spend one rung proving the guard itself — a mechanism you leaned on
   but never exercised is an unverified mechanic.
4. **Advance and read in ONE call.** `cmd_step` takes the whole interaction: `events` (tape
   rows, `at:1` = first stepped frame), `n`, and `lua` — the response arrives after the frames
   ran, carrying the lua values (`_G.state` from step 2 is still in scope):
   ```
   cmd_step '{"events":[{"at":1,"event":"keypressed","args":["left"]},
                        {"at":2,"event":"keyreleased","args":["left"]}],
              "n":10, "lua":"return {x=_G.state.actor.x, mode=_G.state.mode}"}'
   ```
   One round-trip = press a key, run 10 frames, read state. Compare against what you
   predicted, then issue the next one-call step; each small step is a checkpoint where a wrong
   prediction is caught within frames of its cause. When the frame count is unknown ("run
   until the terminal state"), don't guess N — **step until**: `per_frame` runs after every
   stepped frame and a truthy return stops early, making `n` the cap:
   ```
   cmd_step '{"n":300, "per_frame":"return _G.state.mode ~= \"playing\"",
              "lua":"return {mode=_G.state.mode, score=_G.state.score}"}'
   ```
   The result reports `frames_run`/`stopped_early`. Side effects in `per_frame` are allowed.
   Add `"quiet":true` to trim the deferred response to just the values (no schedule echo).
   (Bare `cmd_step` without `lua`/`per_frame`/`wait` returns at *schedule* time — then you
   must read in a follow-up call; prefer the one-call form.) Stepped frames carry a
   **deterministic dt of 1/fps** (echoed as `step_dt`), so `n` frames advance exactly `n/fps`
   gameplay seconds; pass `dt` to cross a timer in fewer frames (`'{"n":1,"dt":0.12}'`).
5. **Escalate goals as a ladder, not a marathon.** Prove the minimal staged case first (one
   target, adjacent), then re-stage harder configurations (multiple targets; an obstacle on
   the path; the goal across the board, reached entirely through taped inputs). Each rung
   verifies exactly one new thing, so a failure indicts one mechanism — one long organic run
   "verifies" everything at once and diagnoses nothing when it fails.
6. **Then look at it.** After mechanics are proven from state: one visual check —
   `cmd_screenshot` captures at the game's VIRTUAL resolution by default (cheap; `full=true`
   for native window pixels, `sample_pixels` for point checks) — and one short live-play
   pass for readability, motion, pacing, and layout, which state checks can't judge.
   The blessed live-pass recipe: **stage the interesting situation while frozen**, then run
   it as one bounded step — stepped frames render at display rate, so it plays on screen in
   real time, auto-stops at the terminal state, and ends still frozen:
   ```
   cmd_step '{"n":180, "per_frame":"return _G.state.mode ~= \"playing\"",
              "quiet":true, "lua":"return {mode=_G.state.mode}"}'
   ```
   Avoid unfreeze-and-`sleep` observation: your sleep is wall-clock while the game keeps its
   own tick rate, so an over-long sleep watches the game die off-screen (from center, a
   moving actor reaches the wall in `distance / speed` seconds — do that arithmetic or let
   `per_frame` do it for you). True unfrozen play is only for a human at the keyboard;
   `send_love_event` queues onto the next gameplay frame if you do need live injection.
   Keep cosmetic iteration proportional to the request; don't enter a
   build→screenshot→tweak loop over colors.

## Using the game tools

- **`run_lua`** runs `function(world) ... end` and returns values as **JSON by default** — return
  a table for a cheap structured read (`lua = true` for raw tostring). The result is an envelope
  `{returned, values}`: `values` is an array of your return values in order. The code is
  **sandboxed**: love2d APIs, the ECS world, and `require("tecs2d.…")` work; the filesystem
  (`io`, `os.execute`) and module loading (`require("io")`, `load`) are blocked;
  `love.filesystem` save-dir writes work for data files but refuse `.lua`/`.tl` paths.
  **State persists across calls** (`_G.handle = ...`). `modules("<name>")` reaches a loaded
  module's **exports** — file-local functions are unreachable, so anything verification needs
  to call (a reset, a spawner) must be exported, stored in a named resource, or registered as
  a `cmd_*` command via `commands.register`.
- **Verify with data, not pixels.** Read state by NAME: `cmd_fetch '{"expr":"Comp -Other"}'`
  returns matching entities *with component data*; `cmd_resources '{"name":"game.state"}'`
  reads a named resource; `cmd_lua_modules`/`cmd_lua_exports` inspect loaded modules; inside
  `run_lua`, `require("tecs").findKey("<name>")` resolves named keys and `modules("<mod>")`
  hands you your own component records to query with. This only works if you named your keys.
- **Tape events; don't poke input state.** `cmd_step`'s `events` rows (and standalone
  `cmd_input_tape`) dispatch literal Love events through the real input pipeline
  (`tecs2d.input`, Tecs events, `love.*` callbacks) on exact gameplay frames — model releases
  as their own rows. `send_love_event` sends ONE immediate event (`{event = "keypressed",
  args = ["space"]}`, args forgiving). Bare `cmd_input_tape` reports fired/held actuals;
  `clear=true` drops pending rows and releases anything held.
- **Iterate entities** with `world:query({include = {Comp}}):iter()` (there is no `world:each`);
  `query:count()` totals matches.
- **If the game crashes, the tools tell you.** A gameplay error does not kill the MCP server:
  every world tool answers `game_crashed` with the traceback, `ping` reports
  `crashed: true`, and `get_logs` (plus the bridge's `game_logs`) holds the full stack. Read
  the traceback, fix the code, and `restart_game` (or `build` + `start_game`) — do not retry
  tools against a crashed world or kill the process by hand.
- Advanced tools — rewind/replay (time travel), watching world events through the log ring,
  attaching to the game's HTTP MCP directly — are in `references.md` next to this skill. Read
  it when a bug needs re-running history or push-based event observation.

## Dependencies

Vendor pure-Lua rocks with LuaRocks into the project tree:

```sh
luarocks install --tree src/vendor --lua-version=5.1 <rock>
```

Install the matching `<rock>-tl-type` rock too so `tecs check` keeps passing. Only pure-Lua rocks
work — the runtime is Love's LuaJIT with no C toolchain. `src/vendor/` is regenerated and
gitignored, so record installed rocks somewhere repeatable.

## Facts worth knowing

- `build/tecs_buildinfo.lua` records name, timestamp, tool versions, and a `dev` flag; read it at
  runtime with `require("tecs2d.buildinfo")`.
- `TECS_MCP_PORT` picks the game's MCP port; harnesses assign a free one.
- `build/` and `src/vendor/` are generated; never edit them by hand.
