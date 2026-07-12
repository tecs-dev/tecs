---
outline: deep
---

# Custom debugger commands

Games can extend the runtime debugger with project-specific operations. Define a
command once and Tecs2D uses the same declaration for:

- Command-line parsing and validation in the in-game debugger
- Generated usage, argument help, examples, and Tab completion
- A `cmd_<name>` MCP tool with a generated JSON input schema
- Identical execution and structured results on both surfaces

Custom commands are useful for operations that understand the game better than
generic ECS tools: starting a boss phase, jumping to a checkpoint, spawning an
encounter, validating a level, dumping an AI decision, or applying a safe
domain-specific edit.

## Register a command

Install the debug plugin before registering commands:

```teal
local debug = require("tecs2d.debug")
local commands = require("tecs2d.debug.commands")

world:addPlugin(debug.new())

commands.register(world, {
    name = "wave",
    shortHelp = "spawn an enemy wave at the camera",
    examples = {
        "wave",
        "wave 12 elite",
        "wave count=20 kind=grunt",
    },
    schema = {
        args = {
            count = {default = 5, help = "enemies to spawn"},
            kind = {default = "grunt", help = "enemy bundle name"},
        },
        positional = {"count", "kind"},
    },
    run = function(v: {string: any}, _parts: {string}): commands.Result
        local n = spawnWave(world, v.count as number, v.kind as string)
        return {
            ok = true,
            message = "spawned " .. tostring(n) .. " " .. tostring(v.kind),
            data = {spawned = n, kind = v.kind},
        }
    end,
})
```

The developer can type any of the following:

```text
wave
wave 12 elite
wave count=20 kind=grunt
wave 12 kind=elite
```

An MCP client discovers the equivalent `cmd_wave` tool:

```json
{"name":"cmd_wave","arguments":{"count":12,"kind":"elite"}}
```

Registration raises immediately if the debug plugin is missing, the name or an
alias collides, the command has no action, or its schema is invalid.

## Argument schemas

A schema declares every accepted argument and which arguments can be written
positionally. The same schema validates command-line values and MCP JSON
arguments.

```teal
schema = {
    args = {
        count = {
            kind = "number",
            required = true,
            help = "number of enemies",
        },
        elite = {
            kind = "boolean",
            default = false,
            help = "use elite variants",
        },
        label = {
            help = "optional wave label",
        },
    },
    positional = {"count", "label"},
}
```

Each argument supports:

| Field | Meaning |
| --- | --- |
| `help` | Description used by debugger help and the generated MCP schema |
| `required` | Reject the call when the argument is absent |
| `default` | Value applied when omitted; also infers its type |
| `kind` | Explicit `"string"`, `"number"`, or `"boolean"` type |
| `rest` | Capture the remaining command line as one free-text string |
| `forward` | Feed this argument into a synthetic positional choice |
| `synthetic` | Define a hidden positional slot backed by several typed arguments |

If an optional number or boolean has no default, declare `kind` explicitly.
Otherwise arguments default to strings. Named arguments must follow positional
arguments on the command line.

Boolean command-line values accept `true`/`false`, `on`/`off`, `yes`/`no`, and
`1`/`0`. A bare named boolean enables it:

```text
wave 12 elite
wave 12 elite=false
```

### Free-text arguments

Use `rest = true` for messages or expressions containing spaces. It must be the
last positional slot and must be string-typed:

```teal
schema = {
    args = {
        text = {rest = true, required = true, help = "announcement text"},
        urgent = {default = false, help = "show as urgent"},
    },
    positional = {"text"},
}
```

```text
announce The bridge is collapsing urgent=true
```

Through MCP, `text` remains a normal string argument.

### One positional target, typed MCP arguments

Synthetic arguments let the command line accept one positional choice while MCP
retains separate typed properties. This command accepts either an entity ID or
a mark name:

```teal
schema = {
    args = {
        id = {kind = "number", forward = "target", help = "entity id"},
        name = {forward = "target", help = "debugger mark name"},
        target = {
            synthetic = {"id", "name"},
            required = true,
            help = "entity id or mark name",
        },
    },
    positional = {"target"},
}
```

The overlay accepts `focus 42` or `focus boss`. MCP exposes `id` and `name` as
separate optional properties and requires exactly one:

```json
{"name":"cmd_focus","arguments":{"id":42}}
{"name":"cmd_focus","arguments":{"name":"boss"}}
```

The chosen value is available as `v.target`; the source field (`v.id` or
`v.name`) is also preserved.

## Return structured results

Every action returns `commands.Result`:

| Field | Surface | Purpose |
| --- | --- | --- |
| `ok` | Both | Whether the action succeeded |
| `code` | Both | Stable machine-readable failure code when `ok = false` |
| `message` | Both | Short status line; MCP includes it with the structured payload |
| `data` | MCP and callers | Canonical structured result object |
| `popup` | Overlay | Multi-line detail shown in the debugger |
| `popupImagePath` | Overlay | Save-directory image displayed with the popup |

Return useful facts in `data`, even when the popup already displays them. MCP
does not receive popup lines or popup images. Reserve the `message` key in
`data`; the MCP dispatcher uses it for the result's human-readable message.

```teal
run = function(v: {string: any}, _parts: {string}): commands.Result
    local report = validateEncounter(v.name as string)
    if not report then
        return {
            ok = false,
            code = "unknown_encounter",
            message = "no encounter named " .. tostring(v.name),
        }
    end

    return {
        ok = true,
        message = report.ok and "encounter valid" or "encounter has errors",
        popup = {
            "encounter " .. tostring(v.name),
            "  enemies\t" .. tostring(report.enemies),
            "  errors\t" .. tostring(#report.errors),
        },
        data = {
            valid = report.ok,
            enemies = report.enemies,
            errors = report.errors,
        },
    }
end
```

