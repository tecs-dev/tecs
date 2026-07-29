---
description: "The tecs command line tool: project commands and the MCP bridge to a running game"
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
| `tecs run`                      | Build, then replace the CLI process with the game                     |
| `tecs clean`                    | Remove the project's build directory                                  |
| `tecs info`                     | Print versions, pinned revisions, project details and package targets |
| `tecs mcp`                      | Connect an MCP client on stdio to a running game's HTTP endpoint      |

Clap parses and validates this surface. `tecs help`, `tecs --help` and command-specific `--help` render it, and
`tecs --version` prints the CLI version.

A project is a directory containing `tecs.lua`. Project commands search upward for it, so they work from any
directory inside the project.

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
