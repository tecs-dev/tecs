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
| `tecs info`        | Versions, project status, next step, and third-party licence notices |
| `tecs clean`       | Remove build output                                                  |
| `tecs completions` | Print a bash, zsh or fish completion script                          |
| `tecs help`        | Command overview, plus `--version` and `--quiet` as global flags     |

An `api` command that looks up framework and project symbols is planned for a later phase.

## What a project is

A directory containing `tecs.lua`, which returns a table. The file is both the marker and the manifest, and the
tool searches upward from the working directory for it, so it can be run from a subdirectory.

```lua
return {
    name = "hello",
    identifier = "com.example.hello",
    entry = "src/main.tl",
    assets = "assets",
    window = { title = "Hello", width = 1280, height = 960 },
}
```

Lua rather than JSON, for three reasons: no parser is needed, it takes comments, and it can be type-checked by the
same `tl` the tool already runs. Every field except `name` has a default.

`tlconfig.lua` is still written by `tecs new`, because `tl` needs it, but it is not the project marker.

The entry file compiles to `build/main.lua` and runs through the seam the host already has: `tecs --entry
build/main.lua`. It must return an application. See [getting started](/getting-started#the-entry-file).

## What it will not do

**It does not wrap CMake or Make.** CMake and Make build the engine and the tool. The tool builds games. Those are
different jobs with different inputs, so there is no second implementation and no shelling out to Make from a
user's machine. `make run` runs this repository's own demo, which is a test of the engine; `tecs run` builds and
runs a project. Both stay, and neither delegates to the other.

**It does not cross-compile.** A macOS host cannot produce a Windows game and the reverse is worse, since a Mach-O
needs an SDK whose licence forbids redistributing it. `tecs dist` packages for the platform it is running on, and
`tecs new` scaffolds a CI workflow with a three-OS matrix that runs it on each.

## Offline documentation

This site and the tool's offline reference are meant to be one content tree, not two. Every page here carries a
one-line `description:` in its frontmatter for exactly that reason: the descriptions label pages in the generated
`llms.txt` index and in an offline reference. `scripts/check-docs-descriptions.sh` gates it, and `make docs-check`
runs it.
