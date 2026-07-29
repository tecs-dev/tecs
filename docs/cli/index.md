---
description: "The tecs command line tool: project commands, offline reference, and MCP bridge"
outline: deep
---

# Tecs CLI

The command line tool is the primary way to use Tecs: install one file, run `tecs new`, and never install
LuaRocks or a compiler on a player's machine. The executable carries the engine, Teal toolchain, project template
and its Rust native services inside the same file.

## Commands

| Command                         | What it does                                                          |
| ------------------------------- | --------------------------------------------------------------------- |
| `tecs new <directory>`          | Scaffold a working project; `--force` permits replacement             |
| `tecs check [paths]`            | Type-check against the engine's installed Teal types                  |
| `tecs format [--check] [paths]` | Format, or report files that are not formatted                        |
| `tecs test`                     | Compile and run the project's specs                                   |
| `tecs build`                    | Compile sources and stage assets in the project's build directory     |
| `tecs run [entry] [-- args...]` | Build, then replace the CLI process with the selected game entry      |
| `tecs clean`                    | Remove the project's build directory                                  |
| `tecs info`                     | Print versions, pinned revisions, project details and package targets |
| `tecs docs [query]`             | Browse or search the offline reference carried with the tool          |
| `tecs mcp`                      | Connect an MCP client on stdio to a running game's HTTP endpoint      |

Clap parses and validates this surface. `tecs help`, `tecs --help` and command-specific `--help` render it, and
`tecs --version` prints the CLI version.

A project is a directory containing `tecs.lua`. Project commands search upward for it, so they work from any
directory inside the project.

## Run another entry

With no operand, `tecs run` uses the `entry` configured in `tecs.lua`. A project-relative `.tl` or `.lua` path
selects another application entry for that invocation:

```bash
tecs run
tecs run src/editor.tl
tecs run tools/asset-preview.lua
tecs run src/main.tl -- --debug "save slot 2"
```

A Teal entry is type-checked and compiled with the project. It may live under the configured source directory or
elsewhere inside the project. A Lua entry runs directly after the project has been built. Both entry forms receive
the `tecs` global and can require the project's compiled modules, and both must return the application created by
`tecs.newApplication`.

Only operands after `--` are game arguments. The application sees them as `arg[1]` through `arg[#arg]`; the CLI
command, selected entry and host bootstrap are not present in that table. Use the separator even when the first
game argument does not begin with a hyphen, so the command remains unambiguous.

## Offline reference

`tecs docs` prints an index of API pages and guides. A short page name resolves
the page, while a fully-qualified public name resolves its generated reference:

```bash
tecs docs
tecs docs physics
tecs docs tecs.physics.attach
```

The reference is staged from this site's Markdown and embedded in the
single-file executable with the rest of its content. It works outside a
project and does not use the network. An exact or unique match exits zero. An
unknown query exits one with the command that lists available topics, and an
ambiguous query lists its matches and exits two so scripts can distinguish it
from a missing reference.

## Connect an agent to a running game

Configure the agent to start the single-file CLI as an MCP stdio server:

```json
{
  "mcpServers": {
    "tecs": {
      "command": "tecs",
      "args": ["mcp"]
    }
  }
}
```

`tecs mcp` uses the official RMCP implementation at both ends. It keeps stdout exclusively for MCP, discovers a
running game's Streamable HTTP endpoint at `/mcp`, and proxies the game's current tools to the invoking agent.
Diagnostics go to stderr.

Discovery checks three loopback ports beginning at `TECS_MCP_PORT`, or `19999` when the variable is absent or
invalid: `19999`, `20000` and `20001` by default. It retries after one second when the game is still starting. If
the game restarts or the selected connection fails, the next operation drops the stale session, scans those ports
again and reconnects.
