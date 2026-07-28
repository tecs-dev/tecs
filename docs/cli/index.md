---
description: "The planned tecs command line tool: its commands, what a project is, and what it will not do"
outline: deep
---

# Tecs CLI

::: warning Not built yet
The `tecs` command does not exist on this branch. This page records the shape it is planned to take so that
nothing else in the site has to pretend it is already there. Everything below is a plan, not a reference, and the
commands cannot be run today.

Build and run through `make` in the meantime. See [getting started](/getting-started).
:::

The command line tool is meant to be the primary way to use Tecs: install one file, run `tecs new`, and never see
CMake, Make, LuaRocks or a C compiler. It links nothing on a user's machine and needs no toolchain there.

## The planned commands

| Command            | What it does                                                         |
| ------------------ | -------------------------------------------------------------------- |
| `tecs new`         | Scaffold a working project from a template carried inside the binary |
| `tecs build`       | Compile the project's Teal, copy assets, build a shader pack         |
| `tecs run`         | Build, then run the project's entry through the host                 |
| `tecs check`       | Type-check the project against the installed Teal tree               |
| `tecs test`        | Compile and run the project's specs                                  |
| `tecs dist`        | Package the game for players, for the host platform only             |
| `tecs mcp`         | Serve the debug server to agent clients over stdio                   |
| `tecs call`        | Call a tool on a running game                                        |
| `tecs info`        | Versions, project status, next step, and third-party license notices |
| `tecs clean`       | Remove build output                                                  |
| `tecs completions` | Print a bash, zsh or fish completion script                          |
| `tecs help`        | Command overview, plus `--version` and `--quiet` as global flags     |

An `api` command that looks up framework and project symbols is planned for a later phase.
