# Changelog

All notable changes to the combined Tecs framework, Tecs2D runtime, and CLI
are documented here beginning with the monorepo release line. Standalone CLI
history through 0.10.9 remains in `cli/CHANGELOG.md`.

## [Unreleased]

### Fixed

- Release automation now resumes safely after a partially successful LuaRocks
  upload and provides a manual repair path for an existing release tag.

## [0.10.10] - 2026-07-19

### Changed

- Consolidated the Tecs CLI source, documentation, tests, and release
  automation into this repository under `cli/`.
- Framework, Tecs2D, CLI, GitHub assets, and LuaRocks releases now share one
  version and one `v*` release tag.
- Standalone installers and package-manager archives are now published from
  `tecs-dev/tecs` GitHub Releases.
