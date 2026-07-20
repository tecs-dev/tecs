# Advanced game-driving references

Loaded on demand from the tecs-cli skill. Everything here assumes the MCP bridge is connected
and a game is running.

## Time travel: rewind and replay

Start a session **before letting the game run live/unfrozen**:
`cmd_rewind_start '{"interval":2,"cap":30}'`. The snapshot ring AND the input/dt recorder only
cover moments that happen *while it runs*, so a session started after the bug is useless. If
every verification happens frozen via stage→step→assert (typical for a greenfield build), skip
it — there is no live play to protect.

Two verbs — teleport vs re-run:

- `cmd_rewind_load '{"ref":"latest"}'` (or `'{"ago":10}'`) restores that entry's world state,
  nothing else. From there the game runs forward *live* — new inputs, new timeline.
- `cmd_rewind_replay '{"ref":"latest"}'` (freeze first: `cmd_freeze '{"on":true}'`) restores
  the entry AND re-runs everything recorded after it — every input event on its original
  frame, with its original dt, RNG state included — through the real input path. It ends
  still frozen: follow with one-call `cmd_step` to walk frame-by-frame into the moment you
  care about, reading state as you go. Deterministic bug repro without writing a driver.
- Both pause ring capture (reason "loaded"); `cmd_rewind_resume` when you're done in the past.
  Touching live input during a replay isn't blocked — it just forks a new timeline.

## Watching world events instead of polling

Wire an observer to a logger once via `run_lua`, then read it incrementally through
`get_logs` — the game pushes into the buffer, you read only what's new:

```lua
-- run_lua, once per session:
local ev  = require("tecs2d.events")
local log = require("tecs.utils.logging").getLogger("agent.events")
world:observe(0, ev.KeyPressed, function(e) log:info("key %s", e.key) end)
-- your own events reach scope via modules("..."):
world:observe(0, modules("events").Scored,
    function(e) log:info("scored %d", e.value) end)
```

Then poll `get_logs '{"contains":"agent.events","after":<last seq>}'` (the result's `latest`
is your next cursor). `world:observe(entityId, ...)` scopes to one entity and is auto-cleaned
when it despawns. Keep messages terse — the log ring holds 500 lines.

## Attaching to the game's HTTP MCP directly

If the `tecs` MCP tools disconnect after `start_game` (a client mis-reconciling the tool
list), attach to the running game's HTTP endpoint: `game_status` reports the port, then POST
JSON-RPC to `http://127.0.0.1:<port>/mcp`. The `:19999` endpoint is also how you attach to a
dist build launched with `enableInDist`.
