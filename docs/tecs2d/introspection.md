---
outline: deep
---

# Runtime introspection

Tecs2D treats a running game as an inspectable system. The in-game debugger and
the built-in MCP server share one command registry, one debug context, and one
freeze controller. A developer can point at something in the game; an agent can
inspect the same selection, annotate it on screen, change it, replay the scene,
and leave evidence behind.

This is not a separate AI console layered over the engine. It is the same
runtime debugging surface presented in two forms:

- The [debugger](./debug) gives a developer an in-game command line, selection,
  overlays, capture tools, and time travel without requiring an IDE.
- The [MCP server](./mcp/) gives an agent structured tools for the same running
  world, including every debugger command projected as a typed `debug_*` tool.
- Games can add their own commands once and expose them to both surfaces.

## One shared investigation

A typical investigation moves between visual evidence, structured state, and
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

The developer and agent do not need to translate between two debugging models.
Selection, marks, notes, annotations, snapshots, rewind entries, diffs, and
artifacts are shared runtime state.

## Human and agent roles

The in-game surface is particularly good at spatial context: clicking an entity,
dragging over an area, seeing bounds, toggling layers, or noticing a visual
artifact. MCP is particularly good at structured inspection: querying
components, comparing many entities, reading logs, applying a precise patch, or
drilling into a snapshot diff.

They are designed to hand work back and forth:

| Developer action | Agent view or action |
| --- | --- |
| Click or drag to select entities | Read `get_debug_context`, then inspect the selected IDs |
| Mark a group `boss` | Use the mark as a target for `debug_*` commands |
| Add a note to an entity | Read the note with its compact entity range |
| Freeze in the debugger | Inspect safely and advance with `step` |
| Start a rewind ring | Compare `rewind:<ref>` with `current`, then load and replay |
| Draw a probe or toggle bounds | See the same annotation in screenshots and recordings |
| Save a capture | Read its metadata or open the artifact by path |

## Time travel and evidence

`rewind` captures a bounded ring of world snapshots while the game runs. Opening
the debugger or pausing through MCP holds the ring, preserving the moments before
the failure. From there, a developer or agent can:

```text
rewind list
diff rewind:10s current ignore=Transform
rewind load ago=10
step 30
rewind keep latest before-bug
```

Snapshots are durable checkpoints. Rewind entries are disposable recent
history. Diffs explain structural changes between either kind of checkpoint and
the live world. Screenshots and recordings preserve the visual result; profiles
preserve performance evidence.

See [Snapshots, time travel, and timeline diffs](./debug#snapshots) for the full
operator workflow.

## One extensible command surface

Debugger commands are declared in a schema-based registry. The schema drives
command-line parsing, help, completion, MCP JSON Schema, validation, and
dispatch. The action returns both overlay presentation and structured agent
data.
The developer can type a game-defined command such as `wave 12 elite`; an agent
discovers the corresponding `debug_wave` tool with typed arguments. There is no
second integration to maintain. See [Custom debugger commands](./custom-debug-commands)
for schemas, structured results, shared context, subcommands, completion, and
surface scoping.

## Next steps

- [Use the in-game debugger](./debug)
- [Connect an agent through MCP](./mcp/)
- [Browse the MCP tool reference](./mcp/tools)
- [Register custom debugger commands](./custom-debug-commands)
