# Changelog

All notable changes to this project will be documented in this file.

When cutting a release, bump the version in `tecs_cli/cli.lua` (`VERSION`) and
the rockspec filename, `version`, and source `tag` together. When the bump
lands on main, CI pushes the matching `v*` git tag and uploads the rock to
luarocks.org (see `.github/workflows/release-rock.yml`).

## [Unreleased]

### Added

- Initial release.
