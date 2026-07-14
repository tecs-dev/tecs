# Tecs Game

Created with `tecs new`.

## Tecs CLI

Every workflow runs through the [Tecs CLI](https://github.com/tecs-dev/tecs-cli).
If it is not installed:

```sh
# macOS and Linux
brew install tecs-dev/tap/tecs-cli
```

```powershell
# Windows
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

Standalone installers are on the
[tecs-cli releases page](https://github.com/tecs-dev/tecs-cli/releases/latest).

## Commands

```sh
tecs check    # type-check src/
tecs run      # build and launch the game
tecs build    # compile to build/ (hot-reloads a running game)
tecs integ    # run spec/ against the built game
tecs dist     # package a .love, macOS app bundle, and Windows executable
tecs docs     # print the bundled Tecs reference (see below)
```

`tecs docs` is the reference for building with Tecs — the CLI workflow,
integration testing, rendering, components/systems/queries, input, Teal
gotchas, and style. Run `tecs docs` to list the topics and `tecs docs <topic>`
to read one. It ships with the CLI, so it always matches the installed `tecs`.

The hello demo enables the MCP server and runtime debugger; both disable
themselves automatically in `tecs dist` builds. Press `Ctrl+/` in the running
game to toggle the debugger. Agent tooling lives in `AGENTS.md` (which agents
read automatically), `.mcp.json`, and `.codex/config.toml`; all of it points
back to `tecs docs`.
