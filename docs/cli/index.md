---
description: "The tecs command line tool: project commands, offline reference, and MCP bridge"
outline: deep
---

# Tecs CLI

The `tecs` executable carries the engine, Teal toolchain, project template, and native services. It builds games
without LuaRocks or a compiler on the player's machine.

## Commands

| Command                         | What it does                                                          |
| ------------------------------- | --------------------------------------------------------------------- |
| `tecs new <directory>`          | Scaffold a working project; `--force` permits replacement             |
| `tecs check [paths]`            | Type-check against the engine's installed Teal types                  |
| `tecs format [--check] [paths]` | Format, or report files that are not formatted                        |
| `tecs test`                     | Compile and run the project's specs                                   |
| `tecs build`                    | Stage development assets without compiling source                     |
| `tecs dist`                     | Type-check, precompile, and stage the distributable build directory   |
| `tecs run [entry] [-- args...]` | Replace the CLI process with the selected source entry                |
| `tecs clean`                    | Remove the project's build directory                                  |
| `tecs info`                     | Print versions, pinned revisions, project details and package targets |
| `tecs docs [query]`             | Browse or search the offline reference carried with the tool          |
| `tecs mcp`                      | Connect an MCP client on stdio to a running game's HTTP endpoint      |
| `tecs completions <shell>`      | Print a Bash, Zsh, or Fish completion script                          |

Run `tecs help`, `tecs --help`, or `<command> --help` for the complete command reference. `tecs --version` prints
the CLI version.

A project is a directory containing `tecs.lua`. Project commands search upward for it, so they work from any
directory inside the project.

## Entries and arguments

With no operand, `tecs run` uses the `entry` configured in `tecs.lua`. A project-relative `.tl` or `.lua` path
selects another application entry for that invocation:

```bash
tecs run
tecs run src/editor.tl
tecs run tools/asset-preview.lua
tecs run src/main.tl -- --debug "save slot 2"
```

`tecs run` loads a Teal entry in memory. A Lua entry runs directly. Both receive the `tecs` global, can require source
or precompiled project modules, and must return `tecs.newApplication(...)`. Use `tecs dist` to type-check and compile
the project into `build/` for distribution.

Only operands after `--` become game arguments. The application receives them in `arg[1]` through `arg[#arg]`.

## Runtime Teal

The host can also load a `.tl` entry directly. It compiles the file in memory using the Teal toolchain carried with
Tecs, then makes required `.tl` modules available to the same Lua state. A `.lua` module still takes precedence, so
precompiled games keep their normal load path.

Invoke the host with `--entry` and set `TECS_TL_PATH` when module names are relative to a source root other than the
entry file's directory:

```sh
TECS_TL_PATH=src tecs --entry src/main.tl
```

`TECS_TL_PATH` accepts semicolon-separated roots. Runtime compilation does not type-check, so use `tecs check` as the
development gate and `tecs dist` for the usual precompiled release.

## Shell completion

`tecs completions bash|zsh|fish` prints a completion script generated from the command's own parser. Install it
for the shell that runs `tecs`:

```sh
# Bash: add this to ~/.bashrc.
eval "$(tecs completions bash)"

# Zsh: write _tecs into a directory on fpath.
tecs completions zsh > "${fpath[1]}/_tecs"

# Fish
tecs completions fish > ~/.config/fish/completions/tecs.fish
```

## Offline reference

`tecs docs` prints an index of API pages and guides. A short page name resolves
the page, while a fully-qualified public name resolves its generated reference:

```bash
tecs docs
tecs docs physics
tecs docs tecs.physics.attach
```

The single-file executable embeds this site's Markdown. `tecs docs` works outside a project and never uses the
network. An exact or unique match exits zero. A missing query exits one. An ambiguous query lists its matches and
exits two.

## MCP bridge

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

`tecs mcp` keeps stdout for MCP, discovers a running game's Streamable HTTP endpoint at `/mcp`, and proxies the
game's tools to the client. It writes diagnostics to stderr.

Discovery checks three loopback ports beginning at `TECS_MCP_PORT`, or `19999` by default. It retries after one
second while the game starts. After a restart or failed connection, the next operation scans the ports and
reconnects.
