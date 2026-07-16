# Changelog

All notable changes to this project will be documented in this file.

When cutting a release, bump `VERSION` in `tecs_cli/cli.lua`, update this file,
and push the matching `v*` tag. CI publishes the self-contained `.love`
payload, launchers, and installers as GitHub release assets.

## [Unreleased]

### Fixed

- The MCP bridge's `tools/list` no longer corrupts empty `{}` schemas into `[]`
  (strict clients like Claude Code rejected the whole list, so no tecs tools
  ever appeared); the user-level tool cache is now version-keyed so upgrades
  drop poisoned copies.

### Added

- `tecs call <tool> ['<json>']` / `tecs call --list`: built-in MCP client for
  the running game. `tecs info --keys` lists its named context keys.
- Named context keys (`tecs.newKey("game.state")`, `tecs.findKey`/`listKeys`),
  `cmd_resources` value reads, `cmd_lua_modules`/`cmd_lua_exports`, and a
  `modules()` helper in the `run_lua` sandbox.
- `cmd_input_tape`: schedule literal LÖVE events on exact gameplay frames for
  deterministic input verification; `cmd_step` echoes the scheduled window.
- `cmd_rewind_replay`: rewind records inputs + per-frame dt while running and
  replays deterministically from any ring entry; snapshots now carry
  `love.math` random state.
- Stale-process detection: `ping` reports the running build, and a game that
  cannot bind an already-served MCP port logs an ERROR naming the conflict.
- `tecs api` resolves type aliases to their terminal type (`tecs api
  tecs.System` shows the `function(dt, world)` signature, not a dead-end
  "type alias to ..."), and resolves `tecs.builtins` (Transform et al);
  `check` hints
  `math.floor` on integer-index errors.
- `start_game '{"frozen":true}'` boots the game with the freeze already held
  (inspectable at frame zero; `cmd_freeze on=false` releases it).
- `tecs new` stamps the LÖVE identity/title with the project name, so games no
  longer share a save dir (stale debugger artifacts bled between projects).
- `fixture.eventually` now polls until truthy, not merely non-nil — a
  `return cond` poll no longer fails on its first `false`.
- Reworked agent guidance: canonical freeze/tape/step verification loop,
  staging + goal ladder, time-travel workflow, and a world-space template
  gameplay layer with an idle tween.

## [0.10.7] - 2026-07-15

### Added

