---
description: "The tecs CLI commands for creating, checking, building, running, testing, and packaging Tecs2D projects"
outline: deep
---

# Tecs CLI

The `tecs` command creates, checks, builds, tests, runs, and packages Tecs2D
projects. It is a self-contained tool: it bundles the Teal compiler, the
Tecs/Tecs2D sources, type declarations, and a busted test runner, and it
downloads a cached LÖVE 12 runtime on first use. No Lua, LuaRocks, or
compiler toolchain is required.

## Install

::: code-group

```bash [macOS]
brew install tecs-dev/tap/tecs-cli
```

```powershell [Windows]
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

```bash [Linux]
brew install tecs-dev/tap/tecs-cli
```

:::

Standalone installer scripts (`install.sh`, `install.ps1`) are published with
each [tecs-cli release](https://github.com/tecs-dev/tecs/releases/latest).

## Commands

| Command | Description |
| ------- | ----------- |
| `tecs new <dir>` | Create a project: sources, CI workflow, agent tooling, an example spec |
| `tecs check` | Type-check `src/` (`--json` for machine-readable diagnostics) |
| `tecs build` | Compile to `build/`; a running game hot-reloads the result |
| `tecs run` | Build, then launch the game with the cached LÖVE runtime |
| `tecs integ` | Run `spec/` with the bundled busted runner ([Integration Testing](/tecs2d/integration-testing)) |
| `tecs dist` | Package the game for players ([Packaging](/cli/packaging)) |
| `tecs mcp` | Serve the project to agent clients over stdio ([MCP Bridge](/cli/mcp)) |
| `tecs info` | Runtime versions and project status (`--json` for tooling) |
| `tecs agent` | List bundled agent guides or print one's installed path |
| `tecs completions` | Print a bash, zsh, or fish completion script |
| `tecs clean` | Remove `build/` |

## Project workflow

```sh
tecs new my-game
cd my-game
tecs run
```

`tecs new` generates a complete project: `src/main.tl` and `src/conf.tl`, a
Teal configuration, a GitHub Actions workflow that type-checks and builds on
Linux, macOS, and Windows, an integration spec, and agent tooling
(`AGENTS.md`, `CLAUDE.md`, MCP client configuration for Claude Code and
Codex, and a Claude Code skill for integration testing).

While the game is running, rerun `tecs build` after editing sources. A
successful build refreshes `build/.tecs-reload-stamp`, and the game
snapshots, restarts its Lua state, and restores automatically.

Every build writes a `build/tecs_buildinfo.lua` manifest recording the
project name, build timestamp, tool versions, and a `dev` flag. Games can
read it with `require("tecs2d.buildinfo")`.

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `TECS_DIR` | Use framework sources from a local Tecs checkout; `tecs dev` copies them into `src/vendor/` |
| `TECS_TEAL_DIR` | Load the Teal compiler from a local `teal-language/tl` checkout |
| `TECS_CACHE_DIR` | Override the LÖVE runtime cache directory |
| `TECS_MCP_PORT` | Port for the game's built-in MCP server (assigned automatically by test and agent harnesses) |

## Updating

Package-manager installs update normally (`brew upgrade tecs-cli`,
`scoop update tecs`). Each release publishes checksummed archives, and
post-publication smoke tests install the exact released assets on all three
platforms before the package repositories pick them up.
