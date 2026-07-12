# Changelog

All notable changes to this project will be documented in this file.

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

When cutting a release, bump `VERSION` in `tecs_cli/cli.lua`, update this file,
and push the matching `v*` tag. CI publishes the self-contained `.love`
payload, launchers, and installers as GitHub release assets.

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