- `tecs api <symbol>` looks up exact API signatures over a type index, as both a
  CLI command and an MCP bridge tool sharing one lookup core. Two tiers merge at
  query time, both generated at runtime by the CLI's bundled type extractor
  (`tecs_cli/apidocs.lua`, driving the vendored Teal compiler's type API) with no
  build or running game: the framework surface (extracted from the vendored
  framework sources and cached at the user level, keyed by CLI version, so a
  repeat call is instant) and a dynamic overlay of the project's own `src/`
  symbols, type-checked on demand and cached under `build/api-index.json`.
  Addressing mirrors Teal: `tecs api`
  lists modules, `tecs api <module>` lists its symbols, `tecs api <module>.<Type>`
  renders a `record` block, `tecs api <Type>:<method>` prints one method, and a
  bare symbol prefers the project's own symbols — a framework symbol with the
  same name is listed as `also matches` instead of silently winning. Every hit
  opens with its canonical module-qualified address. `--json`
  returns the structured records; `--fields <keys>` projects only the requested
  keys to save tokens; multiple symbol arguments (or the MCP tool's `queries`
  array) fan out and never short-circuit — a miss reports module-qualified
  `did you mean` suggestions usable verbatim as the next query. Like `check`,
  this is toolchain-class: it works the instant a project is generated, before
  `build` or `start_game`, and outside a project the framework tier still
  answers (staged under the user data dir, never into the cwd). Type errors in
  a project module do not block its symbols; a module that fails to parse is
  skipped with a note, and if the whole overlay build fails the framework tier
  still resolves.
- Check diagnostics now carry a `tecs api` remediation hint for unknown-field
  (`invalid key` / `cannot index key`), wrong-arity, and argument-type errors:
  the hint names the exact lookup for the offending record or call target (e.g.
  ``tecs api world:getMut`` for a bad `world:getMutt` call), so the fix is one
  cheap command away at the moment the error is read. Attached wherever the
  structured diagnostics flow: `tecs check --json` and the MCP `check` tool.

### Removed

- The generated `tecs2d/api/*` doc pages (0.10.5): `tecs api` supersedes them.
  The type extractor behind it now lives in this repo (`tecs_cli/apidocs.lua`).

## [0.10.6] - 2026-07-14

### Changed

- The `run_lua` sandbox now also strips love2d escape hatches: `love.thread`
  (spawns threads with a full stdlib), `love.filesystem.load` (runs Lua under
  the real globals), `love.filesystem.mount`/`mountFullPath`/`unmount` (reach
  arbitrary host paths), the `love.filesystem` write functions,
  `love.system.openURL`, and `love.event.quit`. Ordinary love2d APIs
  (rendering, `love.filesystem.read`, input) stay available, and the game's own
  systems keep the real `love`. Requires the bundled framework from this release.

## [0.10.5] - 2026-07-14

### Added

- `tecs docs` now includes a generated API signature reference under
  `tecs2d/api/` (`gfx`, `world`, `input`, `events`): real argument and return
  types, optionality, generic constraints, constructors, and methods, extracted
  from the framework's Teal type definitions. Agents can pull exact signatures
  (e.g. `tecs docs tecs2d/api/gfx`) instead of reading vendored sources.

## [0.10.4] - 2026-07-14

### Fixed

- New projects ship a `.claude/settings.json` that pre-approves their own
  `tecs` MCP server (`enabledMcpjsonServers`), so `tecs mcp` connects with no
  interactive approval once the folder is trusted. Without it, Claude Code left
  the project's MCP server unapproved and its tools never appeared, forcing
  agents onto a hand-rolled raw-HTTP client.

### Changed

- The `tecs-cli` skill documents the `run_lua` result envelope
  (`{returned, values}`, values indexed in return order) and that `run_lua` is
  sandboxed (love2d and the ECS world are in scope; the filesystem, network,
  and module loading are blocked). Requires the bundled framework from this
  release.

## [0.10.3] - 2026-07-14

### Fixed

- The `tecs mcp` bridge front-loads a bundled default tool manifest (every
  kernel and `cmd_*` tool, generated in the Tecs repo and vendored at build
  time) at initialize, so even a machine's first-ever `start_game` finds the
  advertised tool set unchanged and fires no `tools/list_changed`. Previously
  only runs after the first `start_game` were covered by the user-level cache;
  the first run still swapped ~15 tools for ~140 and could make some clients
  drop the `tecs` tools.

## [0.10.2] - 2026-07-14

### Changed

- `run_lua` returns values as JSON by default (pass `lua = true` for the Lua
  `tostring` form), so structured reads no longer need hand-built delimited
  strings. Requires the bundled framework from this release.
- The MCP `build` tool includes hot-reload tips in its response when the game is
  running, pointing at `restart_game` / snapshot handlers for changes that a
  reload appears to drop.

### Added

- Entry-point guidance in the bundled skills: `tecs-conventions` covers the
  centered-default `Pivot`, same-layer draw order, and that hot reload skips
  `Startup` systems; the `tecs-cli` skill documents the `send_love_event` shape,
  `run_lua` JSON returns, iterating with `world:query():iter()` (no `world:each`),
  preferring ECS/data reads and clipped screenshots over full frames, and
  attaching to the game's HTTP MCP if the bridge tools disconnect.

## [0.10.1] - 2026-07-14

### Added

- `tecs check` diagnostics can carry a remediation slot (`hint` + a `tecs docs`
  page in `docs`), surfaced at the moment of the error and through the MCP
  `check` tool. Piloted on the "event used as a value" mistake
  (`world:observe(0, tecs2d.MousePressed, ...)`), which points at
  `require("tecs2d.events")`.
- The `tecs-conventions` skill gained a "Gameplay & rendering pitfalls" section
  (draw order within a layer, Transform's `(x, y, z, layer)` signature, events
  as values, pointer→coordinate conversion, hot-reload state), each with a
  `tecs docs` back-reference. The starter `main.tl` now spells out the Transform
  signature and same-layer draw-order rule inline.

### Changed

- The `tecs mcp` bridge front-loads the game's full tool set at initialize
  (cached from the first `start_game`) and only fires `tools/list_changed` when
  the set actually changes, so a large post-`start_game` tool-list swap no longer
  makes some clients drop the `tecs` tools.
- New projects' CI uses the `tecs-dev/setup-tecs` action to install the CLI and
  cache the LÖVE runtime, instead of inlining per-OS Homebrew/Scoop/installer
  steps. Old projects that reference `@v1` track install-channel fixes
  automatically. Requires the `tecs-dev/setup-tecs` repo tagged `v1`.

## [0.10.0] - 2026-07-14

### Added

- `tecs docs` command: an offline mirror of the framework documentation,
  vendored from the Tecs checkout at build time and versioned with the installed
  CLI. `tecs docs` prints the page index (titled, described tree); `tecs docs
  <page>` prints one page by its index path (e.g. `tecs2d/rendering/shapes`);
  `tecs docs --full` prints every page; `tecs docs --json` prints the index as
  `{id, title, description}`. Agents can scan the index and pull the exact page
  they need instead of reading vendored sources under `src/vendor/`.
- A `tecs-conventions` Claude Code skill covering idiomatic Tecs/Teal
  conventions and the pitfalls that break `tecs check`, alongside the existing
  `tecs-cli` and `integration-testing` skills. Procedural guidance ships as
  skills (surfaced automatically while you work); `tecs docs` is the pulled
  reference.

## [0.9.0] - 2026-07-13

### Removed

- `tecs add`, `tecs remove`, and `tecs update`. Vendor rocks with LuaRocks
  instead: `luarocks install --tree src/vendor --lua-version=5.1 <rock>`
  (see `tecs help`).

### Added

- New projects include a `tecs-cli` Claude Code skill covering the command
  workflow and LuaRocks-based dependencies.

## [0.8.0] - 2026-07-13

### Added

- `tecs mcp` serves the project over MCP on stdio: `check`, `build`, `integ`,
  and `dist` as tools, game lifecycle management (`start_game`, `stop_game`,
  `restart_game`, `game_status`, `game_logs`), and a proxy to the running
  game's own MCP tools. Generated `.mcp.json` and `.codex/config.toml` now
  use it instead of the raw HTTP endpoint.

## [0.7.1] - 2026-07-12

### Changed

- Generated project READMEs document CLI installation (Homebrew, Scoop,
  standalone installers) and the full command set, and the bundled agent
  guide tells agents how to install a missing CLI.

## [0.7.0] - 2026-07-12

### Added

- `tecs build` writes a `build/tecs_buildinfo.lua` manifest (project name,
  build timestamp, tool versions, `dev` flag) and `tecs dist` packages it
  with `dev = false`. The MCP server and debugger read it through the new
  `tecs2d.buildinfo` module and disable themselves in distributed builds
  unless constructed with `enableInDist = true`.

## [0.6.0] - 2026-07-12

### Added

- `tecs dist` packages the built game into `dist/`: a `.love` file, a fused
  Windows executable with LÖVE's DLLs (buildable on any host), and a macOS
  app bundle with a patched Info.plist (macOS/Linux hosts). Runtimes come
  from the launcher cache or a one-time download.

## [0.5.0] - 2026-07-12

### Added

- `tecs new` generates a Claude Code skill
  (`.claude/skills/integration-testing/SKILL.md`) covering how to write and
  run integration specs with `tecs integ`.

## [0.4.0] - 2026-07-12

### Added

- `tecs integ` compiles `spec/**/*.tl` and runs it with a bundled busted
  runner (no busted or LuaRocks installation). `*_lovespec.tl` specs launch
  the built game under real LÖVE via `tecs2d.testing.fixture` and drive it
  over MCP. New projects include `spec/game_lovespec.tl` and run `tecs integ`
  on macOS in their generated CI.

## [0.3.0] - 2026-07-12

### Added

- `tecs new` generates a GitHub Actions workflow that type-checks and builds
  the project on Linux, macOS, and Windows using the published CLI
  (Homebrew, Scoop, or the installer script per platform).
- `tecs new` generates agent tooling: `AGENTS.md`/`CLAUDE.md` from the bundled
  guide, plus MCP client configuration for Claude Code (`.mcp.json`) and
  Codex (`.codex/config.toml`) pointing at the game's MCP server.

### Changed

- The vendored-rock manifest moved from `src/vendor/rocks.lua` to
  `tecs-rocks.lua` at the project root so it survives gitignored vendor
  trees; the old location is still read. `tecs check` and `tecs build` now
  restore missing recorded rocks at their pinned versions, so fresh clones
  build without re-running `tecs add`.

### Fixed

- Fish completion scripts now complete positional argument choices (e.g. the
  shells for `tecs completions` and the actions for `tecs agent`), and the
  docs give per-shell install instructions.

## [0.2.0] - 2026-07-12

### Added

- Post-publication smoke tests install the exact tagged GitHub Release and run
  a clean project build on Linux, macOS, and Windows.
- `tecs check --json` and `tecs info --json` print machine-readable output,
  serialized with the framework's `tecs.utils.json` module.
- `tecs agent list` and `tecs agent path <name>` expose the agent guides
  bundled with the CLI for AI coding tools.
- `tecs completions bash|zsh|fish` prints shell completion scripts.
- `TECS_TEAL_DIR` loads the Teal compiler from a local `teal-language/tl`
  checkout instead of the embedded copy.
- `tecs add`, `tecs remove`, and `tecs update` vendor pure-Lua rocks (plus
  dependencies, licenses, and `<rock>-tl-type` Teal declarations) from
  luarocks.org into `src/vendor/` without a LuaRocks installation.

### Fixed

- The macOS/Linux launcher resolves symlinks before locating its payload, so
  package managers can link `tecs` onto `PATH`.

### Distribution

- Releases additionally publish versioned archives for package managers:
  `tecs-cli-<version>.tar.gz` (launcher, payload, license) and
  `tecs-cli-<version>-windows.zip`, both covered by `SHA256SUMS` and verified
  by the post-publication smoke tests.

## [0.1.0] - 2026-07-12

### Added

- Self-contained `tecs-cli.love` application running on the same LÖVE 12 and
  LuaJIT runtime used by Tecs2D games.
- Headless macOS, Linux, and Windows launchers that download and cache LÖVE 12
  without requiring Lua, LuaRocks, or a compiler toolchain.
- `new`, `check`, `build`, `run`, `clean`, `dev`, and `info` commands.
- Embedded Teal compiler, Tecs/Tecs2D sources, type declarations, starter
  template, built-in font assets, and third-party license notices.
- Make targets for building, testing, and refreshing embedded dependencies.
- Cross-platform cold-cache CI and tag-triggered GitHub Releases.

### Distribution

- Releases publish the `.love` payload, platform launchers, and install scripts
  with checksums as GitHub Release assets.
- The CLI is licensed under MIT and is not distributed as a LuaRock.
