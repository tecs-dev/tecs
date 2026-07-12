# Changelog

All notable changes to this project will be documented in this file.

When cutting a release, bump `VERSION` in `tecs_cli/cli.lua`, update this file,
and push the matching `v*` tag. CI publishes the self-contained `.love`
payload, launchers, and installers as GitHub release assets.

## [Unreleased]

### Added

- Post-publication smoke tests install the exact tagged GitHub Release and run
  a clean project build on Linux, macOS, and Windows.

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