Use stable failure codes such as `unknown_checkpoint`, `invalid_phase`, or
`encounter_locked`; agents can react without parsing prose.

## Read shared debugger state

Commands can operate on the developer's current selection, marks, notes, and
other debug context:

```teal
local debugcontext = require("tecs2d.debug.context")

commands.register(world, {
    name = "heal-selection",
    shortHelp = "restore health on every selected entity",
    run = function(_v: {string: any}, _parts: {string}): commands.Result
        local ctx = world.resources[debugcontext.KEY]
        local healed = 0

        for i = 1, #ctx.selected do
            local id = ctx.selected[i]
            local health = world:getMut(id, Health)
            if health then
                health.current = health.maximum
                healed = healed + 1
            end
        end

        return {
            ok = true,
            message = "healed " .. tostring(healed) .. " selected entities",
            data = {healed = healed, selected = #ctx.selected},
        }
    end,
})
```

This state is shared with `cmd_context`, so an operator can select entities
in-game and ask an agent to run the project-specific command against that exact
selection.

Follow the normal [mutation model](/tecs/mutation-model): use `getMut` only when
writing and mark direct FFI writes dirty when required.

## Command families

Use subcommands when several verbs operate on one domain. A command with only
subcommands does not need a top-level `run` action:

```teal
commands.register(world, {
    name = "checkpoint",
    shortHelp = "inspect or jump between game checkpoints",
    examples = {"checkpoint list", "checkpoint goto foundry"},
    subcommands = {
        {
            name = "list",
            aliases = {"ls"},
            shortHelp = "list available checkpoints",
            run = function(_v: {string: any}, _parts: {string}): commands.Result
                local names = listCheckpoints()
                return {
                    ok = true,
                    popup = names,
                    data = {checkpoints = names},
                }
            end,
        },
        {
            name = "goto",
            shortHelp = "load a checkpoint",
            schema = {
                args = {
                    name = {required = true, help = "checkpoint name"},
                },
                positional = {"name"},
            },
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local ok = loadCheckpoint(v.name as string)
                return ok
                    and {ok = true, message = "loaded " .. tostring(v.name)}
                    or {ok = false, code = "unknown_checkpoint",
                        message = "unknown checkpoint " .. tostring(v.name)}
            end,
        },
    },
})
```

The debugger exposes `checkpoint list` and `checkpoint goto foundry`. MCP
projects them as `cmd_checkpoint_list` and `cmd_checkpoint_goto`. Aliases
are command-line conveniences and do not create additional MCP tools.

## Help, sections, and completion

Use these presentation fields to make commands discoverable:

| Field | Purpose |
| --- | --- |
| `shortHelp` | Required one-line description shown in help and MCP discovery |
| `examples` | Command lines displayed in the detailed debugger help popup |
| `aliases` | Alternate command-line names |
| `section` | Help group; omitted custom commands appear under `Custom` |
| `complete` | Built-in live completion sources by argument position |
| `outputSchema` | JSON Schema for the `data` payload; projected as the MCP tool's `outputSchema` (wrapped in the `{ok, result}` envelope) and rendered in the generated command reference |
| `metadata` | Free-form application metadata; the engine only interprets documented keys |

The one documented `metadata` key is `screenshots`: a list of
`{file = "path", alt = "alt text", docs = true}` entries. Entries with
`docs = true` render as images in the generated
[Command Reference](./debug-reference) (`file` is resolved from that page, so
use paths like `./assets/debug/select.png`). Other entries, and any other
`metadata` keys, ride along untouched in `cmd_describe` for your own tooling.

Completion positions start at `1` after the command or subcommand. Position `0`
applies to any later argument. Available sources are `components`, `marks`,
`targets`, `edittargets`, `bundles`, `systems`, `cameras`, and `commands`.
Comma-separate sources to combine them:

```teal
complete = {
    [1] = "targets",
    [2] = "components",
    [0] = "components",
}
```

Subcommand names complete automatically. Completion affects only the in-game
command line; MCP clients use the generated input schema.

## Choose the exposed surfaces

Commands are available to both surfaces by default:

```teal
mcp = false      -- overlay-only; no cmd_* MCP tool
overlay = false  -- MCP-only; hidden from debugger dispatch, help, and completion
```

Subcommands can set `mcp = false` independently. Use overlay-only commands for
host UI operations that make no sense remotely. Use MCP-only commands sparingly;
shared commands are easier for developers to discover and reproduce manually.

The `parts` argument contains tokenized command-line input for overlay calls,
but MCP dispatch does not reconstruct a command line. MCP-enabled actions should
use the parsed `v` values and must not depend on `parts`.

## Registration guidance

- Register after installing the debug plugin, normally during game setup.
- Prefer domain operations over thin wrappers around arbitrary Lua execution.
- Keep command names stable because they become MCP tool names.
- Return structured `data` for every fact an agent may need.
- Use subcommands for related verbs rather than many unrelated top-level names.
- Validate game-specific constraints in `run` and return stable failure codes.
- Avoid destructive defaults; require explicit arguments for loads, resets, or broad edits.
- Use shared selection and marks when the operation benefits from visible operator context.

See [Runtime introspection](./introspection) for the human-agent workflow and
[MCP tools](./mcp/tools#command-tools) for projected tool behavior.

