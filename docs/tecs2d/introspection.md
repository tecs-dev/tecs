---
description: "Shared human-agent debugging model connecting the debugger, MCP server, and custom commands over one selection and freeze state"
outline: deep
---

# Runtime introspection

The in-game debugger and the built-in MCP server share one command registry,
one debug context, and one freeze controller. A selection made by clicking in
the game is the same selection an agent reads over MCP; a command typed in the
overlay and the matching `cmd_*` tool run the same code against the same
state.

- The [debugger](./debug) is an in-game command line with selection, overlays,
  capture tools, and time travel.
- The [MCP server](./mcp/) exposes structured tools for the running world,
  including every debugger command projected as a typed `cmd_*` tool.
- Games [register their own commands](./custom-debug-commands) once; the
  registration serves both surfaces.

## Investigation workflow

An investigation moves between visual evidence, structured state, and
controlled replay:

```text
Something goes wrong in the running game
→ freeze the game and preserve the rewind ring
→ inspect a screenshot and the shared debug context
→ select or mark the suspicious entity in-game
→ inspect its components, systems, logs, and render state
→ diff an earlier rewind entry against the current world
→ load the earlier state and step toward the failure
→ patch the cause and replay
→ capture a screenshot, recording, profile, or diff as evidence
```

Selection, marks, notes, annotations, snapshots, rewind entries, diffs, and
artifacts are shared runtime state, so work started on one surface continues
on the other.

## Handing work between surfaces

In-game input carries spatial context: clicking an entity, dragging over an
area, seeing bounds, toggling layers, noticing a visual artifact. MCP carries
structured access: querying components, comparing many entities, reading
logs, applying a precise patch, drilling into a snapshot diff. The shared
state connects the two:

| Developer action | Agent view or action |
| --- | --- |
| Click or drag to select entities | Read `cmd_context`, then inspect the selected IDs |
| Mark a group `boss` | Use the mark as a target for `cmd_*` commands |
| Add a note to an entity | Read the note with its compact entity range |
| Freeze in the debugger | Inspect safely and advance with `cmd_step` |
| Start a rewind ring | Compare `rewind:<ref>` with `current`, then load and replay |
| Draw a probe or toggle bounds | See the same annotation in screenshots and recordings |
| Save a capture | Read its metadata or open the artifact by path |

## Time travel and evidence

`rewind` captures a bounded ring of world snapshots while the game runs.
Opening the debugger or pausing through MCP holds the ring, preserving the
moments before the failure. From there, a developer or agent can:

```text
rewind list
diff rewind:10s current ignore=Transform
rewind load ago=10
step 30
rewind keep latest before-bug
```

Snapshots are durable checkpoints. Rewind entries are disposable recent
history. Diffs explain structural changes between either kind of checkpoint
and the live world. Screenshots and recordings preserve the visual result;
profiles preserve performance evidence.

See [Snapshots, time travel, and timeline diffs](./debug#snapshots) for the
full operator workflow.

## Custom commands

Debugger commands are declared in a schema-based registry. The schema drives
command-line parsing, help, completion, the MCP JSON Schema, validation, and
dispatch; the action returns overlay presentation and structured agent data.
A game-defined command such as `wave 12 elite` is typeable in the overlay and
appears to agents as a `cmd_wave` tool with typed arguments. See
[Custom debugger commands](./custom-debug-commands) for schemas, structured
results, shared context, subcommands, completion, and surface scoping.

## Next steps

- [Use the in-game debugger](./debug)
- [Connect an agent through MCP](./mcp/)
- [Browse the MCP tool reference](./mcp/tools)
- [Register custom debugger commands](./custom-debug-commands)
